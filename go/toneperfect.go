// Package toneperfect is a client for the TonePerfect pronunciation assessment API
// (https://api.toneperfect.app). Standard library only.
//
// It wraps the two public endpoints:
//
//	GET  /v1/capabilities   -> languages served, limits, model version (no key needed)
//	POST /v1/assess         -> score one scripted recording
//
// Accounts, API keys and billing are managed in the web dashboard
// (https://api.toneperfect.app/dashboard); those routes are session-based and are
// deliberately not wrapped. Full reference: https://api.toneperfect.app/docs
//
//	client := toneperfect.New("tp_live_...") // or "" to read TONEPERFECT_API_KEY
//	res, err := client.AssessFile(ctx, "hello.wav", toneperfect.AssessParams{Text: "你好", Language: "zh-CN"})
package toneperfect

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/textproto"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Version of this client.
const Version = "0.1.0"

// DefaultBaseURL is the public API origin. It sits behind a proxy with a 26-second request
// timeout; if your assessments run longer, ask nik@toneperfect.app for the direct gateway address.
const DefaultBaseURL = "https://api.toneperfect.app"

// Tasks accepted by POST /v1/assess.
var Tasks = []string{"general", "connected_speech", "isolated_word"}

// Decisions are the values of "decision" on words and phones. review / uncertain / no_correction
// are the feedback decisions; unassessable, partial and legacy_correction also occur. Treat
// unknown values as "no decision".
var Decisions = []string{"review", "uncertain", "no_correction", "unassessable", "partial", "legacy_correction"}

// RetrySameKeyCodes are error codes after which the SAME Idempotency-Key must be retried:
// nothing was finalized.
var RetrySameKeyCodes = map[string]bool{
	"rate_limit": true, "account_busy": true, "gateway_busy": true, "decoder_busy": true,
	"audio_decoder_unavailable": true, "upload_timeout": true, "request_pending": true,
	"timeout": true, "network_error": true,
}

// NewKeyCodes are error codes that mean the key is spent: start a new attempt with a new key.
var NewKeyCodes = map[string]bool{"idempotency_expired": true, "idempotency_conflict": true}

var idempotencyRE = regexp.MustCompile(`^[A-Za-z0-9_.:-]{8,128}$`)

// NewIdempotencyKey returns a fresh key for one recording attempt. Keep the same key while the
// result is unknown or pending (Error.Retryable); use a new key for a different attempt or after
// a definite failed response (Error.NeedsNewKey). Never generate one inside an automatic retry loop.
func NewIdempotencyKey(prefix string) (string, error) {
	if prefix == "" {
		prefix = "tp"
	}
	b := make([]byte, 18)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	key := prefix + "-" + hex.EncodeToString(b[:16]) + "-" + hex.EncodeToString(b[16:])
	if !idempotencyRE.MatchString(key) {
		return "", errors.New("toneperfect: prefix must be letters, digits, dots, dashes, underscores or colons")
	}
	return key, nil
}

// ErrorKind classifies an Error the same way the other SDKs use exception classes.
type ErrorKind string

const (
	KindAuthentication  ErrorKind = "AuthenticationError"  // 401 invalid_api_key
	KindPaymentRequired ErrorKind = "PaymentRequiredError" // 402 subscription_required, insufficient_credits, payment_balance_due (nothing charged)
	KindRateLimit       ErrorKind = "RateLimitError"       // 429 rate_limit (60/min) or account_busy (2 running)
	KindValidation      ErrorKind = "ValidationError"      // other 4xx: fix the request
	KindServer          ErrorKind = "ServerError"          // 5xx
	KindAPIConnection   ErrorKind = "APIConnectionError"   // transport failure, Status 0: timeout or network_error
	KindOther           ErrorKind = "TonePerfectError"
)

// Sentinel errors for errors.Is: errors.Is(err, toneperfect.ErrPaymentRequired).
var (
	ErrAuthentication  = errors.New("toneperfect: authentication error")
	ErrPaymentRequired = errors.New("toneperfect: payment required")
	ErrRateLimit       = errors.New("toneperfect: rate limited")
	ErrValidation      = errors.New("toneperfect: validation error")
	ErrServer          = errors.New("toneperfect: server error")
	ErrAPIConnection   = errors.New("toneperfect: connection error")
)

// Error is returned for any non-2xx response and for transport failures (Status 0).
//
// Code and Message come from the API's "error" object. A non-JSON body (for example an HTML 502
// from a proxy) gets Code "http_error" and the raw text as the message. What to do next is
// decided by the BODY, not the status:
//   - Finalized: the failure was stored under this Idempotency-Key (body carries a req_… id and
//     billing with credits 0). The same key replays it for 24 h, so NeedsNewKey is true.
//   - Retryable: nothing was finalized; retry later with the SAME key.
//   - anything else (invalid_api_key, insufficient_credits, invalid_audio, …) needs a fix on your side.
type Error struct {
	Status     int
	Code       string
	Message    string
	RequestID  string
	RetryAfter *float64
	Body       map[string]any
	// ID is the req_… result id when the failure was finalized under your Idempotency-Key.
	ID      string
	Billing map[string]any
}

func newError(status int, code, message, requestID string, retryAfter *float64, body map[string]any) *Error {
	e := &Error{Status: status, Code: code, Message: message, RequestID: requestID, RetryAfter: retryAfter, Body: body}
	if e.Body == nil {
		e.Body = map[string]any{}
	}
	if id, ok := e.Body["id"].(string); ok {
		e.ID = id
	}
	if b, ok := e.Body["billing"].(map[string]any); ok {
		e.Billing = b
	}
	return e
}

func (e *Error) Error() string { return fmt.Sprintf("%d %s: %s", e.Status, e.Code, e.Message) }

// Kind maps the HTTP status to the error class used by the other SDKs.
func (e *Error) Kind() ErrorKind {
	switch {
	case e.Status == 0:
		return KindAPIConnection
	case e.Status == 401:
		return KindAuthentication
	case e.Status == 402:
		return KindPaymentRequired
	case e.Status == 429:
		return KindRateLimit
	case e.Status >= 500:
		return KindServer
	case e.Status >= 400:
		return KindValidation
	}
	return KindOther
}

// Is lets errors.Is match the sentinel errors (ErrPaymentRequired, …).
func (e *Error) Is(target error) bool {
	switch target {
	case ErrAuthentication:
		return e.Kind() == KindAuthentication
	case ErrPaymentRequired:
		return e.Kind() == KindPaymentRequired
	case ErrRateLimit:
		return e.Kind() == KindRateLimit
	case ErrValidation:
		return e.Kind() == KindValidation
	case ErrServer:
		return e.Kind() == KindServer
	case ErrAPIConnection:
		return e.Kind() == KindAPIConnection
	}
	return false
}

// Finalized reports that the failure is a stored result for this key (id + billing present).
func (e *Error) Finalized() bool { return e.ID != "" && e.Billing != nil }

// NeedsNewKey: start a new attempt with a new Idempotency-Key; the old key replays this response.
func (e *Error) NeedsNewKey() bool { return e.Finalized() || NewKeyCodes[e.Code] }

// Retryable: retry later with the SAME Idempotency-Key, nothing was finalized.
func (e *Error) Retryable() bool {
	if e.Finalized() || NewKeyCodes[e.Code] {
		return false
	}
	if RetrySameKeyCodes[e.Code] {
		return true
	}
	switch e.Status {
	case 408, 429, 502, 503, 504:
		return true
	}
	return false
}

// Assessment is one POST /v1/assess result. Data is the full JSON body exactly as returned.
type Assessment struct {
	Data      map[string]any
	Raw       []byte
	Status    int
	Header    http.Header
	RequestID string
	// Replayed is true when the result was served from a previous identical request (not charged again).
	Replayed bool
}

// Assessable is false when the audio could not be meaningfully scored (silence, wrong sentence,
// unreadable). Never show an unassessable result as a score of zero; see Reason.
func (a *Assessment) Assessable() bool { v, _ := a.Data["assessable"].(bool); return v }

// Reason explains why a result is not assessable ("" when absent).
func (a *Assessment) Reason() string { v, _ := a.Data["reason"].(string); return v }

// Scores holds 0-100 display grades per dimension; a nil value means the dimension is not
// supported by this pack.
func (a *Assessment) Scores() map[string]*float64 {
	out := map[string]*float64{}
	m, _ := a.Data["scores"].(map[string]any)
	for k, v := range m {
		if f, ok := v.(float64); ok {
			f := f
			out[k] = &f
		} else {
			out[k] = nil
		}
	}
	return out
}

// Overall is scores.overall, nil when absent or null.
func (a *Assessment) Overall() *float64 { return a.Scores()["overall"] }

// Words are the per word/character rows: score, start_ms/end_ms and phones (expected, heard,
// score, decision; see Decisions).
func (a *Assessment) Words() []map[string]any {
	list, _ := a.Data["words"].([]any)
	out := make([]map[string]any, 0, len(list))
	for _, w := range list {
		if m, ok := w.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

// Billing is {"credits": charged, "balance_credits": remaining}; failed or unassessable requests charge 0.
func (a *Assessment) Billing() map[string]any {
	m, _ := a.Data["billing"].(map[string]any)
	if m == nil {
		return map[string]any{}
	}
	return m
}

// ModelVersion is the model_version field ("" when absent).
func (a *Assessment) ModelVersion() string { v, _ := a.Data["model_version"].(string); return v }

// ID is the result id (req_…), also returned in the X-Request-Id header.
func (a *Assessment) ID() string {
	if v, ok := a.Data["id"].(string); ok && v != "" {
		return v
	}
	return a.RequestID
}

// Decode unmarshals the raw response body into v (for typed structs of your own).
func (a *Assessment) Decode(v any) error { return json.Unmarshal(a.Raw, v) }

// AssessParams are the fields of one POST /v1/assess.
type AssessParams struct {
	// Text the learner was asked to read. Required unless Pinyin is given (Mandarin only).
	Text string
	// Language is a locale such as zh-CN, en-US, fr-FR (default zh-CN). See Capabilities.
	Language string
	// Pinyin is an explicit Mandarin reading with numbered tones, e.g. "ni3 hao3".
	Pinyin string
	// Task is general (default), connected_speech or isolated_word.
	Task string
	// IdempotencyKey is unique per recording attempt; generated when empty. If a network error
	// prevents you from receiving a result, retry with the same key and identical inputs: a
	// completed request is returned without charging again, including a completed failure.
	IdempotencyKey string
	// Filename sent with the audio part (default recording.wav).
	Filename string
	// ContentType of the audio part (default application/octet-stream).
	ContentType string
}

// Client talks to https://api.toneperfect.app. The zero value is not usable; call New.
type Client struct {
	APIKey     string
	BaseURL    string
	HTTPClient *http.Client
	UserAgent  string
}

// Option customises a Client.
type Option func(*Client)

// WithBaseURL overrides the API origin.
func WithBaseURL(u string) Option { return func(c *Client) { c.BaseURL = strings.TrimRight(u, "/") } }

// WithHTTPClient sets the http.Client (timeouts, proxies, tests).
func WithHTTPClient(h *http.Client) Option { return func(c *Client) { c.HTTPClient = h } }

// WithTimeout sets the per-request timeout (default 90 s).
func WithTimeout(d time.Duration) Option {
	return func(c *Client) { c.HTTPClient = &http.Client{Timeout: d} }
}

// WithUserAgent overrides the User-Agent header.
func WithUserAgent(ua string) Option { return func(c *Client) { c.UserAgent = ua } }

// New returns a client. An empty apiKey falls back to $TONEPERFECT_API_KEY.
func New(apiKey string, opts ...Option) *Client {
	if apiKey == "" {
		apiKey = os.Getenv("TONEPERFECT_API_KEY")
	}
	c := &Client{
		APIKey:     apiKey,
		BaseURL:    DefaultBaseURL,
		HTTPClient: &http.Client{Timeout: 90 * time.Second},
		UserAgent:  "toneperfect-go/" + Version,
	}
	for _, o := range opts {
		o(c)
	}
	return c
}

// Capabilities calls GET /v1/capabilities: languages (locale, status, dimensions, limitations),
// limits, model_version. No API key required.
func (c *Client) Capabilities(ctx context.Context) (map[string]any, error) {
	status, header, raw, err := c.send(ctx, http.MethodGet, "/v1/capabilities", nil, nil)
	if err != nil {
		return nil, err
	}
	return parseJSON(status, header, raw)
}

// AssessFile reads the recording from path and calls Assess.
func (c *Client) AssessFile(ctx context.Context, path string, p AssessParams) (*Assessment, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return c.Assess(ctx, data, p)
}

// Assess calls POST /v1/assess: score one scripted recording (up to 30 s and 10 MB; WAV, MP3,
// M4A, Ogg, WebM) against its reference text. Every non-2xx status returns *Error.
func (c *Client) Assess(ctx context.Context, audio []byte, p AssessParams) (*Assessment, error) {
	if c.APIKey == "" {
		return nil, newError(401, "invalid_api_key", "Set the API key or the TONEPERFECT_API_KEY environment variable.", "", nil, nil)
	}
	if p.Task == "" {
		p.Task = "general"
	}
	validTask := false
	for _, t := range Tasks {
		validTask = validTask || t == p.Task
	}
	if !validTask {
		return nil, fmt.Errorf("toneperfect: task must be one of %s", strings.Join(Tasks, ", "))
	}
	if p.Text == "" && p.Pinyin == "" {
		return nil, errors.New("toneperfect: provide Text (or Pinyin for Mandarin)")
	}
	if p.Language == "" {
		p.Language = "zh-CN"
	}
	if p.Filename == "" {
		p.Filename = "recording.wav"
	}
	if p.ContentType == "" {
		p.ContentType = "application/octet-stream"
	}
	key := p.IdempotencyKey
	if key == "" {
		var err error
		if key, err = NewIdempotencyKey("tp"); err != nil {
			return nil, err
		}
	} else if !idempotencyRE.MatchString(key) {
		return nil, errors.New("toneperfect: IdempotencyKey must be 8-128 letters, digits, dots, dashes, underscores or colons")
	}

	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	fields := [][2]string{{"language", p.Language}, {"task", p.Task}}
	if p.Text != "" {
		fields = append(fields, [2]string{"text", p.Text})
	}
	if p.Pinyin != "" {
		fields = append(fields, [2]string{"pinyin", p.Pinyin})
	}
	for _, f := range fields {
		if err := w.WriteField(f[0], f[1]); err != nil {
			return nil, err
		}
	}
	h := make(textproto.MIMEHeader)
	safe := strings.NewReplacer(`"`, "_", "\r", "", "\n", "").Replace(p.Filename)
	h.Set("Content-Disposition", fmt.Sprintf(`form-data; name="audio"; filename="%s"`, safe))
	h.Set("Content-Type", p.ContentType)
	part, err := w.CreatePart(h)
	if err != nil {
		return nil, err
	}
	if _, err := part.Write(audio); err != nil {
		return nil, err
	}
	if err := w.Close(); err != nil {
		return nil, err
	}

	headers := map[string]string{
		"Authorization":   "Bearer " + c.APIKey,
		"Idempotency-Key": key,
		"Content-Type":    w.FormDataContentType(),
	}
	status, header, raw, err := c.send(ctx, http.MethodPost, "/v1/assess", buf.Bytes(), headers)
	if err != nil {
		return nil, err
	}
	data, err := parseJSON(status, header, raw)
	if err != nil {
		return nil, err
	}
	return &Assessment{
		Data: data, Raw: raw, Status: status, Header: header,
		RequestID: header.Get("X-Request-Id"),
		Replayed:  strings.EqualFold(header.Get("Idempotent-Replayed"), "true"),
	}, nil
}

func (c *Client) send(ctx context.Context, method, path string, body []byte, headers map[string]string) (int, http.Header, []byte, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(c.BaseURL, "/")+path, reader)
	if err != nil {
		return 0, nil, nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", c.UserAgent)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	hc := c.HTTPClient
	if hc == nil {
		hc = http.DefaultClient
	}
	resp, err := hc.Do(req)
	if err == nil {
		defer resp.Body.Close()
		var raw []byte
		raw, err = io.ReadAll(resp.Body)
		if err == nil {
			return resp.StatusCode, resp.Header, raw, nil
		}
	}
	var netErr net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &netErr) && netErr.Timeout()) {
		return 0, nil, nil, newError(0, "timeout", "No response in time; the outcome is unknown, retry with the same Idempotency-Key.", "", nil, nil)
	}
	return 0, nil, nil, newError(0, "network_error", fmt.Sprintf("Could not reach %s: %v", c.BaseURL, err), "", nil, nil)
}

func parseJSON(status int, header http.Header, raw []byte) (map[string]any, error) {
	var data map[string]any
	var parsed bool
	if len(bytes.TrimSpace(raw)) == 0 {
		data, parsed = map[string]any{}, true
	} else {
		parsed = json.Unmarshal(raw, &data) == nil && data != nil
	}
	if status >= 200 && status < 300 && parsed {
		return data, nil
	}
	var retryAfter *float64
	if v := header.Get("Retry-After"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			retryAfter = &f
		}
	}
	if parsed {
		if errObj, ok := data["error"].(map[string]any); ok {
			code, _ := errObj["code"].(string)
			if code == "" {
				code = "request_error"
			}
			msg, _ := errObj["message"].(string)
			rid, _ := data["request_id"].(string)
			if rid == "" {
				rid = header.Get("X-Request-Id")
			}
			return nil, newError(status, code, msg, rid, retryAfter, data)
		}
	}
	snippet := strings.TrimSpace(strings.ToValidUTF8(string(raw[:min(len(raw), 200)]), "�"))
	if snippet == "" {
		snippet = fmt.Sprintf("HTTP %d", status)
	}
	return nil, newError(status, "http_error", snippet, header.Get("X-Request-Id"), retryAfter, nil)
}

// Package toneperfect is a client for the TonePerfect pronunciation assessment API
// (https://api.toneperfect.app), standard library only, Go 1.21+.
//
// It wraps the public endpoints:
//
//	GET  /v1/capabilities  languages served, limits, model version (no key)
//	POST /v1/assess        score one scripted recording
//	POST /v1/lint          check a reference text before recording (free, no key)
//	GET  /v1/status        synthetic engine probe summary (free, no key)
//
// Accounts, API keys and billing are managed in the web dashboard; those routes are
// session-based and deliberately not wrapped. Reference: https://api.toneperfect.app/docs
//
//	client := toneperfect.New("") // reads TONEPERFECT_API_KEY
//	res, err := client.AssessFile(ctx, "hello.ogg", toneperfect.AssessParams{Text: "你好", Language: "zh-CN"})
package toneperfect

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	mrand "math/rand"
	"mime/multipart"
	"net"
	"net/http"
	"net/textproto"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Version of this client, sent in the User-Agent.
const Version = "0.3.0"

// DefaultBaseURL is the public API origin.
const DefaultBaseURL = "https://api.toneperfect.app"

// BillingURL is where a 402 is fixed. A 402 from the API may carry its own billing_url.
const BillingURL = "https://api.toneperfect.app/dashboard?tab=billing"

// Tasks accepted in AssessParams.Task.
var Tasks = []string{"general", "connected_speech", "isolated_word"}

// TestOutcomes a tp_test_ key can rehearse (AssessParams.TestOutcome).
var TestOutcomes = []string{"success", "unassessable", "invalid_assessment", "engine_unavailable", "subscription_required",
	"subscription_past_due", "insufficient_credits", "account_busy", "rate_limit"}

// Decisions on words and phones. review / uncertain / no_correction are the feedback decisions;
// unassessable, partial and legacy_correction also occur. Treat unknown values as "no decision".
var Decisions = []string{"review", "uncertain", "no_correction", "unassessable", "partial", "legacy_correction"}

// RetrySameKeyCodes: after these the SAME Idempotency-Key is retried, nothing was stored under it.
var RetrySameKeyCodes = map[string]bool{
	"rate_limit": true, "account_busy": true, "uploads_in_progress": true, "gateway_busy": true, "decoder_busy": true,
	"audio_decoder_unavailable": true, "upload_timeout": true, "request_pending": true, "request_interrupted": true,
	"engine_unavailable": true, "result_held": true, "timeout": true, "network_error": true,
}

// NewKeyCodes mean the key is spent: start a new attempt with a new key.
var NewKeyCodes = map[string]bool{"idempotency_expired": true, "idempotency_conflict": true}

// notRetryable: free_capacity (429) clears at the next UTC day, or at once with a paid plan.
var notRetryable = map[string]bool{"free_capacity": true}

var contentTypes = map[string]string{".wav": "audio/wav", ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".mp4": "audio/mp4", ".aac": "audio/aac",
	".ogg": "audio/ogg", ".oga": "audio/ogg", ".opus": "audio/ogg", ".webm": "audio/webm", ".flac": "audio/flac"}

// NewIdempotencyKey returns a fresh key (a UUID) for one recording attempt. Assess makes one per call
// and reuses it for its own retries; pass your own to resend the same recording safely across restarts.
func NewIdempotencyKey() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// ---------------------------------------------------------------- errors

// ErrorKind names the error class shared with the other SDKs.
type ErrorKind string

// Error classes.
const (
	KindAuthentication  ErrorKind = "AuthenticationError"  // 401 invalid_api_key
	KindPaymentRequired ErrorKind = "PaymentRequiredError" // 402: nothing charged; see BillingURL
	KindRateLimit       ErrorKind = "RateLimitError"       // 429
	KindValidation      ErrorKind = "ValidationError"      // other 4xx: fix the request
	KindServer          ErrorKind = "ServerError"          // 5xx: never stored, never charged
	KindAPIConnection   ErrorKind = "APIConnectionError"   // Status 0: timeout or network_error
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

// Error is returned for each non-2xx response and each transport failure (Status 0).
// Code and Message come from the API's "error" object; branch on Code.
//   - Retryable: nothing was stored under the key; the client already retried with the SAME key.
//   - NeedsNewKey: the failure is stored under the key (Finalized: a 4xx with a req_… ID and Billing,
//     such as invalid_assessment) or the key expired or conflicts.
//   - otherwise: fix the request (invalid_api_key, invalid_audio, unsupported_language, …).
type Error struct {
	Status         int
	Code           string
	Message        string
	RequestID      string
	RetryAfter     *float64
	Body           map[string]any
	IdempotencyKey string
	// ID is the req_… result id when the failure is stored under the key.
	ID      string
	Billing map[string]any
	// BillingURL (402): where to start, renew or fix a plan: the API's link, else the dashboard billing tab.
	BillingURL string
	// PricingURL and Plan (402): the plans page and the least expensive plan on sale, when the API sends them.
	PricingURL string
	Plan       map[string]any
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
	if obj, ok := e.Body["error"].(map[string]any); ok {
		e.BillingURL, _ = obj["billing_url"].(string)
		e.PricingURL, _ = obj["pricing_url"].(string)
		e.Plan, _ = obj["plan"].(map[string]any)
	}
	if e.BillingURL == "" && status == 402 {
		e.BillingURL = BillingURL
	}
	return e
}

func (e *Error) Error() string {
	text := fmt.Sprintf("%d %s: %s", e.Status, e.Code, e.Message)
	if e.BillingURL != "" && !strings.Contains(e.Message, e.BillingURL) {
		text += " (" + e.BillingURL + ")"
	}
	return text
}

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

// Finalized reports a stored result for this key: a 4xx with ID and Billing. A 5xx is never stored.
func (e *Error) Finalized() bool { return e.ID != "" && e.Billing != nil && e.Status < 500 }

// NeedsNewKey: start a new attempt with a new Idempotency-Key; the old key replays this response.
func (e *Error) NeedsNewKey() bool { return e.Finalized() || NewKeyCodes[e.Code] }

// Retryable: retry later with the SAME Idempotency-Key, nothing was stored under it.
func (e *Error) Retryable() bool {
	if e.Finalized() || NewKeyCodes[e.Code] || notRetryable[e.Code] {
		return false
	}
	if RetrySameKeyCodes[e.Code] {
		return true
	}
	switch e.Status {
	case 0, 408, 429, 502, 503, 504:
		return true
	}
	return false
}

// ---------------------------------------------------------------- results

// Phone is one scored unit under a word: a phoneme, or a Mandarin initial, final or tone.
type Phone struct {
	Dimension string   `json:"dimension"`
	Expected  any      `json:"expected"` // a string, or a tone number
	Heard     any      `json:"heard"`
	Score     *float64 `json:"score"`    // nil = not scored
	Decision  string   `json:"decision"` // "" when absent
}

// Word is one word (one character in Mandarin). Full and compact responses fill the same fields.
type Word struct {
	Word     string   `json:"word"`
	Score    *float64 `json:"score"`
	StartMs  *float64 `json:"start_ms"`
	EndMs    *float64 `json:"end_ms"`
	Decision string   `json:"decision"`
	Pinyin   string   `json:"pinyin"`
	Phones   []Phone  `json:"phones"`
	// Text and Units are the compact schema's names; they are copied into Word and Phones.
	Text  string  `json:"text"`
	Units []Phone `json:"units"`
}

// Billing is what the request cost.
type Billing struct {
	Credits        int    `json:"credits"`
	BalanceCredits *int   `json:"balance_credits"`
	FreeCredits    *int   `json:"free_credits"`
	Source         string `json:"source"` // free, plan or test
}

// EngineRoute says which engine answered (fallback scores are calibrated differently).
type EngineRoute struct {
	Engine   string `json:"engine"` // primary or fallback
	Fallback bool   `json:"fallback"`
}

// Assessment is one POST /v1/assess result. Raw is the JSON body as returned; Decode reads any other field.
type Assessment struct {
	ID           string              `json:"id"`
	Schema       string              `json:"schema"` // toneperfect.compact.v1 for a compact response
	Assessable   bool                `json:"assessable"`
	Reason       string              `json:"reason"` // why it was not assessable; never show that as a zero score
	Locale       string              `json:"locale"`
	Task         string              `json:"task"`
	ModelVersion string              `json:"model_version"`
	Scores       map[string]*float64 `json:"scores"` // 0–100; nil = not measured by this pack
	Words        []Word              `json:"words"`
	Warnings     []any               `json:"warnings"`
	EngineRoute  *EngineRoute        `json:"engine_route"`
	Billing      Billing             `json:"billing"`
	Test         bool                `json:"test"` // a fixed example from a tp_test_ key

	HTTPStatus     int             `json:"-"`
	RequestID      string          `json:"-"`
	Replayed       bool            `json:"-"`
	IdempotencyKey string          `json:"-"`
	Header         http.Header     `json:"-"`
	Raw            json.RawMessage `json:"-"`
}

// Overall is scores.overall (nil when not measured).
func (a *Assessment) Overall() *float64 { return a.Scores["overall"] }

// Engine is "primary" or "fallback".
func (a *Assessment) Engine() string {
	if a.EngineRoute != nil {
		return a.EngineRoute.Engine
	}
	return a.Header.Get("X-TonePerfect-Engine")
}

// Decode unmarshals the raw body into v, for fields this struct does not name (syllables, heard, timings).
func (a *Assessment) Decode(v any) error { return json.Unmarshal(a.Raw, v) }

// LintIssue is one finding of POST /v1/lint.
type LintIssue struct {
	Code     string `json:"code"`
	Message  string `json:"message"`
	Field    string `json:"field"`
	Severity string `json:"severity"` // error or warning
}

// LintResult is the POST /v1/lint answer.
type LintResult struct {
	OK       bool        `json:"ok"`
	Language string      `json:"language"`
	Issues   []LintIssue `json:"issues"`
	Units    int         `json:"units"`
}

// ---------------------------------------------------------------- client

// AssessParams are the fields of one assessment. Language is required.
type AssessParams struct {
	Text     string // what the learner was asked to say (Mandarin may send toned Pinyin instead)
	Language string // zh-CN, en-US, fr-FR, es-419, de-DE, it-IT, pt-BR, ru-RU, ko-KR or ja-JP
	Pinyin   string // Mandarin: picks the reading of a polyphone next to characters, or toned pinyin alone
	Task     string // general (default), connected_speech or isolated_word
	// IdempotencyKey: one per recording attempt; made for you and reused by the automatic retries.
	IdempotencyKey string
	Filename       string // default: the file's name (AssessFile), else "recording"
	ContentType    string // default: from the file extension
	Compact        bool   // the stable compact schema (toneperfect.compact.v1)
	TestOutcome    string // tp_test_ keys only: one of TestOutcomes
}

// Client calls the API. Build it with New.
type Client struct {
	APIKey     string
	BaseURL    string
	HTTPClient *http.Client
	MaxRetries int
	Headers    map[string]string
	UserAgent  string
}

// Option configures a Client.
type Option func(*Client)

// WithBaseURL sets the API origin (default: TONEPERFECT_BASE_URL, else https://api.toneperfect.app).
func WithBaseURL(u string) Option { return func(c *Client) { c.BaseURL = strings.TrimRight(u, "/") } }

// WithHTTPClient replaces the HTTP client.
func WithHTTPClient(h *http.Client) Option { return func(c *Client) { c.HTTPClient = h } }

// WithTimeout sets the per-request timeout (default 60 s).
func WithTimeout(d time.Duration) Option {
	return func(c *Client) { c.HTTPClient = &http.Client{Timeout: d} }
}

// WithMaxRetries sets the automatic retries of a retryable failure, with the same key (default 2).
func WithMaxRetries(n int) Option { return func(c *Client) { c.MaxRetries = n } }

// WithHeader adds a header to every request, e.g. WithHeader("TonePerfect-Fallback", "off").
func WithHeader(name, value string) Option { return func(c *Client) { c.Headers[name] = value } }

// WithUserAgent replaces the User-Agent.
func WithUserAgent(ua string) Option { return func(c *Client) { c.UserAgent = ua } }

// New builds a client. An empty apiKey reads TONEPERFECT_API_KEY (tp_live_…, or a tp_test_… test key).
func New(apiKey string, opts ...Option) *Client {
	if apiKey == "" {
		apiKey = os.Getenv("TONEPERFECT_API_KEY")
	}
	base := os.Getenv("TONEPERFECT_BASE_URL")
	if base == "" {
		base = DefaultBaseURL
	}
	c := &Client{APIKey: apiKey, BaseURL: strings.TrimRight(base, "/"), HTTPClient: &http.Client{Timeout: 60 * time.Second},
		MaxRetries: 2, Headers: map[string]string{}, UserAgent: "toneperfect-go/" + Version}
	for _, o := range opts {
		o(c)
	}
	return c
}

// Capabilities is GET /v1/capabilities (no key): languages, limits, model version.
func (c *Client) Capabilities(ctx context.Context) (map[string]any, error) {
	var out map[string]any
	_, err := c.call(ctx, "GET", "/v1/capabilities", nil, nil, "", &out)
	return out, err
}

// Status is GET /v1/status (no key): the synthetic engine probe.
func (c *Client) Status(ctx context.Context) (map[string]any, error) {
	var out map[string]any
	_, err := c.call(ctx, "GET", "/v1/status", nil, nil, "", &out)
	return out, err
}

// Lint is POST /v1/lint (free, no key): the engine's reference rules without audio.
func (c *Client) Lint(ctx context.Context, text, language, pinyin string) (*LintResult, error) {
	if language == "" {
		return nil, errors.New("toneperfect: language is required, for example \"en-US\" or \"zh-CN\"")
	}
	body, _ := json.Marshal(map[string]string{"text": text, "language": language, "pinyin": pinyin, "task": "general"})
	var out LintResult
	_, err := c.call(ctx, "POST", "/v1/lint", func() (io.Reader, string) { return bytes.NewReader(body), "application/json" }, nil, "", &out)
	if err != nil {
		return nil, err
	}
	return &out, nil
}

// AssessFile reads a recording from disk and assesses it (file name and content type from the path).
func (c *Client) AssessFile(ctx context.Context, path string, p AssessParams) (*Assessment, error) {
	audio, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if p.Filename == "" {
		p.Filename = filepath.Base(path)
	}
	return c.Assess(ctx, audio, p)
}

// Assess is POST /v1/assess: score one scripted recording (WAV, MP3, M4A, Ogg or WebM, 0.15–120 s, up to 10 MB).
// Failures are *Error; retryable ones were already retried with the same Idempotency-Key.
func (c *Client) Assess(ctx context.Context, audio []byte, p AssessParams) (*Assessment, error) {
	if c.APIKey == "" {
		return nil, newError(401, "invalid_api_key", "Set the API key or the TONEPERFECT_API_KEY environment variable.", "", nil, nil)
	}
	if p.Language == "" {
		return nil, errors.New("toneperfect: Language is required, for example \"en-US\" or \"zh-CN\"")
	}
	if p.Task == "" {
		p.Task = "general"
	}
	if p.Text == "" && p.Pinyin == "" {
		return nil, errors.New("toneperfect: provide Text (or, for Mandarin, Pinyin with tones)")
	}
	key := p.IdempotencyKey
	if key == "" {
		key = NewIdempotencyKey()
	}
	if len(key) > 255 || strings.IndexFunc(key, func(r rune) bool { return r < 0x20 || r > 0x7e }) >= 0 {
		return nil, errors.New("toneperfect: IdempotencyKey must be 1-255 printable ASCII characters (a UUID works everywhere)")
	}
	name := p.Filename
	if name == "" {
		name = "recording"
	}
	ctype := p.ContentType
	if ctype == "" {
		ctype = contentTypes[strings.ToLower(filepath.Ext(name))]
		if ctype == "" {
			ctype = "application/octet-stream"
		}
	}
	fields := [][2]string{{"language", p.Language}, {"task", p.Task}}
	if p.Text != "" {
		fields = append(fields, [2]string{"text", p.Text})
	}
	if p.Pinyin != "" {
		fields = append(fields, [2]string{"pinyin", p.Pinyin})
	}
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	for _, f := range fields {
		_ = w.WriteField(f[0], f[1])
	}
	h := make(textproto.MIMEHeader)
	h.Set("Content-Disposition", fmt.Sprintf(`form-data; name="audio"; filename=%q`, strings.NewReplacer("\r", "", "\n", "").Replace(name)))
	h.Set("Content-Type", ctype)
	part, _ := w.CreatePart(h)
	_, _ = part.Write(audio)
	_ = w.Close()
	payload, formType := buf.Bytes(), w.FormDataContentType()
	headers := map[string]string{"Authorization": "Bearer " + c.APIKey, "Idempotency-Key": key}
	if p.Compact {
		headers["TonePerfect-Response"] = "compact"
	}
	if p.TestOutcome != "" {
		headers["TonePerfect-Test-Outcome"] = p.TestOutcome
	}
	var a Assessment
	resp, err := c.call(ctx, "POST", "/v1/assess", func() (io.Reader, string) { return bytes.NewReader(payload), formType }, headers, key, &a)
	if err != nil {
		return nil, err
	}
	for i := range a.Words {
		if a.Words[i].Word == "" {
			a.Words[i].Word = a.Words[i].Text
		}
		if a.Words[i].Phones == nil {
			a.Words[i].Phones = a.Words[i].Units
		}
	}
	a.HTTPStatus, a.RequestID, a.Header, a.Raw = resp.status, resp.header.Get("X-Request-Id"), resp.header, resp.raw
	a.Replayed = strings.EqualFold(resp.header.Get("Idempotent-Replayed"), "true")
	a.IdempotencyKey = key
	if echoed := resp.header.Get("Idempotency-Key"); echoed != "" {
		a.IdempotencyKey = echoed
	}
	if a.ID == "" {
		a.ID = a.RequestID
	}
	return &a, nil
}

type response struct {
	status int
	header http.Header
	raw    []byte
}

func (c *Client) call(ctx context.Context, method, path string, body func() (io.Reader, string), headers map[string]string, key string, out any) (*response, error) {
	for attempt := 0; ; attempt++ {
		resp, err := c.send(ctx, method, path, body, headers)
		if err == nil {
			err = parse(resp, out)
		}
		if err == nil {
			return resp, nil
		}
		var e *Error
		if !errors.As(err, &e) {
			return nil, err
		}
		e.IdempotencyKey = key
		if attempt >= c.MaxRetries || !e.Retryable() {
			return nil, e
		}
		select {
		case <-ctx.Done():
			return nil, e
		case <-time.After(backoff(e, attempt)):
		}
	}
}

func backoff(e *Error, attempt int) time.Duration {
	if e.RetryAfter != nil {
		return time.Duration(math.Max(0, math.Min(*e.RetryAfter, 30)) * float64(time.Second))
	}
	base := 0.5
	if e.Code == "engine_unavailable" {
		base = 2
	}
	return time.Duration((math.Min(base*math.Pow(2, float64(attempt)), 8) + mrand.Float64()*0.25) * float64(time.Second))
}

func (c *Client) send(ctx context.Context, method, path string, body func() (io.Reader, string), headers map[string]string) (*response, error) {
	var reader io.Reader
	var ctype string
	if body != nil {
		reader, ctype = body()
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(c.BaseURL, "/")+path, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", c.UserAgent)
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	for k, v := range c.Headers {
		req.Header.Set(k, v)
	}
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
			return &response{resp.StatusCode, resp.Header, raw}, nil
		}
	}
	var netErr net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &netErr) && netErr.Timeout()) {
		return nil, newError(0, "timeout", "No response in time; the outcome is unknown, retry with the same Idempotency-Key.", "", nil, nil)
	}
	return nil, newError(0, "network_error", fmt.Sprintf("Could not reach %s: %v", c.BaseURL, err), "", nil, nil)
}

func parse(resp *response, out any) error {
	var data map[string]any
	parsed := len(bytes.TrimSpace(resp.raw)) > 0 && json.Unmarshal(resp.raw, &data) == nil && data != nil
	if resp.status >= 200 && resp.status < 300 && parsed {
		if err := json.Unmarshal(resp.raw, out); err != nil {
			return fmt.Errorf("toneperfect: unexpected response shape: %w", err)
		}
		return nil
	}
	var retryAfter *float64
	if v := resp.header.Get("Retry-After"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			retryAfter = &f
		}
	}
	rid := resp.header.Get("X-Request-Id")
	if parsed {
		if obj, ok := data["error"].(map[string]any); ok {
			code, _ := obj["code"].(string)
			if code == "" {
				code = "request_error"
			}
			msg, _ := obj["message"].(string)
			if r, _ := data["request_id"].(string); r != "" {
				rid = r
			}
			return newError(resp.status, code, msg, rid, retryAfter, data)
		}
		if detail, ok := data["detail"].(string); ok { // framework errors (405 on a trailing slash)
			return newError(resp.status, "http_error", detail, rid, retryAfter, data)
		}
	}
	snippet := strings.TrimSpace(strings.ToValidUTF8(string(resp.raw[:min(len(resp.raw), 200)]), "�"))
	if snippet == "" {
		snippet = fmt.Sprintf("HTTP %d", resp.status)
	}
	return newError(resp.status, "http_error", snippet, rid, retryAfter, nil)
}

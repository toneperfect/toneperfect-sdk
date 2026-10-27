package toneperfect

// Offline tests against net/http/httptest servers; nothing touches the network.

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type captured struct {
	method, path string
	header       http.Header
	fields       map[string]string
	audio        string
	filename     string
}

func server(t *testing.T, status int, body string, headers map[string]string, got *captured) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got != nil {
			got.method, got.path, got.header = r.Method, r.URL.Path, r.Header.Clone()
			got.fields = map[string]string{}
			if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
				if err := r.ParseMultipartForm(1 << 20); err != nil {
					t.Errorf("multipart: %v", err)
				}
				for k, v := range r.MultipartForm.Value {
					got.fields[k] = v[0]
				}
				if f, fh, err := r.FormFile("audio"); err == nil {
					b, _ := io.ReadAll(f)
					got.audio, got.filename = string(b), fh.Filename
				}
			}
		}
		for k, v := range headers {
			w.Header().Set(k, v)
		}
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func js(v any) string { b, _ := json.Marshal(v); return string(b) }

var ctx = context.Background()

func TestAssessSendsRealContract(t *testing.T) {
	var got captured
	body := js(map[string]any{"assessable": true, "scores": map[string]any{"overall": 86, "tone": 80, "fluency": nil},
		"words": []any{map[string]any{"word": "你", "score": 94}}, "billing": map[string]any{"credits": 1, "balance_credits": 2499},
		"model_version": "mandarin-human-v2-x", "id": "req_1"})
	srv := server(t, 200, body, map[string]string{"X-Request-Id": "req_1"}, &got)
	c := New("tp_live_test", WithBaseURL(srv.URL+"/"))
	res, err := c.Assess(ctx, []byte("RIFF...."), AssessParams{Text: "你好", Language: "zh-CN", Pinyin: "ni3 hao3",
		Task: "connected_speech", IdempotencyKey: "lesson-42-attempt-1", Filename: "hello.wav"})
	if err != nil {
		t.Fatal(err)
	}
	if got.method != "POST" || got.path != "/v1/assess" {
		t.Fatalf("got %s %s", got.method, got.path)
	}
	if got.header.Get("Authorization") != "Bearer tp_live_test" || got.header.Get("Idempotency-Key") != "lesson-42-attempt-1" {
		t.Fatalf("headers %v", got.header)
	}
	if got.header.Get("User-Agent") != "toneperfect-go/0.1.0" {
		t.Fatalf("ua %q", got.header.Get("User-Agent"))
	}
	for k, v := range map[string]string{"text": "你好", "language": "zh-CN", "pinyin": "ni3 hao3", "task": "connected_speech"} {
		if got.fields[k] != v {
			t.Errorf("field %s = %q", k, got.fields[k])
		}
	}
	if got.audio != "RIFF...." || got.filename != "hello.wav" {
		t.Errorf("audio %q %q", got.audio, got.filename)
	}
	if !res.Assessable() || *res.Overall() != 86 || res.Scores()["fluency"] != nil {
		t.Errorf("scores %v", res.Data)
	}
	if res.Billing()["credits"].(float64) != 1 || res.ModelVersion() != "mandarin-human-v2-x" || res.ID() != "req_1" || res.Replayed {
		t.Errorf("result %+v", res)
	}
	if res.Words()[0]["word"] != "你" {
		t.Errorf("words %v", res.Words())
	}
	var typed struct {
		Scores struct{ Overall float64 } `json:"scores"`
	}
	if err := res.Decode(&typed); err != nil || typed.Scores.Overall != 86 {
		t.Errorf("decode %v %v", err, typed)
	}
}

func TestAssessFileReplayGeneratedKeyUnassessable(t *testing.T) {
	var got captured
	srv := server(t, 200, js(map[string]any{"assessable": false, "reason": "silence", "scores": map[string]any{"overall": nil},
		"billing": map[string]any{"credits": 0, "balance_credits": 5}}), map[string]string{"Idempotent-Replayed": "true"}, &got)
	path := filepath.Join(t.TempDir(), "clip.wav")
	if err := os.WriteFile(path, []byte("WAVDATA"), 0o600); err != nil {
		t.Fatal(err)
	}
	res, err := New("k", WithBaseURL(srv.URL)).AssessFile(ctx, path, AssessParams{Text: "hi", Language: "en-US"})
	if err != nil {
		t.Fatal(err)
	}
	if !idempotencyRE.MatchString(got.header.Get("Idempotency-Key")) {
		t.Errorf("key %q", got.header.Get("Idempotency-Key"))
	}
	if _, ok := got.fields["pinyin"]; ok {
		t.Error("pinyin should be omitted")
	}
	if got.fields["task"] != "general" || got.audio != "WAVDATA" {
		t.Errorf("fields %v audio %q", got.fields, got.audio)
	}
	if !res.Replayed || res.Assessable() || res.Reason() != "silence" || res.Overall() != nil || res.Billing()["credits"].(float64) != 0 {
		t.Errorf("result %+v", res.Data)
	}
}

func errFrom(t *testing.T, status int, body any, headers map[string]string) *Error {
	t.Helper()
	srv := server(t, status, js(body), headers, nil)
	_, err := New("k", WithBaseURL(srv.URL)).Assess(ctx, []byte("x"), AssessParams{Text: "hi", IdempotencyKey: "lesson-42-attempt-1"})
	var e *Error
	if !errors.As(err, &e) {
		t.Fatalf("want *Error, got %v", err)
	}
	return e
}

func TestAPIErrorIsTyped(t *testing.T) {
	e := errFrom(t, 402, map[string]any{"error": map[string]any{"code": "insufficient_credits", "message": "Purchase a credit pack."}, "request_id": "req_9"}, nil)
	if e.Status != 402 || e.Code != "insufficient_credits" || e.RequestID != "req_9" || e.Retryable() {
		t.Errorf("%+v", e)
	}
	if e.Kind() != KindPaymentRequired || !errors.Is(e, ErrPaymentRequired) || errors.Is(e, ErrServer) {
		t.Errorf("kind %s", e.Kind())
	}
}

func TestErrorsTypedByStatus(t *testing.T) {
	for status, want := range map[int]error{401: ErrAuthentication, 402: ErrPaymentRequired, 429: ErrRateLimit, 422: ErrValidation, 503: ErrServer} {
		srv := server(t, status, js(map[string]any{"error": map[string]any{"code": "subscription_required", "message": "m"}}), nil, nil)
		_, err := New("tp_live_test", WithBaseURL(srv.URL)).Capabilities(ctx)
		if !errors.Is(err, want) {
			t.Errorf("%d: %v is not %v", status, err, want)
		}
	}
}

func TestFinalizedFailureNeedsNewKey(t *testing.T) {
	e := errFrom(t, 503, map[string]any{"error": map[string]any{"code": "engine_unavailable", "message": "No credits were charged."},
		"id": "req_77", "billing": map[string]any{"credits": 0, "balance_credits": 12}}, map[string]string{"Idempotent-Replayed": "true"})
	if e.ID != "req_77" || e.Billing["balance_credits"].(float64) != 12 || !e.Finalized() || !e.NeedsNewKey() || e.Retryable() {
		t.Errorf("%+v", e)
	}
	i := errFrom(t, 503, map[string]any{"error": map[string]any{"code": "request_interrupted", "message": "x"}, "id": "req_78",
		"billing": map[string]any{"credits": 0, "balance_credits": 12}}, nil)
	if !i.NeedsNewKey() || i.Retryable() {
		t.Errorf("%+v", i)
	}
}

func TestNotFinalizedRetrySameKey(t *testing.T) {
	cases := []struct {
		status int
		code   string
	}{{409, "request_pending"}, {429, "rate_limit"}, {429, "account_busy"}, {503, "gateway_busy"}, {503, "decoder_busy"},
		{503, "audio_decoder_unavailable"}, {408, "upload_timeout"}, {503, "engine_unavailable"}}
	for _, c := range cases {
		e := errFrom(t, c.status, map[string]any{"error": map[string]any{"code": c.code, "message": "later"}, "request_id": "req_x"}, map[string]string{"Retry-After": "1"})
		if !e.Retryable() || e.NeedsNewKey() || e.Finalized() || e.RetryAfter == nil || *e.RetryAfter != 1 {
			t.Errorf("%s: %+v", c.code, e)
		}
	}
}

func TestSpentKeysAndClientErrors(t *testing.T) {
	for _, code := range []string{"idempotency_expired", "idempotency_conflict"} {
		e := errFrom(t, 409, map[string]any{"error": map[string]any{"code": code, "message": "new key"}}, nil)
		if !e.NeedsNewKey() || e.Retryable() {
			t.Errorf("%s", code)
		}
	}
	for code, status := range map[string]int{"invalid_api_key": 401, "insufficient_credits": 402, "invalid_audio": 422, "unsupported_language": 422, "upload_too_large": 413, "free_capacity": 429} {
		e := errFrom(t, status, map[string]any{"error": map[string]any{"code": code, "message": "fix"}}, nil)
		if e.Retryable() || e.NeedsNewKey() {
			t.Errorf("%s", code)
		}
	}
}

func TestNonJSONProxyError(t *testing.T) {
	srv := server(t, 504, "<html>Gateway Timeout</html>", nil, nil)
	_, err := New("k", WithBaseURL(srv.URL)).Capabilities(ctx)
	var e *Error
	if !errors.As(err, &e) || e.Status != 504 || e.Code != "http_error" || !e.Retryable() || e.NeedsNewKey() || !strings.Contains(e.Message, "Gateway") {
		t.Errorf("%v", err)
	}
	srv2 := server(t, 502, "", nil, nil)
	_, err = New("k", WithBaseURL(srv2.URL)).Capabilities(ctx)
	if !errors.As(err, &e) || !e.Retryable() {
		t.Errorf("%v", err)
	}
}

func TestTransportFailuresKeepSameKey(t *testing.T) {
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { time.Sleep(300 * time.Millisecond) }))
	defer slow.Close()
	_, err := New("k", WithBaseURL(slow.URL), WithTimeout(20*time.Millisecond)).Assess(ctx, []byte("x"), AssessParams{Text: "hi"})
	var e *Error
	if !errors.As(err, &e) || e.Status != 0 || e.Code != "timeout" || !e.Retryable() || e.NeedsNewKey() || !errors.Is(err, ErrAPIConnection) {
		t.Errorf("timeout: %v", err)
	}
	closed := httptest.NewServer(http.NotFoundHandler())
	url := closed.URL
	closed.Close()
	_, err = New("k", WithBaseURL(url)).Assess(ctx, []byte("x"), AssessParams{Text: "hi"})
	if !errors.As(err, &e) || e.Code != "network_error" || !e.Retryable() {
		t.Errorf("refused: %v", err)
	}
}

func TestCapabilitiesNeedsNoKey(t *testing.T) {
	t.Setenv("TONEPERFECT_API_KEY", "")
	var got captured
	srv := server(t, 200, js(map[string]any{"languages": []any{map[string]any{"locale": "zh-CN", "status": "experimental"}}}), nil, &got)
	caps, err := New("", WithBaseURL(srv.URL)).Capabilities(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if got.method != "GET" || got.path != "/v1/capabilities" || got.header.Get("Authorization") != "" {
		t.Errorf("%+v", got)
	}
	if caps["languages"].([]any)[0].(map[string]any)["locale"] != "zh-CN" {
		t.Errorf("%v", caps)
	}
}

func TestValidationAndEnvKey(t *testing.T) {
	t.Setenv("TONEPERFECT_API_KEY", "")
	_, err := New("").Assess(ctx, []byte("x"), AssessParams{Text: "x"})
	if !errors.Is(err, ErrAuthentication) {
		t.Errorf("no key: %v", err)
	}
	c := New("k", WithBaseURL("http://127.0.0.1:1"))
	for name, p := range map[string]AssessParams{
		"no text":   {Language: "en-US"},
		"bad task":  {Text: "x", Task: "freestyle"},
		"short key": {Text: "x", IdempotencyKey: "short"},
	} {
		if _, err := c.Assess(ctx, []byte("x"), p); err == nil {
			t.Errorf("%s: expected error", name)
		} else {
			var e *Error
			if errors.As(err, &e) {
				t.Errorf("%s: validation should not reach the network: %v", name, err)
			}
		}
	}
	if k, err := NewIdempotencyKey("lesson.42"); err != nil || !idempotencyRE.MatchString(k) {
		t.Errorf("key %q %v", k, err)
	}
	if _, err := NewIdempotencyKey("bad prefix"); err == nil {
		t.Error("bad prefix accepted")
	}
	t.Setenv("TONEPERFECT_API_KEY", "tp_live_env")
	if New("").APIKey != "tp_live_env" {
		t.Error("env key not used")
	}
}

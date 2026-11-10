package toneperfect

// Contract tests against testing/mock_api.py (a local stand-in that follows the live gateway's rules).

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

const hello = "../testing/fixtures/hello.ogg"

var (
	servers   = map[string]string{}
	serversMu sync.Mutex
	children  []*exec.Cmd
)

func TestMain(m *testing.M) {
	code := m.Run()
	for _, c := range children {
		_ = c.Process.Kill()
	}
	os.Exit(code)
}

func server(t *testing.T, gateway string) string {
	serversMu.Lock()
	defer serversMu.Unlock()
	if url, ok := servers[gateway]; ok {
		return url
	}
	cmd := exec.Command("python3", "../testing/mock_api.py", "--gateway", gateway)
	out, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	children = append(children, cmd)
	line, _ := bufio.NewReader(out).ReadString('\n')
	servers[gateway] = strings.TrimSpace(line)
	return servers[gateway]
}

type logEntry struct {
	IdempotencyKey string            `json:"idempotency_key"`
	AuthScheme     string            `json:"auth_scheme"`
	Fields         map[string]string `json:"fields"`
	UserAgent      string            `json:"user_agent"`
	Audio          struct {
		Filename    string `json:"filename"`
		ContentType string `json:"content_type"`
	} `json:"audio"`
}

func attempts(t *testing.T, url, key string) []logEntry {
	resp, err := http.Get(url + "/_mock/log")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var all, mine []logEntry
	_ = json.NewDecoder(resp.Body).Decode(&all)
	for _, e := range all {
		if e.IdempotencyKey == key {
			mine = append(mine, e)
		}
	}
	return mine
}

func each(t *testing.T, f func(t *testing.T, gateway, url string)) {
	for _, g := range []string{"live", "1110"} {
		t.Run(g, func(t *testing.T) { f(t, g, server(t, g)) })
	}
}

func asError(t *testing.T, err error) *Error {
	var e *Error
	if !errors.As(err, &e) {
		t.Fatalf("want *Error, got %v", err)
	}
	return e
}

var ctx = context.Background()

func TestAssessRequestAndTypedResult(t *testing.T) {
	each(t, func(t *testing.T, _ string, url string) {
		res, err := New("tp_test_mock", WithBaseURL(url)).AssessFile(ctx, hello, AssessParams{Text: "你好", Language: "zh-CN", Task: "connected_speech"})
		if err != nil {
			t.Fatal(err)
		}
		sent := attempts(t, url, res.IdempotencyKey)[0]
		if !regexp.MustCompile(`^[0-9a-f-]{36}$`).MatchString(res.IdempotencyKey) || sent.AuthScheme != "Bearer" || sent.UserAgent != "toneperfect-go/"+Version {
			t.Fatalf("request: %+v key %s", sent, res.IdempotencyKey)
		}
		if sent.Fields["text"] != "你好" || sent.Fields["language"] != "zh-CN" || sent.Fields["task"] != "connected_speech" || sent.Audio.Filename != "hello.ogg" || sent.Audio.ContentType != "audio/ogg" {
			t.Fatalf("fields: %+v", sent)
		}
		if !res.Assessable || !res.Test || *res.Overall() != 78 || len(res.Words) != 2 || res.Words[0].Word != "你" || res.Words[0].Phones[2].Dimension != "tone" {
			t.Fatalf("result: %+v", res)
		}
		if res.Billing.Credits != 0 || res.Billing.Source != "test" || res.Engine() != "primary" {
			t.Fatalf("billing/engine: %+v %s", res.Billing, res.Engine())
		}
	})
}

func TestCompactMapsToTheSameFields(t *testing.T) {
	each(t, func(t *testing.T, _ string, url string) {
		audio, _ := os.ReadFile(hello)
		res, err := New("tp_test_mock", WithBaseURL(url)).Assess(ctx, audio, AssessParams{Text: "I like sunny days", Language: "en-US", Compact: true})
		if err != nil {
			t.Fatal(err)
		}
		if res.Schema != "toneperfect.compact.v1" || len(res.Words) != 4 || res.Words[1].Word != "like" || res.Words[1].Phones[0].Dimension != "phoneme" {
			t.Fatalf("compact: %+v", res.Words)
		}
	})
}

func TestReplayWithTheSameKey(t *testing.T) {
	each(t, func(t *testing.T, _ string, url string) {
		c, key := New("tp_test_mock", WithBaseURL(url)), NewIdempotencyKey()
		a, _ := c.AssessFile(ctx, hello, AssessParams{Text: "你好", Language: "zh-CN", IdempotencyKey: key})
		b, err := c.AssessFile(ctx, hello, AssessParams{Text: "你好", Language: "zh-CN", IdempotencyKey: key})
		if err != nil || a.ID != b.ID || !b.Replayed {
			t.Fatalf("replay: %v %v %v", err, a.ID, b.Replayed)
		}
	})
}

func TestRetriesWithTheSameKey(t *testing.T) {
	each(t, func(t *testing.T, _ string, url string) {
		res, err := New("tp_test_mock", WithBaseURL(url), WithHeader("X-Mock-Fail", "gateway_busy:2")).AssessFile(ctx, hello, AssessParams{Text: "你好", Language: "zh-CN"})
		if err != nil || len(attempts(t, url, res.IdempotencyKey)) != 3 {
			t.Fatalf("busy retry: %v", err)
		}
		res, err = New("tp_test_mock", WithBaseURL(url), WithHeader("X-Mock-Fail", "html502:1")).AssessFile(ctx, hello, AssessParams{Text: "你好", Language: "zh-CN"})
		if err != nil || len(attempts(t, url, res.IdempotencyKey)) != 2 {
			t.Fatalf("502 retry: %v", err)
		}
		_, err = New("tp_test_mock", WithBaseURL(url), WithMaxRetries(0), WithHeader("X-Mock-Fail", "engine_unavailable:1")).AssessFile(ctx, hello, AssessParams{Text: "你好", Language: "zh-CN"})
		if e := asError(t, err); !errors.Is(err, ErrServer) || !e.Retryable() || e.NeedsNewKey() {
			t.Fatalf("max retries 0: %v", err)
		}
		_, err = New("tp_test_mock", WithBaseURL(url), WithMaxRetries(1)).AssessFile(ctx, hello, AssessParams{Text: "你好", Language: "zh-CN", TestOutcome: "rate_limit"})
		if e := asError(t, err); !errors.Is(err, ErrRateLimit) || len(attempts(t, url, e.IdempotencyKey)) != 2 {
			t.Fatalf("rate limit: %v", err)
		}
	})
}

func TestFinalizedFailureNeedsANewKey(t *testing.T) {
	each(t, func(t *testing.T, _ string, url string) {
		_, err := New("tp_test_mock", WithBaseURL(url)).AssessFile(ctx, hello, AssessParams{Text: "你好", Language: "zh-CN", TestOutcome: "invalid_assessment"})
		e := asError(t, err)
		if !errors.Is(err, ErrValidation) || !e.Finalized() || !e.NeedsNewKey() || e.Retryable() || !strings.HasPrefix(e.ID, "req_") || len(attempts(t, url, e.IdempotencyKey)) != 1 {
			t.Fatalf("finalized: %+v", e)
		}
	})
}

func TestPaymentRequiredCarriesABillingLink(t *testing.T) {
	each(t, func(t *testing.T, gateway string, url string) {
		_, err := New("tp_test_mock", WithBaseURL(url)).AssessFile(ctx, hello, AssessParams{Text: "你好", Language: "zh-CN", TestOutcome: "subscription_required"})
		e := asError(t, err)
		if !errors.Is(err, ErrPaymentRequired) || e.Code != "subscription_required" || e.BillingURL != BillingURL || !strings.Contains(e.Error(), BillingURL) || e.Retryable() {
			t.Fatalf("402: %+v", e)
		}
		if gateway == "1110" && (e.Plan["name"] != "Starter" || e.PricingURL != "https://api.toneperfect.app/pricing/") {
			t.Fatalf("402 plan: %+v", e)
		}
	})
}

func TestAuthenticationTimeoutAndRequiredLanguage(t *testing.T) {
	each(t, func(t *testing.T, _ string, url string) {
		if _, err := New("nope", WithBaseURL(url)).AssessFile(ctx, hello, AssessParams{Text: "你好", Language: "zh-CN"}); !errors.Is(err, ErrAuthentication) {
			t.Fatalf("auth: %v", err)
		}
		_, err := New("tp_test_mock", WithBaseURL(url), WithTimeout(300*time.Millisecond), WithMaxRetries(0), WithHeader("X-Mock-Delay", "1")).AssessFile(ctx, hello, AssessParams{Text: "你好", Language: "zh-CN"})
		if e := asError(t, err); e.Status != 0 || e.Code != "timeout" || !e.Retryable() || !errors.Is(err, ErrAPIConnection) {
			t.Fatalf("timeout: %v", err)
		}
		if _, err := New("tp_test_mock", WithBaseURL(url)).AssessFile(ctx, hello, AssessParams{Text: "你好"}); err == nil {
			t.Fatal("language should be required")
		}
	})
}

func TestOtherEndpoints(t *testing.T) {
	each(t, func(t *testing.T, _ string, url string) {
		c := New("tp_test_mock", WithBaseURL(url))
		caps, err := c.Capabilities(ctx)
		if err != nil || caps["languages"] == nil {
			t.Fatal(err)
		}
		lint, err := c.Lint(ctx, "你好", "zh-CN", "")
		if err != nil || !lint.OK {
			t.Fatal(err)
		}
		if st, err := c.Status(ctx); err != nil || st["status"] == nil {
			t.Fatal(err)
		}
	})
}

func TestEnvironmentDefaults(t *testing.T) {
	t.Setenv("TONEPERFECT_BASE_URL", "http://example.invalid/")
	t.Setenv("TONEPERFECT_API_KEY", "tp_test_env")
	c := New("")
	if c.BaseURL != "http://example.invalid" || c.APIKey != "tp_test_env" || c.MaxRetries != 2 || c.HTTPClient.Timeout != 60*time.Second {
		t.Fatalf("%+v", c)
	}
}

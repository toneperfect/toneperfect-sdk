# TonePerfect Go client

Client for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app): send a short recording
and the text it should contain, get 0–100 scores for the sentence, every word and every sound, with Mandarin
initial, final and tone per syllable. 10 languages. One file, standard library only, Go 1.21+.

```sh
go get github.com/vm542/toneperfect-sdk/go@v0.3.0
```

## Try it with a test key

[Sign up](https://api.toneperfect.app/signup) (50 free credits, no card), then in the dashboard open
**API keys** and create a **test key** (`tp_test_…`). A test key runs the real request path but returns a
fixed example result: it never scores your audio and never spends credits. Swap in a live key
(`tp_live_…`) for real scores. Keep keys on a server.

```sh
export TONEPERFECT_API_KEY="tp_test_..."
curl -o hello.ogg https://api.toneperfect.app/capsule/speech-zh-nihao.ogg   # 2 s of 你好
```

```go
package main

import (
	"context"
	"fmt"
	"log"

	toneperfect "github.com/vm542/toneperfect-sdk/go"
)

func main() {
	client := toneperfect.New("") // "" reads TONEPERFECT_API_KEY
	res, err := client.AssessFile(context.Background(), "hello.ogg", toneperfect.AssessParams{Text: "你好", Language: "zh-CN"})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(res.Assessable, *res.Overall(), res.Billing.Credits, res.Test)
	for _, w := range res.Words {
		for _, p := range w.Phones {
			fmt.Println(w.Word, p.Dimension, p.Expected, p.Heard, *p.Score, p.Decision)
		}
	}
}
```

`Language` is required: `zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR`
or `ja-JP`. `Assess` takes the audio as bytes; `AssessFile` reads a path and sets the file name and type.

## Results

`*Assessment` has `Assessable` and `Reason` (a recording that could not be scored is free and is not a score of
zero), `Scores` (0–100; `nil` = not measured by this pack) and `Overall()`, `Words` (`Word`, `Score`, `StartMs`,
`EndMs`, `Decision`, `Pinyin`, `Phones`), `Phones` (`Dimension`, `Expected`, `Heard`, `Score`, `Decision`),
`Billing` (`Credits`, `BalanceCredits`, `FreeCredits`, `Source`: `free`, `plan` or `test`), `Warnings`,
`Engine()`, `ModelVersion`, `ID`, `Replayed`, `Test`, and `Raw` with `Decode(&v)` for any other field. Act on
`Decision`, not on every low grade. `Compact: true` asks for the `toneperfect.compact.v1` schema; the same
fields are filled.

## Errors, retries and timeouts

Every failure is a `*toneperfect.Error` with the API's `Code`, `Message`, `Status` and `RequestID`;
`errors.Is` matches `ErrAuthentication` (401), `ErrPaymentRequired` (402, with `BillingURL` and, when the API
sends them, `PricingURL` and `Plan`), `ErrRateLimit` (429), `ErrValidation` (other 4xx), `ErrServer` (5xx) and
`ErrAPIConnection` (timeout or network failure). The client retries a failure that stored nothing
(`Retryable()`) up to `MaxRetries` times with the **same** Idempotency-Key, so a finished result is returned and
charged once; `NeedsNewKey()` marks a failure stored under the key. A test key rehearses each outcome:

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	toneperfect "github.com/vm542/toneperfect-sdk/go"
)

func main() {
	client := toneperfect.New("", toneperfect.WithTimeout(30*time.Second), toneperfect.WithMaxRetries(2))
	_, err := client.AssessFile(context.Background(), "hello.ogg", toneperfect.AssessParams{Text: "你好", Language: "zh-CN", TestOutcome: "subscription_required"})
	var apiErr *toneperfect.Error
	if errors.Is(err, toneperfect.ErrPaymentRequired) && errors.As(err, &apiErr) {
		fmt.Println(apiErr.Code, "->", apiErr.BillingURL)
	} else if errors.As(err, &apiErr) {
		fmt.Println(apiErr.Status, apiErr.Code, apiErr.Message, apiErr.Retryable(), apiErr.NeedsNewKey())
	}

	unscored, err := client.AssessFile(context.Background(), "hello.ogg", toneperfect.AssessParams{Text: "你好", Language: "zh-CN", TestOutcome: "unassessable"})
	if err != nil {
		panic(err)
	}
	fmt.Println(unscored.Assessable, unscored.Reason)
}
```

To resend the same recording safely after a crash, keep your own key:

```go
package main

import (
	"context"
	"fmt"

	toneperfect "github.com/vm542/toneperfect-sdk/go"
)

func main() {
	client := toneperfect.New("")
	params := toneperfect.AssessParams{Text: "I like sunny days", Language: "en-US", IdempotencyKey: toneperfect.NewIdempotencyKey()}
	first, err := client.AssessFile(context.Background(), "hello.ogg", params)
	if err != nil {
		panic(err)
	}
	again, err := client.AssessFile(context.Background(), "hello.ogg", params)
	if err != nil {
		panic(err)
	}
	fmt.Println(first.ID == again.ID, again.Replayed) // the stored result, not charged twice
}
```

## Other endpoints

```go
package main

import (
	"context"
	"fmt"

	toneperfect "github.com/vm542/toneperfect-sdk/go"
)

func main() {
	ctx, client := context.Background(), toneperfect.New("")
	lint, err := client.Lint(ctx, "我有3个苹果", "zh-CN", "") // free reference-text check, no key
	if err != nil {
		panic(err)
	}
	fmt.Println(lint.OK, lint.Issues)
	status, err := client.Status(ctx) // synthetic engine probe
	if err != nil {
		panic(err)
	}
	fmt.Println(status["status"])
}
```

## Configuration

`toneperfect.New(apiKey, opts...)` with `WithBaseURL`, `WithTimeout` (default 60 s), `WithMaxRetries` (default 2),
`WithHeader` (for example `TonePerfect-Fallback: off`), `WithHTTPClient` and `WithUserAgent`. An empty key reads
`TONEPERFECT_API_KEY`; the base URL defaults to `TONEPERFECT_BASE_URL`, else `https://api.toneperfect.app` (a proxy
with a 26-second limit: a longer passage comes back on the automatic retry, charged once).

Grades are display scores calibrated per language against native references, not accuracy percentages and not
comparable across vendors. Every language pack is labelled `experimental` in `/v1/capabilities`.
Docs: https://api.toneperfect.app/docs · MIT licence · nik@toneperfect.app

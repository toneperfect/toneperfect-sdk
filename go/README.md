# toneperfect (Go)

Client for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app), 10 languages:
`zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR` (beta) and `ja-JP` (beta).
Send a short scripted recording and the text it should contain, get 0–100 scores for the sentence,
every word and every sound in one JSON response, with expected vs heard sounds and timings.
Mandarin syllables also get separate initial, final and tone scores.

One file, standard library only, Go 1.21+.

```sh
go get github.com/vm542/toneperfect-sdk/go@main
```

The module lives in the `go/` directory of [`vm542/toneperfect-sdk`](https://github.com/vm542/toneperfect-sdk).
No release tag exists yet, so `@main` resolves to a pseudo-version of the current commit; pin
that version in your `go.mod`. Once a `go/v0.1.0` tag is published you can use `@v0.1.0`.
Import it as `toneperfect "github.com/vm542/toneperfect-sdk/go"`.

## Quickstart

```go
client := toneperfect.New("tp_live_...") // "" reads TONEPERFECT_API_KEY
res, err := client.AssessFile(ctx, "hello.wav", toneperfect.AssessParams{Text: "你好", Language: "zh-CN"})
if err != nil {
	log.Fatal(err)
}
if res.Assessable() {
	fmt.Println(*res.Overall(), res.Billing())
	for _, w := range res.Words() {
		fmt.Println(w["word"], w["score"], w["phones"])
	}
} else {
	fmt.Println("not assessable:", res.Reason()) // never show this as a zero score
}
```

Get a key: [create an account](https://api.toneperfect.app/signup) → dashboard → API keys.
New accounts get 50 free credits, no card needed; then the Starter plan is $10/month
([pricing](https://api.toneperfect.app/pricing/)). Keep the key on your server.

## What is wrapped

| Method | Endpoint | Notes |
| --- | --- | --- |
| `client.Capabilities(ctx)` | `GET /v1/capabilities` | No key needed. Languages, `status`, dimensions, `limits`, `model_version`. |
| `client.Assess(ctx, audio []byte, AssessParams{...})` / `AssessFile(ctx, path, ...)` | `POST /v1/assess` | Multipart `audio`, `text`, `language`, optional `pinyin` (`ni3 hao3`) and `task` (`general`, `connected_speech`, `isolated_word`). Headers `Authorization: Bearer` + `Idempotency-Key` (generated when empty). |

Options: `WithBaseURL`, `WithTimeout` (default 90 s), `WithHTTPClient`, `WithUserAgent`.

`*Assessment`: `Data` (full JSON body), `Raw` + `Decode(&yourStruct)`, `Assessable()`,
`Reason()`, `Scores()` (`nil` value = dimension not supported by the pack), `Overall()`,
`Words()`, `Billing()` (failed or unassessable requests charge 0), `ModelVersion()`, `ID()`,
`Replayed`.

## Errors and retries

Every non-2xx response and every transport failure returns `*toneperfect.Error`
(`Status`, `Code`, `Message`, `RequestID`, `RetryAfter`, `Body`, `ID`, `Billing`).
`Kind()` and `errors.Is` give the same classes as the other SDKs:

| Sentinel | When |
| --- | --- |
| `ErrAuthentication` | 401 `invalid_api_key` |
| `ErrPaymentRequired` | 402 `subscription_required`, `insufficient_credits`, `payment_balance_due` (nothing charged) |
| `ErrRateLimit` | 429 `rate_limit` (60/min) or `account_busy` (2 running); `free_capacity` (not retryable until the next UTC day) |
| `ErrValidation` | other 4xx |
| `ErrServer` | 5xx |
| `ErrAPIConnection` | `Status` 0, `timeout` / `network_error` |

`Retryable()` → retry later with the **same** `IdempotencyKey`; `NeedsNewKey()` (incl.
`Finalized()`) → new attempt, new key; otherwise fix the request. `free_capacity` (429, free credits reached today's shared limit) is not retryable: it clears at the next UTC day, or at once with a paid plan.

## Scope

Scripted speech only: the learner reads a known text. Grades are display scores calibrated
per language against native references — not accuracy percentages and not comparable
across vendors. Every language pack is labelled `experimental` in `/v1/capabilities`.

## Development

```sh
go vet ./... && go test ./...
```

MIT licensed. Docs: https://api.toneperfect.app/docs · Questions: nik@toneperfect.app

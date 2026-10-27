# toneperfect (Ruby)

Client for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app), 10 languages:
`zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR` (beta) and `ja-JP` (beta).
Send a short scripted recording and the text it should contain, get 0–100 scores for the sentence,
every word and every sound in one JSON response, with expected vs heard sounds and timings.
Mandarin syllables also get separate initial, final and tone scores.

One file, standard library only (`net/http`, `json`), Ruby 2.7+.

Not on RubyGems yet: install from this repository with Bundler (pin a commit with `ref:`
for reproducible builds):

```ruby
# Gemfile
gem "toneperfect", git: "https://github.com/vm542/toneperfect-sdk", branch: "main", glob: "ruby/*.gemspec"
```

```sh
bundle install
```

Or build the gem yourself:

```sh
git clone https://github.com/vm542/toneperfect-sdk && cd toneperfect-sdk/ruby
gem build toneperfect.gemspec && gem install ./toneperfect-0.1.0.gem
```

Do not `gem install toneperfect` from RubyGems until it is announced here: that name is not ours yet.

## Quickstart

```ruby
require "toneperfect"

client = TonePerfect::Client.new(api_key: "tp_live_...")   # or set TONEPERFECT_API_KEY
result = client.assess("hello.wav", text: "你好", language: "zh-CN")
puts result.assessable?, result.overall, result.billing
result.words.each do |word|
  puts word["word"], word["score"], word["phones"].select { |p| p["decision"] == "review" }
end
```

Get a key: [create an account](https://api.toneperfect.app/signup) → dashboard → API keys.
New accounts get 50 free credits, no card needed; then the Starter plan is $10/month
([pricing](https://api.toneperfect.app/pricing/)). Keep the key on your server.

## What is wrapped

| Method | Endpoint | Notes |
| --- | --- | --- |
| `client.capabilities` | `GET /v1/capabilities` | No key needed. Languages, `status`, dimensions, `limits`, `model_version`. |
| `client.assess(audio, text:, language:, pinyin:, task:, idempotency_key:)` | `POST /v1/assess` | Multipart `audio`, `text`, `language`, optional `pinyin` (`ni3 hao3`) and `task` (`general`, `connected_speech`, `isolated_word`). Headers `Authorization: Bearer` + `Idempotency-Key`. |

`audio` is a file path, an IO opened in binary mode, or a **binary** String
(`File.binread(...)` or `"...".b`); any other String is treated as a path.

`assess` returns a `TonePerfect::Assessment`: `data` (full JSON body), `assessable?` /
`reason` (never show an unassessable result as zero), `scores` (`nil` = dimension not
supported by the pack), `overall`, `words`, `billing` (`{"credits", "balance_credits"}`;
failed or unassessable requests charge 0), `model_version`, `id`, `replayed?`.

## Errors and retries

Every non-2xx response raises a `TonePerfect::Error` subclass with `status`, `code`,
`detail`, `request_id`, `retry_after`, `body`:

| Class | When |
| --- | --- |
| `AuthenticationError` | 401 `invalid_api_key` |
| `PaymentRequiredError` | 402 `subscription_required`, `insufficient_credits`, `payment_balance_due` (nothing charged) |
| `RateLimitError` | 429 `rate_limit` (60/min) or `account_busy` (2 running); `free_capacity` (not retryable until the next UTC day) |
| `ValidationError` | other 4xx (`invalid_audio`, `unsupported_language`, …) |
| `ServerError` | 5xx |
| `APIConnectionError` | transport failure, `status` 0, `timeout` / `network_error` |

Decide the next step from the error, not the status: `retryable?` → retry later with the
**same** `idempotency_key`; `needs_new_key?` (incl. `finalized?`) → start a new attempt with a
new key; otherwise fix the request. `free_capacity` (429, free credits reached today's shared limit) is not retryable: it clears at the next UTC day, or at once with a paid plan.

## Scope

Scripted speech only: the learner reads a known text. Grades are display scores calibrated
per language against native references — not accuracy percentages and not comparable
across vendors. Every language pack is labelled `experimental` in `/v1/capabilities`.

## Development

```sh
ruby -Ilib -Itest test/test_client.rb   # or: rake test
gem build toneperfect.gemspec
```

MIT licensed. Docs: https://api.toneperfect.app/docs · Questions: nik@toneperfect.app

# TonePerfect Ruby client

Client for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app): send a short recording
and the text it should contain, get 0–100 scores for the sentence, every word and every sound, with Mandarin
initial, final and tone per syllable. 10 languages. Standard library only, Ruby 3.0+.

```sh
gem install toneperfect
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

```ruby
require "toneperfect"

client = TonePerfect::Client.new # reads TONEPERFECT_API_KEY
result = client.assess("hello.ogg", text: "你好", language: "zh-CN")

puts [result.assessable?, result.overall, result.billing.credits, result.test?].inspect
result.words.each do |word|
  word.phones.each { |p| puts [word.word, p.dimension, p.expected, p.heard, p.score, p.decision].join(" ") }
end
```

`language:` is required: `zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR` or
`ja-JP`. `audio` is a path, a binary String or an IO opened in binary mode.

## Results

`assess` returns a `TonePerfect::Assessment`: `assessable?` and `reason` (a recording that could not be scored
is free and is not a score of zero), `overall` and `scores` (0–100; `nil` = not measured by this pack), `words`
(`Word`: `word`, `score`, `start_ms`, `end_ms`, `decision`, `pinyin`, `phones`), `phones` (`Phone`:
`dimension`, `expected`, `heard`, `score`, `decision`), `billing` (`credits`, `balance_credits`,
`free_credits`, `source`: `free`, `plan` or `test`), `warnings`, `engine`, `model_version`, `id`, `replayed?`,
`test?`, and `data`, the JSON as returned (`word["field"]` reads any raw field). Act on `decision`, not on every
low grade. `compact: true` asks for the `toneperfect.compact.v1` schema; the same methods work on it.

## Errors, retries and timeouts

Every error is a `TonePerfect::Error` with the API's `code`, `detail` (its message), `status` and `request_id`.
Subclasses: `AuthenticationError` (401), `PaymentRequiredError` (402, with `billing_url` and, when the API sends
them, `pricing_url` and `plan`), `RateLimitError` (429), `ValidationError` (other 4xx), `ServerError` (5xx) and
`APIConnectionError` (timeout or network failure). The client retries a failure that stored nothing
(`retryable?`) up to `max_retries` times with the **same** Idempotency-Key, so a finished result is returned and
charged once; `needs_new_key?` marks a failure stored under the key. A test key rehearses each outcome:

```ruby
require "toneperfect"

client = TonePerfect::Client.new(timeout: 30, max_retries: 2)
begin
  client.assess("hello.ogg", text: "你好", language: "zh-CN", test_outcome: "subscription_required")
rescue TonePerfect::PaymentRequiredError => e
  puts "#{e.code} -> #{e.billing_url}"
rescue TonePerfect::Error => e
  puts [e.status, e.code, e.detail, e.retryable?, e.needs_new_key?].inspect
end

unscored = client.assess("hello.ogg", text: "你好", language: "zh-CN", test_outcome: "unassessable")
puts [unscored.assessable?, unscored.reason].inspect
```

To resend the same recording safely after a crash, keep your own key:

```ruby
require "toneperfect"

client = TonePerfect::Client.new
key = TonePerfect.new_idempotency_key # store it with the recording
first = client.assess("hello.ogg", text: "I like sunny days", language: "en-US", idempotency_key: key)
again = client.assess("hello.ogg", text: "I like sunny days", language: "en-US", idempotency_key: key)
puts [first.id == again.id, again.replayed?].inspect # the stored result, not charged twice
```

## Other endpoints

```ruby
require "toneperfect"

client = TonePerfect::Client.new
puts client.lint("我有3个苹果", language: "zh-CN")["issues"].inspect # free reference-text check, no key
puts client.status["status"]                                         # synthetic engine probe
```

## Configuration

`TonePerfect::Client.new(api_key: nil, base_url: nil, timeout: 60, max_retries: 2, headers: {})`. `api_key`
defaults to `ENV["TONEPERFECT_API_KEY"]`, `base_url` to `ENV["TONEPERFECT_BASE_URL"]`, else
`https://api.toneperfect.app` (a proxy with a 26-second limit: a longer passage comes back on the automatic
retry, charged once). `headers:` adds headers to every request, for example `TonePerfect-Fallback: off`.

Grades are display scores calibrated per language against native references, not accuracy percentages and not
comparable across vendors. Every language pack is labelled `experimental` in `/v1/capabilities`.
Docs: https://api.toneperfect.app/docs · MIT licence · nik@toneperfect.app

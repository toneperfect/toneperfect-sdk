# TonePerfect SDKs

Open-source clients for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app),
10 languages: `zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR`, `ja-JP`.
Send a short scripted recording and the text it should contain, get 0–100 scores for the sentence,
every word and every sound. Mandarin syllables also get separate initial, final and tone scores.

All six clients are version **0.3.0** and share one design (see below). Each README's examples run in CI
(`testing/run_readme_examples.py`).

| Language | Install | Source |
| --- | --- | --- |
| Python 3.9+ (stdlib only) | `pip install toneperfect` | [`python/`](python/) |
| Node.js 18+ (ESM + CJS, types, no deps) | `npm install toneperfect` | [`node/`](node/) |
| Dart 3 / Flutter | `dart pub add toneperfect` | [`dart/`](dart/) |
| Ruby 3.0+ (stdlib only) | `gem install toneperfect` | [`ruby/`](ruby/) |
| PHP 8.0+ (ext-curl, no deps) | `composer require toneperfect/toneperfect` | [`php/`](php/) |
| Go 1.21+ (stdlib only) | `go get github.com/vm542/toneperfect-sdk/go@v0.3.0` | [`go/`](go/) |

```python
from toneperfect import TonePerfect
client = TonePerfect()  # reads TONEPERFECT_API_KEY; a tp_test_ key returns fixed example results for free
result = client.assess("hello.ogg", text="你好", language="zh-CN")
print(result.assessable, result.overall, result.billing.credits)
```

**New accounts get 50 free credits, no card needed**: [sign up](https://api.toneperfect.app/signup), then create
a key (or a free test key) in the dashboard. Plans from $10/month ([pricing](https://api.toneperfect.app/pricing/)).
No SDK needed either: the API is one multipart `POST`; see the [quickstart](https://api.toneperfect.app/quickstart/).

## What every client does

- `capabilities()`, `assess()`, `lint()` and `status()`: `GET /v1/capabilities`, `POST /v1/assess`,
  `POST /v1/lint` and `GET /v1/status`. Accounts, keys and billing stay in the dashboard.
- `assess` requires `language`, sends `Authorization: Bearer <key>` and an `Idempotency-Key` (a UUID per call),
  sets the audio type from the file name, and accepts `pinyin`, `task`, `compact` and `test_outcome`.
- Typed results: the assessment, its words (`word`, `score`, timings, `decision`, `pinyin`) and their sounds
  (`dimension`, `expected`, `heard`, `score`, `decision`), and `billing` (`credits`, balances, `source`). Full and
  compact responses read the same way; the raw JSON stays available.
- Errors: `TonePerfectError` and its subclasses `AuthenticationError` (401), `PaymentRequiredError` (402, with a
  billing link and, when the API sends them, the plans page and cheapest plan), `RateLimitError` (429),
  `ValidationError` (other 4xx), `ServerError` (5xx) and `APIConnectionError` (timeouts, network). Each says
  whether to retry with the same key (`retryable`) or start again with a new one (`needs new key`).
- Retries: failures that stored nothing (busy, rate limit, upload timeout, engine unavailable, proxy 502/504,
  timeouts) are retried with the same key, up to `max retries` (default 2), honouring `Retry-After`. A result that
  finished after a timeout comes back on the retry and is charged once.
- Configuration: API key from `TONEPERFECT_API_KEY`, origin from `TONEPERFECT_BASE_URL`, timeout (default 60 s),
  extra headers (for example `TonePerfect-Fallback: off`).

Grades are display scores calibrated per language against native references, not accuracy percentages and not
comparable across vendors. Every language pack is labelled `experimental` in `/v1/capabilities`.

## Development

```sh
python3 testing/run_readme_examples.py                 # every README block, against testing/mock_api.py
python3 testing/run_readme_examples.py --gateway 1110  # the same against the 2026-11-10 gateway behaviour
TONEPERFECT_API_KEY=tp_test_... python3 testing/run_readme_examples.py --live   # live API, test key, 1 request / 4 s
cd python && PYTHONPATH=src python3 -m unittest discover -s tests -v
cd node && npm test
cd dart && dart pub get && dart analyze && dart test
cd ruby && ruby -Ilib -Itest test/test_client.rb
cd go && go vet ./... && go test ./...
composer validate --strict && php php/tests/run.php
```

The tests start `testing/mock_api.py` (Python 3, standard library). Releasing: [RELEASE.md](RELEASE.md).
MIT licensed. Questions: nik@toneperfect.app

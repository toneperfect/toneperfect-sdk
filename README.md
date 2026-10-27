# TonePerfect SDKs

Thin, open-source clients for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app),
10 languages: `zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR` (beta), `ja-JP` (beta).
Send a short scripted recording and the text it should contain, get 0–100 scores for the sentence,
every word and every sound. Mandarin syllables also get separate initial, final and tone scores.

| Language | Install | Source |
| --- | --- | --- |
| Python 3.9+ (stdlib only) | `pip install "toneperfect @ git+https://github.com/vm542/toneperfect-sdk@main#subdirectory=python"` | [`python/`](python/) |
| Node.js 18+ (ESM + CJS, no deps, types) | `npm install toneperfect` | [`node/`](node/) |
| Dart / Flutter | `dart pub add toneperfect` | [`dart/`](dart/) |
| Ruby 2.7+ (stdlib only) | Bundler from Git, see [`ruby/README.md`](ruby/README.md) | [`ruby/`](ruby/) |
| PHP 8.0+ (ext-curl, no deps) | Composer `path` repository, see [`php/README.md`](php/README.md) | [`php/`](php/) |
| Go 1.21+ (stdlib only) | `go get github.com/vm542/toneperfect-sdk/go@main` | [`go/`](go/) |

Only the npm (`toneperfect`) and pub.dev (`toneperfect`) packages are published by us. The
Python, Ruby and PHP clients are **not** on PyPI, RubyGems or Packagist yet: install them from
this repository as shown, and do not install a package of that name from those registries
until it is announced here.

Each wraps exactly the two public endpoints — `GET /v1/capabilities` (no key) and
`POST /v1/assess` (`Authorization: Bearer`, `Idempotency-Key`, multipart `audio` + `text` +
`language`, optional `pinyin` and `task`) — with typed errors (`PaymentRequiredError` for 402,
`AuthenticationError`, `RateLimitError`, …) and safe idempotent retries.

```python
from toneperfect import TonePerfect
client = TonePerfect(api_key="tp_live_...")
result = client.assess("hello.wav", text="你好", language="zh-CN")
print(result.assessable, result.overall, result.billing)
```

**New accounts get 50 free credits, no card needed** — [sign up](https://api.toneperfect.app/signup),
create a key in the dashboard. Then plans from $10/month ([pricing](https://api.toneperfect.app/pricing/)).

- API reference: https://api.toneperfect.app/docs
- Quickstart: https://api.toneperfect.app/quickstart/
- OpenAPI: https://api.toneperfect.app/openapi.json
- How scores are produced: https://api.toneperfect.app/methodology/

Grades are display scores calibrated per language against native references — not accuracy
percentages and not comparable across vendors. Every language pack is currently labelled
`experimental` in `/v1/capabilities`.

## Development

```sh
cd python && PYTHONPATH=src python -m unittest discover -s tests -v
cd node && npm test
cd dart && dart pub get && dart test
cd ruby && ruby -Ilib -Itest test/test_client.rb && gem build toneperfect.gemspec
cd go && go vet ./... && go test ./...
cd php && php tests/run.php
```

MIT licensed. Questions: nik@toneperfect.app

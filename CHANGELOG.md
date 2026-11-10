# Changelog

## 0.3.0 (all six clients)

One version and one design for Python, Node.js, Dart, Ruby, PHP and Go. It replaces both the 0.1.0 / 0.1.1
packages on npm and pub.dev and the single-file "0.2" clients the website served.

- `language` is required in `assess` and `lint` (the API scored a request without it as Mandarin).
- Typed results: words and sounds as objects that read full and compact responses alike; `billing` with `source`.
- Automatic retries of failures that stored nothing, with the same Idempotency-Key (`max_retries`, default 2;
  `Retry-After` honoured). `engine_unavailable`, `request_interrupted`, `result_held`, `uploads_in_progress`
  are retryable; a 5xx is never `finalized`.
- Error classes in every language (`AuthenticationError`, `PaymentRequiredError`, `RateLimitError`,
  `ValidationError`, `ServerError`, `APIConnectionError`). A 402 carries a billing link (the API's, else the
  dashboard's billing tab) and, when the API sends them, `pricing_url` and `plan`; `subscription_past_due`.
- `lint()`, `status()`, `compact`, `test_outcome`, audio type from the file name, extra headers,
  `TONEPERFECT_BASE_URL`. Default timeout 60 s.
- Idempotency keys are UUIDs; any 1–255 printable ASCII key is accepted (the API is the judge).
- Go: module path `github.com/vm542/toneperfect-sdk/go`. Ruby: 3.0+. PHP: `composer.json` at the repository root.

## 0.1.x

First releases: Python, Node.js (npm 0.1.0) and Dart (pub.dev 0.1.1), then Ruby, PHP and Go (unpublished).

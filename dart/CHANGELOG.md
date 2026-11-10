## 0.3.0

- One version across the six TonePerfect SDKs (Python, Node.js, Dart, Ruby, PHP, Go).
- `language` is required (the API scored a request without it as Mandarin).
- Typed results: `Word`, `Phone` and `Billing` getters that read full and compact responses alike.
- Automatic retries of failures that stored nothing, with the same Idempotency-Key (`maxRetries`,
  default 2; `Retry-After` honoured); a 5xx is never `finalized`.
- 402: `billingUrl`, plus `pricingUrl` and `plan` when the API sends them; `subscription_past_due`.
- `lint()`, `status()`, `compact`, `testOutcome`, `contentType` (from the file name), `headers`.
- `apiKey` and `baseUrl` default to `TONEPERFECT_API_KEY` and `TONEPERFECT_BASE_URL` (not on the web).
- Default timeout 60 s. Idempotency keys are UUIDs; any 1–255 printable ASCII key is accepted.

## 0.1.1

- Package links point to the API documentation (https://api.toneperfect.app/docs).

## 0.1.0

- First release: `capabilities()` (`GET /v1/capabilities`) and `assess()` (`POST /v1/assess`)
  with Bearer auth, `Idempotency-Key` handling and typed errors
  (`AuthenticationError`, `PaymentRequiredError` for 402, `RateLimitError`, `ValidationError`,
  `ServerError`, `APIConnectionError`).

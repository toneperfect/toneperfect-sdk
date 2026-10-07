## 0.1.1

- Package links point to the API documentation (https://api.toneperfect.app/docs).

## 0.1.0

- First release: `capabilities()` (`GET /v1/capabilities`) and `assess()` (`POST /v1/assess`)
  with Bearer auth, `Idempotency-Key` handling and typed errors
  (`AuthenticationError`, `PaymentRequiredError` for 402, `RateLimitError`, `ValidationError`,
  `ServerError`, `APIConnectionError`).

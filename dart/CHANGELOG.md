## 0.1.0

- First release: `capabilities()` (`GET /v1/capabilities`) and `assess()` (`POST /v1/assess`)
  with Bearer auth, `Idempotency-Key` handling and typed errors
  (`AuthenticationError`, `PaymentRequiredError` for 402, `RateLimitError`, `ValidationError`,
  `ServerError`, `APIConnectionError`).

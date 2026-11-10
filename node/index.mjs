// ESM entry: re-exports the CommonJS implementation so both module systems share one file.
import mod from './index.cjs';
export const {
  TonePerfect, Assessment, Word, Phone,
  TonePerfectError, AuthenticationError, PaymentRequiredError, RateLimitError, ValidationError, ServerError, APIConnectionError,
  newIdempotencyKey, DEFAULT_BASE_URL, BILLING_URL, TASKS, TEST_OUTCOMES, DECISIONS, RETRY_SAME_KEY_CODES, NEW_KEY_CODES, VERSION,
} = mod;
export default mod;

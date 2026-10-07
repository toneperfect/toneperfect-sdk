// ESM entry: re-exports the CommonJS implementation so both module systems share one file.
import mod from './index.cjs';
export const { TonePerfect, TonePerfectError, AuthenticationError, PaymentRequiredError, RateLimitError, ValidationError, ServerError, APIConnectionError, Assessment, newIdempotencyKey, DEFAULT_BASE_URL, TASKS, DECISIONS, RETRY_SAME_KEY_CODES, VERSION } = mod;
export default mod;

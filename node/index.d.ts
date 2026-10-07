/// <reference types="node" />
export declare const VERSION: string;
export declare const DEFAULT_BASE_URL: string;
export declare const TASKS: readonly ['general', 'connected_speech', 'isolated_word'];
export type Task = (typeof TASKS)[number];
/** review / uncertain / no_correction are the feedback decisions; unassessable, partial and
 *  legacy_correction also occur. Unknown values should be treated as "no decision". */
export type Decision = 'review' | 'uncertain' | 'no_correction' | 'unassessable' | 'partial' | 'legacy_correction' | (string & {});
export declare const DECISIONS: readonly ['review', 'uncertain', 'no_correction', 'unassessable', 'partial', 'legacy_correction'];
/** Error codes after which the SAME Idempotency-Key must be retried. */
export declare const RETRY_SAME_KEY_CODES: ReadonlySet<string>;

/** One sound (phoneme, or Mandarin initial/final/tone) under a word. Extra evidence fields may be present. */
export interface Phone {
  dimension?: 'initial' | 'final' | 'tone' | string;
  expected: string | number | null;
  heard: string | number | null;
  score: number | null;
  decision?: Decision;
  [key: string]: unknown;
}

/** One word or Mandarin character. */
export interface Word {
  word: string;
  score: number | null;
  start_ms?: number;
  end_ms?: number;
  pinyin?: string;
  decision?: Decision;
  phones?: Phone[];
  [key: string]: unknown;
}

export interface Billing { credits: number; balance_credits: number }

/** Full JSON body of POST /v1/assess. Fields beyond these are returned as-is. */
export interface AssessmentData {
  assessable: boolean;
  reason?: string;
  scores: Record<string, number | null> & { overall?: number | null };
  words?: Word[];
  syllables?: unknown[];
  billing: Billing;
  model_version?: string;
  id?: string;
  [key: string]: unknown;
}

export interface CapabilityLanguage {
  locale: string;
  available?: boolean;
  status?: string;
  dimensions?: string[];
  correction_level?: string;
  limitations?: unknown;
  [key: string]: unknown;
}

export interface Capabilities {
  model_version?: string;
  languages: CapabilityLanguage[];
  limits?: { max_audio_seconds: number; max_upload_bytes: number; concurrent_requests_per_account: number };
  score_scale?: Record<string, unknown>;
  [key: string]: unknown;
}

export declare class TonePerfectError extends Error {
  /** HTTP status, or 0 for a transport failure (code `timeout` / `network_error`). */
  status: number;
  /** API error code: invalid_api_key, subscription_required, insufficient_credits, invalid_audio, rate_limit, ... */
  code: string;
  detail: string;
  requestId: string | null;
  retryAfter: number | null;
  /** The error body as returned by the API. */
  body: Record<string, unknown>;
  /** `req_…` result id when the failure was finalized under your Idempotency-Key. */
  id: string | null;
  billing: Billing | null;
  /** The failure is a stored result for this key (id + billing present); the same key replays it for 24 h. */
  readonly finalized: boolean;
  /** Start a new attempt with a new Idempotency-Key. */
  readonly needsNewKey: boolean;
  /** Nothing was finalized: retry later with the SAME Idempotency-Key. */
  readonly retryable: boolean;
  constructor(status: number, code: string, message: string, requestId?: string | null, retryAfter?: number | null, body?: Record<string, unknown> | null);
}
/** 401: missing, revoked or unknown API key. */
export declare class AuthenticationError extends TonePerfectError {}
/** 402: nothing charged. code: subscription_required | insufficient_credits | payment_balance_due. */
export declare class PaymentRequiredError extends TonePerfectError {}
/** 429: rate_limit or account_busy. Retry with the same Idempotency-Key. */
export declare class RateLimitError extends TonePerfectError {}
/** Other 4xx: fix the request. */
export declare class ValidationError extends TonePerfectError {}
/** 5xx. */
export declare class ServerError extends TonePerfectError {}
/** Transport failure (status 0): timeout or network_error. */
export declare class APIConnectionError extends TonePerfectError {}

export declare class Assessment {
  data: AssessmentData;
  status: number;
  headers: Headers;
  requestId: string | null;
  /** True when the result was replayed from a previous identical request (not charged again). */
  replayed: boolean;
  constructor(data: AssessmentData, status: number, headers: Headers);
  readonly assessable: boolean;
  readonly reason: string | null;
  readonly scores: AssessmentData['scores'];
  readonly overall: number | null;
  readonly words: Word[];
  readonly billing: Billing | Record<string, never>;
  readonly modelVersion: string | null;
  readonly id: string | null;
}

export type AudioInput = string | URL | Buffer | Uint8Array | ArrayBuffer | Blob;

export interface AssessFields {
  /** Reference text the learner read. Required unless `pinyin` is given (Mandarin). */
  text?: string;
  /** Locale such as zh-CN, en-US, fr-FR. Default zh-CN. See capabilities(). */
  language?: string;
  /** Explicit Mandarin reading with numbered tones, e.g. "ni3 hao3". */
  pinyin?: string;
  /** general (default), connected_speech or isolated_word. */
  task?: Task;
  /** Unique per attempt; generated when omitted. Reuse for retries of an unknown outcome. */
  idempotencyKey?: string;
  filename?: string;
  contentType?: string;
}

export interface TonePerfectOptions {
  apiKey?: string;
  baseUrl?: string;
  timeoutMs?: number;
  fetch?: typeof fetch;
  userAgent?: string;
}

export declare class TonePerfect {
  apiKey: string;
  baseUrl: string;
  timeoutMs: number;
  constructor(options?: TonePerfectOptions);
  /** GET /v1/capabilities (no key needed). */
  capabilities(): Promise<Capabilities>;
  /** POST /v1/assess. Throws TonePerfectError for every non-2xx status. */
  assess(audio: AudioInput, fields?: AssessFields): Promise<Assessment>;
}

export declare function newIdempotencyKey(prefix?: string): string;

declare const _default: {
  TonePerfect: typeof TonePerfect;
  TonePerfectError: typeof TonePerfectError;
  Assessment: typeof Assessment;
  newIdempotencyKey: typeof newIdempotencyKey;
  DEFAULT_BASE_URL: string;
  TASKS: typeof TASKS;
  DECISIONS: typeof DECISIONS;
  RETRY_SAME_KEY_CODES: typeof RETRY_SAME_KEY_CODES;
  VERSION: string;
};
export default _default;

// Types for toneperfect 0.3.0 (CommonJS and ESM entries share them).

export declare const VERSION: string;
export declare const DEFAULT_BASE_URL: string;
export declare const BILLING_URL: string;
export declare const TASKS: readonly Task[];
export declare const TEST_OUTCOMES: readonly TestOutcome[];
export declare const DECISIONS: readonly string[];
export declare const RETRY_SAME_KEY_CODES: ReadonlySet<string>;
export declare const NEW_KEY_CODES: ReadonlySet<string>;

export type Locale = 'zh-CN' | 'en-US' | 'fr-FR' | 'es-419' | 'de-DE' | 'it-IT' | 'pt-BR' | 'ru-RU' | 'ko-KR' | 'ja-JP';
export type Task = 'general' | 'connected_speech' | 'isolated_word';
export type TestOutcome = 'success' | 'unassessable' | 'invalid_assessment' | 'engine_unavailable' | 'subscription_required'
  | 'subscription_past_due' | 'insufficient_credits' | 'account_busy' | 'rate_limit';
/** review / uncertain / no_correction, plus unassessable, partial, legacy_correction; treat others as "no decision". */
export type Decision = 'review' | 'uncertain' | 'no_correction' | 'unassessable' | 'partial' | 'legacy_correction' | (string & {});
/** A file path, URL, Buffer (a Uint8Array), Uint8Array, ArrayBuffer or Blob. */
export type AudioInput = string | URL | Uint8Array | ArrayBuffer | Blob;

export interface ClientOptions {
  /** tp_live_… or a tp_test_… test key. Default: process.env.TONEPERFECT_API_KEY. */
  apiKey?: string;
  /** Default: process.env.TONEPERFECT_BASE_URL, else https://api.toneperfect.app. */
  baseUrl?: string;
  /** Per-request timeout in milliseconds (default 60 000). */
  timeoutMs?: number;
  /** Automatic retries of a retryable failure, with the same Idempotency-Key (default 2). */
  maxRetries?: number;
  /** Extra headers for every request, e.g. { 'TonePerfect-Fallback': 'off' }. */
  headers?: Record<string, string>;
  fetch?: typeof fetch;
  userAgent?: string;
}

export interface AssessFields {
  /** Required locale. */
  language: Locale | (string & {});
  /** What the learner was asked to say. Mandarin may send toned pinyin instead. */
  text?: string;
  /** Mandarin: picks the reading of a polyphone next to characters, or toned pinyin alone. */
  pinyin?: string;
  task?: Task;
  /** One per recording attempt; made for you and reused by the automatic retries. */
  idempotencyKey?: string;
  filename?: string;
  contentType?: string;
  /** Ask for the stable compact schema (toneperfect.compact.v1). */
  compact?: boolean;
  /** tp_test_ keys only. */
  testOutcome?: TestOutcome;
}

/** 0–100 display grades; null = not measured by this pack. */
export interface Scores {
  overall: number | null;
  pronunciation?: number | null;
  initial?: number | null;
  final?: number | null;
  tone?: number | null;
  integrity?: number | null;
  completeness?: number | null;
  fluency?: number | null;
  rhythm?: number | null;
  [dimension: string]: number | null | undefined;
}

export interface Billing {
  credits: number;
  balanceCredits: number | null;
  freeCredits: number | null;
  /** free, plan or test. */
  source: 'free' | 'plan' | 'test' | null;
  /** The raw snake_case fields are kept too. */
  [field: string]: unknown;
}

export declare class Phone {
  /** phoneme, or initial / final / tone in Mandarin. */
  readonly dimension: string | null;
  readonly expected: string | number | null;
  readonly heard: string | number | null;
  readonly score: number | null;
  readonly decision: Decision | null;
  readonly data: Record<string, unknown>;
}

export declare class Word {
  readonly word: string | null;
  readonly score: number | null;
  readonly startMs: number | null;
  readonly endMs: number | null;
  readonly decision: Decision | null;
  readonly pinyin: string | null;
  readonly phones: Phone[];
  readonly data: Record<string, unknown>;
}

export declare class Assessment {
  /** The JSON body exactly as returned (full or compact schema). */
  readonly data: Record<string, any>;
  readonly status: number;
  readonly headers: Headers;
  readonly requestId: string | null;
  readonly replayed: boolean;
  readonly idempotencyKey: string;
  readonly id: string | null;
  /** false when the recording could not be scored: see reason. Free, never a score of zero. */
  readonly assessable: boolean;
  readonly reason: string | null;
  readonly scores: Scores;
  readonly overall: number | null;
  readonly words: Word[];
  readonly warnings: string[];
  readonly billing: Billing;
  readonly modelVersion: string | null;
  /** primary or fallback. */
  readonly engine: string | null;
  /** true for a fixed example response from a tp_test_ key. */
  readonly test: boolean;
  readonly compact: boolean;
}

export declare class TonePerfectError extends Error {
  readonly status: number;
  readonly code: string;
  /** The API's message, written for people. */
  readonly detail: string;
  readonly requestId: string | null;
  readonly retryAfter: number | null;
  readonly body: Record<string, any>;
  readonly idempotencyKey: string | null;
  readonly id: string | null;
  readonly billing: Record<string, unknown> | null;
  /** 402: where to start, renew or fix a plan. */
  readonly billingUrl: string | null;
  readonly pricingUrl: string | null;
  readonly plan: { id?: string; name?: string; monthly_credits?: number; price_usd?: number; interval?: string } | null;
  readonly finalized: boolean;
  readonly needsNewKey: boolean;
  readonly retryable: boolean;
}
export declare class AuthenticationError extends TonePerfectError {}
export declare class PaymentRequiredError extends TonePerfectError {}
export declare class RateLimitError extends TonePerfectError {}
export declare class ValidationError extends TonePerfectError {}
export declare class ServerError extends TonePerfectError {}
export declare class APIConnectionError extends TonePerfectError {}

export interface LintIssue { code: string; message: string; field?: 'text' | 'pinyin'; severity: 'error' | 'warning'; }
export interface LintResult { ok: boolean; language: string; issues: LintIssue[]; units: number; }

export declare class TonePerfect {
  constructor(options?: ClientOptions);
  readonly apiKey: string;
  readonly baseUrl: string;
  readonly timeoutMs: number;
  readonly maxRetries: number;
  capabilities(): Promise<Record<string, any>>;
  lint(text: string, options: { language: Locale | (string & {}); pinyin?: string; task?: Task }): Promise<LintResult>;
  status(): Promise<Record<string, any>>;
  assess(audio: AudioInput, fields: AssessFields): Promise<Assessment>;
}

export declare function newIdempotencyKey(): string;

declare const _default: {
  TonePerfect: typeof TonePerfect; Assessment: typeof Assessment; Word: typeof Word; Phone: typeof Phone;
  TonePerfectError: typeof TonePerfectError; AuthenticationError: typeof AuthenticationError; PaymentRequiredError: typeof PaymentRequiredError;
  RateLimitError: typeof RateLimitError; ValidationError: typeof ValidationError; ServerError: typeof ServerError; APIConnectionError: typeof APIConnectionError;
  newIdempotencyKey: typeof newIdempotencyKey; DEFAULT_BASE_URL: string; BILLING_URL: string; VERSION: string;
};
export default _default;

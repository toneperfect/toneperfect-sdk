'use strict';
/**
 * TonePerfect pronunciation assessment API client (Node 18+, no dependencies).
 *
 * Wraps the public endpoints of https://api.toneperfect.app:
 *   GET  /v1/capabilities  -> languages served, limits, model version (no key)
 *   POST /v1/assess        -> score one scripted recording
 *   POST /v1/lint          -> check a reference text before recording (free, no key)
 *   GET  /v1/status        -> synthetic engine probe summary (free, no key)
 *
 * Accounts, API keys and billing are managed in the web dashboard (session-based routes,
 * deliberately not wrapped). Docs: https://api.toneperfect.app/docs
 */
const { randomUUID } = require('node:crypto');
const { readFile } = require('node:fs/promises');
const path = require('node:path');

const VERSION = '0.3.0';
const DEFAULT_BASE_URL = 'https://api.toneperfect.app';
/** Where a 402 is fixed. A 402 from the API may carry its own billing_url. */
const BILLING_URL = 'https://api.toneperfect.app/dashboard?tab=billing';
const TASKS = Object.freeze(['general', 'connected_speech', 'isolated_word']);
/** Outcomes a tp_test_ key can rehearse (testOutcome on assess()). */
const TEST_OUTCOMES = Object.freeze(['success', 'unassessable', 'invalid_assessment', 'engine_unavailable', 'subscription_required', 'subscription_past_due', 'insufficient_credits', 'account_busy', 'rate_limit']);
/** Values of `decision`. review / uncertain / no_correction are the feedback decisions; unassessable, partial and
 *  legacy_correction also occur. Treat unknown values as "no decision". */
const DECISIONS = Object.freeze(['review', 'uncertain', 'no_correction', 'unassessable', 'partial', 'legacy_correction']);
/** Error codes after which the SAME Idempotency-Key is retried: nothing was stored under it. */
const RETRY_SAME_KEY_CODES = new Set(['rate_limit', 'account_busy', 'uploads_in_progress', 'gateway_busy', 'decoder_busy', 'audio_decoder_unavailable', 'upload_timeout', 'request_pending', 'request_interrupted', 'engine_unavailable', 'result_held', 'timeout', 'network_error']);
/** Error codes that mean the key is spent: start a new attempt with a new key. */
const NEW_KEY_CODES = new Set(['idempotency_expired', 'idempotency_conflict']);
/** free_capacity (429): free credits reached today's shared limit; clears at the next UTC day or with a plan. */
const NOT_RETRYABLE_CODES = new Set(['free_capacity']);
const CONTENT_TYPES = { '.wav': 'audio/wav', '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.mp4': 'audio/mp4', '.aac': 'audio/aac', '.ogg': 'audio/ogg', '.oga': 'audio/ogg', '.opus': 'audio/ogg', '.webm': 'audio/webm', '.flac': 'audio/flac' };

/** A fresh Idempotency-Key (a UUID) for one recording attempt. assess() makes one per call and reuses it for its
 *  own retries; pass your own to resend the same recording safely across restarts. */
function newIdempotencyKey() { return randomUUID(); }

/**
 * Base class of every error: each non-2xx response and each transport failure (status 0).
 * `code` and `detail` come from the API's `error` object; branch on `code`.
 *  - retryable: nothing was stored under the key; the client already retried with the SAME key up to maxRetries.
 *  - needsNewKey: the failure is stored under the key (finalized: a 4xx with a `req_…` id and billing, such as
 *    invalid_assessment) or the key expired or conflicts. A new attempt needs a new key.
 *  - otherwise: fix the request (invalid_api_key, invalid_audio, unsupported_language, …).
 */
class TonePerfectError extends Error {
  constructor(status, code, detail, requestId = null, retryAfter = null, body = null, idempotencyKey = null) {
    const error = body && typeof body === 'object' && body.error && typeof body.error === 'object' ? body.error : {};
    const billingUrl = error.billing_url || (status === 402 ? BILLING_URL : null);
    super(`${status} ${code}: ${detail}${billingUrl && !String(detail).includes(billingUrl) ? ` (${billingUrl})` : ''}`);
    this.name = new.target.name;
    this.status = status;
    this.code = code;
    /** The API's message, as written for people. */
    this.detail = detail;
    this.requestId = requestId;
    this.retryAfter = retryAfter;
    this.body = body && typeof body === 'object' ? body : {};
    this.idempotencyKey = idempotencyKey;
    /** `req_…` result id when the failure is stored under the key. */
    this.id = typeof this.body.id === 'string' ? this.body.id : null;
    this.billing = this.body.billing && typeof this.body.billing === 'object' ? this.body.billing : null;
    /** 402: where to start, renew or fix a plan (the API's link, else the dashboard billing tab). */
    this.billingUrl = billingUrl;
    /** 402: the plans page and the least expensive plan on sale, when the API sends them. */
    this.pricingUrl = error.pricing_url || null;
    this.plan = error.plan && typeof error.plan === 'object' ? error.plan : null;
  }
  /** The failure is a stored result for this key: a 4xx with id and billing. A 5xx is never stored. */
  get finalized() { return this.id !== null && this.billing !== null && this.status < 500; }
  /** Start a new attempt with a new Idempotency-Key; the old key replays this response. */
  get needsNewKey() { return this.finalized || NEW_KEY_CODES.has(this.code); }
  /** Retry later with the SAME Idempotency-Key: nothing was stored under it. */
  get retryable() {
    if (this.finalized || NEW_KEY_CODES.has(this.code) || NOT_RETRYABLE_CODES.has(this.code)) return false;
    return RETRY_SAME_KEY_CODES.has(this.code) || [0, 408, 429, 502, 503, 504].includes(this.status);
  }
}
/** 401: missing, unknown or revoked key. Send `Authorization: Bearer KEY`. */
class AuthenticationError extends TonePerfectError {}
/** 402: nothing charged. subscription_required, subscription_past_due, insufficient_credits or payment_balance_due; see billingUrl. */
class PaymentRequiredError extends TonePerfectError {}
/** 429: rate_limit, account_busy, uploads_in_progress (retried) or free_capacity (not retried). */
class RateLimitError extends TonePerfectError {}
/** Any other 4xx: the request needs a fix. needsNewKey tells whether to change the key. */
class ValidationError extends TonePerfectError {}
/** 5xx: never stored, never charged; retried with the same key. */
class ServerError extends TonePerfectError {}
/** Transport failure (status 0): timeout or network_error. The outcome is unknown; retried with the same key. */
class APIConnectionError extends TonePerfectError {}

function errorClass(status) {
  if (status === 0) return APIConnectionError;
  if (status === 401) return AuthenticationError;
  if (status === 402) return PaymentRequiredError;
  if (status === 429) return RateLimitError;
  if (status >= 500) return ServerError;
  if (status >= 400) return ValidationError;
  return TonePerfectError;
}

/** One scored unit under a word: a phoneme, or a Mandarin initial, final or tone. `data` is the raw JSON. */
class Phone {
  constructor(d) {
    this.dimension = d.dimension ?? null; this.expected = d.expected ?? null; this.heard = d.heard ?? null;
    this.score = d.score ?? null; this.decision = d.decision ?? null; this.data = d;
  }
}
/** One word (one character in Mandarin). Full and compact responses map to the same fields. */
class Word {
  constructor(d) {
    this.word = d.word ?? d.text ?? null; this.score = d.score ?? null; this.startMs = d.start_ms ?? null; this.endMs = d.end_ms ?? null;
    this.decision = d.decision ?? null; this.pinyin = d.pinyin ?? null;
    this.phones = (Array.isArray(d.phones) ? d.phones : Array.isArray(d.units) ? d.units : []).filter(p => p && typeof p === 'object').map(p => new Phone(p));
    this.data = d;
  }
}

/** One POST /v1/assess result: `data` is the JSON body as returned (full or compact); getters are typed views of it. */
class Assessment {
  constructor(data, status, headers, idempotencyKey) {
    this.data = data;
    this.status = status;
    this.headers = headers;
    this.requestId = headers.get('x-request-id') || null;
    this.replayed = (headers.get('idempotent-replayed') || '').toLowerCase() === 'true';
    this.idempotencyKey = headers.get('idempotency-key') || idempotencyKey;
  }
  get id() { return this.data.id || this.requestId; }
  /** false when the audio could not be scored (silence, another text): see `reason`. Free, never a zero score. */
  get assessable() { return Boolean(this.data.assessable); }
  get reason() { return this.data.reason ?? null; }
  /** 0–100 display grades per dimension; null = not measured by this pack. */
  get scores() { return this.data.scores || {}; }
  get overall() { return this.scores.overall ?? null; }
  get words() { return (Array.isArray(this.data.words) ? this.data.words : []).filter(w => w && typeof w === 'object').map(w => new Word(w)); }
  get warnings() { return (Array.isArray(this.data.warnings) ? this.data.warnings : []).filter(w => typeof w === 'string'); }
  /** {credits, balance_credits, free_credits, source: free | plan | test}. */
  get billing() { const b = this.data.billing || {}; return { credits: b.credits ?? 0, balanceCredits: b.balance_credits ?? null, freeCredits: b.free_credits ?? null, source: b.source ?? null, ...b }; }
  get modelVersion() { return this.data.model_version ?? null; }
  /** primary or fallback (engine_route.engine). */
  get engine() { return (this.data.engine_route && this.data.engine_route.engine) || this.headers.get('x-toneperfect-engine') || null; }
  /** true for a fixed example response from a tp_test_ key (no audio scored, nothing charged). */
  get test() { return this.data.test === true; }
  get compact() { return this.data.schema === 'toneperfect.compact.v1'; }
}

async function toBlob(audio, contentType) {
  if (typeof Blob !== 'undefined' && audio instanceof Blob) return audio;
  if (typeof audio === 'string' || audio instanceof URL) return new Blob([await readFile(audio)], { type: contentType });
  if (audio instanceof ArrayBuffer || ArrayBuffer.isView(audio)) return new Blob([audio], { type: contentType });
  throw new TypeError('audio must be a file path, URL, Buffer/Uint8Array, ArrayBuffer or Blob');
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function backoffMs(error, attempt) {
  if (error.retryAfter !== null && error.retryAfter !== undefined) return Math.max(0, Math.min(error.retryAfter, 30)) * 1000;
  const base = error.code === 'engine_unavailable' ? 2000 : 500;
  return Math.min(base * 2 ** attempt, 8000) + Math.random() * 250;
}

class TonePerfect {
  /**
   * @param {object} [options]
   * @param {string} [options.apiKey]     tp_live_… (or a tp_test_… test key). Default: process.env.TONEPERFECT_API_KEY.
   * @param {string} [options.baseUrl]    Default: process.env.TONEPERFECT_BASE_URL, else https://api.toneperfect.app
   *   (a proxy with a 26 s limit: a longer assessment comes back on the automatic retry, charged once).
   * @param {number} [options.timeoutMs]  per-request timeout, default 60 000.
   * @param {number} [options.maxRetries] automatic retries of a retryable failure with the same key, default 2.
   * @param {Record<string,string>} [options.headers] extra headers for every request, e.g. {'TonePerfect-Fallback': 'off'}.
   * @param {typeof fetch} [options.fetch] custom fetch (tests, proxies).
   */
  constructor(options = {}) {
    this.apiKey = options.apiKey ?? process.env.TONEPERFECT_API_KEY ?? '';
    this.baseUrl = (options.baseUrl || process.env.TONEPERFECT_BASE_URL || DEFAULT_BASE_URL).replace(/\/+$/, '');
    this.timeoutMs = options.timeoutMs ?? 60_000;
    this.maxRetries = Math.max(0, options.maxRetries ?? 2);
    this.headers = { ...(options.headers || {}) };
    this.fetch = options.fetch || globalThis.fetch;
    this.userAgent = options.userAgent || `toneperfect-node/${VERSION}`;
    if (typeof this.fetch !== 'function') throw new Error('Node 18+ (global fetch) is required, or pass options.fetch.');
  }

  /** GET /v1/capabilities (no key): languages[] (locale, status, dimensions, limitations), limits, model_version. */
  async capabilities() { return (await this._call('GET', '/v1/capabilities', () => null, {})).data; }

  /** POST /v1/lint (free, no key): {ok, language, issues: [{code, message, field, severity}], units}. */
  async lint(text, { language, pinyin = '', task = 'general' } = {}) {
    if (!language) throw new TypeError('language is required, for example "en-US" or "zh-CN"');
    const body = JSON.stringify({ text: text || '', language, pinyin: pinyin || '', task });
    return (await this._call('POST', '/v1/lint', () => body, { 'Content-Type': 'application/json' })).data;
  }

  /** GET /v1/status (no key): the synthetic engine probe (status, last_check, last_24h, last_7d). */
  async status() { return (await this._call('GET', '/v1/status', () => null, {})).data; }

  /**
   * POST /v1/assess: score one scripted recording.
   * @param {string|URL|Buffer|Uint8Array|ArrayBuffer|Blob} audio  WAV, MP3, M4A, Ogg or WebM, 0.15–120 s, up to 10 MB
   * @param {object} fields
   * @param {string} fields.language          required: zh-CN, en-US, fr-FR, es-419, de-DE, it-IT, pt-BR, ru-RU, ko-KR, ja-JP
   * @param {string} [fields.text]            what the learner was asked to say (Mandarin may send toned pinyin instead)
   * @param {string} [fields.pinyin]          Mandarin: picks the reading of a polyphone next to characters, or alone
   * @param {'general'|'connected_speech'|'isolated_word'} [fields.task]
   * @param {string} [fields.idempotencyKey]  one per recording attempt; made for you and reused by the automatic retries
   * @param {string} [fields.filename]        default: the path's name, else "recording"
   * @param {string} [fields.contentType]     default: from the file extension
   * @param {boolean} [fields.compact]        the stable compact schema (toneperfect.compact.v1)
   * @param {string} [fields.testOutcome]     tp_test_ keys only: one of TEST_OUTCOMES
   * @returns {Promise<Assessment>}
   */
  async assess(audio, fields = {}) {
    const { text, language, pinyin, task = 'general' } = fields;
    if (!this.apiKey) throw new AuthenticationError(401, 'invalid_api_key', 'Set apiKey or the TONEPERFECT_API_KEY environment variable.');
    if (!language) throw new TypeError('language is required, for example "en-US" or "zh-CN"');
    if (!TASKS.includes(task)) throw new RangeError(`task must be one of ${TASKS.join(', ')}`);
    if (!text && !pinyin) throw new RangeError('Provide text (or, for Mandarin, pinyin with tones).');
    const key = fields.idempotencyKey || newIdempotencyKey();
    if (!/^[\x20-\x7e]{1,255}$/.test(key)) throw new RangeError('idempotencyKey must be 1-255 printable ASCII characters (a UUID works everywhere)');
    const filename = fields.filename || (typeof audio === 'string' ? path.basename(audio) : audio instanceof URL ? path.basename(audio.pathname) : 'recording');
    const contentType = fields.contentType || CONTENT_TYPES[path.extname(filename).toLowerCase()] || 'application/octet-stream';
    const blob = await toBlob(audio, contentType);
    const form = () => {
      const f = new FormData();
      f.append('audio', blob, filename);
      if (text) f.append('text', text);
      if (pinyin) f.append('pinyin', pinyin);
      f.append('language', language);
      f.append('task', task);
      return f;
    };
    const headers = { Authorization: `Bearer ${this.apiKey}`, 'Idempotency-Key': key };
    if (fields.compact) headers['TonePerfect-Response'] = 'compact';
    if (fields.testOutcome) headers['TonePerfect-Test-Outcome'] = String(fields.testOutcome);
    const { data, status, headers: responseHeaders } = await this._call('POST', '/v1/assess', form, headers, key);
    return new Assessment(data, status, responseHeaders, key);
  }

  async _call(method, route, body, headers, key = null) {
    for (let attempt = 0; ; attempt++) {
      try {
        const { status, headers: responseHeaders, text } = await this._send(method, route, body(), headers);
        return { data: parseJson(status, responseHeaders, text, key), status, headers: responseHeaders };
      } catch (error) {
        if (error instanceof TonePerfectError && key && !error.idempotencyKey) error.idempotencyKey = key;
        if (!(error instanceof TonePerfectError) || attempt >= this.maxRetries || !error.retryable) throw error;
        await sleep(backoffMs(error, attempt));
      }
    }
  }

  async _send(method, route, body, headers) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetch(this.baseUrl + route, {
        method, body, signal: controller.signal,
        headers: { Accept: 'application/json', 'User-Agent': this.userAgent, ...this.headers, ...headers },
      });
      return { status: response.status, headers: response.headers, text: await response.text() };
    } catch (error) {
      if (error && error.name === 'AbortError') throw new APIConnectionError(0, 'timeout', `No response within ${this.timeoutMs} ms; the outcome is unknown, retry with the same Idempotency-Key.`);
      throw new APIConnectionError(0, 'network_error', `Could not reach ${this.baseUrl}: ${error && error.message}`);
    } finally {
      clearTimeout(timer);
    }
  }
}

function parseJson(status, headers, text, key = null) {
  let data = null;
  try { data = text ? JSON.parse(text) : {}; } catch { data = null; }
  if (status >= 200 && status < 300 && data && typeof data === 'object') return data;
  const ra = headers.get('retry-after');
  const retryAfter = ra !== null && ra !== '' && !Number.isNaN(Number(ra)) ? Number(ra) : null;
  const Cls = errorClass(status);
  if (data && typeof data === 'object' && data.error && typeof data.error === 'object') {
    throw new Cls(status, String(data.error.code || 'request_error'), String(data.error.message || ''), data.request_id || headers.get('x-request-id') || null, retryAfter, data, key);
  }
  if (data && typeof data === 'object' && typeof data.detail === 'string') throw new Cls(status, 'http_error', data.detail, headers.get('x-request-id') || null, retryAfter, data, key);
  throw new Cls(status, 'http_error', (text || '').slice(0, 200).trim() || `HTTP ${status}`, headers.get('x-request-id') || null, retryAfter, null, key);
}

module.exports = {
  TonePerfect, Assessment, Word, Phone,
  TonePerfectError, AuthenticationError, PaymentRequiredError, RateLimitError, ValidationError, ServerError, APIConnectionError,
  newIdempotencyKey, DEFAULT_BASE_URL, BILLING_URL, TASKS, TEST_OUTCOMES, DECISIONS, RETRY_SAME_KEY_CODES, NEW_KEY_CODES, VERSION,
};

'use strict';
/**
 * TonePerfect pronunciation assessment API client (Node 18+, no dependencies).
 *
 * Wraps the two public endpoints of https://api.toneperfect.app:
 *   GET  /v1/capabilities  -> languages served, limits, model version
 *   POST /v1/assess        -> score one scripted recording
 *
 * Accounts, API keys and billing are managed in the web dashboard
 * (session-based routes, deliberately not wrapped). Docs: https://api.toneperfect.app/docs
 */
const { randomUUID } = require('node:crypto');
const { readFile } = require('node:fs/promises');

const VERSION = '0.1.0';
const DEFAULT_BASE_URL = 'https://api.toneperfect.app';
const TASKS = Object.freeze(['general', 'connected_speech', 'isolated_word']);
/** Values of `decision` on words and phones. review / uncertain / no_correction are the feedback
 *  decisions; unassessable, partial and legacy_correction also occur. Treat unknown values as "no decision". */
const DECISIONS = Object.freeze(['review', 'uncertain', 'no_correction', 'unassessable', 'partial', 'legacy_correction']);
/** Error codes after which the SAME Idempotency-Key must be retried: nothing was finalized. */
const RETRY_SAME_KEY_CODES = new Set(['rate_limit', 'account_busy', 'gateway_busy', 'decoder_busy', 'audio_decoder_unavailable', 'upload_timeout', 'request_pending', 'timeout', 'network_error']);
/** Error codes that mean the key is spent: start a new attempt with a new key. */
const NEW_KEY_CODES = new Set(['idempotency_expired', 'idempotency_conflict']);
const IDEMPOTENCY_RE = /^[A-Za-z0-9_.:-]{8,128}$/;

/**
 * A fresh Idempotency-Key for one recording attempt. Keep the same key while the result is
 * unknown or pending (error.retryable); use a new key for a different attempt or after a
 * definite failed response (error.needsNewKey). Never generate one inside an automatic retry loop.
 */
function newIdempotencyKey(prefix = 'tp') {
  const key = `${prefix}-${randomUUID()}`;
  if (!IDEMPOTENCY_RE.test(key)) throw new Error('prefix must be letters, digits, dots, dashes, underscores or colons');
  return key;
}

/**
 * Any non-2xx response, or a transport failure (status 0). `code`/`detail` come from the
 * API's `error` object. What to do next is decided by the BODY, not the status:
 *  - finalized: the failure was stored under your Idempotency-Key (body has a `req_…` `id`
 *    and `billing` with credits 0, e.g. engine_unavailable / request_interrupted after the
 *    request was accepted). The same key replays this failure for 24 h → needsNewKey.
 *  - retryable: nothing was finalized; retry later with the SAME key (rate_limit, account_busy,
 *    gateway_busy, decoder_busy, audio_decoder_unavailable, upload_timeout, request_pending,
 *    transport timeout / network_error, any non-finalized 5xx such as an HTML or empty 502/504).
 *  - everything else (invalid_api_key, insufficient_credits, invalid_audio, …) needs a fix on your side.
 */
class TonePerfectError extends Error {
  get name() { return this.constructor.name; }
  constructor(status, code, message, requestId = null, retryAfter = null, body = null) {
    super(`${status} ${code}: ${message}`);
    this.status = status;
    this.code = code;
    this.detail = message;
    this.requestId = requestId;
    this.retryAfter = retryAfter;
    this.body = body && typeof body === 'object' ? body : {};
    /** `req_…` result id when the failure was finalized under your Idempotency-Key. */
    this.id = typeof this.body.id === 'string' ? this.body.id : null;
    this.billing = this.body.billing && typeof this.body.billing === 'object' ? this.body.billing : null;
  }
  /** The failure is a stored result for this key (id + billing present). */
  get finalized() { return this.id !== null && this.billing !== null; }
  /** Start a new attempt with a new Idempotency-Key; the old key replays this response. */
  get needsNewKey() { return this.finalized || NEW_KEY_CODES.has(this.code); }
  /** Retry later with the SAME Idempotency-Key: nothing was finalized. */
  get retryable() {
    if (this.finalized || NEW_KEY_CODES.has(this.code)) return false;
    return RETRY_SAME_KEY_CODES.has(this.code) || [408, 429, 502, 503, 504].includes(this.status);
  }
}

/** 401: missing, revoked or unknown API key (invalid_api_key). */
class AuthenticationError extends TonePerfectError {}
/** 402: nothing was charged. code = subscription_required (50 free credits used, no active plan),
 *  insufficient_credits or payment_balance_due. Fix it in https://api.toneperfect.app/dashboard */
class PaymentRequiredError extends TonePerfectError {}
/** 429: rate_limit (60/min) or account_busy (2 running). Retry with the SAME key after retryAfter. */
class RateLimitError extends TonePerfectError {}
/** Other 4xx: the request needs a fix (invalid_audio, unsupported_language, upload_too_large, ...). */
class ValidationError extends TonePerfectError {}
/** 5xx: engine_unavailable, request_interrupted or a proxy 502/504. Check retryable / needsNewKey. */
class ServerError extends TonePerfectError {}
/** Transport failure (status 0): timeout or network_error. Outcome unknown: retry with the same key. */
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

/** One POST /v1/assess result: `data` is the untouched JSON body; the getters mirror its documented fields. */
class Assessment {
  constructor(data, status, headers) {
    this.data = data;
    this.status = status;
    this.headers = headers;
    this.requestId = headers.get('x-request-id') || null;
    this.replayed = (headers.get('idempotent-replayed') || '').toLowerCase() === 'true';
  }
  /** false when the audio could not be meaningfully scored; never show that as a zero score. See `reason`. */
  get assessable() { return Boolean(this.data.assessable); }
  get reason() { return this.data.reason ?? null; }
  /** 0-100 display grades per dimension; null = not supported by this pack. */
  get scores() { return this.data.scores || {}; }
  get overall() { return this.scores.overall ?? null; }
  /** Per word/character: score, start_ms, end_ms, phones[] {expected, heard, score, decision} (see DECISIONS). */
  get words() { return this.data.words || []; }
  /** {credits: charged, balance_credits: remaining}; failed or unassessable requests charge 0. */
  get billing() { return this.data.billing || {}; }
  get modelVersion() { return this.data.model_version ?? null; }
  get id() { return this.data.id || this.requestId; }
}

async function toBlob(audio, contentType) {
  if (audio instanceof Blob) return audio;
  if (typeof audio === 'string' || (audio && typeof audio === 'object' && 'href' in audio && audio.protocol === 'file:')) {
    return new Blob([await readFile(audio)], { type: contentType });
  }
  if (audio instanceof ArrayBuffer) return new Blob([audio], { type: contentType });
  if (ArrayBuffer.isView(audio)) return new Blob([audio], { type: contentType });
  throw new TypeError('audio must be a file path, Buffer/Uint8Array, ArrayBuffer or Blob');
}

class TonePerfect {
  /**
   * @param {object} [options]
   * @param {string} [options.apiKey]  secret key (tp_live_...). Defaults to process.env.TONEPERFECT_API_KEY.
   * @param {string} [options.baseUrl] API origin. api.toneperfect.app sits behind a proxy with a 26 s request
   *   timeout; if your assessments run longer, ask nik@toneperfect.app for the direct gateway address.
   * @param {number} [options.timeoutMs] per-request timeout (default 90 000).
   * @param {typeof fetch} [options.fetch] custom fetch (tests, proxies).
   */
  constructor(options = {}) {
    this.apiKey = options.apiKey ?? process.env.TONEPERFECT_API_KEY ?? '';
    this.baseUrl = (options.baseUrl || DEFAULT_BASE_URL).replace(/\/+$/, '');
    this.timeoutMs = options.timeoutMs ?? 90_000;
    this.fetch = options.fetch || globalThis.fetch;
    this.userAgent = options.userAgent || `toneperfect-node/${VERSION}`;
    if (typeof this.fetch !== 'function') throw new Error('Node 18+ (global fetch) is required, or pass options.fetch.');
  }

  /** GET /v1/capabilities — no key needed. languages[] (locale, status, dimensions, limitations), limits, model_version. */
  async capabilities() {
    const { status, headers, text } = await this._send('GET', '/v1/capabilities', null, {});
    return parseJson(status, headers, text);
  }

  /**
   * POST /v1/assess — score one scripted recording.
   * @param {string|URL|Buffer|Uint8Array|ArrayBuffer|Blob} audio  up to 30 s / 10 MB (WAV, MP3, M4A, OGG, WebM...)
   * @param {object} fields
   * @param {string} [fields.text]           reference text the learner read (required unless pinyin is given)
   * @param {string} [fields.language]       locale such as zh-CN, en-US, fr-FR (default zh-CN)
   * @param {string} [fields.pinyin]         explicit Mandarin reading with numbered tones, e.g. "ni3 hao3"
   * @param {'general'|'connected_speech'|'isolated_word'} [fields.task]  default general
   * @param {string} [fields.idempotencyKey] unique per attempt; generated when omitted. If a network error
   *   prevents you from receiving a result, retry with the same key and identical inputs: a completed request
   *   is returned without charging again, including a completed failure. Use a new key for a different attempt
   *   or after a definite failed response (error.needsNewKey); keep it while the outcome is unknown (error.retryable).
   * @param {string} [fields.filename]       default recording.wav
   * @param {string} [fields.contentType]    default application/octet-stream
   * @returns {Promise<Assessment>}
   */
  async assess(audio, fields = {}) {
    const { text, language = 'zh-CN', pinyin, task = 'general', filename = 'recording.wav', contentType = 'application/octet-stream' } = fields;
    if (!this.apiKey) throw new AuthenticationError(401, 'invalid_api_key', 'Set apiKey or the TONEPERFECT_API_KEY environment variable.');
    if (!TASKS.includes(task)) throw new RangeError(`task must be one of ${TASKS.join(', ')}`);
    if (!text && !pinyin) throw new RangeError('Provide text (or pinyin for Mandarin).');
    const key = fields.idempotencyKey || newIdempotencyKey();
    if (!IDEMPOTENCY_RE.test(key)) throw new RangeError('idempotencyKey must be 8-128 letters, digits, dots, dashes, underscores or colons');

    const form = new FormData();
    form.append('audio', await toBlob(audio, contentType), filename);
    if (text) form.append('text', text);
    if (pinyin) form.append('pinyin', pinyin);
    form.append('language', language);
    form.append('task', task);
    const { status, headers, text: body } = await this._send('POST', '/v1/assess', form, {
      Authorization: `Bearer ${this.apiKey}`,
      'Idempotency-Key': key,
    });
    return new Assessment(parseJson(status, headers, body), status, headers);
  }

  async _send(method, path, body, headers) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetch(this.baseUrl + path, {
        method, body, signal: controller.signal,
        headers: { Accept: 'application/json', 'User-Agent': this.userAgent, ...headers },
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

function parseJson(status, headers, text) {
  let data = null;
  try { data = text ? JSON.parse(text) : {}; } catch { data = null; }
  if (status >= 200 && status < 300 && data && typeof data === 'object') return data;
  const retryAfter = headers.get('retry-after') ? Number(headers.get('retry-after')) || null : null;
  if (data && typeof data === 'object' && data.error && typeof data.error === 'object') {
    throw new (errorClass(status))(status, String(data.error.code || 'request_error'), String(data.error.message || ''), data.request_id || headers.get('x-request-id') || null, retryAfter, data);
  }
  throw new (errorClass(status))(status, 'http_error', (text || '').slice(0, 200).trim() || `HTTP ${status}`, headers.get('x-request-id') || null, retryAfter);
}

module.exports = { TonePerfect, TonePerfectError, AuthenticationError, PaymentRequiredError, RateLimitError, ValidationError, ServerError, APIConnectionError, Assessment, newIdempotencyKey, DEFAULT_BASE_URL, TASKS, DECISIONS, RETRY_SAME_KEY_CODES, VERSION };

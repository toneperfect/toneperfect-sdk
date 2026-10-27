// Offline tests with a fake fetch. Run: npm test  (node --test)
import test from 'node:test';
import assert from 'node:assert/strict';
import { TonePerfect, TonePerfectError, Assessment, newIdempotencyKey, PaymentRequiredError, AuthenticationError, RateLimitError, ValidationError, ServerError } from '../index.mjs';
import cjs from '../index.cjs';

const json = (status, body, headers = {}) => async (url, init) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });

test('cjs and esm expose the same API', () => {
  assert.equal(cjs.TonePerfect, TonePerfect);
  assert.equal(typeof cjs.newIdempotencyKey, 'function');
});

test('assess sends the real multipart contract and auth headers', async () => {
  let captured;
  const fetch = async (url, init) => { captured = { url, init }; return json(200, { assessable: true, scores: { overall: 86, tone: 80, fluency: null }, words: [{ word: '你', score: 94 }], billing: { credits: 1, balance_credits: 2499 }, model_version: 'mandarin-human-v2-x', id: 'req_1' }, { 'x-request-id': 'req_1' })(); };
  const client = new TonePerfect({ apiKey: 'tp_live_test', baseUrl: 'https://api.toneperfect.app/', fetch });
  const result = await client.assess(Buffer.from('RIFF....'), { text: '你好', language: 'zh-CN', pinyin: 'ni3 hao3', task: 'connected_speech', idempotencyKey: 'lesson-42-attempt-1', filename: 'hello.wav' });
  assert.equal(captured.url, 'https://api.toneperfect.app/v1/assess');
  assert.equal(captured.init.method, 'POST');
  assert.equal(captured.init.headers.Authorization, 'Bearer tp_live_test');
  assert.equal(captured.init.headers['Idempotency-Key'], 'lesson-42-attempt-1');
  const form = captured.init.body;
  assert.ok(form instanceof FormData);
  assert.equal(form.get('text'), '你好');
  assert.equal(form.get('language'), 'zh-CN');
  assert.equal(form.get('pinyin'), 'ni3 hao3');
  assert.equal(form.get('task'), 'connected_speech');
  const audio = form.get('audio');
  assert.equal(audio.name, 'hello.wav');
  assert.equal(await audio.text(), 'RIFF....');
  assert.ok(result instanceof Assessment);
  assert.equal(result.assessable, true);
  assert.equal(result.overall, 86);
  assert.equal(result.scores.fluency, null);
  assert.equal(result.billing.credits, 1);
  assert.equal(result.modelVersion, 'mandarin-human-v2-x');
  assert.equal(result.id, 'req_1');
  assert.equal(result.words[0].word, '你');
  assert.equal(result.replayed, false);
});

test('replayed header, generated idempotency key, unassessable result', async () => {
  let captured;
  const fetch = async (url, init) => { captured = init; return json(200, { assessable: false, reason: 'silence', scores: { overall: null }, billing: { credits: 0, balance_credits: 5 } }, { 'idempotent-replayed': 'true' })(); };
  const result = await new TonePerfect({ apiKey: 'k', fetch }).assess(new Uint8Array([1, 2, 3]), { text: 'hi', language: 'en-US' });
  assert.match(captured.headers['Idempotency-Key'], /^[A-Za-z0-9_.:-]{8,128}$/);
  assert.equal(result.replayed, true);
  assert.equal(result.assessable, false);
  assert.equal(result.reason, 'silence');
  assert.equal(result.billing.credits, 0);
});

test('API errors are typed', async () => {
  const fetch = json(402, { error: { code: 'insufficient_credits', message: 'Purchase a credit pack.' }, request_id: 'req_9' });
  await assert.rejects(new TonePerfect({ apiKey: 'k', fetch }).assess(Buffer.alloc(1), { text: 'hi' }), (error) => {
    assert.ok(error instanceof TonePerfectError);
    assert.equal(error.status, 402); assert.equal(error.code, 'insufficient_credits'); assert.equal(error.requestId, 'req_9'); assert.equal(error.retryable, false);
    return true;
  });
});

const errorFrom = (status, body, headers) => assert.rejects(new TonePerfect({ apiKey: 'k', fetch: json(status, body, headers) }).assess(Buffer.alloc(1), { text: 'hi', idempotencyKey: 'lesson-42-attempt-1' }), e => { errorFrom.last = e; return e instanceof TonePerfectError; }).then(() => errorFrom.last);

test('finalized failure (id + billing in the body) needs a new key and is never retried with the same one', async () => {
  const e = await errorFrom(503, { error: { code: 'engine_unavailable', message: 'No credits were charged.' }, id: 'req_77', billing: { credits: 0, balance_credits: 12 } }, { 'idempotent-replayed': 'true' });
  assert.equal(e.code, 'engine_unavailable'); assert.equal(e.id, 'req_77'); assert.deepEqual(e.billing, { credits: 0, balance_credits: 12 });
  assert.equal(e.finalized, true); assert.equal(e.needsNewKey, true); assert.equal(e.retryable, false);
  const i = await errorFrom(503, { error: { code: 'request_interrupted', message: 'x' }, id: 'req_78', billing: { credits: 0, balance_credits: 12 } });
  assert.equal(i.needsNewKey && !i.retryable, true);
});

test('not-finalized failures retry with the same key', async () => {
  for (const [status, code] of [[409, 'request_pending'], [429, 'rate_limit'], [429, 'account_busy'], [503, 'gateway_busy'], [503, 'decoder_busy'], [503, 'audio_decoder_unavailable'], [408, 'upload_timeout'], [503, 'engine_unavailable']]) {
    const e = await errorFrom(status, { error: { code, message: 'later' }, request_id: 'req_x' }, { 'retry-after': '1' });
    assert.equal(e.retryable, true, code); assert.equal(e.needsNewKey, false, code); assert.equal(e.finalized, false, code); assert.equal(e.retryAfter, 1);
  }
});

test('spent keys and client errors', async () => {
  for (const code of ['idempotency_expired', 'idempotency_conflict']) {
    const e = await errorFrom(409, { error: { code, message: 'new key' } });
    assert.equal(e.needsNewKey, true, code); assert.equal(e.retryable, false, code);
  }
  for (const [status, code] of [[401, 'invalid_api_key'], [402, 'insufficient_credits'], [422, 'invalid_audio'], [422, 'unsupported_language'], [413, 'upload_too_large'], [429, 'free_capacity']]) {
    const e = await errorFrom(status, { error: { code, message: 'fix' } });
    assert.equal(e.retryable, false, code); assert.equal(e.needsNewKey, false, code);
  }
});

test('transport failures: timeout and network errors keep the same key', async () => {
  const abort = async (url, init) => new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' }))));
  await assert.rejects(new TonePerfect({ apiKey: 'k', fetch: abort, timeoutMs: 10 }).assess(Buffer.alloc(1), { text: 'hi' }), e => e.code === 'timeout' && e.status === 0 && e.retryable && !e.needsNewKey);
  const refused = async () => { throw new TypeError('fetch failed'); };
  await assert.rejects(new TonePerfect({ apiKey: 'k', fetch: refused }).assess(Buffer.alloc(1), { text: 'hi' }), e => e.code === 'network_error' && e.status === 0 && e.retryable && !e.needsNewKey);
});

test('non-JSON proxy error', async () => {
  const fetch = async () => new Response('<html>Gateway Timeout</html>', { status: 504 });
  await assert.rejects(new TonePerfect({ apiKey: 'k', fetch }).capabilities(), (error) => {
    assert.equal(error.status, 504); assert.equal(error.code, 'http_error'); assert.equal(error.retryable, true); assert.equal(error.needsNewKey, false); return true;
  });
  await assert.rejects(new TonePerfect({ apiKey: 'k', fetch: async () => new Response('', { status: 502 }) }).capabilities(), e => e.retryable === true);
});

test('capabilities needs no key', async () => {
  let captured;
  const fetch = async (url, init) => { captured = { url, init }; return json(200, { languages: [{ locale: 'zh-CN', status: 'experimental' }], limits: { max_audio_seconds: 30 } })(); };
  const caps = await new TonePerfect({ apiKey: '', fetch }).capabilities();
  assert.equal(captured.url, 'https://api.toneperfect.app/v1/capabilities');
  assert.equal(captured.init.headers.Authorization, undefined);
  assert.equal(caps.languages[0].locale, 'zh-CN');
});

test('validation', async () => {
  const client = new TonePerfect({ apiKey: 'k', fetch: json(200, {}) });
  await assert.rejects(new TonePerfect({ apiKey: '', fetch: json(200, {}) }).assess(Buffer.alloc(1), { text: 'x' }), TonePerfectError);
  await assert.rejects(client.assess(Buffer.alloc(1), { language: 'en-US' }), RangeError);
  await assert.rejects(client.assess(Buffer.alloc(1), { text: 'x', task: 'freestyle' }), RangeError);
  await assert.rejects(client.assess(Buffer.alloc(1), { text: 'x', idempotencyKey: 'short' }), RangeError);
  assert.match(newIdempotencyKey('lesson.42'), /^[A-Za-z0-9_.:-]{8,128}$/);
});

test('errors are typed by status (402 -> PaymentRequiredError)', async () => {
  for (const [status, C] of [[401, AuthenticationError], [402, PaymentRequiredError], [429, RateLimitError], [422, ValidationError], [503, ServerError]]) {
    const client = new TonePerfect({ apiKey: 'tp_live_test', fetch: json(status, { error: { code: 'subscription_required', message: 'm' } }) });
    await assert.rejects(client.capabilities(), (e) => e instanceof C && e instanceof TonePerfectError && e.status === status && e.name === C.name);
  }
});

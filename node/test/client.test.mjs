// Contract tests against testing/mock_api.py (a local stand-in that follows the live gateway's rules).
import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import {
  TonePerfect, newIdempotencyKey, VERSION,
  AuthenticationError, PaymentRequiredError, RateLimitError, ValidationError, ServerError, APIConnectionError,
} from '../index.mjs';

const mockPath = fileURLToPath(new URL('../../testing/mock_api.py', import.meta.url));
const HELLO = fileURLToPath(new URL('../../testing/fixtures/hello.ogg', import.meta.url));
const servers = {};
const children = [];
async function server(gateway) {
  if (!servers[gateway]) {
    servers[gateway] = new Promise((resolve, reject) => {
      const child = spawn('python3', [mockPath, '--gateway', gateway], { stdio: ['ignore', 'pipe', 'inherit'] });
      children.push(child);
      child.stdout.once('data', chunk => resolve(String(chunk).trim().split('\n')[0]));
      child.once('error', reject);
    });
  }
  return servers[gateway];
}
after(() => children.forEach(c => c.kill()));
const attempts = async (url, key) => (await (await fetch(url + '/_mock/log')).json()).filter(e => e.idempotency_key === key);

for (const gateway of ['live', '1110']) {
  const client = async (opts = {}) => new TonePerfect({ apiKey: 'tp_test_mock', baseUrl: await server(gateway), ...opts });

  test(`${gateway}: request and typed result`, async () => {
    const url = await server(gateway);
    const result = await (await client()).assess(HELLO, { text: '你好', language: 'zh-CN', task: 'connected_speech' });
    const [sent] = await attempts(url, result.idempotencyKey);
    assert.equal(sent.auth_scheme, 'Bearer');
    assert.match(result.idempotencyKey, /^[0-9a-f-]{36}$/);
    assert.deepEqual(sent.fields, { text: '你好', language: 'zh-CN', task: 'connected_speech' });
    assert.deepEqual([sent.audio.filename, sent.audio.content_type], ['hello.ogg', 'audio/ogg']);
    assert.equal(sent.user_agent, `toneperfect-node/${VERSION}`);
    assert.ok(result.assessable && result.test);
    assert.equal(result.overall, 78);
    assert.deepEqual(result.words.map(w => w.word), ['你', '好']);
    assert.deepEqual(result.words[0].phones.map(p => p.dimension), ['initial', 'final', 'tone']);
    assert.deepEqual([result.billing.credits, result.billing.source], [0, 'test']);
    assert.equal(result.engine, 'primary');
  });

  test(`${gateway}: compact maps to the same fields`, async () => {
    const result = await (await client()).assess(readFileSync(HELLO), { text: 'I like sunny days', language: 'en-US', compact: true, filename: 'take.ogg' });
    assert.ok(result.compact);
    assert.deepEqual(result.words.map(w => w.word), ['I', 'like', 'sunny', 'days']);
    assert.equal(result.words[1].phones[0].dimension, 'phoneme');
  });

  test(`${gateway}: replay with the same key`, async () => {
    const c = await client(); const key = newIdempotencyKey();
    const first = await c.assess(HELLO, { text: '你好', language: 'zh-CN', idempotencyKey: key });
    const second = await c.assess(HELLO, { text: '你好', language: 'zh-CN', idempotencyKey: key });
    assert.equal(first.id, second.id);
    assert.ok(second.replayed);
  });

  test(`${gateway}: busy and proxy 502 are retried with the same key`, async () => {
    const url = await server(gateway);
    let result = await (await client({ headers: { 'X-Mock-Fail': 'gateway_busy:2' } })).assess(HELLO, { text: '你好', language: 'zh-CN' });
    assert.equal((await attempts(url, result.idempotencyKey)).length, 3);
    result = await (await client({ headers: { 'X-Mock-Fail': 'html502:1' } })).assess(HELLO, { text: '你好', language: 'zh-CN' });
    assert.equal((await attempts(url, result.idempotencyKey)).length, 2);
  });

  test(`${gateway}: retries stop at maxRetries`, async () => {
    const url = await server(gateway);
    await assert.rejects((await client({ maxRetries: 0, headers: { 'X-Mock-Fail': 'engine_unavailable:1' } })).assess(HELLO, { text: '你好', language: 'zh-CN' }),
      e => e instanceof ServerError && e.retryable && !e.needsNewKey);
    let caught;
    await assert.rejects((await client({ maxRetries: 1 })).assess(HELLO, { text: '你好', language: 'zh-CN', testOutcome: 'rate_limit' }), e => (caught = e) instanceof RateLimitError);
    assert.equal((await attempts(url, caught.idempotencyKey)).length, 2);
  });

  test(`${gateway}: a finalized failure needs a new key and is not retried`, async () => {
    const url = await server(gateway);
    let caught;
    await assert.rejects((await client()).assess(HELLO, { text: '你好', language: 'zh-CN', testOutcome: 'invalid_assessment' }), e => (caught = e) instanceof ValidationError);
    assert.ok(caught.finalized && caught.needsNewKey && !caught.retryable);
    assert.match(caught.id, /^req_/);
    assert.equal((await attempts(url, caught.idempotencyKey)).length, 1);
  });

  test(`${gateway}: 402 carries a billing link`, async () => {
    let caught;
    await assert.rejects((await client()).assess(HELLO, { text: '你好', language: 'zh-CN', testOutcome: 'subscription_required' }), e => (caught = e) instanceof PaymentRequiredError);
    assert.equal(caught.code, 'subscription_required');
    assert.equal(caught.billingUrl, 'https://api.toneperfect.app/dashboard?tab=billing');
    assert.ok(caught.message.includes(caught.billingUrl));
    assert.ok(!caught.retryable);
    if (gateway === '1110') { assert.equal(caught.plan.name, 'Starter'); assert.equal(caught.pricingUrl, 'https://api.toneperfect.app/pricing/'); }
  });

  test(`${gateway}: authentication, timeout and required language`, async () => {
    const url = await server(gateway);
    await assert.rejects(new TonePerfect({ apiKey: 'nope', baseUrl: url }).assess(HELLO, { text: '你好', language: 'zh-CN' }), AuthenticationError);
    await assert.rejects((await client({ timeoutMs: 300, maxRetries: 0, headers: { 'X-Mock-Delay': '1' } })).assess(HELLO, { text: '你好', language: 'zh-CN' }),
      e => e instanceof APIConnectionError && e.status === 0 && e.code === 'timeout' && e.retryable);
    await assert.rejects((await client()).assess(HELLO, { text: '你好' }), TypeError);
  });

  test(`${gateway}: other endpoints`, async () => {
    const c = await client();
    assert.ok((await c.capabilities()).languages.some(l => l.locale === 'zh-CN'));
    assert.equal((await c.lint('你好', { language: 'zh-CN' })).ok, true);
    assert.ok('status' in await c.status());
  });
}

test('environment defaults', () => {
  process.env.TONEPERFECT_BASE_URL = 'http://example.invalid/'; process.env.TONEPERFECT_API_KEY = 'tp_test_env';
  try {
    const c = new TonePerfect();
    assert.deepEqual([c.baseUrl, c.apiKey, c.maxRetries, c.timeoutMs], ['http://example.invalid', 'tp_test_env', 2, 60000]);
  } finally { delete process.env.TONEPERFECT_BASE_URL; delete process.env.TONEPERFECT_API_KEY; }
});

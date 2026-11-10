# TonePerfect Node.js client

Client for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app): send a short recording
and the text it should contain, get 0–100 scores for the sentence, every word and every sound, with Mandarin
initial, final and tone per syllable. 10 languages. Node 18+, ESM and CommonJS, TypeScript types, no dependencies.

```sh
npm install toneperfect
```

## Try it with a test key

[Sign up](https://api.toneperfect.app/signup) (50 free credits, no card), then in the dashboard open
**API keys** and create a **test key** (`tp_test_…`). A test key runs the real request path but returns a
fixed example result: it never scores your audio and never spends credits. Swap in a live key
(`tp_live_…`) for real scores. Keep keys on a server; browser and mobile apps should call your backend.

```sh
export TONEPERFECT_API_KEY="tp_test_..."
curl -o hello.ogg https://api.toneperfect.app/capsule/speech-zh-nihao.ogg   # 2 s of 你好
```

```js
import { TonePerfect } from 'toneperfect';

const client = new TonePerfect(); // reads TONEPERFECT_API_KEY
const result = await client.assess('hello.ogg', { text: '你好', language: 'zh-CN' });

console.log(result.assessable, result.overall, result.billing.credits, result.test);
for (const word of result.words) {
  for (const phone of word.phones) console.log(word.word, phone.dimension, phone.expected, phone.heard, phone.score, phone.decision);
}
```

CommonJS works too:

```js
const { TonePerfect } = require('toneperfect');

new TonePerfect().capabilities().then(caps => console.log(caps.languages.map(l => l.locale).join(' ')));
```

`language` is required: `zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR`
or `ja-JP`. `audio` is a file path, `URL`, `Buffer`, `Uint8Array`, `ArrayBuffer` or `Blob`.

## Results

`assess()` resolves to an `Assessment`: `assessable` and `reason` (a recording that could not be scored is
free and is not a score of zero), `overall` and `scores` (0–100; `null` = not measured by this pack),
`words` (`Word`: `word`, `score`, `startMs`, `endMs`, `decision`, `pinyin`, `phones`), `phones` (`Phone`:
`dimension`, `expected`, `heard`, `score`, `decision`), `billing` (`credits`, `balanceCredits`,
`freeCredits`, `source`: `free`, `plan` or `test`), `warnings`, `engine`, `modelVersion`, `id`, `replayed`,
`test`, and `data`, the JSON body as returned. Act on `decision`, not on every low grade.
`compact: true` asks for the versioned `toneperfect.compact.v1` schema; the same getters work on it.

## Errors, retries and timeouts

Every error is a `TonePerfectError` with the API's `code`, `detail` (its message), `status` and `requestId`.
Subclasses: `AuthenticationError` (401), `PaymentRequiredError` (402, with `billingUrl` and, when the API sends
them, `pricingUrl` and `plan`), `RateLimitError` (429), `ValidationError` (other 4xx), `ServerError` (5xx) and
`APIConnectionError` (timeout or network failure). The client retries a failure that stored nothing
(`error.retryable`) up to `maxRetries` times with the **same** Idempotency-Key, so a finished result is returned
and charged once; `error.needsNewKey` marks a failure stored under the key. A test key rehearses each outcome:

```js
import { TonePerfect, PaymentRequiredError, TonePerfectError } from 'toneperfect';

const client = new TonePerfect({ timeoutMs: 30_000, maxRetries: 2 });
try {
  await client.assess('hello.ogg', { text: '你好', language: 'zh-CN', testOutcome: 'subscription_required' });
} catch (error) {
  if (error instanceof PaymentRequiredError) console.log(error.code, '->', error.billingUrl);
  else if (error instanceof TonePerfectError) console.log(error.status, error.code, error.detail, error.retryable, error.needsNewKey);
  else throw error;
}

const unscored = await client.assess('hello.ogg', { text: '你好', language: 'zh-CN', testOutcome: 'unassessable' });
console.log(unscored.assessable, unscored.reason);
```

To resend the same recording safely after a crash, keep your own key:

```js
import { TonePerfect, newIdempotencyKey } from 'toneperfect';

const client = new TonePerfect();
const idempotencyKey = newIdempotencyKey(); // store it with the recording
const first = await client.assess('hello.ogg', { text: 'I like sunny days', language: 'en-US', idempotencyKey });
const again = await client.assess('hello.ogg', { text: 'I like sunny days', language: 'en-US', idempotencyKey });
console.log(first.id === again.id, again.replayed); // the stored result, not charged twice
```

## Other endpoints

```js
import { TonePerfect } from 'toneperfect';

const client = new TonePerfect();
console.log((await client.lint('我有3个苹果', { language: 'zh-CN' })).issues); // free reference-text check, no key
console.log((await client.status()).status);                                  // synthetic engine probe
```

Command line: `npx toneperfect-lint "你好" --language zh-CN`, or `--file lesson.csv`. Your own pass marks:
`require('toneperfect/rubric').applyRubric(result.data, rubric)`.

## Configuration

`new TonePerfect({ apiKey, baseUrl, timeoutMs = 60000, maxRetries = 2, headers, fetch })`. `apiKey` defaults to
`TONEPERFECT_API_KEY`, `baseUrl` to `TONEPERFECT_BASE_URL`, else `https://api.toneperfect.app` (a proxy with a
26-second limit: a longer passage comes back on the automatic retry, charged once).

Grades are display scores calibrated per language against native references, not accuracy percentages and not
comparable across vendors. Every language pack is labelled `experimental` in `/v1/capabilities`.
Docs: https://api.toneperfect.app/docs · MIT licence · nik@toneperfect.app

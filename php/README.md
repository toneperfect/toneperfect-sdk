# toneperfect (PHP)

Client for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app):
send a short scripted recording and the text it should contain, get 0–100 scores for the
sentence, every word and every sound — including a separate initial, final and tone score
for every Mandarin syllable — in one JSON response. Ten languages (`zh-CN`, `en-US`, `fr-FR`,
`es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR`, `ja-JP`); Korean and Japanese are beta.

One file, PHP 8.0+, `ext-curl` + `ext-json`, no Composer dependencies.

```sh
composer require toneperfect/toneperfect
```

## Quickstart

```php
$client = new TonePerfect\Client('tp_live_...');          // or set TONEPERFECT_API_KEY
$result = $client->assess('hello.wav', ['text' => '你好', 'language' => 'zh-CN']);
var_dump($result->assessable(), $result->overall(), $result->billing());
foreach ($result->words() as $word) {
    echo $word['word'], ' ', $word['score'], "\n";
}
```

Get a key: [create an account](https://api.toneperfect.app/signup) → dashboard → API keys.
New accounts get 50 free credits, no card needed; then the Starter plan is $10/month
([pricing](https://api.toneperfect.app/pricing/)). Keep the key on your server.

## What is wrapped

| Method | Endpoint | Notes |
| --- | --- | --- |
| `$client->capabilities()` | `GET /v1/capabilities` | No key needed. Languages, `status`, dimensions, `limits`, `model_version`. |
| `$client->assess($pathOrStream, [...])` / `assessBytes($bytes, [...])` | `POST /v1/assess` | Fields `text`, `language`, optional `pinyin` (`ni3 hao3`), `task` (`general`, `connected_speech`, `isolated_word`), `idempotency_key` (generated when omitted), `filename`, `content_type`. Headers `Authorization: Bearer` + `Idempotency-Key`. |

`TonePerfect\Assessment`: `$data` (full JSON body), `assessable()` / `reason()` (never show
an unassessable result as zero), `scores()` (`null` = dimension not supported by the pack),
`overall()`, `words()`, `billing()` (failed or unassessable requests charge 0),
`modelVersion()`, `id()`, `replayed()`.

## Errors and retries

Every non-2xx response throws a `TonePerfect\TonePerfectException` subclass —
`AuthenticationError` (401), `PaymentRequiredError` (402, nothing charged),
`RateLimitError` (429), `ValidationError` (other 4xx), `ServerError` (5xx),
`APIConnectionError` (transport, `status` 0, `timeout` / `network_error`) — with `status`,
`code()`, `detail`, `requestId`, `retryAfter`, `body`. `retryable()` → retry later with the
**same** `idempotency_key`; `needsNewKey()` (incl. `finalized()`) → new attempt, new key.

## Scope

Scripted speech only: the learner reads a known text. Grades are display scores calibrated
per language against native references — not accuracy percentages and not comparable
across vendors. Every language pack is labelled `experimental` in `/v1/capabilities`.

## Development

```sh
php tests/run.php     # offline: fake transport + php -S on loopback
composer validate --strict
```

MIT licensed. Docs: https://api.toneperfect.app/docs · Questions: nik@toneperfect.app

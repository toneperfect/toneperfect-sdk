# TonePerfect PHP client

Client for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app): send a short recording
and the text it should contain, get 0–100 scores for the sentence, every word and every sound, with Mandarin
initial, final and tone per syllable. 10 languages. PHP 8.0+, ext-curl, no dependencies.

```sh
composer require toneperfect/toneperfect
```

## Try it with a test key

[Sign up](https://api.toneperfect.app/signup) (50 free credits, no card), then in the dashboard open
**API keys** and create a **test key** (`tp_test_…`). A test key runs the real request path but returns a
fixed example result: it never scores your audio and never spends credits. Swap in a live key
(`tp_live_…`) for real scores. Keep keys on a server.

```sh
export TONEPERFECT_API_KEY="tp_test_..."
curl -o hello.ogg https://api.toneperfect.app/capsule/speech-zh-nihao.ogg   # 2 s of 你好
```

```php
<?php
require __DIR__ . '/vendor/autoload.php';

$client = new TonePerfect\Client(); // reads TONEPERFECT_API_KEY
$result = $client->assess('hello.ogg', text: '你好', language: 'zh-CN');

var_dump($result->assessable(), $result->overall(), $result->billing()->credits, $result->test());
foreach ($result->words() as $word) {
    foreach ($word->phones as $phone) {
        echo $word->word, ' ', $phone->dimension, ' ', $phone->expected, ' ', $phone->heard, ' ', $phone->score, ' ', $phone->decision, "\n";
    }
}
```

`language` is required: `zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR` or
`ja-JP`. `assess()` takes a path or a stream; `assessBytes()` takes the recording's bytes.

## Results

`TonePerfect\Assessment`: `assessable()` and `reason()` (a recording that could not be scored is free and is
not a score of zero), `overall()` and `scores()` (0–100; `null` = not measured by this pack), `words()`
(`Word`: `word`, `score`, `startMs`, `endMs`, `decision`, `pinyin`, `phones`), `phones` (`Phone`:
`dimension`, `expected`, `heard`, `score`, `decision`), `billing()` (`credits`, `balanceCredits`,
`freeCredits`, `source`: `free`, `plan` or `test`), `warnings()`, `engine()`, `modelVersion()`, `id()`,
`replayed()`, `test()`, and `$data`, the JSON as returned. Act on `decision`, not on every low grade.
`compact: true` asks for the `toneperfect.compact.v1` schema; the same methods work on it.

## Errors, retries and timeouts

Every error is a `TonePerfect\TonePerfectException` with the API's `code()`, `$detail` (its message), `$status`
and `$requestId`. Subclasses: `AuthenticationError` (401), `PaymentRequiredError` (402, with `$billingUrl` and,
when the API sends them, `$pricingUrl` and `$plan`), `RateLimitError` (429), `ValidationError` (other 4xx),
`ServerError` (5xx) and `APIConnectionError` (timeout or network failure). The client retries a failure that
stored nothing (`retryable()`) up to `maxRetries` times with the **same** Idempotency-Key, so a finished result
is returned and charged once; `needsNewKey()` marks a failure stored under the key. A test key rehearses each
outcome:

```php
<?php
require __DIR__ . '/vendor/autoload.php';

use TonePerfect\{Client, PaymentRequiredError, TonePerfectException};

$client = new Client(timeout: 30, maxRetries: 2);
try {
    $client->assess('hello.ogg', text: '你好', language: 'zh-CN', testOutcome: 'subscription_required');
} catch (PaymentRequiredError $e) {
    echo $e->code(), ' -> ', $e->billingUrl, "\n";
} catch (TonePerfectException $e) {
    echo $e->status, ' ', $e->code(), ' ', $e->detail, ' ', var_export($e->retryable(), true), "\n";
}

$unscored = $client->assess('hello.ogg', text: '你好', language: 'zh-CN', testOutcome: 'unassessable');
var_dump($unscored->assessable(), $unscored->reason());
```

To resend the same recording safely after a crash, keep your own key:

```php
<?php
require __DIR__ . '/vendor/autoload.php';

$client = new TonePerfect\Client();
$key = TonePerfect\new_idempotency_key(); // store it with the recording
$first = $client->assess('hello.ogg', text: 'I like sunny days', language: 'en-US', idempotencyKey: $key);
$again = $client->assess('hello.ogg', text: 'I like sunny days', language: 'en-US', idempotencyKey: $key);
var_dump($first->id() === $again->id(), $again->replayed()); // the stored result, not charged twice
```

## Other endpoints

```php
<?php
require __DIR__ . '/vendor/autoload.php';

$client = new TonePerfect\Client();
print_r($client->lint('我有3个苹果', 'zh-CN')['issues']); // free reference-text check, no key
echo $client->status()['status'], "\n";                 // synthetic engine probe
```

## Configuration

`new TonePerfect\Client(apiKey: null, baseUrl: null, timeout: 60.0, maxRetries: 2, headers: [])`. `apiKey`
defaults to `TONEPERFECT_API_KEY`, `baseUrl` to `TONEPERFECT_BASE_URL`, else `https://api.toneperfect.app` (a proxy
with a 26-second limit: a longer passage comes back on the automatic retry, charged once). `headers` adds headers
to every request, for example `['TonePerfect-Fallback' => 'off']`.

Grades are display scores calibrated per language against native references, not accuracy percentages and not
comparable across vendors. Every language pack is labelled `experimental` in `/v1/capabilities`.
Docs: https://api.toneperfect.app/docs · MIT licence · nik@toneperfect.app

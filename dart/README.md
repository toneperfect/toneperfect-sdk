# TonePerfect Dart client

Client for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app): send a short recording
and the text it should contain, get 0–100 scores for the sentence, every word and every sound, with Mandarin
initial, final and tone per syllable. 10 languages. Dart 3 and Flutter (`package:http`).

```sh
dart pub add toneperfect
```

Keep the API key on a server you control: a Flutter app should send the recording to your backend, which calls
this API (the starter projects at https://api.toneperfect.app/starters/ show one with a Firebase Function).

## Try it with a test key

[Sign up](https://api.toneperfect.app/signup) (50 free credits, no card), then in the dashboard open
**API keys** and create a **test key** (`tp_test_…`). A test key runs the real request path but returns a
fixed example result: it never scores your audio and never spends credits. Swap in a live key
(`tp_live_…`) for real scores.

```sh
export TONEPERFECT_API_KEY="tp_test_..."
curl -o hello.ogg https://api.toneperfect.app/capsule/speech-zh-nihao.ogg   # 2 s of 你好
```

```dart
import 'dart:io';

import 'package:toneperfect/toneperfect.dart';

Future<void> main() async {
  final client = TonePerfect(); // reads TONEPERFECT_API_KEY
  final result = await client.assess(await File('hello.ogg').readAsBytes(), filename: 'hello.ogg', text: '你好', language: 'zh-CN');

  print([result.assessable, result.overall, result.billing.credits, result.test]);
  for (final word in result.words) {
    for (final phone in word.phones) {
      print('${word.word} ${phone.dimension} ${phone.expected} ${phone.heard} ${phone.score} ${phone.decision}');
    }
  }
  client.close();
}
```

`language` is required: `zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR` or
`ja-JP`. `filename` sets the name and, from its extension, the audio type sent with the bytes.

## Results

`Assessment`: `assessable` and `reason` (a recording that could not be scored is free and is not a score of
zero), `overall` and `scores` (0–100; `null` = not measured by this pack), `words` (`Word`: `word`, `score`,
`startMs`, `endMs`, `decision`, `pinyin`, `phones`), `phones` (`Phone`: `dimension`, `expected`, `heard`,
`score`, `decision`), `billing` (`credits`, `balanceCredits`, `freeCredits`, `source`: `free`, `plan` or
`test`), `warnings`, `engine`, `modelVersion`, `id`, `replayed`, `test`, and `data`, the JSON as returned. Act on
`decision`, not on every low grade. `compact: true` asks for the `toneperfect.compact.v1` schema; the same getters
work on it.

## Errors, retries and timeouts

Every error is a `TonePerfectError` with the API's `code`, `message`, `status` and `requestId`. Subclasses:
`AuthenticationError` (401), `PaymentRequiredError` (402, with `billingUrl` and, when the API sends them,
`pricingUrl` and `plan`), `RateLimitError` (429), `ValidationError` (other 4xx), `ServerError` (5xx) and
`APIConnectionError` (timeout or network failure). The client retries a failure that stored nothing
(`retryable`) up to `maxRetries` times with the **same** Idempotency-Key, so a finished result is returned and
charged once; `needsNewKey` marks a failure stored under the key. A test key rehearses each outcome:

```dart
import 'dart:io';

import 'package:toneperfect/toneperfect.dart';

Future<void> main() async {
  final client = TonePerfect(timeout: const Duration(seconds: 30), maxRetries: 2);
  final audio = await File('hello.ogg').readAsBytes();
  try {
    await client.assess(audio, filename: 'hello.ogg', text: '你好', language: 'zh-CN', testOutcome: 'subscription_required');
  } on PaymentRequiredError catch (e) {
    print('${e.code} -> ${e.billingUrl}');
  } on TonePerfectError catch (e) {
    print('${e.status} ${e.code} ${e.message} ${e.retryable} ${e.needsNewKey}');
  }

  final unscored = await client.assess(audio, filename: 'hello.ogg', text: '你好', language: 'zh-CN', testOutcome: 'unassessable');
  print([unscored.assessable, unscored.reason]);
  client.close();
}
```

To resend the same recording safely after a crash, keep your own key:

```dart
import 'dart:io';

import 'package:toneperfect/toneperfect.dart';

Future<void> main() async {
  final client = TonePerfect();
  final audio = await File('hello.ogg').readAsBytes();
  final key = newIdempotencyKey(); // store it with the recording
  final first = await client.assess(audio, filename: 'hello.ogg', text: 'I like sunny days', language: 'en-US', idempotencyKey: key);
  final again = await client.assess(audio, filename: 'hello.ogg', text: 'I like sunny days', language: 'en-US', idempotencyKey: key);
  print([first.id == again.id, again.replayed]); // the stored result, not charged twice
  client.close();
}
```

## Other endpoints

```dart
import 'package:toneperfect/toneperfect.dart';

Future<void> main() async {
  final client = TonePerfect();
  print((await client.lint('我有3个苹果', language: 'zh-CN'))['issues']); // free reference-text check, no key
  print((await client.status())['status']);                           // synthetic engine probe
  client.close();
}
```

## Configuration

`TonePerfect({apiKey, baseUrl, timeout = 60 s, maxRetries = 2, headers, httpClient})`. On the Dart VM and Flutter
mobile or desktop, `apiKey` defaults to the `TONEPERFECT_API_KEY` environment variable and `baseUrl` to
`TONEPERFECT_BASE_URL`, else `https://api.toneperfect.app` (a proxy with a 26-second limit: a longer passage comes
back on the automatic retry, charged once). `headers` adds headers to every request, for example
`{'TonePerfect-Fallback': 'off'}`.

Grades are display scores calibrated per language against native references, not accuracy percentages and not
comparable across vendors. Every language pack is labelled `experimental` in `/v1/capabilities`.
Docs: https://api.toneperfect.app/docs · MIT licence · nik@toneperfect.app

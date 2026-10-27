# toneperfect (Dart / Flutter)

Client for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app), 10 languages:
`zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR` (beta) and `ja-JP` (beta).
Send a short scripted recording and the text it should contain, get 0–100 scores for the sentence,
every word and every sound in one JSON response, with expected vs heard sounds and timings.
Mandarin syllables also get separate initial, final and tone scores.

Depends only on `package:http`; works on the Dart VM, Flutter and the web.

```sh
dart pub add toneperfect
```

## Quickstart

```dart
import 'dart:io';
import 'package:toneperfect/toneperfect.dart';

Future<void> main() async {
  final client = TonePerfect(apiKey: 'tp_live_...');

  // No key needed: which languages are served, and their limits.
  final caps = await client.capabilities();
  print(caps['languages']);

  try {
    final result = await client.assess(File('hello.wav').readAsBytesSync(),
        text: '你好', language: 'zh-CN');
    print('${result.assessable} ${result.overall} ${result.billing}');
    for (final word in result.words) {
      print('${word['word']} ${word['score']}');
    }
  } on PaymentRequiredError catch (e) {
    // 402: free credits used up / no plan. Nothing was charged.
    print('${e.code}: ${e.message}');
  } on TonePerfectError catch (e) {
    print('${e.status} ${e.code}: ${e.message} (retry same key: ${e.retryable})');
  } finally {
    client.close();
  }
}
```

Get a key: [create an account](https://api.toneperfect.app/signup) → dashboard → API keys.
New accounts get **50 free credits**, no card needed; then plans from $10/month
([pricing](https://api.toneperfect.app/pricing/)). One credit per started 15 seconds of
audio; failed and unassessable requests cost nothing. Keep the key on your server — a
Flutter app should call your own backend, which calls this API.

## What is wrapped

| Method | Endpoint |
| --- | --- |
| `capabilities()` | `GET /v1/capabilities` (no key) |
| `assess(bytes, text:, language:, pinyin:, task:, idempotencyKey:, filename:)` | `POST /v1/assess` — multipart `audio`, `text`, `language`, optional `pinyin` (`ni3 hao3`) and `task` (`general`, `connected_speech`, `isolated_word`); headers `Authorization: Bearer` + `Idempotency-Key` |

`Assessment` exposes `data` (the untouched JSON), `assessable`, `reason`, `scores`,
`overall`, `words`, `billing`, `modelVersion`, `id` and `replayed`. Never show an
unassessable result as a zero.

Errors are typed: `AuthenticationError` (401), `PaymentRequiredError` (402:
`subscription_required`, `insufficient_credits`, `payment_balance_due`), `RateLimitError`
(429), `ValidationError` (other 4xx), `ServerError` (5xx) and `APIConnectionError`
(timeout / network). All extend `TonePerfectError` with `status`, `code`, `message`,
`requestId`, `retryable` (retry later with the **same** Idempotency-Key) and
`needsNewKey`. `free_capacity` (429, free credits reached today's shared limit) is not retryable: it clears at the next UTC day, or at once with a paid plan.

## Limits

Up to 30 s and 10 MB of audio (WAV, MP3, M4A, OGG, WebM), scripted speech only, two
concurrent requests per account. Grades are display scores calibrated per language,
not accuracy percentages; every language pack is labelled `experimental` in
`/v1/capabilities`. See the [methodology](https://api.toneperfect.app/methodology/).

Docs: https://api.toneperfect.app/docs · License: MIT

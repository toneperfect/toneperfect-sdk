import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:toneperfect/toneperfect.dart';

void main() {
  test('assess sends the multipart contract and auth headers', () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response(
          jsonEncode({
            'assessable': true,
            'scores': {'overall': 86, 'tone': 80, 'fluency': null},
            'words': [
              {'word': '你', 'score': 94, 'phones': []}
            ],
            'billing': {'credits': 1, 'balance_credits': 49},
            'model_version': 'm1',
            'id': 'req_1',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8', 'x-request-id': 'req_1'});
    });
    final client = TonePerfect(apiKey: 'tp_live_test', baseUrl: 'https://api.toneperfect.app/', httpClient: mock);
    final result = await client.assess(utf8.encode('RIFF....'),
        text: '你好', language: 'zh-CN', pinyin: 'ni3 hao3', task: 'connected_speech', idempotencyKey: 'lesson-42-attempt-1', filename: 'hello.wav');
    expect(captured.url.toString(), 'https://api.toneperfect.app/v1/assess');
    expect(captured.method, 'POST');
    expect(captured.headers['Authorization'], 'Bearer tp_live_test');
    expect(captured.headers['Idempotency-Key'], 'lesson-42-attempt-1');
    expect(captured.headers['content-type'], startsWith('multipart/form-data; boundary='));
    final body = utf8.decode(captured.bodyBytes);
    for (final part in [
      '\r\n\r\n你好\r\n',
      'name="language"\r\n\r\nzh-CN',
      'name="pinyin"\r\n\r\nni3 hao3',
      'name="task"\r\n\r\nconnected_speech',
      'name="audio"; filename="hello.wav"',
      'RIFF....',
    ]) {
      expect(body, contains(part));
    }
    expect(result.assessable, isTrue);
    expect(result.overall, 86);
    expect(result.scores['fluency'], isNull);
    expect(result.billing['credits'], 1);
    expect(result.words.first['word'], '你');
    expect(result.id, 'req_1');
    expect(result.replayed, isFalse);
  });

  test('errors are typed by status; 402 is PaymentRequiredError and not retryable', () async {
    for (final entry in <int, TypeMatcher>{
      401: isA<AuthenticationError>(),
      402: isA<PaymentRequiredError>(),
      429: isA<RateLimitError>(),
      422: isA<ValidationError>(),
      503: isA<ServerError>(),
    }.entries) {
      final client = TonePerfect(
          apiKey: 'tp_live_test',
          httpClient: MockClient((_) async => http.Response(
              jsonEncode({'error': {'code': 'subscription_required', 'message': 'm'}, 'request_id': 'req_9'}), entry.key)));
      await expectLater(
          client.assess([1, 2, 3], text: 'hi', language: 'en-US'),
          throwsA(allOf(entry.value, isA<TonePerfectError>().having((e) => e.status, 'status', entry.key))));
    }
    final client = TonePerfect(
        apiKey: 'k',
        httpClient: MockClient((_) async => http.Response(jsonEncode({'error': {'code': 'insufficient_credits', 'message': 'm'}}), 402)));
    try {
      await client.capabilities();
      fail('expected an error');
    } on PaymentRequiredError catch (e) {
      expect(e.code, 'insufficient_credits');
      expect(e.retryable, isFalse);
    }
  });

  test('HTML 502 from a proxy is retryable with the same key', () async {
    final client = TonePerfect(httpClient: MockClient((_) async => http.Response('<html>bad gateway</html>', 502)));
    try {
      await client.capabilities();
      fail('expected an error');
    } on ServerError catch (e) {
      expect(e.code, 'http_error');
      expect(e.retryable, isTrue);
      expect(e.needsNewKey, isFalse);
    }
  });

  test('assess without a key fails before sending', () async {
    var called = false;
    final client = TonePerfect(httpClient: MockClient((_) async {
      called = true;
      return http.Response('{}', 200);
    }));
    await expectLater(client.assess([1], text: 'hi'), throwsA(isA<AuthenticationError>()));
    expect(called, isFalse);
  });

  test('newIdempotencyKey is valid', () {
    expect(newIdempotencyKey(), matches(RegExp(r'^[A-Za-z0-9_.:-]{8,128}$')));
  });

  test('live: GET /v1/capabilities without a key', () async {
    final client = TonePerfect();
    final caps = await client.capabilities();
    expect(caps['languages'], isA<List>());
    expect((caps['languages'] as List).map((l) => l['locale']), contains('zh-CN'));
    client.close();
  }, tags: ['live']);
}

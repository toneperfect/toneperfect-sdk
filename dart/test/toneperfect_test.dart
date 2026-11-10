// Contract tests against testing/mock_api.py (a local stand-in that follows the live gateway's rules).
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:toneperfect/toneperfect.dart';

const helloPath = '../testing/fixtures/hello.ogg';
final servers = <String, String>{};
final processes = <Process>[];

Future<String> server(String gateway) async {
  if (servers.containsKey(gateway)) return servers[gateway]!;
  final process = await Process.start('python3', ['../testing/mock_api.py', '--gateway', gateway]);
  processes.add(process);
  final url = await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
  return servers[gateway] = url.trim();
}

Future<List<Map<String, dynamic>>> attempts(String url, String key) async {
  final client = HttpClient();
  final request = await client.getUrl(Uri.parse('$url/_mock/log'));
  final body = await (await request.close()).transform(utf8.decoder).join();
  client.close();
  return (jsonDecode(body) as List).cast<Map<String, dynamic>>().where((e) => e['idempotency_key'] == key).toList();
}

Future<T> expectError<T extends TonePerfectError>(Future<Object?> Function() f) async {
  try {
    await f();
  } on TonePerfectError catch (e) {
    expect(e, isA<T>());
    return e as T;
  }
  fail('expected $T');
}

void main() {
  final hello = File(helloPath).readAsBytesSync();
  tearDownAll(() {
    for (final p in processes) {
      p.kill();
    }
  });

  for (final gateway in ['live', '1110']) {
    group(gateway, () {
      late String url;
      setUpAll(() async => url = await server(gateway));
      TonePerfect client({int maxRetries = 2, Duration timeout = const Duration(seconds: 60), Map<String, String>? headers}) =>
          TonePerfect(apiKey: 'tp_test_mock', baseUrl: url, maxRetries: maxRetries, timeout: timeout, headers: headers);

      test('request and typed result', () async {
        final r = await client().assess(hello, text: '你好', language: 'zh-CN', task: 'connected_speech', filename: 'hello.ogg');
        final sent = (await attempts(url, r.idempotencyKey)).first;
        expect(RegExp(r'^[0-9a-f-]{36}$').hasMatch(r.idempotencyKey), isTrue);
        expect(sent['auth_scheme'], 'Bearer');
        expect(sent['fields'], {'text': '你好', 'language': 'zh-CN', 'task': 'connected_speech'});
        expect([sent['audio']['filename'], sent['audio']['content_type']], ['hello.ogg', 'audio/ogg']);
        expect(sent['user_agent'], 'toneperfect-dart/$toneperfectVersion');
        expect(r.assessable && r.test, isTrue);
        expect(r.overall, 78.0);
        expect(r.words.map((w) => w.word), ['你', '好']);
        expect(r.words[0].phones.map((p) => p.dimension), ['initial', 'final', 'tone']);
        expect([r.billing.credits, r.billing.source, r.engine], [0, 'test', 'primary']);
      });

      test('compact maps to the same fields', () async {
        final r = await client().assess(hello, text: 'I like sunny days', language: 'en-US', compact: true);
        expect(r.compact, isTrue);
        expect(r.words.map((w) => w.word), ['I', 'like', 'sunny', 'days']);
        expect(r.words[1].phones[0].dimension, 'phoneme');
      });

      test('replay with the same key', () async {
        final key = newIdempotencyKey();
        final a = await client().assess(hello, text: '你好', language: 'zh-CN', idempotencyKey: key);
        final b = await client().assess(hello, text: '你好', language: 'zh-CN', idempotencyKey: key);
        expect(a.id, b.id);
        expect(b.replayed, isTrue);
      });

      test('retries with the same key', () async {
        var r = await client(headers: {'X-Mock-Fail': 'gateway_busy:2'}).assess(hello, text: '你好', language: 'zh-CN');
        expect((await attempts(url, r.idempotencyKey)).length, 3);
        r = await client(headers: {'X-Mock-Fail': 'html502:1'}).assess(hello, text: '你好', language: 'zh-CN');
        expect((await attempts(url, r.idempotencyKey)).length, 2);
        final e = await expectError<ServerError>(
            () => client(maxRetries: 0, headers: {'X-Mock-Fail': 'engine_unavailable:1'}).assess(hello, text: '你好', language: 'zh-CN'));
        expect(e.retryable && !e.needsNewKey, isTrue);
        final rl = await expectError<RateLimitError>(() => client(maxRetries: 1).assess(hello, text: '你好', language: 'zh-CN', testOutcome: 'rate_limit'));
        expect((await attempts(url, rl.idempotencyKey!)).length, 2);
      });

      test('finalized failure needs a new key', () async {
        final e = await expectError<ValidationError>(() => client().assess(hello, text: '你好', language: 'zh-CN', testOutcome: 'invalid_assessment'));
        expect(e.finalized && e.needsNewKey && !e.retryable, isTrue);
        expect(e.id, startsWith('req_'));
        expect((await attempts(url, e.idempotencyKey!)).length, 1);
      });

      test('402 carries a billing link', () async {
        final e = await expectError<PaymentRequiredError>(() => client().assess(hello, text: '你好', language: 'zh-CN', testOutcome: 'subscription_required'));
        expect(e.code, 'subscription_required');
        expect(e.billingUrl, defaultBillingUrl);
        expect(e.toString(), contains(defaultBillingUrl));
        expect(e.retryable, isFalse);
        if (gateway == '1110') {
          expect(e.plan!['name'], 'Starter');
          expect(e.pricingUrl, 'https://api.toneperfect.app/pricing/');
        }
      });

      test('authentication and timeout', () async {
        await expectError<AuthenticationError>(() => TonePerfect(apiKey: 'nope', baseUrl: url).assess(hello, text: '你好', language: 'zh-CN'));
        final e = await expectError<APIConnectionError>(() => client(maxRetries: 0, timeout: const Duration(milliseconds: 300), headers: {'X-Mock-Delay': '1'})
            .assess(hello, text: '你好', language: 'zh-CN'));
        expect([e.status, e.code, e.retryable], [0, 'timeout', true]);
        expect(() => client().assess(hello, text: '你好', language: ''), throwsArgumentError);
      });

      test('other endpoints', () async {
        final c = client();
        expect((await c.capabilities())['languages'], isNotEmpty);
        expect((await c.lint('你好', language: 'zh-CN'))['ok'], isTrue);
        expect((await c.status()).containsKey('status'), isTrue);
      });
    });
  }
}

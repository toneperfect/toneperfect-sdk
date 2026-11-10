<?php
// Contract tests against testing/mock_api.py (a local stand-in that follows the live gateway's rules).
// Run: php tests/run.php   (or composer test). No dependencies.
declare(strict_types=1);
require __DIR__ . '/../src/TonePerfect.php';

use TonePerfect\{Client, TonePerfectException, AuthenticationError, PaymentRequiredError, RateLimitError, ValidationError, ServerError, APIConnectionError};
use function TonePerfect\new_idempotency_key;
use const TonePerfect\{VERSION, BILLING_URL};

const HELLO = __DIR__ . '/../../testing/fixtures/hello.ogg';
$tests = 0; $assertions = 0; $failures = []; $current = '';
function check(bool $cond, string $msg): void { global $assertions, $failures, $current; $assertions++; if (!$cond) $failures[] = "$current: $msg"; }
function test(string $name, callable $fn): void { global $tests, $current, $failures; $current = $name; $tests++; try { $fn(); } catch (\Throwable $e) { $failures[] = "$name: unexpected " . get_class($e) . ' ' . $e->getMessage(); } }
function expect(string $class, callable $fn): TonePerfectException|\Throwable {
    try { $fn(); } catch (\Throwable $e) { check($e instanceof $class, "expected $class, got " . get_class($e) . ': ' . $e->getMessage()); return $e; }
    check(false, "expected $class, nothing thrown"); return new \RuntimeException('none');
}

$procs = [];
function server(string $gateway): string {
    static $urls = [];
    global $procs;
    if (!isset($urls[$gateway])) {
        $proc = proc_open(['python3', __DIR__ . '/../../testing/mock_api.py', '--gateway', $gateway], [1 => ['pipe', 'w']], $pipes);
        $procs[] = $proc;
        $urls[$gateway] = trim(fgets($pipes[1]));
    }
    return $urls[$gateway];
}
function attempts(string $url, string $key): array {
    return array_values(array_filter(json_decode(file_get_contents("$url/_mock/log"), true), fn ($e) => $e['idempotency_key'] === $key));
}

foreach (['live', '1110'] as $gateway) {
    $url = server($gateway);
    $client = fn (array $o = []) => new Client('tp_test_mock', $url, $o['timeout'] ?? 60.0, $o['maxRetries'] ?? 2, $o['headers'] ?? []);

    test("$gateway: request and typed result", function () use ($client, $url) {
        $r = $client()->assess(HELLO, text: '你好', language: 'zh-CN', task: 'connected_speech');
        $sent = attempts($url, $r->idempotencyKey)[0];
        check((bool) preg_match('/^[0-9a-f-]{36}$/', $r->idempotencyKey), 'uuid key');
        check($sent['auth_scheme'] === 'Bearer', 'Bearer');
        check($sent['fields'] == ['language' => 'zh-CN', 'task' => 'connected_speech', 'text' => '你好'], 'fields ' . json_encode($sent['fields']));
        check($sent['audio']['filename'] === 'hello.ogg' && $sent['audio']['content_type'] === 'audio/ogg', 'file name and type');
        check($sent['user_agent'] === 'toneperfect-php/' . VERSION, 'user agent');
        check($r->assessable() && $r->test() && $r->overall() === 78.0, 'typed result');
        check(array_map(fn ($w) => $w->word, $r->words()) === ['你', '好'], 'words');
        check(array_map(fn ($p) => $p->dimension, $r->words()[0]->phones) === ['initial', 'final', 'tone'], 'phones');
        check($r->billing()->credits === 0 && $r->billing()->source === 'test' && $r->engine() === 'primary', 'billing and engine');
    });
    test("$gateway: compact maps to the same fields", function () use ($client) {
        $fh = fopen(HELLO, 'rb');
        $r = $client()->assess($fh, text: 'I like sunny days', language: 'en-US', compact: true);
        fclose($fh);
        check($r->compact() && array_map(fn ($w) => $w->word, $r->words()) === ['I', 'like', 'sunny', 'days'], 'compact words');
        check($r->words()[1]->phones[0]->dimension === 'phoneme', 'compact units');
    });
    test("$gateway: replay with the same key", function () use ($client) {
        $key = new_idempotency_key();
        $a = $client()->assess(HELLO, text: '你好', language: 'zh-CN', idempotencyKey: $key);
        $b = $client()->assess(HELLO, text: '你好', language: 'zh-CN', idempotencyKey: $key);
        check($a->id() === $b->id() && $b->replayed(), 'replayed');
    });
    test("$gateway: retries with the same key", function () use ($client, $url) {
        $r = $client(['headers' => ['X-Mock-Fail' => 'gateway_busy:2']])->assess(HELLO, text: '你好', language: 'zh-CN');
        check(count(attempts($url, $r->idempotencyKey)) === 3, 'three attempts');
        $r = $client(['headers' => ['X-Mock-Fail' => 'html502:1']])->assess(HELLO, text: '你好', language: 'zh-CN');
        check(count(attempts($url, $r->idempotencyKey)) === 2, '502 retried');
        $e = expect(ServerError::class, fn () => $client(['maxRetries' => 0, 'headers' => ['X-Mock-Fail' => 'engine_unavailable:1']])->assess(HELLO, text: '你好', language: 'zh-CN'));
        check($e->retryable() && !$e->needsNewKey(), 'engine_unavailable retryable');
        $e = expect(RateLimitError::class, fn () => $client(['maxRetries' => 1])->assess(HELLO, text: '你好', language: 'zh-CN', testOutcome: 'rate_limit'));
        check(count(attempts($url, $e->idempotencyKey)) === 2, 'rate limit retried once');
    });
    test("$gateway: finalized failure needs a new key", function () use ($client, $url) {
        $e = expect(ValidationError::class, fn () => $client()->assess(HELLO, text: '你好', language: 'zh-CN', testOutcome: 'invalid_assessment'));
        check($e->finalized() && $e->needsNewKey() && !$e->retryable() && str_starts_with((string) $e->id, 'req_'), 'finalized');
        check(count(attempts($url, $e->idempotencyKey)) === 1, 'not retried');
    });
    test("$gateway: 402 carries a billing link", function () use ($client, $gateway) {
        $e = expect(PaymentRequiredError::class, fn () => $client()->assess(HELLO, text: '你好', language: 'zh-CN', testOutcome: 'subscription_required'));
        check($e->code() === 'subscription_required' && $e->billingUrl === BILLING_URL && str_contains($e->getMessage(), BILLING_URL) && !$e->retryable(), '402 link');
        if ($gateway === '1110') check(($e->plan['name'] ?? null) === 'Starter' && $e->pricingUrl === 'https://api.toneperfect.app/pricing/', '402 plan');
    });
    test("$gateway: authentication, timeout and required language", function () use ($client, $url) {
        expect(AuthenticationError::class, fn () => (new Client('nope', $url))->assess(HELLO, text: '你好', language: 'zh-CN'));
        $e = expect(APIConnectionError::class, fn () => $client(['timeout' => 0.3, 'maxRetries' => 0, 'headers' => ['X-Mock-Delay' => '1']])->assess(HELLO, text: '你好', language: 'zh-CN'));
        check($e->status === 0 && $e->code() === 'timeout' && $e->retryable(), 'timeout');
        expect(\ArgumentCountError::class, fn () => $client()->assess(HELLO, text: '你好'));
    });
    test("$gateway: other endpoints", function () use ($client) {
        $c = $client();
        check(in_array('zh-CN', array_column($c->capabilities()['languages'], 'locale'), true), 'capabilities');
        check($c->lint('你好', 'zh-CN')['ok'] === true, 'lint');
        check(isset($c->status()['status']), 'status');
    });
}
test('environment defaults', function () {
    putenv('TONEPERFECT_BASE_URL=http://example.invalid/'); putenv('TONEPERFECT_API_KEY=tp_test_env');
    $c = new Client();
    check([$c->baseUrl, $c->apiKey, $c->maxRetries, $c->timeout] === ['http://example.invalid', 'tp_test_env', 2, 60.0], 'defaults');
    putenv('TONEPERFECT_BASE_URL'); putenv('TONEPERFECT_API_KEY');
});

foreach ($procs as $p) proc_terminate($p);
echo "$tests tests, $assertions assertions, " . count($failures) . " failures\n";
foreach ($failures as $f) echo "  FAIL $f\n";
exit($failures ? 1 : 0);

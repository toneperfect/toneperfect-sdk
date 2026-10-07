<?php
// Offline tests, no dependencies: a fake transport plus PHP's built-in server on loopback.
// Run: php tests/run.php   (or composer test)
declare(strict_types=1);
require __DIR__ . '/../src/TonePerfect.php';

use TonePerfect\{Client, Assessment, TonePerfectException, AuthenticationError, PaymentRequiredError, RateLimitError, ValidationError, ServerError, APIConnectionError};
use function TonePerfect\new_idempotency_key;
use const TonePerfect\IDEMPOTENCY_RE;

$tests = 0; $assertions = 0; $failures = [];
function check(bool $cond, string $msg): void { global $assertions, $failures, $current; $assertions++; if (!$cond) $failures[] = "$current: $msg"; }
function test(string $name, callable $fn): void { global $tests, $current, $failures; $current = $name; $tests++; try { $fn(); } catch (\Throwable $e) { $failures[] = "$name: unexpected " . get_class($e) . ' ' . $e->getMessage(); } }
function fake(int $status, $body, array $headers = []): object {
    return new class($status, $body, $headers) {
        public array $calls = [];
        public function __construct(public int $status, public $body, public array $headers) {}
        public function __invoke(string $method, string $url, array $headers, ?string $body): array {
            $this->calls[] = compact('method', 'url', 'headers', 'body');
            return [$this->status, $this->headers, is_string($this->body) ? $this->body : json_encode($this->body)];
        }
    };
}
function client($t, string $key = 'tp_live_test'): Client { return new Client($key, 'https://api.toneperfect.app/', 90, null, $t); }
function err(int $status, $body, array $headers = []): TonePerfectException {
    try { client(fake($status, $body, $headers))->assessBytes('x', ['text' => 'hi', 'idempotency_key' => 'lesson-42-attempt-1']); }
    catch (TonePerfectException $e) { return $e; }
    throw new \RuntimeException('no exception');
}

test('assess sends the real contract', function () {
    $t = fake(200, ['assessable' => true, 'scores' => ['overall' => 86, 'tone' => 80, 'fluency' => null], 'words' => [['word' => '你', 'score' => 94]],
        'billing' => ['credits' => 1, 'balance_credits' => 2499], 'model_version' => 'mandarin-human-v2-x', 'id' => 'req_1'], ['X-Request-Id' => 'req_1']);
    $r = client($t)->assessBytes('RIFF....', ['text' => '你好', 'language' => 'zh-CN', 'pinyin' => 'ni3 hao3', 'task' => 'connected_speech',
        'idempotency_key' => 'lesson-42-attempt-1', 'filename' => 'hello.wav']);
    $c = $t->calls[0];
    check($c['method'] === 'POST' && $c['url'] === 'https://api.toneperfect.app/v1/assess', 'url');
    check($c['headers']['Authorization'] === 'Bearer tp_live_test', 'auth');
    check($c['headers']['Idempotency-Key'] === 'lesson-42-attempt-1', 'key');
    check($c['headers']['User-Agent'] === 'toneperfect-php/0.1.0', 'ua');
    check(str_starts_with($c['headers']['Content-Type'], 'multipart/form-data; boundary='), 'ctype');
    foreach (['text' => '你好', 'language' => 'zh-CN', 'pinyin' => 'ni3 hao3', 'task' => 'connected_speech'] as $f => $v) {
        check(str_contains($c['body'], "name=\"$f\"\r\n\r\n$v\r\n"), "field $f");
    }
    check(str_contains($c['body'], 'name="audio"; filename="hello.wav"') && str_contains($c['body'], 'RIFF....'), 'audio part');
    check($r instanceof Assessment && $r->assessable() && $r->overall() === 86 && $r->scores()['fluency'] === null, 'scores');
    check($r->billing()['credits'] === 1 && $r->modelVersion() === 'mandarin-human-v2-x' && $r->id() === 'req_1', 'fields');
    check($r->words()[0]['word'] === '你' && !$r->replayed() && $r->requestId() === 'req_1', 'words/replay');
});

test('path and stream audio, replay, generated key, unassessable', function () {
    $path = tempnam(sys_get_temp_dir(), 'tp'); file_put_contents($path, 'WAVDATA');
    $t = fake(200, ['assessable' => false, 'reason' => 'silence', 'scores' => ['overall' => null], 'billing' => ['credits' => 0, 'balance_credits' => 5]], ['Idempotent-Replayed' => 'true']);
    $r = client($t)->assess($path, ['text' => 'hi', 'language' => 'en-US']);
    check(str_contains($t->calls[0]['body'], 'WAVDATA'), 'path read');
    check((bool) preg_match(IDEMPOTENCY_RE, $t->calls[0]['headers']['Idempotency-Key']), 'generated key');
    check(!str_contains($t->calls[0]['body'], 'name="pinyin"'), 'no pinyin');
    check($r->replayed() && !$r->assessable() && $r->reason() === 'silence' && $r->billing()['credits'] === 0, 'unassessable');
    $fh = fopen($path, 'rb'); client($t)->assess($fh, ['text' => 'hi']); fclose($fh);
    check(str_contains($t->calls[1]['body'], 'WAVDATA'), 'stream read');
    unlink($path);
});

test('API errors are typed', function () {
    $e = err(402, ['error' => ['code' => 'insufficient_credits', 'message' => 'Purchase a credit pack.'], 'request_id' => 'req_9']);
    check($e instanceof PaymentRequiredError && $e->status === 402 && $e->code() === 'insufficient_credits' && $e->requestId === 'req_9' && !$e->retryable(), 'payment');
    foreach ([401 => AuthenticationError::class, 402 => PaymentRequiredError::class, 429 => RateLimitError::class, 422 => ValidationError::class, 503 => ServerError::class] as $s => $cls) {
        try { client(fake($s, ['error' => ['code' => 'subscription_required', 'message' => 'm']]))->capabilities(); check(false, "$s no throw"); }
        catch (TonePerfectException $x) { check($x instanceof $cls && $x->status === $s, "$s -> $cls"); }
    }
});

test('finalized failure needs a new key', function () {
    $e = err(503, ['error' => ['code' => 'engine_unavailable', 'message' => 'No credits were charged.'], 'id' => 'req_77', 'billing' => ['credits' => 0, 'balance_credits' => 12]]);
    check($e->id === 'req_77' && $e->billing === ['credits' => 0, 'balance_credits' => 12] && $e->finalized() && $e->needsNewKey() && !$e->retryable(), 'finalized');
});

test('not-finalized failures retry with the same key', function () {
    foreach ([[409, 'request_pending'], [429, 'rate_limit'], [429, 'account_busy'], [503, 'gateway_busy'], [503, 'decoder_busy'], [503, 'audio_decoder_unavailable'], [408, 'upload_timeout'], [503, 'engine_unavailable']] as [$s, $code]) {
        $e = err($s, ['error' => ['code' => $code, 'message' => 'later'], 'request_id' => 'req_x'], ['Retry-After' => '1']);
        check($e->retryable() && !$e->needsNewKey() && !$e->finalized() && $e->retryAfter === 1.0, $code);
    }
});

test('spent keys and client errors', function () {
    foreach (['idempotency_expired', 'idempotency_conflict'] as $code) { $e = err(409, ['error' => ['code' => $code, 'message' => 'n']]); check($e->needsNewKey() && !$e->retryable(), $code); }
    foreach ([[401, 'invalid_api_key'], [402, 'insufficient_credits'], [422, 'invalid_audio'], [422, 'unsupported_language'], [413, 'upload_too_large']] as [$s, $code]) {
        $e = err($s, ['error' => ['code' => $code, 'message' => 'fix']]); check(!$e->retryable() && !$e->needsNewKey(), $code);
    }
});

test('non-JSON proxy error', function () {
    $e = err(504, '<html>Gateway Timeout</html>');
    check($e instanceof ServerError && $e->code() === 'http_error' && $e->retryable() && !$e->needsNewKey(), '504 html');
    check(err(502, '')->retryable(), '502 empty');
});

test('capabilities needs no key; validation; env key', function () {
    $t = fake(200, ['languages' => [['locale' => 'zh-CN', 'status' => 'experimental']]]);
    $caps = client($t, '')->capabilities();
    check($t->calls[0]['method'] === 'GET' && $t->calls[0]['url'] === 'https://api.toneperfect.app/v1/capabilities' && !isset($t->calls[0]['headers']['Authorization']), 'caps request');
    check($caps['languages'][0]['locale'] === 'zh-CN', 'caps body');
    $ok = fake(200, []);
    foreach ([[fn() => client($ok, '')->assessBytes('x', ['text' => 'x']), AuthenticationError::class],
              [fn() => client($ok)->assessBytes('x', ['language' => 'en-US']), \InvalidArgumentException::class],
              [fn() => client($ok)->assessBytes('x', ['text' => 'x', 'task' => 'freestyle']), \InvalidArgumentException::class],
              [fn() => client($ok)->assessBytes('x', ['text' => 'x', 'idempotency_key' => 'short']), \InvalidArgumentException::class],
              [fn() => new_idempotency_key('bad prefix'), \InvalidArgumentException::class]] as [$fn, $cls]) {
        try { $fn(); check(false, "expected $cls"); } catch (\Throwable $x) { check($x instanceof $cls, "got " . get_class($x)); }
    }
    check(count($ok->calls) === 0, 'validation never sends');
    check((bool) preg_match(IDEMPOTENCY_RE, new_idempotency_key('lesson.42')), 'key format');
    putenv('TONEPERFECT_API_KEY=tp_live_env'); check((new Client())->apiKey === 'tp_live_env', 'env key'); putenv('TONEPERFECT_API_KEY');
});

test('curl transport against a loopback server (402, timeout, refused)', function () {
    $router = tempnam(sys_get_temp_dir(), 'tprouter') . '.php';
    file_put_contents($router, '<?php if ($_SERVER["REQUEST_URI"] === "/slow/v1/capabilities") { sleep(2); exit; }
        header("Content-Type: application/json"); header("X-Request-Id: req_402"); http_response_code(402);
        echo json_encode(["error" => ["code" => "subscription_required", "message" => "Choose a plan."], "request_id" => "req_402",
          "echo" => ["auth" => $_SERVER["HTTP_AUTHORIZATION"] ?? null, "key" => $_SERVER["HTTP_IDEMPOTENCY_KEY"] ?? null, "text" => $_POST["text"] ?? null,
          "audio" => isset($_FILES["audio"]) ? file_get_contents($_FILES["audio"]["tmp_name"]) : null]]);');
    $sock = stream_socket_server('tcp://127.0.0.1:0'); $port = (int) explode(':', stream_socket_get_name($sock, false))[1]; fclose($sock);
    $proc = proc_open([PHP_BINARY, '-S', "127.0.0.1:$port", $router], [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
    for ($i = 0; $i < 50 && !@fsockopen('127.0.0.1', $port); $i++) usleep(100000);
    try {
        try { (new Client('tp_live_local', "http://127.0.0.1:$port", 5))->assessBytes('RIFF', ['text' => 'hello', 'language' => 'en-US', 'idempotency_key' => 'loopback-0001']); check(false, 'no throw'); }
        catch (PaymentRequiredError $e) {
            check($e->code() === 'subscription_required' && $e->requestId === 'req_402', '402 parsed');
            check($e->body['echo'] === ['auth' => 'Bearer tp_live_local', 'key' => 'loopback-0001', 'text' => 'hello', 'audio' => 'RIFF'], 'server saw multipart: ' . json_encode($e->body['echo']));
        }
        try { (new Client('k', "http://127.0.0.1:$port/slow", 0.3))->capabilities(); check(false, 'no timeout'); }
        catch (APIConnectionError $e) { check($e->code() === 'timeout' && $e->status === 0 && $e->retryable(), 'timeout'); }
    } finally { proc_terminate($proc); proc_close($proc); @unlink($router); }
    try { (new Client('k', "http://127.0.0.1:$port", 2))->capabilities(); check(false, 'no refusal'); }
    catch (APIConnectionError $e) { check($e->code() === 'network_error' && $e->retryable(), 'refused'); }
});

printf("%d tests, %d assertions, %d failures\n", $tests, $assertions, count($failures));
foreach ($failures as $f) echo "FAIL $f\n";
exit($failures ? 1 : 0);

<?php
/**
 * TonePerfect pronunciation assessment API client (PHP 8.0+, ext-curl + ext-json, no dependencies).
 *
 * Wraps the two public endpoints of https://api.toneperfect.app:
 *   GET  /v1/capabilities   -> languages served, limits, model version (no key needed)
 *   POST /v1/assess         -> score one scripted recording
 *
 * Accounts, API keys and billing are managed in the web dashboard
 * (https://api.toneperfect.app/dashboard); those routes are deliberately not wrapped.
 * Full reference: https://api.toneperfect.app/docs
 *
 *   $client = new \TonePerfect\Client('tp_live_...');
 *   $result = $client->assess('hello.wav', ['text' => '你好', 'language' => 'zh-CN']);
 *   var_dump($result->assessable(), $result->overall(), $result->billing());
 */
declare(strict_types=1);

namespace TonePerfect;

const VERSION = '0.1.0';
const DEFAULT_BASE_URL = 'https://api.toneperfect.app';
const TASKS = ['general', 'connected_speech', 'isolated_word'];
/** Values of `decision` on words and phones; treat unknown values as "no decision". */
const DECISIONS = ['review', 'uncertain', 'no_correction', 'unassessable', 'partial', 'legacy_correction'];
/** Error codes after which the SAME Idempotency-Key must be retried: nothing was finalized. */
const RETRY_SAME_KEY_CODES = ['rate_limit', 'account_busy', 'gateway_busy', 'decoder_busy', 'audio_decoder_unavailable',
    'upload_timeout', 'request_pending', 'timeout', 'network_error'];
/** Error codes that mean the key is spent: start a new attempt with a new key. */
const NEW_KEY_CODES = ['idempotency_expired', 'idempotency_conflict'];
/** Error codes a retry cannot fix soon. free_capacity (429): free credits reached today's shared limit;
 *  it clears at the next UTC day, or immediately with a paid plan. */
const NOT_RETRYABLE_CODES = ['free_capacity'];
const IDEMPOTENCY_RE = '/^[A-Za-z0-9_.:-]{8,128}$/';

/**
 * A fresh Idempotency-Key for one recording attempt. Keep the same key while the result is unknown or
 * pending (retryable()); use a new key for a different attempt or after a definite failed response
 * (needsNewKey()). Never generate one inside an automatic retry loop.
 */
function new_idempotency_key(string $prefix = 'tp'): string
{
    $key = $prefix . '-' . bin2hex(random_bytes(16)) . '-' . bin2hex(random_bytes(2));
    if (!preg_match(IDEMPOTENCY_RE, $key)) {
        throw new \InvalidArgumentException('prefix must be letters, digits, dots, dashes, underscores or colons');
    }
    return $key;
}

/**
 * Any non-2xx response, or a transport failure (status 0). What to do next is decided by the BODY:
 * finalized() — stored under this Idempotency-Key, the same key replays it for 24 h (needsNewKey());
 * retryable() — nothing was finalized, retry later with the SAME key; anything else needs a fix.
 */
class TonePerfectException extends \RuntimeException
{
    public int $status;
    public string $errorCode;
    public string $detail;
    public ?string $requestId;
    public ?float $retryAfter;
    /** @var array<string,mixed> */
    public array $body;
    /** `req_…` result id when the failure was finalized under your Idempotency-Key. */
    public ?string $id;
    /** @var array<string,mixed>|null */
    public ?array $billing;

    /** @param array<string,mixed>|null $body */
    public function __construct(int $status, string $code, string $message, ?string $requestId = null, ?float $retryAfter = null, ?array $body = null)
    {
        parent::__construct("{$status} {$code}: {$message}", $status);
        $this->status = $status;
        $this->errorCode = $code;
        $this->detail = $message;
        $this->requestId = $requestId;
        $this->retryAfter = $retryAfter;
        $this->body = $body ?? [];
        $this->id = isset($this->body['id']) && is_string($this->body['id']) ? $this->body['id'] : null;
        $this->billing = isset($this->body['billing']) && is_array($this->body['billing']) ? $this->body['billing'] : null;
    }

    /** API error code (invalid_api_key, subscription_required, insufficient_credits, rate_limit, …). */
    public function code(): string { return $this->errorCode; }

    public function finalized(): bool { return $this->id !== null && $this->billing !== null; }

    public function needsNewKey(): bool { return $this->finalized() || in_array($this->errorCode, NEW_KEY_CODES, true); }

    public function retryable(): bool
    {
        if ($this->finalized() || in_array($this->errorCode, NEW_KEY_CODES, true) || in_array($this->errorCode, NOT_RETRYABLE_CODES, true)) {
            return false;
        }
        return in_array($this->errorCode, RETRY_SAME_KEY_CODES, true) || in_array($this->status, [408, 429, 502, 503, 504], true);
    }

    public static function classFor(int $status): string
    {
        if ($status === 0) return APIConnectionError::class;
        if ($status === 401) return AuthenticationError::class;
        if ($status === 402) return PaymentRequiredError::class;
        if ($status === 429) return RateLimitError::class;
        if ($status >= 500) return ServerError::class;
        if ($status >= 400) return ValidationError::class;
        return self::class;
    }
}

/** 401 — missing, revoked or unknown API key. */
class AuthenticationError extends TonePerfectException {}
/** 402 — nothing charged: subscription_required (50 free credits used, no plan), insufficient_credits, payment_balance_due. */
class PaymentRequiredError extends TonePerfectException {}
/** 429 — rate_limit (60/min) or account_busy (2 running): retry with the SAME key. free_capacity: not retryable until the next UTC day. */
class RateLimitError extends TonePerfectException {}
/** Other 4xx — the request needs a fix. */
class ValidationError extends TonePerfectException {}
/** 5xx. Check retryable() / needsNewKey(). */
class ServerError extends TonePerfectException {}
/** Transport failure (status 0): timeout or network_error. Outcome unknown: retry with the same key. */
class APIConnectionError extends TonePerfectException {}

/** One POST /v1/assess result; `data` is the full JSON body exactly as returned. */
class Assessment
{
    /** @param array<string,mixed> $data @param array<string,string> $headers lower-cased */
    public function __construct(public array $data, public int $status, public array $headers)
    {
    }

    public function requestId(): ?string { return $this->headers['x-request-id'] ?? null; }

    /** True when the result was replayed from a previous identical request (not charged again). */
    public function replayed(): bool { return strtolower($this->headers['idempotent-replayed'] ?? '') === 'true'; }

    /** False when the audio could not be meaningfully scored; never show that as a zero score. */
    public function assessable(): bool { return (bool) ($this->data['assessable'] ?? false); }

    public function reason(): ?string { return $this->data['reason'] ?? null; }

    /** @return array<string,float|int|null> 0-100 grades; null = dimension not supported by this pack. */
    public function scores(): array { return $this->data['scores'] ?? []; }

    public function overall(): float|int|null { return $this->scores()['overall'] ?? null; }

    /** @return list<array<string,mixed>> */
    public function words(): array { return $this->data['words'] ?? []; }

    /** @return array<string,mixed> {credits, balance_credits}; failed or unassessable requests charge 0. */
    public function billing(): array { return $this->data['billing'] ?? []; }

    public function modelVersion(): ?string { return $this->data['model_version'] ?? null; }

    public function id(): ?string { return $this->data['id'] ?? $this->requestId(); }
}

class Client
{
    public string $apiKey;
    public string $baseUrl;
    public float $timeout;
    public string $userAgent;
    /** @var callable(string,string,array<string,string>,?string):array{0:int,1:array<string,string>,2:string} */
    private $transport;

    /**
     * @param string|null $apiKey  secret key (tp_live_...); defaults to getenv('TONEPERFECT_API_KEY').
     * @param string $baseUrl      API origin (behind a proxy with a 26 s request timeout).
     * @param callable|null $transport fn(method, url, headers, body) => [status, lower-cased headers, body]; for tests/proxies.
     */
    public function __construct(?string $apiKey = null, string $baseUrl = DEFAULT_BASE_URL, float $timeout = 90.0, ?string $userAgent = null, ?callable $transport = null)
    {
        $this->apiKey = $apiKey ?? (getenv('TONEPERFECT_API_KEY') ?: '');
        $this->baseUrl = rtrim($baseUrl, '/');
        $this->timeout = $timeout;
        $this->userAgent = $userAgent ?? 'toneperfect-php/' . VERSION;
        $this->transport = $transport ?? [$this, 'curlTransport'];
    }

    /** GET /v1/capabilities (no key needed). @return array<string,mixed> */
    public function capabilities(): array
    {
        [$status, $headers, $body] = $this->send('GET', '/v1/capabilities', [], null);
        return self::parseJson($status, $headers, $body);
    }

    /**
     * POST /v1/assess — score one scripted recording (up to 30 s / 10 MB).
     *
     * @param string|resource $audio a file path, or a stream resource opened in binary mode
     *        (raw bytes: use assessBytes()).
     * @param array{text?:string,language?:string,pinyin?:string,task?:string,idempotency_key?:string,filename?:string,content_type?:string} $fields
     *        text (required unless pinyin), language (default zh-CN), pinyin ("ni3 hao3"), task (general |
     *        connected_speech | isolated_word), idempotency_key (generated when omitted; reuse it to retry an
     *        unknown outcome), filename, content_type.
     */
    public function assess($audio, array $fields = []): Assessment
    {
        return $this->assessBytes(self::readAudio($audio), $fields);
    }

    /** POST /v1/assess with the recording given as a binary string. @param array<string,string> $fields see assess() */
    public function assessBytes(string $data, array $fields = []): Assessment
    {
        if ($this->apiKey === '') {
            throw new AuthenticationError(401, 'invalid_api_key', 'Set the API key or the TONEPERFECT_API_KEY environment variable.');
        }
        $task = $fields['task'] ?? 'general';
        if (!in_array($task, TASKS, true)) {
            throw new \InvalidArgumentException('task must be one of ' . implode(', ', TASKS));
        }
        $text = $fields['text'] ?? '';
        $pinyin = $fields['pinyin'] ?? '';
        if ($text === '' && $pinyin === '') {
            throw new \InvalidArgumentException('Provide text (or pinyin for Mandarin).');
        }
        $key = $fields['idempotency_key'] ?? new_idempotency_key();
        if (!preg_match(IDEMPOTENCY_RE, $key)) {
            throw new \InvalidArgumentException('idempotency_key must be 8-128 letters, digits, dots, dashes, underscores or colons');
        }
        $form = ['language' => $fields['language'] ?? 'zh-CN', 'task' => $task];
        if ($text !== '') $form['text'] = $text;
        if ($pinyin !== '') $form['pinyin'] = $pinyin;
        $boundary = '----toneperfect' . bin2hex(random_bytes(16));
        $body = '';
        foreach ($form as $name => $value) {
            $body .= "--{$boundary}\r\nContent-Disposition: form-data; name=\"{$name}\"\r\n\r\n{$value}\r\n";
        }
        $filename = str_replace(['"', "\r", "\n"], ['_', '', ''], $fields['filename'] ?? 'recording.wav');
        $ctype = $fields['content_type'] ?? 'application/octet-stream';
        $body .= "--{$boundary}\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"{$filename}\"\r\nContent-Type: {$ctype}\r\n\r\n{$data}\r\n--{$boundary}--\r\n";

        [$status, $headers, $raw] = $this->send('POST', '/v1/assess', [
            'Authorization' => 'Bearer ' . $this->apiKey,
            'Idempotency-Key' => $key,
            'Content-Type' => "multipart/form-data; boundary={$boundary}",
        ], $body);
        return new Assessment(self::parseJson($status, $headers, $raw), $status, $headers);
    }

    /** @param array<string,string> $headers @return array{0:int,1:array<string,string>,2:string} */
    private function send(string $method, string $path, array $headers, ?string $body): array
    {
        $all = ['Accept' => 'application/json', 'User-Agent' => $this->userAgent] + $headers;
        [$status, $respHeaders, $respBody] = ($this->transport)($method, $this->baseUrl . $path, $all, $body);
        return [(int) $status, array_change_key_case($respHeaders, CASE_LOWER), (string) $respBody];
    }

    /** @param array<string,string> $headers @return array{0:int,1:array<string,string>,2:string} */
    public function curlTransport(string $method, string $url, array $headers, ?string $body): array
    {
        $respHeaders = [];
        $ch = curl_init($url);
        $lines = [];
        foreach ($headers as $k => $v) $lines[] = "{$k}: {$v}";
        curl_setopt_array($ch, [
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER => $lines,
            CURLOPT_TIMEOUT_MS => (int) ($this->timeout * 1000),
            CURLOPT_CONNECTTIMEOUT_MS => (int) ($this->timeout * 1000),
            CURLOPT_HEADERFUNCTION => function ($ch, string $line) use (&$respHeaders): int {
                $parts = explode(':', $line, 2);
                if (count($parts) === 2) $respHeaders[strtolower(trim($parts[0]))] = trim($parts[1]);
                return strlen($line);
            },
        ]);
        if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
        $resp = curl_exec($ch);
        if ($resp === false) {
            $errno = curl_errno($ch);
            $err = curl_error($ch);
            if ($errno === CURLE_OPERATION_TIMEDOUT) {
                throw new APIConnectionError(0, 'timeout', "No response within {$this->timeout}s; the outcome is unknown, retry with the same Idempotency-Key.");
            }
            throw new APIConnectionError(0, 'network_error', "Could not reach {$this->baseUrl}: {$err}");
        }
        return [(int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE), $respHeaders, (string) $resp];
    }

    /** @param array<string,string> $headers @return array<string,mixed> */
    private static function parseJson(int $status, array $headers, string $raw): array
    {
        $data = $raw === '' ? [] : json_decode($raw, true);
        if ($status >= 200 && $status < 300 && is_array($data)) {
            return $data;
        }
        $retryAfter = isset($headers['retry-after']) && is_numeric($headers['retry-after']) ? (float) $headers['retry-after'] : null;
        $class = TonePerfectException::classFor($status);
        if (is_array($data) && isset($data['error']) && is_array($data['error'])) {
            throw new $class($status, (string) ($data['error']['code'] ?? 'request_error'), (string) ($data['error']['message'] ?? ''),
                $data['request_id'] ?? ($headers['x-request-id'] ?? null), $retryAfter, $data);
        }
        $snippet = trim(function_exists('mb_strcut') ? mb_strcut($raw, 0, 200, 'UTF-8') : substr($raw, 0, 200));
        throw new $class($status, 'http_error', $snippet !== '' ? $snippet : "HTTP {$status}", $headers['x-request-id'] ?? null, $retryAfter);
    }

    /** @param string|resource $audio */
    private static function readAudio($audio): string
    {
        if (is_resource($audio)) {
            $data = stream_get_contents($audio);
            if ($data === false) throw new \InvalidArgumentException('Could not read the audio stream.');
            return $data;
        }
        if (is_string($audio) && is_file($audio)) {
            return (string) file_get_contents($audio);
        }
        throw new \InvalidArgumentException('audio must be a readable file path or a stream; use assessBytes() for raw bytes.');
    }
}

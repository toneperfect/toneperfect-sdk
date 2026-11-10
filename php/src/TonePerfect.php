<?php
/**
 * TonePerfect pronunciation assessment API client (PHP 8.0+, ext-curl, no dependencies).
 *
 * Wraps the public endpoints of https://api.toneperfect.app:
 *   GET  /v1/capabilities   languages served, limits, model version (no key)
 *   POST /v1/assess         score one scripted recording
 *   POST /v1/lint           check a reference text before recording (free, no key)
 *   GET  /v1/status         synthetic engine probe summary (free, no key)
 *
 * Accounts, API keys and billing are managed in the web dashboard; those routes are session-based and
 * deliberately not wrapped. Reference: https://api.toneperfect.app/docs
 *
 *   $client = new TonePerfect\Client();      // reads TONEPERFECT_API_KEY
 *   $result = $client->assess('hello.ogg', text: '你好', language: 'zh-CN');
 *   echo $result->overall(), ' ', $result->billing()->credits;
 */
declare(strict_types=1);

namespace TonePerfect;

const VERSION = '0.3.0';
const DEFAULT_BASE_URL = 'https://api.toneperfect.app';
/** Where a 402 is fixed. A 402 from the API may carry its own billing_url. */
const BILLING_URL = 'https://api.toneperfect.app/dashboard?tab=billing';
const TASKS = ['general', 'connected_speech', 'isolated_word'];
/** Outcomes a tp_test_ key can rehearse (testOutcome: on Client::assess). */
const TEST_OUTCOMES = ['success', 'unassessable', 'invalid_assessment', 'engine_unavailable', 'subscription_required',
    'subscription_past_due', 'insufficient_credits', 'account_busy', 'rate_limit'];
/** review / uncertain / no_correction are the feedback decisions; unassessable, partial, legacy_correction also occur. */
const DECISIONS = ['review', 'uncertain', 'no_correction', 'unassessable', 'partial', 'legacy_correction'];
/** Error codes after which the SAME Idempotency-Key is retried: nothing was stored under it. */
const RETRY_SAME_KEY_CODES = ['rate_limit', 'account_busy', 'uploads_in_progress', 'gateway_busy', 'decoder_busy', 'audio_decoder_unavailable',
    'upload_timeout', 'request_pending', 'request_interrupted', 'engine_unavailable', 'result_held', 'timeout', 'network_error'];
/** Error codes that mean the key is spent: start a new attempt with a new key. */
const NEW_KEY_CODES = ['idempotency_expired', 'idempotency_conflict'];
/** free_capacity (429): free credits reached today's shared limit; clears at the next UTC day or with a plan. */
const NOT_RETRYABLE_CODES = ['free_capacity'];
const CONTENT_TYPES = ['wav' => 'audio/wav', 'mp3' => 'audio/mpeg', 'm4a' => 'audio/mp4', 'mp4' => 'audio/mp4', 'aac' => 'audio/aac',
    'ogg' => 'audio/ogg', 'oga' => 'audio/ogg', 'opus' => 'audio/ogg', 'webm' => 'audio/webm', 'flac' => 'audio/flac'];

/** A fresh Idempotency-Key (a UUID) for one recording attempt. assess() makes one per call and reuses it for its retries. */
function new_idempotency_key(): string
{
    $b = random_bytes(16);
    $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
    $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
    return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($b), 4));
}

/**
 * Base class of every error: each non-2xx response and each transport failure (status 0).
 * code() and detail come from the API's error object; branch on code().
 *  - retryable(): nothing was stored under the key; the client already retried with the SAME key.
 *  - needsNewKey(): the failure is stored under the key (finalized(): a 4xx with a req_… id and billing,
 *    such as invalid_assessment) or the key expired or conflicts.
 *  - otherwise: fix the request (invalid_api_key, invalid_audio, unsupported_language, …).
 */
class TonePerfectException extends \RuntimeException
{
    public int $status;
    public string $errorCode;
    /** The API's message, written for people. */
    public string $detail;
    public ?string $requestId;
    public ?float $retryAfter;
    public array $body;
    public ?string $idempotencyKey;
    /** req_… result id when the failure is stored under the key. */
    public ?string $id;
    public ?array $billing;
    /** 402: where to start, renew or fix a plan (the API's link, else the dashboard billing tab). */
    public ?string $billingUrl;
    /** 402: the plans page and the least expensive plan on sale, when the API sends them. */
    public ?string $pricingUrl;
    public ?array $plan;

    public function __construct(int $status, string $code, string $message, ?string $requestId = null, ?float $retryAfter = null, ?array $body = null, ?string $idempotencyKey = null)
    {
        $this->status = $status;
        $this->errorCode = $code;
        $this->detail = $message;
        $this->requestId = $requestId;
        $this->retryAfter = $retryAfter;
        $this->body = $body ?? [];
        $this->idempotencyKey = $idempotencyKey;
        $this->id = is_string($this->body['id'] ?? null) ? $this->body['id'] : null;
        $this->billing = is_array($this->body['billing'] ?? null) ? $this->body['billing'] : null;
        $error = is_array($this->body['error'] ?? null) ? $this->body['error'] : [];
        $this->billingUrl = $error['billing_url'] ?? ($status === 402 ? BILLING_URL : null);
        $this->pricingUrl = $error['pricing_url'] ?? null;
        $this->plan = is_array($error['plan'] ?? null) ? $error['plan'] : null;
        $text = "$status $code: $message";
        if ($this->billingUrl !== null && !str_contains($message, $this->billingUrl)) {
            $text .= " ({$this->billingUrl})";
        }
        parent::__construct($text, $status);
    }

    /** The API's machine-readable error code. */
    public function code(): string { return $this->errorCode; }
    /** A stored result for this key: a 4xx with id and billing. A 5xx is never stored. */
    public function finalized(): bool { return $this->id !== null && $this->billing !== null && $this->status < 500; }
    /** Start a new attempt with a new Idempotency-Key; the old key replays this response. */
    public function needsNewKey(): bool { return $this->finalized() || in_array($this->errorCode, NEW_KEY_CODES, true); }
    /** Retry later with the SAME Idempotency-Key: nothing was stored under it. */
    public function retryable(): bool
    {
        if ($this->finalized() || in_array($this->errorCode, NEW_KEY_CODES, true) || in_array($this->errorCode, NOT_RETRYABLE_CODES, true)) {
            return false;
        }
        return in_array($this->errorCode, RETRY_SAME_KEY_CODES, true) || in_array($this->status, [0, 408, 429, 502, 503, 504], true);
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

/** 401: missing, unknown or revoked key. Send Authorization: Bearer KEY. */
class AuthenticationError extends TonePerfectException {}
/** 402: nothing charged. subscription_required, subscription_past_due, insufficient_credits or payment_balance_due; see $billingUrl. */
class PaymentRequiredError extends TonePerfectException {}
/** 429: rate_limit, account_busy, uploads_in_progress (retried) or free_capacity (not retried). */
class RateLimitError extends TonePerfectException {}
/** Any other 4xx: the request needs a fix. needsNewKey() tells whether to change the key. */
class ValidationError extends TonePerfectException {}
/** 5xx: never stored, never charged; retried with the same key. */
class ServerError extends TonePerfectException {}
/** Transport failure (status 0): timeout or network_error. The outcome is unknown; retried with the same key. */
class APIConnectionError extends TonePerfectException {}

/** One scored unit under a word: a phoneme, or a Mandarin initial, final or tone. $data is the raw JSON. */
class Phone
{
    public ?string $dimension;
    /** @var string|int|null */
    public $expected;
    /** @var string|int|null */
    public $heard;
    public ?float $score;
    public ?string $decision;

    public function __construct(public array $data)
    {
        $this->dimension = $data['dimension'] ?? null;
        $this->expected = $data['expected'] ?? null;
        $this->heard = $data['heard'] ?? null;
        $this->score = isset($data['score']) ? (float) $data['score'] : null;
        $this->decision = $data['decision'] ?? null;
    }
}

/** One word (one character in Mandarin). Full and compact responses map to the same properties. */
class Word
{
    public ?string $word;
    public ?float $score;
    public ?float $startMs;
    public ?float $endMs;
    public ?string $decision;
    public ?string $pinyin;
    /** @var Phone[] */
    public array $phones;

    public function __construct(public array $data)
    {
        $this->word = $data['word'] ?? $data['text'] ?? null;
        $this->score = isset($data['score']) ? (float) $data['score'] : null;
        $this->startMs = isset($data['start_ms']) ? (float) $data['start_ms'] : null;
        $this->endMs = isset($data['end_ms']) ? (float) $data['end_ms'] : null;
        $this->decision = $data['decision'] ?? null;
        $this->pinyin = $data['pinyin'] ?? null;
        $units = is_array($data['phones'] ?? null) ? $data['phones'] : (is_array($data['units'] ?? null) ? $data['units'] : []);
        $this->phones = array_values(array_map(fn ($p) => new Phone($p), array_filter($units, 'is_array')));
    }
}

/** What the request cost: credits, balanceCredits, freeCredits, source (free, plan or test). */
class Billing
{
    public int $credits;
    public ?int $balanceCredits;
    public ?int $freeCredits;
    public ?string $source;

    public function __construct(public array $data)
    {
        $this->credits = (int) ($data['credits'] ?? 0);
        $this->balanceCredits = isset($data['balance_credits']) ? (int) $data['balance_credits'] : null;
        $this->freeCredits = isset($data['free_credits']) ? (int) $data['free_credits'] : null;
        $this->source = $data['source'] ?? null;
    }
}

/** One POST /v1/assess result. $data is the JSON body as returned (full or compact schema). */
class Assessment
{
    public function __construct(public array $data, public int $status, public array $headers, public string $idempotencyKey)
    {
        if (isset($headers['idempotency-key'])) {
            $this->idempotencyKey = $headers['idempotency-key'];
        }
    }

    public function requestId(): ?string { return $this->headers['x-request-id'] ?? null; }
    public function replayed(): bool { return strtolower($this->headers['idempotent-replayed'] ?? '') === 'true'; }
    public function id(): ?string { return $this->data['id'] ?? $this->requestId(); }
    /** false when the recording could not be scored (see reason()). Free, and never a score of zero. */
    public function assessable(): bool { return ($this->data['assessable'] ?? false) === true; }
    public function reason(): ?string { return $this->data['reason'] ?? null; }
    /** 0–100 display grades per dimension; null = not measured by this pack. */
    public function scores(): array { return $this->data['scores'] ?? []; }
    public function overall(): ?float { $v = $this->scores()['overall'] ?? null; return $v === null ? null : (float) $v; }
    /** @return Word[] */
    public function words(): array { return array_values(array_map(fn ($w) => new Word($w), array_filter($this->data['words'] ?? [], 'is_array'))); }
    /** @return string[] */
    public function warnings(): array { return array_values(array_filter($this->data['warnings'] ?? [], 'is_string')); }
    public function billing(): Billing { return new Billing($this->data['billing'] ?? []); }
    public function modelVersion(): ?string { return $this->data['model_version'] ?? null; }
    /** "primary" or "fallback". */
    public function engine(): ?string { return $this->data['engine_route']['engine'] ?? ($this->headers['x-toneperfect-engine'] ?? null); }
    /** true for a fixed example response from a tp_test_ key. */
    public function test(): bool { return ($this->data['test'] ?? false) === true; }
    public function compact(): bool { return ($this->data['schema'] ?? null) === 'toneperfect.compact.v1'; }
}

class Client
{
    public string $apiKey;
    public string $baseUrl;
    public float $timeout;
    public int $maxRetries;
    public array $headers;
    public string $userAgent;
    /** @var callable */
    private $transport;

    /**
     * @param string|null $apiKey  tp_live_… or a tp_test_… test key (default: TONEPERFECT_API_KEY)
     * @param string|null $baseUrl default: TONEPERFECT_BASE_URL, else https://api.toneperfect.app (a proxy with a 26 s limit:
     *                             a longer assessment comes back on the automatic retry, charged once)
     * @param float $timeout       seconds per request
     * @param int $maxRetries      automatic retries of a retryable failure, with the same Idempotency-Key
     * @param array $headers       extra headers for every request, e.g. ['TonePerfect-Fallback' => 'off']
     */
    public function __construct(?string $apiKey = null, ?string $baseUrl = null, float $timeout = 60.0, int $maxRetries = 2,
                                array $headers = [], ?string $userAgent = null, ?callable $transport = null)
    {
        $this->apiKey = $apiKey ?? (getenv('TONEPERFECT_API_KEY') ?: '');
        $this->baseUrl = rtrim($baseUrl ?? (getenv('TONEPERFECT_BASE_URL') ?: DEFAULT_BASE_URL), '/');
        $this->timeout = $timeout;
        $this->maxRetries = max(0, $maxRetries);
        $this->headers = $headers;
        $this->userAgent = $userAgent ?? 'toneperfect-php/' . VERSION;
        $this->transport = $transport ?? [$this, 'curlTransport'];
    }

    /** GET /v1/capabilities (no key): languages, limits, model_version. */
    public function capabilities(): array { return $this->call('GET', '/v1/capabilities', [], null)[0]; }

    /** GET /v1/status (no key): the synthetic engine probe. */
    public function status(): array { return $this->call('GET', '/v1/status', [], null)[0]; }

    /** POST /v1/lint (free, no key): ['ok', 'language', 'issues', 'units']. */
    public function lint(string $text, string $language, string $pinyin = '', string $task = 'general'): array
    {
        if (trim($language) === '') throw new \InvalidArgumentException('language is required, for example "en-US" or "zh-CN"');
        $body = json_encode(['text' => $text, 'language' => $language, 'pinyin' => $pinyin, 'task' => $task], JSON_UNESCAPED_UNICODE);
        return $this->call('POST', '/v1/lint', ['Content-Type' => 'application/json'], $body)[0];
    }

    /**
     * POST /v1/assess: score one scripted recording (WAV, MP3, M4A, Ogg or WebM, 0.15–120 s, up to 10 MB).
     * $audio is a file path or a stream resource; use assessBytes() for audio already in memory.
     * Throws a TonePerfectException subclass.
     * @param string|resource $audio
     */
    public function assess($audio, string $language, ?string $text = null, ?string $pinyin = null, string $task = 'general',
                           ?string $idempotencyKey = null, ?string $filename = null, ?string $contentType = null,
                           bool $compact = false, ?string $testOutcome = null): Assessment
    {
        if (is_resource($audio)) {
            $data = stream_get_contents($audio);
            $meta = stream_get_meta_data($audio);
            $filename ??= isset($meta['uri']) ? basename((string) $meta['uri']) : null;
        } elseif (is_string($audio)) {
            $data = @file_get_contents($audio);
            if ($data === false) throw new \InvalidArgumentException("Cannot read $audio");
            $filename ??= basename($audio);
        } else {
            throw new \InvalidArgumentException('audio must be a file path or a stream resource');
        }
        return $this->assessBytes((string) $data, $language, $text, $pinyin, $task, $idempotencyKey, $filename, $contentType, $compact, $testOutcome);
    }

    /** POST /v1/assess with the recording's bytes. */
    public function assessBytes(string $data, string $language, ?string $text = null, ?string $pinyin = null, string $task = 'general',
                                ?string $idempotencyKey = null, ?string $filename = null, ?string $contentType = null,
                                bool $compact = false, ?string $testOutcome = null): Assessment
    {
        if ($this->apiKey === '') throw new AuthenticationError(401, 'invalid_api_key', 'Set the API key or the TONEPERFECT_API_KEY environment variable.');
        if (trim($language) === '') throw new \InvalidArgumentException('language is required, for example "en-US" or "zh-CN"');
        if (!in_array($task, TASKS, true)) throw new \InvalidArgumentException('task must be one of ' . implode(', ', TASKS));
        if (($text ?? '') === '' && ($pinyin ?? '') === '') throw new \InvalidArgumentException('Provide text (or, for Mandarin, pinyin with tones).');
        $key = $idempotencyKey ?? new_idempotency_key();
        if (!preg_match('/\A[\x20-\x7e]{1,255}\z/', $key)) throw new \InvalidArgumentException('idempotencyKey must be 1-255 printable ASCII characters');
        $filename ??= 'recording';
        $contentType ??= CONTENT_TYPES[strtolower(pathinfo($filename, PATHINFO_EXTENSION))] ?? 'application/octet-stream';
        $fields = ['language' => $language, 'task' => $task];
        if (($text ?? '') !== '') $fields['text'] = $text;
        if (($pinyin ?? '') !== '') $fields['pinyin'] = $pinyin;
        $boundary = '----toneperfect' . bin2hex(random_bytes(16));
        $body = '';
        foreach ($fields as $name => $value) {
            $body .= "--$boundary\r\nContent-Disposition: form-data; name=\"$name\"\r\n\r\n$value\r\n";
        }
        $safe = str_replace(['"', "\r", "\n"], ['_', '', ''], $filename);
        $body .= "--$boundary\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"$safe\"\r\nContent-Type: $contentType\r\n\r\n$data\r\n--$boundary--\r\n";
        $headers = ['Authorization' => "Bearer {$this->apiKey}", 'Idempotency-Key' => $key, 'Content-Type' => "multipart/form-data; boundary=$boundary"];
        if ($compact) $headers['TonePerfect-Response'] = 'compact';
        if ($testOutcome !== null) $headers['TonePerfect-Test-Outcome'] = $testOutcome;
        [$result, $status, $responseHeaders] = $this->call('POST', '/v1/assess', $headers, $body, $key);
        return new Assessment($result, $status, $responseHeaders, $key);
    }

    private function call(string $method, string $path, array $headers, ?string $body, ?string $key = null): array
    {
        for ($attempt = 0; ; $attempt++) {
            try {
                [$status, $responseHeaders, $raw] = $this->send($method, $path, $headers, $body);
                return [self::parseJson($status, $responseHeaders, $raw, $key), $status, $responseHeaders];
            } catch (TonePerfectException $e) {
                $e->idempotencyKey ??= $key;
                if ($attempt >= $this->maxRetries || !$e->retryable()) throw $e;
                usleep((int) (self::backoff($e, $attempt) * 1e6));
            }
        }
    }

    private static function backoff(TonePerfectException $e, int $attempt): float
    {
        if ($e->retryAfter !== null) return max(0.0, min($e->retryAfter, 30.0));
        $base = $e->errorCode === 'engine_unavailable' ? 2.0 : 0.5;
        return min($base * (2 ** $attempt), 8.0) + mt_rand(0, 250) / 1000;
    }

    private function send(string $method, string $path, array $headers, ?string $body): array
    {
        $all = array_merge(['Accept' => 'application/json', 'User-Agent' => $this->userAgent], $this->headers, $headers);
        [$status, $responseHeaders, $raw] = ($this->transport)($method, $this->baseUrl . $path, $all, $body);
        return [(int) $status, array_change_key_case($responseHeaders, CASE_LOWER), (string) $raw];
    }

    /** The default transport (ext-curl). */
    public function curlTransport(string $method, string $url, array $headers, ?string $body): array
    {
        $ch = curl_init($url);
        $respHeaders = [];
        $lines = [];
        foreach ($headers as $k => $v) $lines[] = "$k: $v";
        curl_setopt_array($ch, [
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_HTTPHEADER => $lines,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT_MS => (int) ($this->timeout * 1000),
            CURLOPT_CONNECTTIMEOUT_MS => (int) ($this->timeout * 1000),
            CURLOPT_HEADERFUNCTION => function ($ch, string $line) use (&$respHeaders): int {
                $parts = explode(':', $line, 2);
                if (count($parts) === 2) $respHeaders[strtolower(trim($parts[0]))] = trim($parts[1]);
                return strlen($line);
            },
        ]);
        if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
        $raw = curl_exec($ch);
        if ($raw === false) {
            $errno = curl_errno($ch);
            $error = curl_error($ch);
            if ($errno === CURLE_OPERATION_TIMEDOUT) {
                throw new APIConnectionError(0, 'timeout', "No response within {$this->timeout}s; the outcome is unknown, retry with the same Idempotency-Key.");
            }
            throw new APIConnectionError(0, 'network_error', "Could not reach {$this->baseUrl}: $error");
        }
        $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        return [$status, $respHeaders, $raw];
    }

    private static function parseJson(int $status, array $headers, string $raw, ?string $key): array
    {
        $data = $raw === '' ? [] : json_decode($raw, true);
        if ($status >= 200 && $status < 300 && is_array($data)) return $data;
        $retryAfter = isset($headers['retry-after']) && is_numeric($headers['retry-after']) ? (float) $headers['retry-after'] : null;
        $class = TonePerfectException::classFor($status);
        $rid = $headers['x-request-id'] ?? null;
        if (is_array($data) && is_array($data['error'] ?? null)) {
            throw new $class($status, (string) ($data['error']['code'] ?? 'request_error'), (string) ($data['error']['message'] ?? ''), $data['request_id'] ?? $rid, $retryAfter, $data, $key);
        }
        if (is_array($data) && is_string($data['detail'] ?? null)) { // framework errors (405 on a trailing slash)
            throw new $class($status, 'http_error', $data['detail'], $rid, $retryAfter, $data, $key);
        }
        $snippet = trim(substr($raw, 0, 200));
        throw new $class($status, 'http_error', $snippet === '' ? "HTTP $status" : $snippet, $rid, $retryAfter, null, $key);
    }
}

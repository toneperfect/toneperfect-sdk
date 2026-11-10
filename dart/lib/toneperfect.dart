/// Client for the TonePerfect pronunciation assessment API
/// (https://api.toneperfect.app).
///
/// Wraps the public endpoints:
///
/// * `GET  /v1/capabilities` languages served, limits, model version (no key)
/// * `POST /v1/assess`       score one scripted recording against its reference text
/// * `POST /v1/lint`         check a reference text before recording (free, no key)
/// * `GET  /v1/status`       synthetic engine probe summary (free, no key)
///
/// Accounts, API keys and billing live in the web dashboard and are not wrapped.
/// Keep the API key on your server: mobile and browser apps should call your
/// own backend, which calls this API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import 'src/env_stub.dart' if (dart.library.io) 'src/env_io.dart';

/// Package version, sent in the User-Agent header.
const String toneperfectVersion = '0.3.0';

/// Production API origin. Requests pass a proxy with a 26-second limit.
const String defaultBaseUrl = 'https://api.toneperfect.app';

/// Where a 402 is fixed. A 402 from the API may carry its own `billing_url`.
const String defaultBillingUrl = 'https://api.toneperfect.app/dashboard?tab=billing';

/// Accepted values of the `task` field.
const List<String> tasks = ['general', 'connected_speech', 'isolated_word'];

/// Outcomes a `tp_test_` key can rehearse ([TonePerfect.assess] `testOutcome`).
const List<String> testOutcomes = [
  'success', 'unassessable', 'invalid_assessment', 'engine_unavailable', 'subscription_required', //
  'subscription_past_due', 'insufficient_credits', 'account_busy', 'rate_limit',
];

/// Error codes after which the SAME Idempotency-Key is retried: nothing was stored under it.
const Set<String> retrySameKeyCodes = {
  'rate_limit', 'account_busy', 'uploads_in_progress', 'gateway_busy', 'decoder_busy', //
  'audio_decoder_unavailable', 'upload_timeout', 'request_pending', 'request_interrupted', //
  'engine_unavailable', 'result_held', 'timeout', 'network_error',
};

/// Error codes that mean the key is spent: start a new attempt with a new key.
const Set<String> newKeyCodes = {'idempotency_expired', 'idempotency_conflict'};

/// `free_capacity` (429): free credits reached today's shared limit; clears at the next UTC day or with a plan.
const Set<String> notRetryableCodes = {'free_capacity'};

const Map<String, String> _contentTypes = {
  'wav': 'audio/wav', 'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'mp4': 'audio/mp4', 'aac': 'audio/aac', //
  'ogg': 'audio/ogg', 'oga': 'audio/ogg', 'opus': 'audio/ogg', 'webm': 'audio/webm', 'flac': 'audio/flac',
};

final Random _random = Random.secure();

/// A fresh Idempotency-Key (a UUID) for one recording attempt. [TonePerfect.assess] makes one per call
/// and reuses it for its own retries; pass your own to resend the same recording safely across restarts.
String newIdempotencyKey() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Base class of every error: each non-2xx response and each transport failure (status 0).
/// [code] and [message] come from the API's `error` object; branch on [code].
///
/// * [retryable]: nothing was stored under the key; the client already retried with the SAME key.
/// * [needsNewKey]: the failure is stored under the key ([finalized]: a 4xx with a `req_…` id and
///   billing, such as `invalid_assessment`) or the key expired or conflicts.
/// * otherwise: fix the request (`invalid_api_key`, `invalid_audio`, `unsupported_language`, …).
class TonePerfectError implements Exception {
  TonePerfectError(this.status, this.code, this.message,
      {this.requestId, this.retryAfter, Map<String, dynamic>? body, this.idempotencyKey})
      : body = body ?? const {};

  /// HTTP status, or 0 for a transport failure (code `timeout` / `network_error`).
  final int status;
  final String code;

  /// The API's message, written for people.
  final String message;
  final String? requestId;

  /// Seconds from the `Retry-After` header, when present.
  final double? retryAfter;

  /// The error body as returned by the API.
  final Map<String, dynamic> body;

  /// The Idempotency-Key of the attempt (assess only).
  String? idempotencyKey;

  Map<String, dynamic> get _error => body['error'] is Map ? Map<String, dynamic>.from(body['error'] as Map) : const {};

  /// `req_…` result id when the failure is stored under the key.
  String? get id => body['id'] is String ? body['id'] as String : null;
  Map<String, dynamic>? get billing => body['billing'] is Map ? Map<String, dynamic>.from(body['billing'] as Map) : null;

  /// 402: where to start, renew or fix a plan (the API's link, else the dashboard billing tab).
  String? get billingUrl => _error['billing_url'] as String? ?? (status == 402 ? defaultBillingUrl : null);

  /// 402: the plans page, when the API sends it.
  String? get pricingUrl => _error['pricing_url'] as String?;

  /// 402: the least expensive plan on sale, when the API sends it.
  Map<String, dynamic>? get plan => _error['plan'] is Map ? Map<String, dynamic>.from(_error['plan'] as Map) : null;

  /// A stored result for this key: a 4xx with id and billing. A 5xx is never stored.
  bool get finalized => id != null && billing != null && status < 500;

  /// Start a new attempt with a new Idempotency-Key; the old key replays this response.
  bool get needsNewKey => finalized || newKeyCodes.contains(code);

  /// Retry later with the SAME Idempotency-Key: nothing was stored under it.
  bool get retryable {
    if (finalized || newKeyCodes.contains(code) || notRetryableCodes.contains(code)) return false;
    return retrySameKeyCodes.contains(code) || const [0, 408, 429, 502, 503, 504].contains(status);
  }

  @override
  String toString() {
    final link = billingUrl;
    return '$runtimeType($status $code: $message${link != null && !message.contains(link) ? ' ($link)' : ''})';
  }
}

/// 401: missing, unknown or revoked key. Send `Authorization: Bearer KEY`.
class AuthenticationError extends TonePerfectError {
  AuthenticationError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body, super.idempotencyKey});
}

/// 402: nothing charged. `subscription_required`, `subscription_past_due`, `insufficient_credits` or
/// `payment_balance_due`; see [billingUrl].
class PaymentRequiredError extends TonePerfectError {
  PaymentRequiredError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body, super.idempotencyKey});
}

/// 429: `rate_limit`, `account_busy`, `uploads_in_progress` (retried) or `free_capacity` (not retried).
class RateLimitError extends TonePerfectError {
  RateLimitError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body, super.idempotencyKey});
}

/// Any other 4xx: the request needs a fix. [needsNewKey] tells whether to change the key.
class ValidationError extends TonePerfectError {
  ValidationError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body, super.idempotencyKey});
}

/// 5xx: never stored, never charged; retried with the same key.
class ServerError extends TonePerfectError {
  ServerError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body, super.idempotencyKey});
}

/// Transport failure (status 0): `timeout` or `network_error`. The outcome is unknown; retried with the same key.
class APIConnectionError extends TonePerfectError {
  APIConnectionError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body, super.idempotencyKey});
}

TonePerfectError _makeError(int status, String code, String message,
    {String? requestId, double? retryAfter, Map<String, dynamic>? body, String? key}) {
  if (status == 0) return APIConnectionError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body, idempotencyKey: key);
  if (status == 401) return AuthenticationError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body, idempotencyKey: key);
  if (status == 402) return PaymentRequiredError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body, idempotencyKey: key);
  if (status == 429) return RateLimitError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body, idempotencyKey: key);
  if (status >= 500) return ServerError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body, idempotencyKey: key);
  if (status >= 400) return ValidationError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body, idempotencyKey: key);
  return TonePerfectError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body, idempotencyKey: key);
}

double? _num(Object? v) => v is num ? v.toDouble() : null;

/// One scored unit under a word: a phoneme, or a Mandarin initial, final or tone. [data] is the raw JSON.
class Phone {
  Phone(this.data);
  final Map<String, dynamic> data;

  /// `phoneme`, or `initial` / `final` / `tone` in Mandarin.
  String? get dimension => data['dimension'] as String?;

  /// A string, or a tone number.
  Object? get expected => data['expected'];
  Object? get heard => data['heard'];
  double? get score => _num(data['score']);
  String? get decision => data['decision'] as String?;
}

/// One word (one character in Mandarin). Full and compact responses map to the same getters.
class Word {
  Word(this.data);
  final Map<String, dynamic> data;
  String? get word => (data['word'] ?? data['text']) as String?;
  double? get score => _num(data['score']);
  double? get startMs => _num(data['start_ms']);
  double? get endMs => _num(data['end_ms']);
  String? get decision => data['decision'] as String?;
  String? get pinyin => data['pinyin'] as String?;
  List<Phone> get phones => ((data['phones'] ?? data['units']) as List? ?? const [])
      .whereType<Map>()
      .map((p) => Phone(Map<String, dynamic>.from(p)))
      .toList();
}

/// What the request cost: [credits], [balanceCredits], [freeCredits], [source] (`free`, `plan` or `test`).
class Billing {
  Billing(this.data);
  final Map<String, dynamic> data;
  int get credits => (data['credits'] as num?)?.toInt() ?? 0;
  int? get balanceCredits => (data['balance_credits'] as num?)?.toInt();
  int? get freeCredits => (data['free_credits'] as num?)?.toInt();
  String? get source => data['source'] as String?;
}

/// One `POST /v1/assess` result. [data] is the JSON body as returned (full or compact schema).
class Assessment {
  Assessment(this.data, this.status, this.headers, String idempotencyKey)
      : idempotencyKey = headers['idempotency-key'] ?? idempotencyKey;

  final Map<String, dynamic> data;
  final int status;
  final Map<String, String> headers;
  final String idempotencyKey;

  String? get requestId => headers['x-request-id'];
  bool get replayed => (headers['idempotent-replayed'] ?? '').toLowerCase() == 'true';
  String? get id => (data['id'] as String?) ?? requestId;

  /// false when the recording could not be scored (see [reason]). Free, and never a score of zero.
  bool get assessable => data['assessable'] == true;
  String? get reason => data['reason'] as String?;

  /// 0–100 display grades per dimension; null = not measured by this pack.
  Map<String, double?> get scores =>
      (data['scores'] as Map? ?? const {}).map((k, v) => MapEntry('$k', _num(v)));
  double? get overall => scores['overall'];
  List<Word> get words => (data['words'] as List? ?? const []).whereType<Map>().map((w) => Word(Map<String, dynamic>.from(w))).toList();
  List<String> get warnings => (data['warnings'] as List? ?? const []).whereType<String>().toList();
  Billing get billing => Billing(Map<String, dynamic>.from(data['billing'] as Map? ?? const {}));
  String? get modelVersion => data['model_version'] as String?;

  /// `primary` or `fallback`.
  String? get engine => (data['engine_route'] is Map ? (data['engine_route'] as Map)['engine'] as String? : null) ?? headers['x-toneperfect-engine'];

  /// true for a fixed example response from a `tp_test_` key.
  bool get test => data['test'] == true;
  bool get compact => data['schema'] == 'toneperfect.compact.v1';
}

/// Client for https://api.toneperfect.app.
class TonePerfect {
  /// [apiKey]: `tp_live_…` or a `tp_test_…` test key (default: the `TONEPERFECT_API_KEY` environment variable).
  /// [baseUrl]: default `TONEPERFECT_BASE_URL`, else https://api.toneperfect.app (a proxy with a 26 s limit: a longer
  /// assessment comes back on the automatic retry, charged once). [maxRetries]: automatic retries of a retryable
  /// failure, with the same Idempotency-Key. [headers]: extra headers for every request.
  TonePerfect({
    String? apiKey,
    String? baseUrl,
    this.timeout = const Duration(seconds: 60),
    this.maxRetries = 2,
    Map<String, String>? headers,
    http.Client? httpClient,
    String? userAgent,
  })  : apiKey = apiKey ?? environmentVariable('TONEPERFECT_API_KEY') ?? '',
        baseUrl = (baseUrl ?? environmentVariable('TONEPERFECT_BASE_URL') ?? defaultBaseUrl).replaceAll(RegExp(r'/+$'), ''),
        headers = {...?headers},
        _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        userAgent = userAgent ?? 'toneperfect-dart/$toneperfectVersion';

  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final int maxRetries;
  final Map<String, String> headers;
  final String userAgent;
  final http.Client _http;
  final bool _ownsClient;

  /// `GET /v1/capabilities` (no key): `languages`, `limits`, `model_version`.
  Future<Map<String, dynamic>> capabilities() async =>
      (await _call(() => http.Request('GET', Uri.parse('$baseUrl/v1/capabilities')), null)).$1;

  /// `GET /v1/status` (no key): the synthetic engine probe.
  Future<Map<String, dynamic>> status() async =>
      (await _call(() => http.Request('GET', Uri.parse('$baseUrl/v1/status')), null)).$1;

  /// `POST /v1/lint` (free, no key): `{ok, language, issues, units}`.
  Future<Map<String, dynamic>> lint(String text, {required String language, String pinyin = '', String task = 'general'}) async {
    if (language.trim().isEmpty) throw ArgumentError('language is required, for example "en-US" or "zh-CN"');
    final body = jsonEncode({'text': text, 'language': language, 'pinyin': pinyin, 'task': task});
    return (await _call(
            () => http.Request('POST', Uri.parse('$baseUrl/v1/lint'))
              ..headers['Content-Type'] = 'application/json'
              ..body = body,
            null))
        .$1;
  }

  /// `POST /v1/assess`: score one scripted recording (WAV, MP3, M4A, Ogg or WebM, 0.15–120 s, up to 10 MB).
  ///
  /// [language] is required: `zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR`
  /// or `ja-JP`. [text] is what the learner was asked to say (Mandarin may send toned [pinyin] instead).
  /// [idempotencyKey] is made for you and reused by the automatic retries. [compact] asks for the stable
  /// `toneperfect.compact.v1` schema. [testOutcome] rehearses an outcome with a `tp_test_` key.
  Future<Assessment> assess(
    List<int> audio, {
    required String language,
    String? text,
    String? pinyin,
    String task = 'general',
    String? idempotencyKey,
    String filename = 'recording',
    String? contentType,
    bool compact = false,
    String? testOutcome,
  }) async {
    if (apiKey.isEmpty) {
      throw AuthenticationError(401, 'invalid_api_key', 'Pass apiKey or set TONEPERFECT_API_KEY.');
    }
    if (language.trim().isEmpty) throw ArgumentError('language is required, for example "en-US" or "zh-CN"');
    if (!tasks.contains(task)) throw ArgumentError.value(task, 'task', 'must be one of $tasks');
    if ((text == null || text.isEmpty) && (pinyin == null || pinyin.isEmpty)) {
      throw ArgumentError('Provide text (or, for Mandarin, pinyin with tones).');
    }
    final key = idempotencyKey ?? newIdempotencyKey();
    if (!RegExp(r'^[\x20-\x7e]{1,255}$').hasMatch(key)) {
      throw ArgumentError.value(key, 'idempotencyKey', 'must be 1-255 printable ASCII characters');
    }
    final bytes = audio is Uint8List ? audio : Uint8List.fromList(audio);
    final ext = filename.contains('.') ? filename.split('.').last.toLowerCase() : '';
    final type = MediaType.parse(contentType ?? _contentTypes[ext] ?? 'application/octet-stream');
    final (data, response) = await _call(() {
      final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/v1/assess'))
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..headers['Idempotency-Key'] = key
        ..files.add(http.MultipartFile.fromBytes('audio', bytes, filename: filename, contentType: type));
      if (text != null && text.isNotEmpty) request.fields['text'] = text;
      if (pinyin != null && pinyin.isNotEmpty) request.fields['pinyin'] = pinyin;
      request.fields['language'] = language;
      request.fields['task'] = task;
      if (compact) request.headers['TonePerfect-Response'] = 'compact';
      if (testOutcome != null) request.headers['TonePerfect-Test-Outcome'] = testOutcome;
      return request;
    }, key);
    return Assessment(data, response!.statusCode, response.headers, key);
  }

  /// Closes the underlying HTTP client if this instance created it.
  void close() {
    if (_ownsClient) _http.close();
  }

  Future<(Map<String, dynamic>, http.Response?)> _call(http.BaseRequest Function() build, String? key) async {
    for (var attempt = 0;; attempt++) {
      try {
        final response = await _send(build());
        return (_parse(response, key), response);
      } on TonePerfectError catch (e) {
        e.idempotencyKey ??= key;
        if (attempt >= maxRetries || !e.retryable) rethrow;
        await Future<void>.delayed(_backoff(e, attempt));
      }
    }
  }

  static Duration _backoff(TonePerfectError e, int attempt) {
    final retryAfter = e.retryAfter;
    if (retryAfter != null) return Duration(milliseconds: (retryAfter.clamp(0, 30) * 1000).round());
    final base = e.code == 'engine_unavailable' ? 2.0 : 0.5;
    return Duration(milliseconds: ((min(base * pow(2, attempt), 8.0) + _random.nextDouble() * 0.25) * 1000).round());
  }

  Future<http.Response> _send(http.BaseRequest request) async {
    request.headers['Accept'] = 'application/json';
    request.headers['User-Agent'] = userAgent;
    headers.forEach((k, v) => request.headers.putIfAbsent(k, () => v));
    try {
      final streamed = await _http.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw APIConnectionError(0, 'timeout',
          'No response within ${timeout.inMilliseconds} ms; the outcome is unknown, retry with the same Idempotency-Key.');
    } on TonePerfectError {
      rethrow;
    } catch (error) {
      throw APIConnectionError(0, 'network_error', 'Could not reach $baseUrl: $error');
    }
  }

  static Map<String, dynamic> _parse(http.Response response, String? key) {
    final status = response.statusCode;
    final raw = utf8.decode(response.bodyBytes, allowMalformed: true);
    Object? data;
    try {
      data = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw);
    } on FormatException {
      data = null;
    }
    if (status >= 200 && status < 300 && data is Map) return Map<String, dynamic>.from(data);
    final retryAfter = double.tryParse(response.headers['retry-after'] ?? '');
    final requestId = response.headers['x-request-id'];
    if (data is Map && data['error'] is Map) {
      final error = data['error'] as Map;
      throw _makeError(status, '${error['code'] ?? 'request_error'}', '${error['message'] ?? ''}',
          requestId: (data['request_id'] as String?) ?? requestId, retryAfter: retryAfter, body: Map<String, dynamic>.from(data), key: key);
    }
    if (data is Map && data['detail'] is String) {
      throw _makeError(status, 'http_error', data['detail'] as String,
          requestId: requestId, retryAfter: retryAfter, body: Map<String, dynamic>.from(data), key: key);
    }
    final snippet = raw.length > 200 ? raw.substring(0, 200) : raw;
    throw _makeError(status, 'http_error', snippet.trim().isEmpty ? 'HTTP $status' : snippet.trim(),
        requestId: requestId, retryAfter: retryAfter, key: key);
  }
}

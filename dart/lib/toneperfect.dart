/// Client for the TonePerfect pronunciation assessment API
/// (https://api.toneperfect.app).
///
/// Wraps the two public endpoints:
///
/// * `GET  /v1/capabilities` — languages served, limits, model version (no key needed)
/// * `POST /v1/assess`       — score one scripted recording against its reference text
///
/// Accounts, API keys and billing live in the web dashboard
/// (https://api.toneperfect.app/dashboard) and are not wrapped.
/// Keep the API key on your server: mobile and browser apps should call your
/// own backend, which calls this API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Package version, sent in the User-Agent header.
const String toneperfectVersion = '0.1.0';

/// Production API origin. Requests pass a proxy with a 26-second timeout.
const String defaultBaseUrl = 'https://api.toneperfect.app';

/// Accepted values of the `task` field.
const List<String> tasks = ['general', 'connected_speech', 'isolated_word'];

/// Error codes after which the SAME Idempotency-Key must be retried: nothing was finalized.
const Set<String> retrySameKeyCodes = {
  'rate_limit', 'account_busy', 'gateway_busy', 'decoder_busy', //
  'audio_decoder_unavailable', 'upload_timeout', 'request_pending', //
  'timeout', 'network_error',
};

/// Error codes that mean the key is spent: start a new attempt with a new key.
const Set<String> newKeyCodes = {'idempotency_expired', 'idempotency_conflict'};

final RegExp _idempotencyRe = RegExp(r'^[A-Za-z0-9_.:-]{8,128}$');

/// A fresh Idempotency-Key for one recording attempt.
///
/// Keep the same key while the outcome is unknown ([TonePerfectError.retryable]);
/// use a new key for a different attempt or after a definite failure
/// ([TonePerfectError.needsNewKey]). Never generate one inside an automatic retry loop.
String newIdempotencyKey([String prefix = 'tp']) {
  final rnd = Random.secure();
  final hex = List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  final key = '$prefix-$hex';
  if (!_idempotencyRe.hasMatch(key)) {
    throw ArgumentError('prefix must be letters, digits, dots, dashes, underscores or colons');
  }
  return key;
}

/// Any non-2xx response, or a transport failure ([status] 0).
///
/// [code] and [message] come from the API's `error` object
/// (`{"error": {"code": ..., "message": ...}, "request_id": ...}`).
/// Catch a subclass to branch on the kind of failure, e.g. [PaymentRequiredError].
class TonePerfectError implements Exception {
  TonePerfectError(this.status, this.code, this.message,
      {this.requestId, this.retryAfter, Map<String, dynamic>? body})
      : body = body ?? const {};

  /// HTTP status, or 0 for a transport failure (code `timeout` / `network_error`).
  final int status;

  /// API error code: `invalid_api_key`, `subscription_required`, `insufficient_credits`,
  /// `invalid_audio`, `unsupported_language`, `rate_limit`, `engine_unavailable`, ...
  final String code;
  final String message;
  final String? requestId;

  /// Seconds from the `Retry-After` header, when present.
  final double? retryAfter;

  /// The error body as returned by the API.
  final Map<String, dynamic> body;

  /// `req_…` result id when the failure was finalized under your Idempotency-Key.
  String? get id => body['id'] is String ? body['id'] as String : null;
  Map<String, dynamic>? get billing =>
      body['billing'] is Map ? Map<String, dynamic>.from(body['billing'] as Map) : null;

  /// The failure is a stored result for this key (`id` + `billing` present).
  bool get finalized => id != null && billing != null;

  /// Start a new attempt with a new Idempotency-Key; the old key replays this response.
  bool get needsNewKey => finalized || newKeyCodes.contains(code);

  /// Retry later with the SAME Idempotency-Key: nothing was finalized.
  bool get retryable {
    if (finalized || newKeyCodes.contains(code)) return false;
    return retrySameKeyCodes.contains(code) || const [408, 429, 502, 503, 504].contains(status);
  }

  @override
  String toString() => '$runtimeType($status $code: $message)';
}

/// 401: missing, revoked or unknown API key (`invalid_api_key`).
class AuthenticationError extends TonePerfectError {
  AuthenticationError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body});
}

/// 402: nothing was charged. [code] is `subscription_required` (the 50 free credits are
/// used up and there is no active plan), `insufficient_credits` or `payment_balance_due`.
/// Fix it in https://api.toneperfect.app/dashboard.
class PaymentRequiredError extends TonePerfectError {
  PaymentRequiredError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body});
}

/// 429: `rate_limit` (60 assessments/minute) or `account_busy` (2 running). Retry with the same key.
class RateLimitError extends TonePerfectError {
  RateLimitError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body});
}

/// Other 4xx: the request needs a fix (`invalid_audio`, `unsupported_language`,
/// `invalid_reference`, `upload_too_large`, `idempotency_conflict`, ...).
class ValidationError extends TonePerfectError {
  ValidationError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body});
}

/// 5xx: `engine_unavailable`, `request_interrupted` or a proxy 502/504.
class ServerError extends TonePerfectError {
  ServerError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body});
}

/// Transport failure (status 0): `timeout` or `network_error`. The outcome is unknown:
/// retry with the same Idempotency-Key.
class APIConnectionError extends TonePerfectError {
  APIConnectionError(super.status, super.code, super.message, {super.requestId, super.retryAfter, super.body});
}

TonePerfectError _makeError(int status, String code, String message,
    {String? requestId, double? retryAfter, Map<String, dynamic>? body}) {
  if (status == 0) return APIConnectionError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body);
  if (status == 401) return AuthenticationError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body);
  if (status == 402) return PaymentRequiredError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body);
  if (status == 429) return RateLimitError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body);
  if (status >= 500) return ServerError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body);
  if (status >= 400) return ValidationError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body);
  return TonePerfectError(status, code, message, requestId: requestId, retryAfter: retryAfter, body: body);
}

/// One `POST /v1/assess` result. [data] is the full JSON body, untouched.
class Assessment {
  Assessment(this.data, this.status, this.headers)
      : requestId = headers['x-request-id'],
        replayed = (headers['idempotent-replayed'] ?? '').toLowerCase() == 'true';

  final Map<String, dynamic> data;
  final int status;
  final Map<String, String> headers;
  final String? requestId;

  /// The result was served from a previous identical request (no new charge).
  final bool replayed;

  /// False when the audio could not be meaningfully scored. Never show that as a zero; see [reason].
  bool get assessable => data['assessable'] == true;
  String? get reason => data['reason'] as String?;

  /// 0–100 display grades per dimension; null means the pack does not support that dimension.
  Map<String, num?> get scores =>
      data['scores'] is Map ? Map<String, num?>.from(data['scores'] as Map) : const {};
  num? get overall => scores['overall'];

  /// Per word/character: `score`, `start_ms`, `end_ms`, `phones` (`expected`, `heard`, `score`, `decision`).
  List<Map<String, dynamic>> get words => data['words'] is List
      ? (data['words'] as List).whereType<Map>().map((w) => Map<String, dynamic>.from(w)).toList()
      : const [];

  /// `{"credits": charged, "balance_credits": remaining}`; failed or unassessable requests charge 0.
  Map<String, dynamic> get billing =>
      data['billing'] is Map ? Map<String, dynamic>.from(data['billing'] as Map) : const {};
  String? get modelVersion => data['model_version'] as String?;

  /// Result id (`req_…`).
  String? get id => (data['id'] as String?) ?? requestId;
}

/// Client for https://api.toneperfect.app.
class TonePerfect {
  /// [apiKey] is the secret key from the dashboard (`tp_live_...`); only [assess] needs it.
  TonePerfect({
    this.apiKey = '',
    String baseUrl = defaultBaseUrl,
    this.timeout = const Duration(seconds: 90),
    http.Client? httpClient,
    String? userAgent,
  })  : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        userAgent = userAgent ?? 'toneperfect-dart/$toneperfectVersion';

  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  final String userAgent;
  final http.Client _http;
  final bool _ownsClient;

  /// `GET /v1/capabilities` — no key needed. `languages` (locale, status, dimensions,
  /// limitations), `limits`, `model_version`.
  Future<Map<String, dynamic>> capabilities() async {
    final request = http.Request('GET', Uri.parse('$baseUrl/v1/capabilities'));
    final response = await _send(request);
    return _parse(response);
  }

  /// `POST /v1/assess` — score one scripted recording (up to 30 s / 10 MB; WAV, MP3, M4A, OGG, WebM).
  ///
  /// [text] is what the learner was asked to read (required unless [pinyin] is given, Mandarin only).
  /// [language] is a locale from [capabilities] such as `zh-CN`, `en-US`, `fr-FR`.
  /// [task] is `general` (default), `connected_speech` or `isolated_word`.
  /// [idempotencyKey] is generated when omitted; reuse the same key (and identical inputs) to
  /// retry after a network error — a completed request is returned without charging again.
  Future<Assessment> assess(
    List<int> audio, {
    String? text,
    String language = 'zh-CN',
    String? pinyin,
    String task = 'general',
    String? idempotencyKey,
    String filename = 'recording.wav',
  }) async {
    if (apiKey.isEmpty) {
      throw AuthenticationError(401, 'invalid_api_key', 'Pass apiKey (a tp_live_... key from the dashboard).');
    }
    if (!tasks.contains(task)) throw ArgumentError.value(task, 'task', 'must be one of $tasks');
    if ((text == null || text.isEmpty) && (pinyin == null || pinyin.isEmpty)) {
      throw ArgumentError('Provide text (or pinyin for Mandarin).');
    }
    final key = idempotencyKey ?? newIdempotencyKey();
    if (!_idempotencyRe.hasMatch(key)) {
      throw ArgumentError.value(key, 'idempotencyKey', 'must be 8-128 letters, digits, dots, dashes, underscores or colons');
    }
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/v1/assess'))
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..headers['Idempotency-Key'] = key
      ..files.add(http.MultipartFile.fromBytes('audio', audio is Uint8List ? audio : Uint8List.fromList(audio), filename: filename));
    if (text != null && text.isNotEmpty) request.fields['text'] = text;
    if (pinyin != null && pinyin.isNotEmpty) request.fields['pinyin'] = pinyin;
    request.fields['language'] = language;
    request.fields['task'] = task;
    final response = await _send(request);
    return Assessment(_parse(response), response.statusCode, response.headers);
  }

  /// Closes the underlying HTTP client if this instance created it.
  void close() {
    if (_ownsClient) _http.close();
  }

  Future<http.Response> _send(http.BaseRequest request) async {
    request.headers['Accept'] = 'application/json';
    request.headers['User-Agent'] = userAgent;
    try {
      final streamed = await _http.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw APIConnectionError(0, 'timeout',
          'No response within ${timeout.inSeconds}s; the outcome is unknown, retry with the same Idempotency-Key.');
    } on TonePerfectError {
      rethrow;
    } catch (error) {
      throw APIConnectionError(0, 'network_error', 'Could not reach $baseUrl: $error');
    }
  }

  static Map<String, dynamic> _parse(http.Response response) {
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
          requestId: (data['request_id'] as String?) ?? requestId,
          retryAfter: retryAfter,
          body: Map<String, dynamic>.from(data));
    }
    final snippet = raw.length > 200 ? raw.substring(0, 200) : raw;
    throw _makeError(status, 'http_error', snippet.trim().isEmpty ? 'HTTP $status' : snippet.trim(),
        requestId: requestId, retryAfter: retryAfter);
  }
}

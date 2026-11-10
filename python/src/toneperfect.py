"""TonePerfect pronunciation assessment API client.

One file, standard library only, Python 3.9+. Wraps the public endpoints of
https://api.toneperfect.app:

    GET  /v1/capabilities   -> languages served, limits, model version (no key)
    POST /v1/assess         -> score one scripted recording
    POST /v1/lint           -> check a reference text before recording (free, no key)
    GET  /v1/status         -> synthetic engine probe summary (free, no key)

Command line: ``python -m toneperfect lint "我有三本书" --language zh-CN`` or
``python -m toneperfect lint --file lesson.csv`` (exit 1 when a text has an error).

Accounts, API keys and billing are managed in the web dashboard
(https://api.toneperfect.app/dashboard); those routes are session-based and
are deliberately not wrapped here. Full reference: https://api.toneperfect.app/docs

Quick start::

    from toneperfect import TonePerfect
    client = TonePerfect()                       # reads TONEPERFECT_API_KEY
    result = client.assess("hello.ogg", text="你好", language="zh-CN")
    print(result.assessable, result.overall, result.billing.credits)
"""
from __future__ import annotations

import http.client
import io
import json
import os
import random
import secrets
import socket
import time
import uuid
from dataclasses import dataclass, field
from typing import IO, Any, Dict, List, Mapping, Optional, Union
from urllib import request as _request
from urllib.error import HTTPError, URLError

__all__ = [
    "TonePerfect", "Assessment", "Word", "Phone", "Billing",
    "TonePerfectError", "AuthenticationError", "PaymentRequiredError", "RateLimitError",
    "ValidationError", "ServerError", "APIConnectionError",
    "new_idempotency_key", "DEFAULT_BASE_URL", "BILLING_URL", "TASKS", "DECISIONS", "TEST_OUTCOMES",
    "RETRY_SAME_KEY_CODES", "NEW_KEY_CODES",
]
__version__ = "0.3.0"

DEFAULT_BASE_URL = "https://api.toneperfect.app"
#: Where a 402 is fixed (start, renew or repair a plan). A 402 from the API may carry its own ``billing_url``.
BILLING_URL = "https://api.toneperfect.app/dashboard?tab=billing"
TASKS = ("general", "connected_speech", "isolated_word")
#: Outcomes a ``tp_test_`` key can rehearse (``test_outcome=`` on :meth:`TonePerfect.assess`).
TEST_OUTCOMES = ("success", "unassessable", "invalid_assessment", "engine_unavailable", "subscription_required",
                 "subscription_past_due", "insufficient_credits", "account_busy", "rate_limit")
#: Values of ``decision`` on words and phones. ``review`` / ``uncertain`` / ``no_correction``
#: are the feedback decisions; ``unassessable`` (no evidence for that unit), ``partial``
#: (word only partly covered by the phonetic inventory) and ``legacy_correction`` (Mandarin
#: components decided by the legacy policy) also occur. Treat unknown values as "no decision".
DECISIONS = ("review", "uncertain", "no_correction", "unassessable", "partial", "legacy_correction")
#: Error codes after which the SAME Idempotency-Key is retried: nothing was stored under it.
RETRY_SAME_KEY_CODES = frozenset({
    "rate_limit", "account_busy", "uploads_in_progress", "gateway_busy", "decoder_busy", "audio_decoder_unavailable",
    "upload_timeout", "request_pending", "request_interrupted", "engine_unavailable", "result_held",
    "timeout", "network_error",
})
#: Error codes that mean the key is spent: start a new attempt with a new key.
NEW_KEY_CODES = frozenset({"idempotency_expired", "idempotency_conflict"})
#: Error codes a retry cannot fix soon. ``free_capacity`` (429): the shared daily limit for free
#: credits is reached; it clears at the next UTC day, or at once with a paid plan.
NOT_RETRYABLE_CODES = frozenset({"free_capacity"})
_CONTENT_TYPES = {".wav": "audio/wav", ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".mp4": "audio/mp4", ".aac": "audio/aac",
                  ".ogg": "audio/ogg", ".oga": "audio/ogg", ".opus": "audio/ogg", ".webm": "audio/webm", ".flac": "audio/flac"}

AudioInput = Union[str, "os.PathLike[str]", bytes, bytearray, IO[bytes]]


def new_idempotency_key() -> str:
    """A fresh key for one recording attempt (a UUID).

    :meth:`TonePerfect.assess` makes one per call and reuses it for its own automatic
    retries. Pass your own (``idempotency_key=``) when your code may resend the same
    recording after a crash or a lost response: the same key and identical fields return
    the stored result without a second charge. Use a new key for a new recording.
    """
    return str(uuid.uuid4())


# ---------------------------------------------------------------- errors

class TonePerfectError(Exception):
    """Base class of every error. Raised for each non-2xx response and for transport failures (``status`` 0).

    ``code`` and ``message`` come from the API's ``error`` object
    (``{"error": {"code": ..., "message": ...}, "request_id": ...}``); branch on ``code``.
    A non-JSON body (for example an HTML 502 from a proxy) gets ``code="http_error"``.

    What to do next:

    * ``retryable``: nothing was stored under the Idempotency-Key; the client already retried
      with the SAME key up to ``max_retries`` times. Retry later with the same key.
    * ``needs_new_key``: the failure is stored under the key (``finalized``: a 4xx carrying a
      ``req_…`` ``id`` and ``billing``, such as ``invalid_assessment``) or the key expired or
      conflicts. A new attempt needs a new key (the default when you do not pass one).
    * otherwise: fix the request (``invalid_api_key``, ``invalid_audio``, ``unsupported_language``, …).
    """

    def __init__(self, status: int, code: str, message: str, request_id: Optional[str] = None,
                 retry_after: Optional[float] = None, body: Optional[Dict[str, Any]] = None,
                 idempotency_key: Optional[str] = None):
        self.status = status
        self.code = code
        self.message = message
        self.request_id = request_id
        self.retry_after = retry_after
        self.body: Dict[str, Any] = body or {}
        #: The Idempotency-Key of the attempt (assess only).
        self.idempotency_key = idempotency_key
        error = self.body.get("error") if isinstance(self.body.get("error"), dict) else {}
        #: ``req_…`` result id when the failure was stored under the key.
        self.id: Optional[str] = self.body.get("id") if isinstance(self.body.get("id"), str) else None
        self.billing: Optional[Dict[str, Any]] = self.body.get("billing") if isinstance(self.body.get("billing"), dict) else None
        #: 402: where to start, renew or fix a plan (the API's own link, else the dashboard billing tab).
        self.billing_url: Optional[str] = error.get("billing_url") or (BILLING_URL if status == 402 else None)
        #: 402: the plans page, when the API sends it.
        self.pricing_url: Optional[str] = error.get("pricing_url")
        #: 402: the least expensive monthly plan on sale, when the API sends it (``id``, ``name``, ``price_usd``, ``monthly_credits``).
        self.plan: Optional[Dict[str, Any]] = error.get("plan") if isinstance(error.get("plan"), dict) else None
        super().__init__(str(self))

    def __str__(self) -> str:
        text = f"{self.status} {self.code}: {self.message}"
        return f"{text} ({self.billing_url})" if self.billing_url and self.billing_url not in self.message else text

    @property
    def finalized(self) -> bool:
        """The failure is a stored result for this key: a 4xx with ``id`` and ``billing``. A 5xx is never stored."""
        return self.id is not None and self.billing is not None and self.status < 500

    @property
    def needs_new_key(self) -> bool:
        """Start a new attempt with a new Idempotency-Key; the old key replays this response."""
        return self.finalized or self.code in NEW_KEY_CODES

    @property
    def retryable(self) -> bool:
        """Retry later with the SAME Idempotency-Key: nothing was stored under it."""
        if self.finalized or self.code in NEW_KEY_CODES or self.code in NOT_RETRYABLE_CODES:
            return False
        return self.code in RETRY_SAME_KEY_CODES or self.status in (0, 408, 429, 502, 503, 504)


class AuthenticationError(TonePerfectError):
    """401: missing, unknown or revoked API key (``invalid_api_key``). Send ``Authorization: Bearer KEY``."""


class PaymentRequiredError(TonePerfectError):
    """402: nothing was charged. ``code``: ``subscription_required`` (free credits used up, no active plan),
    ``subscription_past_due`` (a renewal payment failed or is pending), ``insufficient_credits`` (the plan
    balance does not cover the recording) or ``payment_balance_due``. ``billing_url`` says where to fix it."""


class RateLimitError(TonePerfectError):
    """429: ``rate_limit`` (60 assessments a minute), ``account_busy`` (concurrent limit), ``uploads_in_progress``
    (retried with the same key) or ``free_capacity`` (daily free-credit cap; not retried)."""


class ValidationError(TonePerfectError):
    """Any other 4xx: the request needs a fix (``invalid_audio``, ``unsupported_language``, ``invalid_reference``,
    ``upload_too_large``, ``idempotency_conflict``, …). ``needs_new_key`` tells whether to change the key."""


class ServerError(TonePerfectError):
    """5xx: ``engine_unavailable``, ``gateway_busy``, ``request_interrupted``, a proxy 502/504. Never stored and
    never charged; the client retries these with the same key."""


class APIConnectionError(TonePerfectError):
    """Transport failure (``status`` 0): ``timeout`` or ``network_error``. The outcome is unknown, so the client
    retries with the same key: a finished result comes back once, charged once."""


def _error_class(status: int):
    if status == 0:
        return APIConnectionError
    if status == 401:
        return AuthenticationError
    if status == 402:
        return PaymentRequiredError
    if status == 429:
        return RateLimitError
    if status >= 500:
        return ServerError
    if 400 <= status < 500:
        return ValidationError
    return TonePerfectError


# ---------------------------------------------------------------- results

class _Row:
    """Typed view of one JSON object; ``row["field"]`` and ``row.get()`` still read the raw JSON."""

    data: Dict[str, Any]

    def __getitem__(self, key: str) -> Any:
        return self.data[key]

    def get(self, key: str, default: Any = None) -> Any:
        return self.data.get(key, default)


@dataclass(frozen=True)
class Phone(_Row):
    """One scored unit under a word: a phoneme, or a Mandarin initial, final or tone."""

    dimension: Optional[str]
    expected: Any
    heard: Any
    score: Optional[float]
    decision: Optional[str]
    data: Dict[str, Any] = field(repr=False)

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> "Phone":
        return cls(d.get("dimension"), d.get("expected"), d.get("heard"), d.get("score"), d.get("decision"), d)


@dataclass(frozen=True)
class Word(_Row):
    """One word (one character in Mandarin). Full and compact responses map to the same fields."""

    word: Optional[str]
    score: Optional[float]
    start_ms: Optional[int]
    end_ms: Optional[int]
    decision: Optional[str]
    pinyin: Optional[str]
    phones: List[Phone]
    data: Dict[str, Any] = field(repr=False)

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> "Word":
        units = d.get("phones") if d.get("phones") is not None else d.get("units") or []
        return cls(d.get("word", d.get("text")), d.get("score"), d.get("start_ms"), d.get("end_ms"), d.get("decision"),
                   d.get("pinyin"), [Phone.from_dict(u) for u in units if isinstance(u, dict)], d)


@dataclass(frozen=True)
class Billing(_Row):
    """What the request cost: ``credits`` charged, remaining ``balance_credits`` and ``free_credits``, ``source``
    (``free``, ``plan`` or ``test``)."""

    credits: int
    balance_credits: Optional[int]
    free_credits: Optional[int]
    source: Optional[str]
    data: Dict[str, Any] = field(repr=False)

    @classmethod
    def from_dict(cls, d: Optional[Dict[str, Any]]) -> "Billing":
        d = d or {}
        return cls(int(d.get("credits") or 0), d.get("balance_credits"), d.get("free_credits"), d.get("source"), d)


@dataclass
class Assessment:
    """One ``POST /v1/assess`` result.

    ``data`` is the JSON body exactly as returned (full or compact schema); the attributes are
    typed views of its documented fields. Anything else (``syllables``, ``heard``, timings) is in ``data``.
    """

    data: Dict[str, Any]
    status: int
    request_id: Optional[str] = None
    replayed: bool = False
    headers: Dict[str, str] = field(default_factory=dict)
    idempotency_key: Optional[str] = None

    @property
    def id(self) -> Optional[str]:
        """Result id (``req_…``), also in the ``X-Request-Id`` header."""
        return self.data.get("id") or self.request_id

    @property
    def assessable(self) -> bool:
        """False when the audio could not be scored (silence, another text, unreadable): see ``reason``. Free,
        and never a score of zero."""
        return bool(self.data.get("assessable"))

    @property
    def reason(self) -> Optional[str]:
        return self.data.get("reason")

    @property
    def scores(self) -> Dict[str, Optional[float]]:
        """0–100 display grades per dimension; ``None`` = not measured by this language pack."""
        return self.data.get("scores") or {}

    @property
    def overall(self) -> Optional[float]:
        return self.scores.get("overall")

    @property
    def words(self) -> List[Word]:
        return [Word.from_dict(w) for w in self.data.get("words") or [] if isinstance(w, dict)]

    @property
    def warnings(self) -> List[str]:
        return [w for w in self.data.get("warnings") or [] if isinstance(w, str)]

    @property
    def billing(self) -> Billing:
        return Billing.from_dict(self.data.get("billing"))

    @property
    def model_version(self) -> Optional[str]:
        return self.data.get("model_version")

    @property
    def engine(self) -> Optional[str]:
        """``primary`` or ``fallback`` (``engine_route.engine``; fallback scores are calibrated differently)."""
        route = self.data.get("engine_route")
        return route.get("engine") if isinstance(route, dict) else self.headers.get("x-toneperfect-engine")

    @property
    def test(self) -> bool:
        """True for a fixed example response from a ``tp_test_`` key (no audio scored, nothing charged)."""
        return self.data.get("test") is True

    @property
    def compact(self) -> bool:
        return self.data.get("schema") == "toneperfect.compact.v1"


# ---------------------------------------------------------------- client

class TonePerfect:
    """Client for https://api.toneperfect.app.

    :param api_key: secret key from the dashboard (``tp_live_…``, or a ``tp_test_…`` test key that returns fixed
        example results and never spends credits). Defaults to ``$TONEPERFECT_API_KEY``.
    :param base_url: API origin. Defaults to ``$TONEPERFECT_BASE_URL``, else ``https://api.toneperfect.app``
        (a proxy with a 26-second limit: a longer assessment comes back on the automatic retry).
    :param timeout: seconds to wait for each response.
    :param max_retries: automatic retries of a retryable failure, with the same Idempotency-Key.
    :param headers: extra headers for every request, for example ``{"TonePerfect-Fallback": "off"}``.
    """

    def __init__(self, api_key: Optional[str] = None, *, base_url: Optional[str] = None, timeout: float = 60.0,
                 max_retries: int = 2, headers: Optional[Mapping[str, str]] = None, user_agent: Optional[str] = None):
        self.api_key = api_key or os.environ.get("TONEPERFECT_API_KEY", "")
        self.base_url = (base_url or os.environ.get("TONEPERFECT_BASE_URL") or DEFAULT_BASE_URL).rstrip("/")
        self.timeout = timeout
        self.max_retries = max(0, int(max_retries))
        self.user_agent = user_agent or f"toneperfect-python/{__version__}"
        self.headers: Dict[str, str] = dict(headers or {})

    # ---- public endpoints ----

    def capabilities(self) -> Dict[str, Any]:
        """``GET /v1/capabilities`` (no key): ``languages`` (locale, status, dimensions, limitations), ``limits``,
        ``model_version``. Every pack is currently labelled ``experimental``."""
        return self._call("GET", "/v1/capabilities", None, {})[0]

    def lint(self, text: str, *, language: str, pinyin: str = "", task: str = "general") -> Dict[str, Any]:
        """``POST /v1/lint`` (free, no key): the engine's reference rules without audio.

        Returns ``{"ok", "language", "issues": [{code, message, field, severity}], "units"}``. A text that
        passes can still be refused by a newer engine; the assess response stays authoritative.
        """
        body = json.dumps({"text": text or "", "language": language, "pinyin": pinyin or "", "task": task}).encode("utf-8")
        return self._call("POST", "/v1/lint", body, {"Content-Type": "application/json"})[0]

    def status(self) -> Dict[str, Any]:
        """``GET /v1/status`` (no key): the synthetic engine probe (status, last_check, last_24h, last_7d)."""
        return self._call("GET", "/v1/status", None, {})[0]

    def assess(self, audio: AudioInput, *, text: Optional[str] = None, language: str, pinyin: Optional[str] = None,
               task: str = "general", idempotency_key: Optional[str] = None, filename: Optional[str] = None,
               content_type: Optional[str] = None, compact: bool = False, test_outcome: Optional[str] = None) -> Assessment:
        """``POST /v1/assess``: score one scripted recording against its reference text.

        :param audio: a path, bytes, or a binary file object: WAV, MP3, M4A, Ogg or WebM, 0.15–120 s, up to 10 MB.
        :param text: what the learner was asked to say. Mandarin may send ``pinyin`` with tones instead.
        :param language: required locale: ``zh-CN``, ``en-US``, ``fr-FR``, ``es-419``, ``de-DE``, ``it-IT``,
            ``pt-BR``, ``ru-RU``, ``ko-KR`` or ``ja-JP`` (see :meth:`capabilities`).
        :param pinyin: Mandarin only: with characters, one syllable per character picks the reading of a
            polyphone; alone, toned pinyin (``ni3 hao3``) is scored.
        :param task: ``general`` (default), ``connected_speech`` or ``isolated_word``.
        :param idempotency_key: one per recording attempt; made for you when omitted and reused by the
            automatic retries. Pass your own to resend the same recording safely across restarts.
        :param filename: file name sent with the audio (defaults to the path's name, else ``recording``).
        :param content_type: audio media type (defaults from the file extension).
        :param compact: ask for the stable compact schema (``toneperfect.compact.v1``).
        :param test_outcome: ``tp_test_`` keys only: one of :data:`TEST_OUTCOMES`, to rehearse error handling.
        :raises TonePerfectError: a subclass per status (see the module docs); transport failures raise
            :class:`APIConnectionError`.
        """
        if not self.api_key:
            raise AuthenticationError(401, "invalid_api_key", "Set api_key or the TONEPERFECT_API_KEY environment variable.")
        if not language:
            raise ValueError("language is required, for example 'en-US' or 'zh-CN'")
        if task not in TASKS:
            raise ValueError(f"task must be one of {TASKS}")
        if not (text or pinyin):
            raise ValueError("Provide text (or, for Mandarin, pinyin with tones).")
        key = idempotency_key or new_idempotency_key()
        if not (0 < len(key) <= 255 and all(32 <= ord(c) < 127 for c in key)):
            raise ValueError("idempotency_key must be 1-255 printable ASCII characters (a UUID works everywhere)")
        data, name = _read_audio(audio)
        name = filename or name or "recording"
        ctype = content_type or _CONTENT_TYPES.get(os.path.splitext(name)[1].lower(), "application/octet-stream")
        fields: Dict[str, str] = {"language": language, "task": task}
        if text:
            fields["text"] = text
        if pinyin:
            fields["pinyin"] = pinyin
        body, boundary = _multipart(fields, "audio", name, ctype, data)
        headers = {"Authorization": f"Bearer {self.api_key}", "Idempotency-Key": key,
                   "Content-Type": f"multipart/form-data; boundary={boundary}"}
        if compact:
            headers["TonePerfect-Response"] = "compact"
        if test_outcome:
            headers["TonePerfect-Test-Outcome"] = str(test_outcome)
        result, status, response_headers = self._call("POST", "/v1/assess", body, headers, key)
        return Assessment(data=result, status=status, request_id=response_headers.get("x-request-id"),
                          replayed=response_headers.get("idempotent-replayed", "").lower() == "true",
                          headers=response_headers, idempotency_key=response_headers.get("idempotency-key") or key)

    # ---- transport ----

    def _call(self, method: str, path: str, body: Optional[bytes], headers: Mapping[str, str], key: Optional[str] = None):
        attempt = 0
        while True:
            try:
                status, response_headers, raw = self._send(method, path, body, headers)
                return self._json(status, response_headers, raw, key), status, response_headers
            except TonePerfectError as error:
                if key and error.idempotency_key is None:
                    error.idempotency_key = key
                if attempt >= self.max_retries or not error.retryable:
                    raise
                time.sleep(_backoff(error, attempt))
                attempt += 1

    def _send(self, method: str, path: str, body: Optional[bytes], headers: Mapping[str, str]):
        req = _request.Request(self.base_url + path, data=body, method=method)
        req.add_header("Accept", "application/json")
        req.add_header("User-Agent", self.user_agent)
        for name, value in {**self.headers, **headers}.items():
            req.add_header(name, value)
        timeout_error = APIConnectionError(0, "timeout", f"No response within {self.timeout}s; the outcome is unknown, retry with the same Idempotency-Key.")
        try:
            try:
                with _request.urlopen(req, timeout=self.timeout) as response:  # noqa: S310 - https origin chosen by the caller
                    return response.status, {k.lower(): v for k, v in response.headers.items()}, response.read()
            except HTTPError as error:  # a subclass of URLError: handle first
                try:
                    return error.code, {k.lower(): v for k, v in error.headers.items()}, error.read()
                finally:
                    error.close()
        except URLError as error:
            if isinstance(error.reason, (socket.timeout, TimeoutError)):
                raise timeout_error from error
            raise APIConnectionError(0, "network_error", f"Could not reach {self.base_url}: {error.reason}") from error
        except (socket.timeout, TimeoutError) as error:
            raise timeout_error from error
        except (OSError, http.client.HTTPException) as error:  # reset connections, TLS failures, truncated bodies
            raise APIConnectionError(0, "network_error", f"Could not reach {self.base_url}: {error}") from error

    @staticmethod
    def _json(status: int, headers: Mapping[str, str], raw: bytes, key: Optional[str] = None) -> Dict[str, Any]:
        try:
            data = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            data = None
        if 200 <= status < 300 and isinstance(data, dict):
            return data
        retry_after = None
        try:
            retry_after = float(headers["retry-after"]) if "retry-after" in headers else None
        except ValueError:
            pass
        cls = _error_class(status)
        if isinstance(data, dict) and isinstance(data.get("error"), dict):
            err = data["error"]
            raise cls(status, str(err.get("code", "request_error")), str(err.get("message", "")),
                      data.get("request_id") or headers.get("x-request-id"), retry_after, data, key)
        if isinstance(data, dict) and isinstance(data.get("detail"), str):  # framework errors (405 on a trailing slash)
            raise cls(status, "http_error", data["detail"], headers.get("x-request-id"), retry_after, data, key)
        snippet = raw[:200].decode("utf-8", "replace").strip() if raw else ""
        raise cls(status, "http_error", snippet or f"HTTP {status}", headers.get("x-request-id"), retry_after, None, key)


# ---------------------------------------------------------------- helpers

def _backoff(error: TonePerfectError, attempt: int) -> float:
    if error.retry_after is not None:
        return max(0.0, min(error.retry_after, 30.0))
    base = 2.0 if error.code == "engine_unavailable" else 0.5
    return min(base * (2 ** attempt), 8.0) + random.uniform(0, 0.25)


def _read_audio(audio: AudioInput):
    if isinstance(audio, (bytes, bytearray)):
        return bytes(audio), None
    if hasattr(audio, "read"):
        data = audio.read()  # type: ignore[union-attr]
        if isinstance(data, str):
            raise TypeError("Open audio files in binary mode ('rb').")
        name = getattr(audio, "name", None)
        return data, os.path.basename(name) if isinstance(name, str) else None
    path = os.fspath(audio)  # type: ignore[arg-type]
    with open(path, "rb") as handle:
        return handle.read(), os.path.basename(path)


def _multipart(fields: Mapping[str, str], file_field: str, filename: str, content_type: str, data: bytes):
    boundary = "----toneperfect" + secrets.token_hex(16)
    out = io.BytesIO()
    for name, value in fields.items():
        out.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n".encode("utf-8"))
        out.write(str(value).encode("utf-8"))
        out.write(b"\r\n")
    safe_name = filename.replace('"', "_").replace("\r", "").replace("\n", "")
    out.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; filename=\"{safe_name}\"\r\nContent-Type: {content_type}\r\n\r\n".encode("utf-8"))
    out.write(data)
    out.write(f"\r\n--{boundary}--\r\n".encode("utf-8"))
    return out.getvalue(), boundary


# ---------------------------------------------------------------- command line: python -m toneperfect lint ...

def _lint_items(texts, path, language, pinyin):
    import csv
    items = [{"text": t, "language": language, "pinyin": pinyin} for t in texts]
    if path:
        with open(path, encoding="utf-8") as handle:
            lines = [line.strip() for line in handle if line.strip() and not line.lstrip().startswith("#")]
        if path.endswith(".jsonl"):
            for number, line in enumerate(lines, 1):
                try:
                    row = json.loads(line)
                except ValueError:
                    raise ValueError(f"line {number} is not valid JSON") from None
                if not isinstance(row, dict):
                    raise ValueError(f"line {number} is not a JSON object")
                items.append({"text": row.get("text", ""), "language": row.get("language") or language, "pinyin": row.get("pinyin", "")})
        elif path.endswith(".csv"):
            for row in csv.reader(lines):
                if not row or row[:2] == ["text", "language"]:
                    continue
                items.append({"text": row[0].strip(), "language": (row[1].strip() if len(row) > 1 and row[1].strip() else language),
                              "pinyin": row[2].strip() if len(row) > 2 else ""})
        else:
            items.extend({"text": line, "language": language, "pinyin": ""} for line in lines)
    return items


def main(argv=None, client: Optional["TonePerfect"] = None, out=None) -> int:
    """``python -m toneperfect lint TEXT... [--file F] [--language L] [--pinyin P] [--json]``.

    Exit 0 = every text passes, 1 = at least one error, 2 = usage or network problem.
    """
    import argparse
    import sys
    out = out or sys.stdout
    parser = argparse.ArgumentParser(prog="python -m toneperfect", description="Check reference texts with POST /v1/lint (free, no key).")
    sub = parser.add_subparsers(dest="command", required=True)
    lint = sub.add_parser("lint", help="check reference texts before recording")
    lint.add_argument("texts", nargs="*")
    lint.add_argument("--file", "-f", help=".txt (one text per line), .csv (text,language[,pinyin]) or .jsonl")
    lint.add_argument("--language", "-l", default="zh-CN")
    lint.add_argument("--pinyin", default="")
    lint.add_argument("--task", default="general", choices=TASKS)
    lint.add_argument("--json", action="store_true")
    lint.add_argument("--base-url", default=None)
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    try:
        items = _lint_items(args.texts, args.file, args.language, args.pinyin)
    except FileNotFoundError:
        print(f"Cannot read {args.file}: file not found", file=sys.stderr)
        return 2
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        print(f"Cannot read {args.file}: {exc}", file=sys.stderr)
        return 2
    if not items:
        print("Give a text or --file.", file=sys.stderr)
        return 2
    client = client or TonePerfect(api_key="unused-for-lint", base_url=args.base_url)
    failed = 0
    for item in items:
        try:
            result = client.lint(item["text"], language=item["language"], pinyin=item["pinyin"], task=args.task)
        except TonePerfectError as exc:
            print(f"network/API error: {exc}", file=sys.stderr)
            return 2
        failed += not result.get("ok")
        if args.json:
            print(json.dumps({**item, **result}, ensure_ascii=False), file=out)
            continue
        label = "ok   " if result.get("ok") else "ERROR"
        print(f"{label} [{item['language']}] {item['text']}" + (f" ({item['pinyin']})" if item["pinyin"] else ""), file=out)
        for issue in result.get("issues") or []:
            print(f"      {issue.get('severity')}: {issue.get('code')}: {issue.get('message')}", file=out)
    if not args.json:
        print(f"{len(items) - failed}/{len(items)} texts pass.", file=out)
    return 1 if failed else 0


def _lint_entry() -> int:
    """Console script ``toneperfect-lint ...`` (same as ``python -m toneperfect lint ...``)."""
    import sys
    return main(["lint", *sys.argv[1:]])


if __name__ == "__main__":
    raise SystemExit(main())

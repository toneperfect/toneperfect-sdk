"""TonePerfect pronunciation assessment API client.

One file, standard library only. Wraps the two public endpoints of
https://api.toneperfect.app:

    GET  /v1/capabilities   -> languages served, limits, model version
    POST /v1/assess         -> score one scripted recording

Accounts, API keys and billing are managed in the web dashboard
(https://api.toneperfect.app/dashboard); those routes are session-based and
are deliberately not wrapped here. Full reference: https://api.toneperfect.app/docs

Quick start::

    from toneperfect import TonePerfect
    client = TonePerfect(api_key="tp_live_...")
    result = client.assess("hello.wav", text="你好", language="zh-CN")
    print(result.assessable, result.scores, result.billing)
"""
from __future__ import annotations

import io
import json
import os
import re
import secrets
import http.client
import socket
import uuid
from dataclasses import dataclass, field
from typing import IO, Any, Dict, List, Mapping, Optional, Union
from urllib import request as _request
from urllib.error import HTTPError, URLError

__all__ = ["TonePerfect", "TonePerfectError", "AuthenticationError", "PaymentRequiredError", "RateLimitError", "ValidationError", "ServerError", "APIConnectionError", "Assessment", "new_idempotency_key", "DEFAULT_BASE_URL", "TASKS", "DECISIONS", "RETRY_SAME_KEY_CODES"]
__version__ = "0.1.0"

DEFAULT_BASE_URL = "https://api.toneperfect.app"
TASKS = ("general", "connected_speech", "isolated_word")
#: Values of ``decision`` on words and phones. ``review`` / ``uncertain`` / ``no_correction``
#: are the feedback decisions; ``unassessable`` (no evidence for that unit), ``partial``
#: (word only partly covered by the phonetic inventory) and ``legacy_correction`` (Mandarin
#: components decided by the legacy policy) also occur. Treat unknown values as "no decision".
DECISIONS = ("review", "uncertain", "no_correction", "unassessable", "partial", "legacy_correction")
#: Error codes after which the SAME Idempotency-Key must be retried: nothing was finalized.
RETRY_SAME_KEY_CODES = frozenset({
    "rate_limit", "account_busy", "gateway_busy", "decoder_busy", "audio_decoder_unavailable",
    "upload_timeout", "request_pending", "timeout", "network_error",
})
#: Error codes that mean the key is spent: start a new attempt with a new key.
NEW_KEY_CODES = frozenset({"idempotency_expired", "idempotency_conflict"})
_IDEMPOTENCY_RE = re.compile(r"^[A-Za-z0-9_.:-]{8,128}$")

AudioInput = Union[str, "os.PathLike[str]", bytes, bytearray, IO[bytes]]


def new_idempotency_key(prefix: str = "tp") -> str:
    """A fresh key for one recording attempt (letters, digits, dots, dashes, underscores, colons; 8-128 chars).

    Keep the same key when the result is unknown or still pending (timeout,
    dropped connection, an HTML/empty 502/504 from a proxy, ``request_pending``);
    use a new key for a different attempt or after a definite failed response
    (``TonePerfectError.needs_new_key``). Never generate a new key inside an
    automatic retry loop.
    """
    key = f"{prefix}-{uuid.uuid4().hex}-{secrets.token_hex(2)}"
    if not _IDEMPOTENCY_RE.match(key):
        raise ValueError("prefix must be letters, digits, dots, dashes, underscores or colons")
    return key


class TonePerfectError(Exception):
    """Raised for any non-2xx response, and for transport failures (``status`` 0).

    ``code`` and ``message`` come from the API's ``error`` object
    (``{"error": {"code": ..., "message": ...}, "request_id": ...}``). A non-JSON
    body (for example an HTML 502 from a proxy) gets ``code="http_error"`` and the
    raw text as the message.

    What to do next is decided by the *body*, not the status:

    * ``finalized`` — the failure was stored under this Idempotency-Key (the body
      carries a ``req_…`` ``id`` and ``billing`` with ``credits: 0``; for example
      ``engine_unavailable`` or ``request_interrupted`` after the request was
      accepted). Retrying with the same key replays this same failure for 24 hours:
      ``needs_new_key`` is True and ``retryable`` is False.
    * ``retryable`` — nothing was finalized; retry later with the **same** key
      (``rate_limit``, ``account_busy``, ``gateway_busy``, ``decoder_busy``,
      ``audio_decoder_unavailable``, ``upload_timeout``, ``request_pending``,
      transport ``timeout`` / ``network_error``, and any non-finalized 5xx such as
      an HTML or empty 502/504 from a proxy).
    * Everything else (``invalid_api_key``, ``insufficient_credits``,
      ``invalid_audio``, ``unsupported_language``, …) needs a fix on your side.
    """

    def __init__(self, status: int, code: str, message: str, request_id: Optional[str] = None, retry_after: Optional[float] = None,
                 body: Optional[Dict[str, Any]] = None):
        super().__init__(f"{status} {code}: {message}")
        self.status = status
        self.code = code
        self.message = message
        self.request_id = request_id
        self.retry_after = retry_after
        self.body: Dict[str, Any] = body or {}
        #: ``req_…`` result id when the failure was finalized under your Idempotency-Key.
        self.id: Optional[str] = self.body.get("id") if isinstance(self.body.get("id"), str) else None
        self.billing: Optional[Dict[str, Any]] = self.body.get("billing") if isinstance(self.body.get("billing"), dict) else None

    @property
    def finalized(self) -> bool:
        """The failure is a stored result for this key (``id`` + ``billing`` present)."""
        return self.id is not None and self.billing is not None

    @property
    def needs_new_key(self) -> bool:
        """Start a new attempt with a new Idempotency-Key; the old key replays this response."""
        return self.finalized or self.code in NEW_KEY_CODES

    @property
    def retryable(self) -> bool:
        """Retry later with the SAME Idempotency-Key: nothing was finalized."""
        if self.finalized or self.code in NEW_KEY_CODES:
            return False
        return self.code in RETRY_SAME_KEY_CODES or self.status in (408, 429, 502, 503, 504)


class AuthenticationError(TonePerfectError):
    """401 — missing, revoked or unknown API key (``invalid_api_key``)."""


class PaymentRequiredError(TonePerfectError):
    """402 — nothing was charged. ``code`` says why: ``subscription_required`` (the 50 free
    credits are used up and there is no active plan), ``insufficient_credits`` (plan balance
    is empty, or the recording needs more free credits than remain) or ``payment_balance_due``
    (a refunded/disputed purchase left a balance). Fix it in the dashboard:
    https://api.toneperfect.app/dashboard"""


class RateLimitError(TonePerfectError):
    """429 — ``rate_limit`` (60 assessments/minute) or ``account_busy`` (2 running). Retry with the SAME key; see ``retry_after``."""


class ValidationError(TonePerfectError):
    """400/409/413/422 — the request needs a fix (``invalid_audio``, ``unsupported_language``,
    ``invalid_reference``, ``upload_too_large``, ``idempotency_conflict``, …)."""


class ServerError(TonePerfectError):
    """5xx — ``engine_unavailable``, ``request_interrupted`` or a proxy 502/504. Check ``retryable`` / ``needs_new_key``."""


class APIConnectionError(TonePerfectError):
    """Transport failure (``status`` 0): ``timeout`` or ``network_error``. The outcome is unknown: retry with the same key."""


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


@dataclass
class Assessment:
    """One ``POST /v1/assess`` result.

    ``data`` is the full JSON body exactly as returned by the API. The
    properties below are convenience accessors for its documented top-level
    fields; anything else (``syllables``, evidence, timings) is in ``data``.
    """

    data: Dict[str, Any]
    status: int
    request_id: Optional[str] = None
    replayed: bool = False
    headers: Dict[str, str] = field(default_factory=dict)

    @property
    def assessable(self) -> bool:
        """False when the audio could not be meaningfully scored (silence, wrong sentence, unreadable).
        Never show an unassessable result as a score of zero; see ``reason``."""
        return bool(self.data.get("assessable"))

    @property
    def reason(self) -> Optional[str]:
        return self.data.get("reason")

    @property
    def scores(self) -> Dict[str, Optional[float]]:
        """0-100 display grades per dimension; ``None`` means the dimension is not supported by this pack."""
        return self.data.get("scores") or {}

    @property
    def overall(self) -> Optional[float]:
        return self.scores.get("overall")

    @property
    def words(self) -> List[Dict[str, Any]]:
        """Per word/character rows: grade, ``start_ms``/``end_ms`` and ``phones`` (expected, heard, score, decision; see :data:`DECISIONS`)."""
        return self.data.get("words") or []

    @property
    def billing(self) -> Dict[str, Any]:
        """``{"credits": charged, "balance_credits": remaining}``; failed or unassessable requests charge 0."""
        return self.data.get("billing") or {}

    @property
    def model_version(self) -> Optional[str]:
        return self.data.get("model_version")

    @property
    def id(self) -> Optional[str]:
        """Result id (``req_...``), also returned in the ``X-Request-Id`` header."""
        return self.data.get("id") or self.request_id


class TonePerfect:
    """Client for https://api.toneperfect.app.

    :param api_key: secret key from the dashboard (``tp_live_...``). Defaults to ``$TONEPERFECT_API_KEY``.
    :param base_url: API origin. ``https://api.toneperfect.app`` goes through a proxy with a
        26-second request timeout; if your assessments run longer than that, ask
        nik@toneperfect.app for the direct gateway address and pass it here.
    :param timeout: socket timeout in seconds for each request.
    """

    def __init__(self, api_key: Optional[str] = None, base_url: str = DEFAULT_BASE_URL, timeout: float = 90.0, user_agent: Optional[str] = None):
        self.api_key = api_key or os.environ.get("TONEPERFECT_API_KEY", "")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.user_agent = user_agent or f"toneperfect-python/{__version__}"

    # ---- public endpoints ----

    def capabilities(self) -> Dict[str, Any]:
        """``GET /v1/capabilities``: ``languages`` (locale, status, dimensions, limitations), ``limits``, ``model_version``.

        No API key required. Check ``status`` per language before sending it; every pack is
        currently labelled ``experimental``.
        """
        status, headers, body = self._send("GET", "/v1/capabilities", None, {})
        return self._json(status, headers, body)

    def assess(
        self,
        audio: AudioInput,
        *,
        text: Optional[str] = None,
        language: str = "zh-CN",
        pinyin: Optional[str] = None,
        task: str = "general",
        idempotency_key: Optional[str] = None,
        filename: str = "recording.wav",
        content_type: str = "application/octet-stream",
    ) -> Assessment:
        """``POST /v1/assess``: score one scripted recording against its reference text.

        :param audio: path, bytes, or a binary file object. Up to 30 s and 10 MB
            (WAV, MP3, M4A, OGG, WebM...).
        :param text: what the learner was asked to read. Required unless ``pinyin`` is given (Mandarin only).
        :param language: locale such as ``zh-CN``, ``en-US``, ``fr-FR`` — see :meth:`capabilities`.
        :param pinyin: optional explicit Mandarin reading with numbered tones, e.g. ``"ni3 hao3"``.
        :param task: ``general`` (default), ``connected_speech`` or ``isolated_word``. Mandarin
            per-component correction decisions apply only with ``connected_speech``.
        :param idempotency_key: unique per recording attempt; generated when omitted. If a
            network error prevents you from receiving a result, retry with the same key and
            identical inputs: a completed request is returned without charging again — including
            a completed failure (``Assessment.replayed`` / ``TonePerfectError.finalized``). Use a
            new key for a different attempt or after a definite failed response
            (``TonePerfectError.needs_new_key``). Keep the same key while the result is unknown or
            pending (``TonePerfectError.retryable``).
        :raises TonePerfectError: for every non-2xx status (``error.code`` is in ``.code``) and
            for transport failures (``status`` 0, code ``timeout`` or ``network_error``).
        """
        if not self.api_key:
            raise AuthenticationError(401, "invalid_api_key", "Set api_key or the TONEPERFECT_API_KEY environment variable.")
        if task not in TASKS:
            raise ValueError(f"task must be one of {TASKS}")
        if not (text or pinyin):
            raise ValueError("Provide text (or pinyin for Mandarin).")
        key = idempotency_key or new_idempotency_key()
        if not _IDEMPOTENCY_RE.match(key):
            raise ValueError("idempotency_key must be 8-128 letters, digits, dots, dashes, underscores or colons")

        fields: Dict[str, str] = {"language": language, "task": task}
        if text:
            fields["text"] = text
        if pinyin:
            fields["pinyin"] = pinyin
        body, boundary = _multipart(fields, "audio", filename, content_type, _read_audio(audio))
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Idempotency-Key": key,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        }
        status, response_headers, raw = self._send("POST", "/v1/assess", body, headers)
        data = self._json(status, response_headers, raw)
        return Assessment(
            data=data,
            status=status,
            request_id=response_headers.get("x-request-id"),
            replayed=response_headers.get("idempotent-replayed", "").lower() == "true",
            headers=response_headers,
        )

    # ---- transport ----

    def _send(self, method: str, path: str, body: Optional[bytes], headers: Mapping[str, str]):
        req = _request.Request(self.base_url + path, data=body, method=method)
        req.add_header("Accept", "application/json")
        req.add_header("User-Agent", self.user_agent)
        for name, value in headers.items():
            req.add_header(name, value)
        timeout_error = APIConnectionError(0, "timeout", f"No response within {self.timeout}s; the outcome is unknown, retry with the same Idempotency-Key.")
        try:
            try:
                with _request.urlopen(req, timeout=self.timeout) as response:  # noqa: S310 - fixed https origin
                    return response.status, {k.lower(): v for k, v in response.headers.items()}, response.read()
            except HTTPError as error:  # a subclass of URLError: handle first
                return error.code, {k.lower(): v for k, v in error.headers.items()}, error.read()
        except URLError as error:
            # Timeouts while connecting or sending are wrapped in URLError by urllib.
            if isinstance(error.reason, (socket.timeout, TimeoutError)):
                raise timeout_error from error
            raise APIConnectionError(0, "network_error", f"Could not reach {self.base_url}: {error.reason}") from error
        except (socket.timeout, TimeoutError) as error:
            # Timeouts while waiting for or reading the response surface bare (OSError on 3.9).
            raise timeout_error from error
        except (OSError, http.client.HTTPException) as error:  # reset connections, TLS failures, truncated bodies
            raise APIConnectionError(0, "network_error", f"Could not reach {self.base_url}: {error}") from error

    @staticmethod
    def _json(status: int, headers: Mapping[str, str], raw: bytes) -> Dict[str, Any]:
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
        if isinstance(data, dict) and isinstance(data.get("error"), dict):
            err = data["error"]
            raise _error_class(status)(status, str(err.get("code", "request_error")), str(err.get("message", "")), data.get("request_id") or headers.get("x-request-id"), retry_after, data)
        snippet = raw[:200].decode("utf-8", "replace").strip() if raw else ""
        raise _error_class(status)(status, "http_error", snippet or f"HTTP {status}", headers.get("x-request-id"), retry_after)


# ---- helpers ----

def _read_audio(audio: AudioInput) -> bytes:
    if isinstance(audio, (bytes, bytearray)):
        return bytes(audio)
    if hasattr(audio, "read"):
        data = audio.read()  # type: ignore[union-attr]
        if isinstance(data, str):
            raise TypeError("Open audio files in binary mode ('rb').")
        return data
    with open(os.fspath(audio), "rb") as handle:  # type: ignore[arg-type]
        return handle.read()


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

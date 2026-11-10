"""A local stand-in for https://api.toneperfect.app, for the SDK tests (standard library only).

It follows the live gateway's request rules (2026-11-10) and the test-key behaviour (oob_api/testmode.py):
fixed example results, TonePerfect-Test-Outcome rehearsals, Idempotency-Key replays and conflicts.

    python3 testing/mock_api.py [--port 0] [--gateway live|1110]

prints ``http://127.0.0.1:<port>`` on its first line, then serves until killed.

--gateway live (default): Idempotency-Key required (8-128 of A-Z a-z 0-9 _ . : -), Bearer case-sensitive, a 402 without
links. --gateway 1110: the 2026-11-10 gateway wave (key optional and echoed, any printable ASCII up to 255, a 402 with
billing_url, pricing_url and plan, subscription_past_due).

Test hooks (never sent by the SDKs on their own):
- header ``X-Mock-Fail: <code>:<n>``: the first n attempts with that Idempotency-Key fail with <code>
  (gateway_busy/engine_unavailable -> 503, account_busy/rate_limit -> 429, upload_timeout -> 408, html502 -> an HTML 502),
  Retry-After 0.
- header ``X-Mock-Delay: <seconds>``: sleep before answering.
- ``GET /_mock/log``: every /v1 request seen (method, path, idempotency key, authorization scheme, fields).
"""
import argparse
import email.parser
import email.policy
import hashlib
import json
import os
import re
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
CAPABILITIES = json.load(open(os.path.join(HERE, "fixtures", "capabilities.json"), encoding="utf-8"))
STATUS = json.load(open(os.path.join(HERE, "fixtures", "status.json"), encoding="utf-8"))
LOCALES = [entry["locale"] for entry in CAPABILITIES["languages"]]
LIVE_KEY_RE = re.compile(r"^[A-Za-z0-9_.:-]{8,128}$")
CYCLE = (88.0, 64.0, 92.0, 41.0, 79.0)
OUTCOMES = {
    "invalid_assessment": (422, "The engine could not assess this reference: example refusal from a test key."),
    "engine_unavailable": (503, "The engine could not finish this assessment. No credits were charged."),
    "subscription_required": (402, "Your free credits are used up. Start or renew a monthly plan to keep assessing; any plan credits you have remain in your account."),
    "subscription_past_due": (402, "Your monthly plan's renewal payment failed or is not confirmed yet. Plan credits are kept."),
    "insufficient_credits": (402, "Purchase a credit pack before sending an assessment."),
    "account_busy": (429, "2 assessment(s) are already running for this account. Retry shortly with the same Idempotency-Key."),
    "rate_limit": (429, "Maximum 60 assessment requests per minute per account."),
}
FAIL_STATUS = {"gateway_busy": 503, "engine_unavailable": 503, "decoder_busy": 503, "account_busy": 429, "rate_limit": 429,
               "upload_timeout": 408, "html502": 502, "request_pending": 409}


class State:
    lock = threading.Lock()
    stored = {}      # idempotency key -> (fingerprint, status, body)
    attempts = {}    # idempotency key -> count
    log = []
    gateway = "live"


def parse_multipart(content_type, body):
    message = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
        b"Content-Type: " + content_type.encode("latin-1") + b"\r\n\r\n" + body)
    fields, files = {}, {}
    if not message.is_multipart():
        return None, None
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if not name:
            continue
        if part.get_filename() is not None:
            files[name] = (part.get_filename(), part.get_content_type(), part.get_payload(decode=True) or b"")
        else:
            fields[name] = (part.get_payload(decode=True) or b"").decode("utf-8")
    return fields, files


def words_for(text, language):
    if language == "zh-CN" and re.search(r"[㐀-鿿]", text):
        units = [c for c in text if "㐀" <= c <= "鿿"]
    else:
        units = text.split()
    out = []
    for i, unit in enumerate(units[:40]):
        score = CYCLE[i % len(CYCLE)]
        decision = "review" if score < 60 else "no_correction"
        if language == "zh-CN":
            phones = [{"dimension": d, "expected": None, "heard": None, "score": s, "decision": "no_correction" if d != "tone" else decision}
                      for d, s in (("initial", 90.0), ("final", 84.0), ("tone", score))]
        else:
            phones = [{"dimension": "phoneme", "expected": None, "heard": None, "score": score, "decision": decision}]
        out.append({"word": unit, "pinyin": None, "score": score, "start_ms": 200 + 300 * i, "end_ms": 480 + 300 * i,
                    "decision": decision, "phones": phones})
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quiet
        pass

    def send(self, status, body, headers=None, raw=None, content_type="application/json"):
        data = raw if raw is not None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def error(self, status, code, message, headers=None, extra=None):
        body = {"error": {"code": code, "message": message}, "request_id": "req_mock_" + uuid.uuid4().hex[:12]}
        if extra:
            body.update(extra)
        self.send(status, body, {"X-Request-Id": body["request_id"], **(headers or {})})

    def do_GET(self):
        if self.path == "/_mock/log":
            with State.lock:
                return self.send(200, State.log)
        if self.path == "/v1/capabilities":
            return self.send(200, CAPABILITIES)
        if self.path == "/v1/status":
            return self.send(200, STATUS)
        if self.path == "/v1/assess":
            return self.error(401, "invalid_api_key", "Provide an active API key using Authorization: Bearer YOUR_KEY.")
        return self.error(404, "not_found", "Page not found.")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.headers.get("X-Mock-Delay"):
            time.sleep(float(self.headers["X-Mock-Delay"]))
        if self.path == "/v1/lint":
            if (self.headers.get("Content-Type") or "").split(";")[0] != "application/json":
                return self.error(415, "invalid_content_type", "Send JSON with Content-Type: application/json.")
            data = json.loads(body or b"{}")
            text = data.get("text", "")
            issues = [] if text else [{"code": "empty", "message": "Provide a reference text.", "field": "text", "severity": "error"}]
            return self.send(200, {"ok": not issues, "language": data.get("language", "zh-CN"), "issues": issues, "units": len(text.split()) or len(text)})
        if self.path.rstrip("/") == "/v1/assess" and self.path.endswith("/"):
            return self.send(405, {"detail": "Method Not Allowed"})
        if self.path != "/v1/assess":
            return self.error(404, "not_found", "Page not found.")
        return self.assess(body)

    def assess(self, body):
        new = State.gateway == "1110"
        auth = self.headers.get("Authorization", "")
        if new:
            match = re.match(r"^\s*(?:bearer\s+)?(\S+)\s*$", auth, re.I)
            token = match.group(1) if match else self.headers.get("X-Api-Key", "")
        else:
            token = auth[7:] if auth.startswith("Bearer ") else self.headers.get("X-Api-Key", "")
        key = self.headers.get("Idempotency-Key")
        fields, files = parse_multipart(self.headers.get("Content-Type", ""), body)
        with State.lock:
            State.log.append({"path": self.path, "idempotency_key": key, "auth_scheme": auth.split(" ")[0] if auth else None,
                              "x_api_key": bool(self.headers.get("X-Api-Key")), "fields": fields, "user_agent": self.headers.get("User-Agent"),
                              "audio": None if not files or "audio" not in files else {"filename": files["audio"][0], "content_type": files["audio"][1], "bytes": len(files["audio"][2])},
                              "test_outcome": self.headers.get("TonePerfect-Test-Outcome"), "compact": self.headers.get("TonePerfect-Response")})
        if not token.startswith("tp_test_") and not token.startswith("tp_live_"):
            return self.error(401, "invalid_api_key", "Provide an active API key using Authorization: Bearer YOUR_KEY.")
        echo = {}
        if new:
            if key is None:
                key = "auto-" + uuid.uuid4().hex
            elif not (0 < len(key) <= 255 and all(32 <= ord(c) < 127 for c in key)):
                return self.error(422, "invalid_idempotency_key", "The Idempotency-Key header must be at most 255 printable ASCII characters.")
            echo = {"Idempotency-Key": key}
        elif not key or not LIVE_KEY_RE.match(key):
            return self.error(422, "invalid_idempotency_key", "Send an Idempotency-Key of 8-128 letters, digits, dots, dashes, underscores or colons.")
        fail = self.headers.get("X-Mock-Fail")
        if fail:
            code, _, times = fail.partition(":")
            with State.lock:
                State.attempts[key] = State.attempts.get(key, 0) + 1
                count = State.attempts[key]
            if count <= int(times or 1):
                status = FAIL_STATUS.get(code, 503)
                if code == "html502":
                    return self.send(502, None, raw=b"<html><body>Bad gateway</body></html>", content_type="text/html")
                return self.error(status, code, f"Mock failure {count} of {times}.", {"Retry-After": "0"})
        if fields is None or not files or "audio" not in files:
            return self.error(422, "missing_audio", "Attach a recording in the audio field.")
        text, pinyin = fields.get("text", "").strip(), fields.get("pinyin", "").strip()
        language = fields.get("language", "").strip()
        if not language:
            if new and not re.search(r"[㐀-鿿]", text):
                return self.error(422, "missing_language", "Send the language field, for example language=en-US.")
            language = "zh-CN"
        if not (text or pinyin):
            return self.error(422, "invalid_reference", "Provide a reference text (up to 2000 characters) or Mandarin pinyin.")
        if language not in LOCALES:
            return self.error(422, "unsupported_language", "Choose an available locale from GET /v1/capabilities.")
        if language == "zh-CN" and not re.search(r"[㐀-鿿]", text) and not re.search(r"[1-5]|[āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ]", text + pinyin):
            return self.error(422, "invalid_assessment", "The engine could not assess this reference: Mandarin text must contain Chinese characters (汉字) or pinyin with tones (ni3 hao3 or nǐ hǎo).")
        fingerprint = hashlib.sha256(json.dumps([language, text, pinyin, fields.get("task", "general")], ensure_ascii=False).encode() + files["audio"][2]).hexdigest()
        with State.lock:
            stored = State.stored.get(key)
        if stored:
            if stored[0] != fingerprint:
                return self.error(409, "idempotency_conflict", "This Idempotency-Key was already used for a different request.")
            return self.send(stored[1], stored[2], {"Idempotent-Replayed": "true", "X-Request-Id": stored[2].get("id", ""), **echo})
        outcome = (self.headers.get("TonePerfect-Test-Outcome") or "success").strip().lower()
        if outcome not in OUTCOMES and outcome not in ("success", "unassessable"):
            return self.error(422, "invalid_test_outcome", "Unknown TonePerfect-Test-Outcome.")
        if outcome == "subscription_past_due" and not new:
            return self.error(422, "invalid_test_outcome", "Unknown TonePerfect-Test-Outcome.")
        rid = "req_mock_" + uuid.uuid4().hex[:12]
        billing = {"credits": 0, "balance_credits": 2500, "free_credits": 50, "source": "test"}
        if outcome in OUTCOMES:
            status, message = OUTCOMES[outcome]
            extra = {}
            if status in (422, 503):
                extra = {"id": rid, "billing": billing}
            error = {"code": outcome, "message": message}
            if status == 402 and new:
                error.update({"billing_url": "https://api.toneperfect.app/dashboard?tab=billing", "pricing_url": "https://api.toneperfect.app/pricing/",
                              "plan": {"id": "starter", "name": "Starter", "monthly_credits": 2500, "price_usd": 10, "interval": "month"}})
            payload = {"error": error, "request_id": rid, **extra}
            headers = {"X-Request-Id": rid, "X-TonePerfect-Test": "true", **echo}
            if status == 429:
                headers["Retry-After"] = "0"
            if status == 422:
                with State.lock:
                    State.stored[key] = (fingerprint, status, payload)
            return self.send(status, payload, headers)
        words = words_for(text or pinyin, language)
        scores = {"overall": 78.0, "pronunciation": 74.0, "fluency": None, "rhythm": None}
        scores.update({"initial": 82.0, "final": 76.0, "tone": 61.0} if language == "zh-CN" else {"integrity": 100.0})
        result = {"id": rid, "language": language.split("-")[0], "locale": language, "model_version": "test-fixture-v1", "task": fields.get("task", "general"),
                  "status": "completed", "assessable": outcome == "success", "reason": None if outcome == "success" else "no_speech", "test": True,
                  "scores": scores if outcome == "success" else {k: None for k in scores}, "words": words if outcome == "success" else [],
                  "warnings": ["Test key: fixed example response. No audio was scored and no credits were charged."],
                  "engine_route": {"engine": "primary", "fallback": False, "reason": None}, "billing": billing}
        if self.headers.get("TonePerfect-Response") == "compact":
            result = {"schema": "toneperfect.compact.v1", "id": rid, "assessable": result["assessable"], "reason": result["reason"], "locale": language,
                      "task": result["task"], "model_version": "test-fixture-v1", "scores": {**scores, "completeness": scores.get("integrity")},
                      "words": [{"text": w["word"], "pinyin": w["pinyin"], "score": w["score"], "start_ms": w["start_ms"], "end_ms": w["end_ms"],
                                 "decision": w["decision"], "units": w["phones"]} for w in result["words"]],
                      "warnings": result["warnings"], "engine_route": result["engine_route"], "billing": billing, "test": True}
        with State.lock:
            State.stored[key] = (fingerprint, 200, result)
        self.send(200, result, {"X-Request-Id": rid, "X-TonePerfect-Test": "true", "X-TonePerfect-Credits-Charged": "0", **echo})


def serve(port=0, gateway="live"):
    State.gateway = gateway
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--gateway", choices=["live", "1110"], default="live")
    args = parser.parse_args()
    server, url = serve(args.port, args.gateway)
    print(url, flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        server.shutdown()
        sys.exit(0)

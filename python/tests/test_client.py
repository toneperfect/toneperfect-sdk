"""Offline tests: the transport is faked, nothing touches the network.  Run: python -m unittest discover -s tests -v"""
import io
import json
import re
import socket
import unittest
from unittest import mock
from urllib.error import HTTPError, URLError

import toneperfect
from toneperfect import Assessment, TonePerfect, TonePerfectError, new_idempotency_key


class FakeResponse(io.BytesIO):
    def __init__(self, status, body, headers=None):
        super().__init__(body)
        self.status = status
        self.headers = {"Content-Type": "application/json", **(headers or {})}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def http_error(status, body, headers=None):
    hdrs = mock.MagicMock()
    hdrs.items.return_value = list((headers or {}).items())
    return HTTPError("https://api.toneperfect.app/v1/assess", status, "err", hdrs, io.BytesIO(body))


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.client = TonePerfect(api_key="tp_live_test", base_url="https://api.toneperfect.app/")

    def test_assess_sends_real_contract(self):
        body = json.dumps({"assessable": True, "scores": {"overall": 86, "tone": 80, "fluency": None}, "words": [], "billing": {"credits": 1, "balance_credits": 2499}, "model_version": "mandarin-human-v2-x", "id": "req_1"}).encode()
        with mock.patch.object(toneperfect._request, "urlopen", return_value=FakeResponse(200, body, {"X-Request-Id": "req_1"})) as urlopen:
            result = self.client.assess(b"RIFF....", text="你好", language="zh-CN", pinyin="ni3 hao3", task="connected_speech", idempotency_key="lesson-42-attempt-1", filename="hello.wav")
        req = urlopen.call_args.args[0]
        self.assertEqual(req.full_url, "https://api.toneperfect.app/v1/assess")
        self.assertEqual(req.get_method(), "POST")
        self.assertEqual(req.get_header("Authorization"), "Bearer tp_live_test")
        self.assertEqual(req.get_header("Idempotency-key"), "lesson-42-attempt-1")
        self.assertTrue(req.get_header("Content-type").startswith("multipart/form-data; boundary="))
        raw = req.data.decode("utf-8", "replace")
        for field, value in (("text", "你好"), ("language", "zh-CN"), ("pinyin", "ni3 hao3"), ("task", "connected_speech")):
            self.assertIn(f'name="{field}"\r\n\r\n{value}\r\n', raw)
        self.assertIn('name="audio"; filename="hello.wav"', raw)
        self.assertIn("RIFF....", raw)
        self.assertIsInstance(result, Assessment)
        self.assertTrue(result.assessable)
        self.assertEqual(result.overall, 86)
        self.assertIsNone(result.scores["fluency"])
        self.assertEqual(result.billing["credits"], 1)
        self.assertEqual(result.model_version, "mandarin-human-v2-x")
        self.assertEqual(result.id, "req_1")
        self.assertFalse(result.replayed)

    def test_replay_header_and_generated_key(self):
        body = json.dumps({"assessable": False, "reason": "silence", "scores": {"overall": None}, "billing": {"credits": 0, "balance_credits": 5}}).encode()
        with mock.patch.object(toneperfect._request, "urlopen", return_value=FakeResponse(200, body, {"Idempotent-Replayed": "true"})) as urlopen:
            result = self.client.assess(io.BytesIO(b"abc"), text="hi", language="en-US")
        key = urlopen.call_args.args[0].get_header("Idempotency-key")
        self.assertRegex(key, r"^[A-Za-z0-9_.:-]{8,128}$")
        self.assertTrue(result.replayed)
        self.assertFalse(result.assessable)
        self.assertEqual(result.reason, "silence")
        self.assertEqual(result.billing["credits"], 0)

    def test_api_error_is_typed(self):
        body = json.dumps({"error": {"code": "insufficient_credits", "message": "Purchase a credit pack."}, "request_id": "req_9"}).encode()
        with mock.patch.object(toneperfect._request, "urlopen", side_effect=http_error(402, body, {"X-Request-Id": "req_9"})):
            with self.assertRaises(TonePerfectError) as ctx:
                self.client.assess(b"x", text="hi", language="en-US")
        self.assertEqual((ctx.exception.status, ctx.exception.code, ctx.exception.request_id), (402, "insufficient_credits", "req_9"))
        self.assertIsInstance(ctx.exception, toneperfect.PaymentRequiredError)
        self.assertFalse(ctx.exception.retryable)

    def test_typed_error_classes(self):
        for status, cls in ((401, toneperfect.AuthenticationError), (402, toneperfect.PaymentRequiredError), (429, toneperfect.RateLimitError), (422, toneperfect.ValidationError), (503, toneperfect.ServerError)):
            body = json.dumps({"error": {"code": "x", "message": "m"}}).encode()
            with mock.patch.object(toneperfect._request, "urlopen", side_effect=http_error(status, body)):
                with self.assertRaises(cls):
                    self.client.capabilities()

    def _error(self, status, body, headers=None):
        with mock.patch.object(toneperfect._request, "urlopen", side_effect=http_error(status, json.dumps(body).encode(), headers)):
            with self.assertRaises(TonePerfectError) as ctx:
                self.client.assess(b"x", text="hi", language="en-US", idempotency_key="lesson-42-attempt-1")
        return ctx.exception

    def test_finalized_failure_needs_a_new_key(self):
        # engine_unavailable AFTER the request was accepted: stored under the key and replayed for 24 h.
        error = self._error(503, {"error": {"code": "engine_unavailable", "message": "No credits were charged."}, "id": "req_77", "billing": {"credits": 0, "balance_credits": 12}}, {"Idempotent-Replayed": "true"})
        self.assertEqual((error.code, error.id, error.billing), ("engine_unavailable", "req_77", {"credits": 0, "balance_credits": 12}))
        self.assertTrue(error.finalized)
        self.assertTrue(error.needs_new_key)
        self.assertFalse(error.retryable, "same key would replay the failure forever")
        interrupted = self._error(503, {"error": {"code": "request_interrupted", "message": "Interrupted."}, "id": "req_78", "billing": {"credits": 0, "balance_credits": 12}})
        self.assertTrue(interrupted.needs_new_key and not interrupted.retryable)

    def test_not_finalized_failures_retry_with_the_same_key(self):
        for status, code in ((409, "request_pending"), (429, "rate_limit"), (429, "account_busy"), (503, "gateway_busy"), (503, "decoder_busy"), (503, "audio_decoder_unavailable"), (408, "upload_timeout"), (503, "engine_unavailable")):
            error = self._error(status, {"error": {"code": code, "message": "later"}, "request_id": "req_x"}, {"Retry-After": "1"})
            self.assertTrue(error.retryable, code)
            self.assertFalse(error.needs_new_key, code)
            self.assertFalse(error.finalized, code)
            self.assertEqual(error.retry_after, 1.0)

    def test_spent_keys_and_client_errors(self):
        for status, code in ((409, "idempotency_expired"), (409, "idempotency_conflict")):
            error = self._error(status, {"error": {"code": code, "message": "new key"}})
            self.assertTrue(error.needs_new_key, code)
            self.assertFalse(error.retryable, code)
        for status, code in ((401, "invalid_api_key"), (402, "insufficient_credits"), (422, "invalid_audio"), (422, "unsupported_language"), (413, "upload_too_large")):
            error = self._error(status, {"error": {"code": code, "message": "fix"}})
            self.assertFalse(error.retryable, code)
            self.assertFalse(error.needs_new_key, code)

    def test_transport_failures(self):
        cases = [
            (URLError(socket.timeout("timed out")), "timeout"),
            (URLError(TimeoutError("timed out")), "timeout"),
            (URLError(ConnectionRefusedError(61, "refused")), "network_error"),
            (socket.timeout("read timed out"), "timeout"),
            (TimeoutError("read timed out"), "timeout"),
            (ConnectionResetError(54, "reset"), "network_error"),
        ]
        for raised, code in cases:
            with mock.patch.object(toneperfect._request, "urlopen", side_effect=raised):
                with self.assertRaises(TonePerfectError) as ctx:
                    self.client.assess(b"x", text="hi", language="en-US")
            self.assertEqual((ctx.exception.status, ctx.exception.code), (0, code), repr(raised))
            self.assertTrue(ctx.exception.retryable, "nothing finalized: same key is safe")
            self.assertFalse(ctx.exception.needs_new_key)

    def test_read_timeout_after_headers(self):
        class Hanging(FakeResponse):
            def read(self, *a):
                raise socket.timeout("read timed out")
        with mock.patch.object(toneperfect._request, "urlopen", return_value=Hanging(200, b"")):
            with self.assertRaises(TonePerfectError) as ctx:
                self.client.capabilities()
        self.assertEqual(ctx.exception.code, "timeout")

    def test_proxy_html_error(self):
        with mock.patch.object(toneperfect._request, "urlopen", side_effect=http_error(504, b"<html>Gateway Timeout</html>")):
            with self.assertRaises(TonePerfectError) as ctx:
                self.client.capabilities()
        self.assertEqual((ctx.exception.status, ctx.exception.code), (504, "http_error"))
        self.assertTrue(ctx.exception.retryable, "unrecognized 502/504: outcome unknown, same key")
        self.assertFalse(ctx.exception.needs_new_key)
        with mock.patch.object(toneperfect._request, "urlopen", side_effect=http_error(502, b"")):
            with self.assertRaises(TonePerfectError) as ctx:
                self.client.capabilities()
        self.assertTrue(ctx.exception.retryable, "empty 502")

    def test_capabilities_needs_no_key(self):
        body = json.dumps({"languages": [{"locale": "zh-CN", "status": "experimental"}], "limits": {"max_audio_seconds": 30}}).encode()
        with mock.patch.object(toneperfect._request, "urlopen", return_value=FakeResponse(200, body)) as urlopen:
            caps = TonePerfect(api_key="").capabilities()
        self.assertEqual(urlopen.call_args.args[0].full_url, "https://api.toneperfect.app/v1/capabilities")
        self.assertIsNone(urlopen.call_args.args[0].get_header("Authorization"))
        self.assertEqual(caps["languages"][0]["locale"], "zh-CN")

    def test_validation(self):
        with self.assertRaises(TonePerfectError):
            TonePerfect(api_key="").assess(b"x", text="hi")
        with self.assertRaises(ValueError):
            self.client.assess(b"x", language="en-US")  # no text, no pinyin
        with self.assertRaises(ValueError):
            self.client.assess(b"x", text="hi", task="freestyle")
        with self.assertRaises(ValueError):
            self.client.assess(b"x", text="hi", idempotency_key="short")
        self.assertTrue(re.match(r"^[A-Za-z0-9_.:-]{8,128}$", new_idempotency_key("lesson.42")))


if __name__ == "__main__":
    unittest.main()


class ProxyLevelFailures(unittest.TestCase):
    def test_non_json_429_and_truncated_body_are_retryable_with_the_same_key(self):
        import http.client

        html_429 = toneperfect.TonePerfectError(429, "http_error", "Too Many Requests")
        self.assertTrue(html_429.retryable)
        self.assertFalse(html_429.needs_new_key)

        client = toneperfect.TonePerfect("tp_test", base_url="https://api.example")
        with mock.patch.object(toneperfect._request, "urlopen", side_effect=http.client.IncompleteRead(b"partial")):
            with self.assertRaises(toneperfect.TonePerfectError) as caught:
                client.capabilities()
        self.assertEqual(caught.exception.code, "network_error")
        self.assertTrue(caught.exception.retryable)

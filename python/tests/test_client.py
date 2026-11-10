"""Contract tests against testing/mock_api.py (a local stand-in that follows the live gateway's rules).
Run: PYTHONPATH=src python -m unittest discover -s tests -v"""
import json
import os
import sys
import unittest
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "testing"))
import mock_api  # noqa: E402

import toneperfect  # noqa: E402
from toneperfect import (APIConnectionError, AuthenticationError, PaymentRequiredError, RateLimitError,  # noqa: E402
                         ServerError, TonePerfect, ValidationError)

HELLO = os.path.join(ROOT, "testing", "fixtures", "hello.ogg")
SERVERS = {}


def server(gateway):
    if gateway not in SERVERS:
        SERVERS[gateway] = mock_api.serve(0, gateway)[1]
    return SERVERS[gateway]


def attempts(url, key):
    log = json.load(urllib.request.urlopen(url + "/_mock/log"))
    return [entry for entry in log if entry["idempotency_key"] == key]


class Contract(unittest.TestCase):
    gateway = "live"

    def client(self, **kw):
        self.url = server(self.gateway)
        return TonePerfect("tp_test_mock", base_url=self.url, **kw)

    def test_assess_request_and_typed_result(self):
        result = self.client().assess(HELLO, text="你好", language="zh-CN", task="connected_speech")
        sent = attempts(self.url, result.idempotency_key)[0]
        self.assertEqual(sent["auth_scheme"], "Bearer")
        uuid.UUID(result.idempotency_key)
        self.assertEqual(sent["fields"], {"language": "zh-CN", "task": "connected_speech", "text": "你好"})
        self.assertEqual(sent["audio"]["filename"], "hello.ogg")
        self.assertEqual(sent["audio"]["content_type"], "audio/ogg")
        self.assertEqual(sent["user_agent"], f"toneperfect-python/{toneperfect.__version__}")
        self.assertTrue(result.assessable and result.test)
        self.assertEqual(result.overall, 78.0)
        self.assertEqual([w.word for w in result.words], ["你", "好"])
        self.assertEqual([p.dimension for p in result.words[0].phones], ["initial", "final", "tone"])
        self.assertEqual(result.words[0]["word"], "你")  # raw access still works
        self.assertEqual((result.billing.credits, result.billing.source), (0, "test"))
        self.assertEqual(result.engine, "primary")

    def test_compact_maps_to_the_same_fields(self):
        with open(HELLO, "rb") as audio:
            result = self.client().assess(audio, text="I like sunny days", language="en-US", compact=True)
        self.assertTrue(result.compact)
        self.assertEqual([w.word for w in result.words], ["I", "like", "sunny", "days"])
        self.assertEqual(result.words[1].phones[0].dimension, "phoneme")

    def test_replay_with_the_same_key(self):
        client, key = self.client(), toneperfect.new_idempotency_key()
        first = client.assess(HELLO, text="你好", language="zh-CN", idempotency_key=key)
        second = client.assess(HELLO, text="你好", language="zh-CN", idempotency_key=key)
        self.assertEqual(first.id, second.id)
        self.assertTrue(second.replayed)

    def test_busy_is_retried_with_the_same_key(self):
        client = self.client(headers={"X-Mock-Fail": "gateway_busy:2"})
        result = client.assess(HELLO, text="你好", language="zh-CN")
        tries = attempts(self.url, result.idempotency_key)
        self.assertEqual(len(tries), 3)
        self.assertEqual({t["idempotency_key"] for t in tries}, {result.idempotency_key})

    def test_proxy_html_502_is_retried(self):
        result = self.client(headers={"X-Mock-Fail": "html502:1"}).assess(HELLO, text="你好", language="zh-CN")
        self.assertEqual(len(attempts(self.url, result.idempotency_key)), 2)

    def test_retries_stop_at_max_retries(self):
        with self.assertRaises(ServerError) as caught:
            self.client(max_retries=0, headers={"X-Mock-Fail": "engine_unavailable:1"}).assess(HELLO, text="你好", language="zh-CN")
        self.assertTrue(caught.exception.retryable)
        self.assertFalse(caught.exception.needs_new_key)
        with self.assertRaises(RateLimitError) as caught:
            self.client(max_retries=1).assess(HELLO, text="你好", language="zh-CN", test_outcome="rate_limit")
        self.assertEqual(len(attempts(self.url, caught.exception.idempotency_key)), 2)

    def test_finalized_failure_needs_a_new_key_and_is_not_retried(self):
        with self.assertRaises(ValidationError) as caught:
            self.client().assess(HELLO, text="你好", language="zh-CN", test_outcome="invalid_assessment")
        error = caught.exception
        self.assertTrue(error.finalized and error.needs_new_key)
        self.assertFalse(error.retryable)
        self.assertTrue(error.id.startswith("req_"))
        self.assertEqual(len(attempts(self.url, error.idempotency_key)), 1)

    def test_payment_required_carries_a_billing_link(self):
        with self.assertRaises(PaymentRequiredError) as caught:
            self.client().assess(HELLO, text="你好", language="zh-CN", test_outcome="subscription_required")
        error = caught.exception
        self.assertEqual(error.code, "subscription_required")
        self.assertEqual(error.billing_url, "https://api.toneperfect.app/dashboard?tab=billing")
        self.assertIn(error.billing_url, str(error))
        self.assertFalse(error.retryable)
        if self.gateway == "1110":
            self.assertEqual(error.plan["name"], "Starter")
            self.assertEqual(error.pricing_url, "https://api.toneperfect.app/pricing/")

    def test_authentication_error(self):
        with self.assertRaises(AuthenticationError):
            TonePerfect("nope", base_url=server(self.gateway)).assess(HELLO, text="你好", language="zh-CN")

    def test_timeout_is_a_connection_error(self):
        with self.assertRaises(APIConnectionError) as caught:
            self.client(timeout=0.3, max_retries=0, headers={"X-Mock-Delay": "1"}).assess(HELLO, text="你好", language="zh-CN")
        self.assertEqual((caught.exception.status, caught.exception.code), (0, "timeout"))
        self.assertTrue(caught.exception.retryable)

    def test_language_is_required(self):
        with self.assertRaises(TypeError):
            self.client().assess(HELLO, text="你好")  # pylint: disable=missing-kwoa
        with self.assertRaises(ValueError):
            self.client().assess(HELLO, text="你好", language="")

    def test_other_endpoints(self):
        client = self.client()
        self.assertIn("zh-CN", [l["locale"] for l in client.capabilities()["languages"]])
        self.assertTrue(client.lint("你好", language="zh-CN")["ok"])
        self.assertIn("status", client.status())

    def test_environment_defaults(self):
        os.environ["TONEPERFECT_BASE_URL"], os.environ["TONEPERFECT_API_KEY"] = "http://example.invalid/", "tp_test_env"
        try:
            client = TonePerfect()
            self.assertEqual((client.base_url, client.api_key, client.max_retries), ("http://example.invalid", "tp_test_env", 2))
        finally:
            del os.environ["TONEPERFECT_BASE_URL"], os.environ["TONEPERFECT_API_KEY"]


class Contract1110(Contract):
    """The 2026-11-10 gateway wave: optional key echoed, richer 402."""
    gateway = "1110"


class Cli(unittest.TestCase):
    def test_lint_cli(self):
        import io
        out = io.StringIO()
        code = toneperfect.main(["lint", "你好", "--base-url", server("live")], out=out)
        self.assertEqual(code, 0)
        self.assertIn("1/1 texts pass", out.getvalue())


if __name__ == "__main__":
    unittest.main()

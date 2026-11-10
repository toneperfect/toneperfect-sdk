# TonePerfect Python client

Client for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app): send a short recording
and the text it should contain, get 0–100 scores for the sentence, every word and every sound, with Mandarin
initial, final and tone per syllable. 10 languages. One file, standard library only, Python 3.9+.

```sh
pip install toneperfect
```

## Try it with a test key

[Sign up](https://api.toneperfect.app/signup) (50 free credits, no card), then in the dashboard open
**API keys** and create a **test key** (`tp_test_…`). A test key runs the real request path but returns a
fixed example result: it never scores your audio and never spends credits. Swap in a live key
(`tp_live_…`) for real scores. Keep keys on a server.

```sh
export TONEPERFECT_API_KEY="tp_test_..."
curl -o hello.ogg https://api.toneperfect.app/capsule/speech-zh-nihao.ogg   # 2 s of 你好
```

```python
from toneperfect import TonePerfect

client = TonePerfect()  # reads TONEPERFECT_API_KEY
result = client.assess("hello.ogg", text="你好", language="zh-CN")

print(result.assessable, result.overall, result.billing.credits, result.test)
for word in result.words:
    for phone in word.phones:
        print(word.word, phone.dimension, phone.expected, phone.heard, phone.score, phone.decision)
```

`language` is required: `zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR`
or `ja-JP` (live list: `client.capabilities()`).

## Results

`assess()` returns an `Assessment`:

| Attribute | Meaning |
| --- | --- |
| `assessable`, `reason` | `False` with a `reason` when the recording could not be scored (silence, another text). Free, and not a score of zero. |
| `overall`, `scores` | 0–100 display grades; `None` = not measured by this language pack. |
| `words` | `Word` objects: `word`, `score`, `start_ms`, `end_ms`, `decision`, `pinyin`, `phones`. |
| `words[i].phones` | `Phone` objects: `dimension` (`phoneme`, or `initial` / `final` / `tone`), `expected`, `heard`, `score`, `decision`. |
| `billing` | `Billing`: `credits` charged, `balance_credits`, `free_credits`, `source` (`free`, `plan` or `test`). |
| `warnings`, `engine`, `model_version`, `id`, `replayed`, `test` | Notes, `primary` or `fallback` engine, model, `req_…` id, replay and test flags. |
| `data` | The JSON body exactly as returned. `word["field"]` reads any raw field too. |

Act on `decision` (`review`, `uncertain`, `no_correction`), not on every low grade. `compact=True` asks for the
versioned `toneperfect.compact.v1` schema; the same attributes work on it.

## Errors, retries and timeouts

Every error is a `TonePerfectError` with the API's `code`, `message`, `status` and `request_id`. Subclasses:
`AuthenticationError` (401), `PaymentRequiredError` (402, with `billing_url` and, when the API sends them,
`pricing_url` and `plan`), `RateLimitError` (429), `ValidationError` (other 4xx), `ServerError` (5xx) and
`APIConnectionError` (timeout or network failure).

The client retries a failure that stored nothing (`error.retryable`: busy, rate limit, upload timeout, engine
unavailable, proxy 502/504, timeout) up to `max_retries` times with the **same** Idempotency-Key, so a result
that finished is returned and charged once. `error.needs_new_key` marks a failure stored under the key
(`invalid_assessment`) or a spent key. A test key rehearses each outcome:

```python
from toneperfect import TonePerfect, PaymentRequiredError, TonePerfectError

client = TonePerfect(timeout=30, max_retries=2)
try:
    client.assess("hello.ogg", text="你好", language="zh-CN", test_outcome="subscription_required")
except PaymentRequiredError as error:
    print(error.code, "->", error.billing_url)
except TonePerfectError as error:
    print(error.status, error.code, error.message, "retry:", error.retryable, "new key:", error.needs_new_key)

unscored = client.assess("hello.ogg", text="你好", language="zh-CN", test_outcome="unassessable")
print(unscored.assessable, unscored.reason)
```

To resend the same recording safely after a crash, keep your own key:

```python
from toneperfect import TonePerfect, new_idempotency_key

client = TonePerfect()
key = new_idempotency_key()  # store it with the recording
first = client.assess("hello.ogg", text="I like sunny days", language="en-US", idempotency_key=key)
again = client.assess("hello.ogg", text="I like sunny days", language="en-US", idempotency_key=key)
print(first.id == again.id, again.replayed)  # the stored result, not charged twice
```

## Other endpoints

```python
from toneperfect import TonePerfect

client = TonePerfect()
print([lang["locale"] for lang in client.capabilities()["languages"]])
print(client.lint("我有3个苹果", language="zh-CN")["issues"])   # free reference-text check, no key
print(client.status()["status"])                                # synthetic engine probe
```

Command line: `python -m toneperfect lint "你好" --language zh-CN` (or `toneperfect-lint`), `--file lesson.csv`.

## Configuration

`TonePerfect(api_key=None, *, base_url=None, timeout=60.0, max_retries=2)`. `api_key` defaults to
`$TONEPERFECT_API_KEY`, `base_url` to `$TONEPERFECT_BASE_URL`, else `https://api.toneperfect.app` (a proxy with a
26-second limit: a longer passage comes back on the automatic retry, charged once).

Grades are display scores calibrated per language against native references, not accuracy percentages and not
comparable across vendors. Every language pack is labelled `experimental` in `/v1/capabilities`.
Docs: https://api.toneperfect.app/docs · MIT licence · nik@toneperfect.app

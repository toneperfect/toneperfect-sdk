# toneperfect (Python)

Client for the [TonePerfect pronunciation assessment API](https://api.toneperfect.app), 10 languages:
`zh-CN`, `en-US`, `fr-FR`, `es-419`, `de-DE`, `it-IT`, `pt-BR`, `ru-RU`, `ko-KR` (beta) and `ja-JP` (beta).
Send a short scripted recording and the text it should contain, get 0–100 scores for the sentence,
every word and every sound in one JSON response, with expected vs heard sounds and timings.
Mandarin syllables also get separate initial, final and tone scores.

One file, standard library only (Python 3.9+), no dependencies.

```sh
pip install toneperfect
```

## Quickstart

```python
from toneperfect import TonePerfect

client = TonePerfect(api_key="tp_live_...")            # or set TONEPERFECT_API_KEY
result = client.assess("hello.wav", text="你好", language="zh-CN")
print(result.assessable, result.scores["overall"], result.billing)
for word in result.words:
    print(word["word"], word["score"], [p for p in word["phones"] if p["decision"] == "review"])
```

Get a key: [create an account](https://api.toneperfect.app/signup) → dashboard → API keys.
New accounts get 50 free credits, no card needed; then plans from $10/month
([pricing](https://api.toneperfect.app/pricing/)). Keep the key on your server —
browser and mobile apps should call your own backend.

## What is wrapped

Only the two public endpoints, with their real field names:

| Method | Endpoint | Notes |
| --- | --- | --- |
| `client.capabilities()` | `GET /v1/capabilities` | No key needed. Languages, `status` (all `experimental` today), dimensions, `limits`, `model_version`. |
| `client.assess(audio, text=, language=, pinyin=, task=, idempotency_key=)` | `POST /v1/assess` | Multipart fields `audio`, `text`, `language`, optional `pinyin` (numbered tones, `ni3 hao3`) and `task` (`general`, `connected_speech`, `isolated_word`). Header `Authorization: Bearer` + `Idempotency-Key`. |

Accounts, keys, usage and billing are dashboard-only (session cookie + origin check)
and are not wrapped.

`assess()` returns an `Assessment`:

- `.data` — the full JSON body, untouched.
- `.assessable` / `.reason` — `False` when the audio could not be meaningfully scored
  (silence, wrong sentence, unreadable). Never show that as a score of zero.
- `.scores` — `overall` plus per-dimension grades; `None` means the dimension is not
  supported by the pack (fluency/rhythm are English and French only).
- `.words` — per word/character: `score`, `start_ms`, `end_ms`, `phones[]` with
  `expected`, `heard`, `score`, `decision`. `decision` is one of `review`, `uncertain`, `no_correction`; `unassessable` (no evidence
for that unit), `partial` (word only partly covered by the phonetic inventory) and
`legacy_correction` (Mandarin components decided by the legacy policy) also occur — treat any
other value as "no decision".
- `.billing` — `{"credits": charged, "balance_credits": remaining}`. Failed or
  unassessable requests charge 0.
- `.model_version`, `.id` (`req_…`), `.replayed` (result served from a previous
  identical request).

Errors raise `TonePerfectError(status, code, message, request_id)` or one of its typed
subclasses: `AuthenticationError` (401), `PaymentRequiredError` (402 — `subscription_required`
when the 50 free credits are used up, `insufficient_credits`, `payment_balance_due`; nothing is
charged), `RateLimitError` (429), `ValidationError` (other 4xx), `ServerError` (5xx) and
`APIConnectionError` (transport).  `code` is the API's
own value (`invalid_api_key`, `subscription_required`, `insufficient_credits`,
`invalid_audio`, `unsupported_language`, `rate_limit`, `account_busy`,
`engine_unavailable`, …); transport failures use status `0` with code `timeout` or
`network_error`. See the next section for `retryable`, `needs_new_key` and `finalized`.

## Safe retries

Every attempt carries a unique `Idempotency-Key` (generated when you do not pass one). If a
network error prevents you from receiving a result, retry with the same key and identical
audio, reference text, language, pinyin and practice type: a completed request is returned
without charging again, including a completed failure. Use a new key for a different attempt
or to try again after a definite failed response. Reusing a key with a different request
returns a conflict. Keep the same key when the result is unknown or still pending, including
an HTML, empty or unrecognized 502/504 proxy response — an HTTP status alone does not prove
that the assessment stopped. A finalized backend failure includes a `req_…` result id,
`billing.credits: 0` and a completed error code such as `engine_unavailable`. Do not generate
a new key inside an automatic retry loop. Stored results expire after 24 hours; an expired key
returns a conflict and never causes another charge.

The client decides this from the response **body**, not the status:

- `error.retryable` — nothing was finalized; retry later with the **same** key
  (`rate_limit`, `account_busy`, `gateway_busy`, `decoder_busy`, `audio_decoder_unavailable`,
  `upload_timeout`, `request_pending`, transport `timeout` / `network_error`, non-JSON 502/504).
- `error.needs_new_key` — the failure was stored under the key (`error.finalized`: `error.id`
  and `error.billing` present) or the key expired; a new attempt needs a new key.
- neither — fix the request (`invalid_api_key`, `insufficient_credits`, `invalid_audio`, …).

`https://api.toneperfect.app` sits behind a proxy with a 26-second request timeout.
Assessments normally finish well inside that; if yours do not, email
nik@toneperfect.app for the direct gateway address and pass it as `base_url`.

## Limits

Up to 30 s and 10 MB of audio per request (WAV, MP3, M4A, OGG, WebM); up to 40 words
(100 Mandarin characters) of reference text; two concurrent requests per account;
scripted speech only — the learner reads the text you send. Audio is deleted after
scoring; results are kept for 24 hours for idempotent replays.

## How the scores are produced

Grades are 0–100 and calibrated per unit against native-speaker references, so a 70 in
Portuguese and a 70 in English are not the same distance from native; they are display
scores, not accuracy percentages, and not comparable across vendors. Correction
decisions are separate from grades: act on `decision`, show the grade. There is no single
published accuracy number, because detection rates depend on the error type, the
context, the learner's first language and the false-accusation budget you accept. Full
detail: [methodology](https://api.toneperfect.app/methodology/).

## Example and tests

```sh
export TONEPERFECT_API_KEY=tp_live_...
python examples/assess_file.py hello.wav 你好 zh-CN
PYTHONPATH=src python -m unittest discover -s tests -v      # offline, transport is faked
```

Documentation: https://api.toneperfect.app/docs · License: MIT

"""Assess one recording and print what the API returned.

    export TONEPERFECT_API_KEY=tp_live_...
    python examples/assess_file.py hello.wav 你好 zh-CN
    python examples/assess_file.py sunny.wav "I like sunny days" en-US
"""
import sys

from toneperfect import TonePerfect, TonePerfectError

if len(sys.argv) < 3:
    sys.exit(__doc__)
path, text = sys.argv[1], sys.argv[2]
language = sys.argv[3] if len(sys.argv) > 3 else "zh-CN"

client = TonePerfect()  # reads TONEPERFECT_API_KEY
try:
    result = client.assess(path, text=text, language=language)
except TonePerfectError as error:
    # error.code is the API's machine-readable code: invalid_api_key,
    # subscription_required, insufficient_credits, invalid_audio, rate_limit...
    sys.exit(f"{error.status} {error.code}: {error.message} (request {error.request_id})")

print("model:", result.model_version, "| request:", result.id, "| replayed:", result.replayed)
print("billing:", result.billing)
if not result.assessable:
    sys.exit(f"not assessable: {result.reason}")
print("scores:", result.scores)
for word in result.words:
    label = word.get("word") or word.get("text")
    print(f"  {label!s:<10} {word.get('score')!s:>4}  {word.get('start_ms')}–{word.get('end_ms')} ms")
    for phone in word.get("phones") or []:
        if phone.get("decision") in ("review", "uncertain"):
            print(f"      {phone.get('dimension') or ''} expected {phone.get('expected')!r} heard {phone.get('heard')!r} → {phone.get('decision')} ({phone.get('score')})")

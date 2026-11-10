"""Assess one recording and print what the API returned.

    export TONEPERFECT_API_KEY=tp_test_...      # or tp_live_... for real scores
    python examples/assess_file.py hello.ogg 你好 zh-CN
    python examples/assess_file.py sunny.wav "I like sunny days" en-US
"""
import sys

from toneperfect import PaymentRequiredError, TonePerfect, TonePerfectError

if len(sys.argv) < 4:
    sys.exit(__doc__)
path, text, language = sys.argv[1:4]

client = TonePerfect()  # reads TONEPERFECT_API_KEY
try:
    result = client.assess(path, text=text, language=language)
except PaymentRequiredError as error:
    sys.exit(f"{error.code}: {error.message} Fix it at {error.billing_url}")
except TonePerfectError as error:
    # error.code is the API's machine-readable code: invalid_api_key, invalid_audio, unsupported_language...
    sys.exit(f"{error.status} {error.code}: {error.message} (request {error.request_id})")

print("model:", result.model_version, "| request:", result.id, "| engine:", result.engine, "| test:", result.test)
print("billing:", result.billing.credits, "credit(s), source", result.billing.source)
if not result.assessable:
    sys.exit(f"not assessable: {result.reason}")
print("scores:", result.scores)
for word in result.words:
    flagged = [f"{p.dimension} {p.expected}->{p.heard}" for p in word.phones if p.decision == "review"]
    print(f"{word.word}\t{word.score}\t{word.decision or ''}\t{', '.join(flagged)}")

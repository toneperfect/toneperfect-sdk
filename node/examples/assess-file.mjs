// Assess one recording and print what the API returned.
//
//   export TONEPERFECT_API_KEY=tp_live_...
//   node examples/assess-file.mjs hello.wav 你好 zh-CN
//   node examples/assess-file.mjs sunny.wav "I like sunny days" en-US
import { TonePerfect, TonePerfectError } from '../index.mjs'; // in your project: 'toneperfect'

const [path, text, language = 'zh-CN'] = process.argv.slice(2);
if (!path || !text) { console.error('usage: node examples/assess-file.mjs <audio file> <reference text> [locale]'); process.exit(2); }

const client = new TonePerfect(); // reads TONEPERFECT_API_KEY
try {
  const result = await client.assess(path, { text, language });
  console.log('model:', result.modelVersion, '| request:', result.id, '| replayed:', result.replayed);
  console.log('billing:', result.billing);
  if (!result.assessable) { console.log('not assessable:', result.reason); process.exit(0); }
  console.log('scores:', result.scores);
  for (const word of result.words) {
    console.log(`  ${String(word.word).padEnd(10)} ${String(word.score).padStart(4)}  ${word.start_ms}–${word.end_ms} ms`);
    for (const phone of word.phones || []) {
      if (phone.decision === 'review' || phone.decision === 'uncertain') {
        console.log(`      ${phone.dimension || ''} expected ${JSON.stringify(phone.expected)} heard ${JSON.stringify(phone.heard)} → ${phone.decision} (${phone.score})`);
      }
    }
  }
} catch (error) {
  if (error instanceof TonePerfectError) {
    // error.code is the API's machine-readable code: invalid_api_key, subscription_required, insufficient_credits, invalid_audio, rate_limit...
    console.error(`${error.status} ${error.code}: ${error.detail} (request ${error.requestId})`);
    process.exit(1);
  }
  throw error;
}

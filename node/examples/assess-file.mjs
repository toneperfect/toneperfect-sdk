// Assess one recording and print what the API returned.
//   export TONEPERFECT_API_KEY=tp_test_...      (or tp_live_... for real scores)
//   node examples/assess-file.mjs hello.ogg 你好 zh-CN
import { TonePerfect, PaymentRequiredError, TonePerfectError } from 'toneperfect';

const [file, text, language] = process.argv.slice(2);
if (!language) { console.error('usage: node assess-file.mjs <audio> <text> <locale>'); process.exit(2); }
const client = new TonePerfect();
try {
  const result = await client.assess(file, { text, language });
  console.log('model:', result.modelVersion, '| request:', result.id, '| engine:', result.engine, '| test:', result.test);
  console.log('billing:', result.billing.credits, 'credit(s), source', result.billing.source);
  if (!result.assessable) { console.log('not assessable:', result.reason); process.exit(1); }
  console.log('scores:', result.scores);
  for (const word of result.words) {
    const flagged = word.phones.filter(p => p.decision === 'review').map(p => `${p.dimension} ${p.expected}->${p.heard}`);
    console.log(`${word.word}\t${word.score}\t${word.decision ?? ''}\t${flagged.join(', ')}`);
  }
} catch (error) {
  if (error instanceof PaymentRequiredError) console.error(`${error.code}: ${error.detail} Fix it at ${error.billingUrl}`);
  else if (error instanceof TonePerfectError) console.error(`${error.status} ${error.code}: ${error.detail} (request ${error.requestId})`);
  else throw error;
  process.exit(1);
}

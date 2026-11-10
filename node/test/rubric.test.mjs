import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { applyRubric, DISCLAIMER } = require('../rubric.cjs');

const compact = JSON.parse(readFileSync(new URL('../../testing/fixtures/compact-zh.json', import.meta.url), 'utf8'));
const rubric = { name: 'Class A', dimensions: { overall: [{ min: 0, label: 'Practise again' }, { min: 70, label: 'Good' }], tone: [{ min: 50, label: 'Tones need work' }, { min: 75, label: 'Tones fine' }], fluency: [{ min: 0, label: 'x' }] }, reviewBelow: { tone: 60 } };

test('bands a compact result with the customer labels and lists units to review', () => {
  const out = applyRubric(compact, rubric);
  assert.equal(out.status, 'scored');
  assert.deepEqual(out.dimensions.overall, { value: 81.2, band: 'Good', status: 'banded' });
  assert.deepEqual(out.dimensions.tone, { value: 66.5, band: 'Tones need work', status: 'banded' });
  assert.deepEqual(out.dimensions.fluency, { value: null, band: null, status: 'no_measurement' });
  assert.deepEqual(out.units_to_review.map(u => [u.word, u.dimension, u.expected, u.heard, u.why]), [['你', 'tone', '3', '2', ['engine_decision_review', 'below_rubric_threshold']]]);
  assert.equal(out.disclaimer, DISCLAIMER);
  assert.doesNotMatch(JSON.stringify(out), /proficient|certif(?!ication from)|CEFR|HSK level|passed/i);
});

test('full-schema results and Assessment objects work the same', () => {
  const full = { assessable: true, model_version: 'm', scores: { overall: 40, tone: 45 }, words: [{ word: '好', phones: [{ dimension: 'tone', expected: 3, heard: 3, score: 45, decision: 'no_correction' }] }] };
  const out = applyRubric({ data: full }, rubric);
  assert.equal(out.dimensions.overall.band, 'Practise again');
  assert.deepEqual(out.dimensions.tone, { value: 45, band: null, status: 'below_lowest_band' });
  assert.deepEqual(out.units_to_review[0].why, ['below_rubric_threshold']);
  assert.equal(out.schema, 'full');
});

test('unassessable is not_assessed, never a zero or a lowest band', () => {
  const out = applyRubric({ ...compact, assessable: false, reason: 'no_speech', scores: { overall: null } }, rubric);
  assert.equal(out.status, 'not_assessed');
  assert.equal(out.reason, 'no_speech');
  for (const d of Object.values(out.dimensions)) assert.deepEqual(d, { value: null, band: null, status: 'not_assessed' });
  assert.deepEqual(out.units_to_review, []);
});

test('rejects malformed rubrics and inputs', () => {
  assert.throws(() => applyRubric(compact, {}), /dimensions/);
  assert.throws(() => applyRubric(compact, { dimensions: { overall: [{ min: 70, label: 'b' }, { min: 10, label: 'a' }] } }), /increasing/);
  assert.throws(() => applyRubric({ scores: {} }, rubric), /assessment body/);
});

// The website repository (toneperfectapi) keeps the pilot checklist; this check runs where the SDK sits inside it.
const checklist = new URL('../../../docs/PILOT_ACCEPTANCE_CHECKLIST.md', import.meta.url);
test('the pilot checklist sample output is what the adapter produces today', { skip: !existsSync(checklist) && 'pilot checklist not in this checkout' }, () => {
  const doc = readFileSync(checklist, 'utf8');
  const blocks = [...doc.matchAll(/```json\n([\s\S]*?)```/g)].map(m => JSON.parse(m[1]));
  assert.deepEqual(blocks[0], compact);
  const sample = applyRubric(compact, { name: 'Pilot rubric (example)', dimensions: { overall: [{ min: 0, label: 'Practise again' }, { min: 70, label: 'On track' }], tone: [{ min: 0, label: 'Tones need work' }, { min: 75, label: 'Tones on track' }] }, reviewBelow: { tone: 60 } });
  assert.deepEqual(blocks[1], sample);
  assert.doesNotMatch(doc, /\$\d|USD|signature:|signed by/i);
});

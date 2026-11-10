'use strict';
/**
 * Bring-your-own rubric (Codex audit II N23). Applies YOUR thresholds and
 * labels to a TonePerfect result (full or compact schema) without changing it.
 *
 *   const { applyRubric } = require('toneperfect/rubric');
 *   applyRubric(result.data, {
 *     name: 'Grade 4 reading',
 *     dimensions: { overall: [{ min: 0, label: 'Practise again' }, { min: 70, label: 'Good' }],
 *                   tone:    [{ min: 0, label: 'Tones need work' }, { min: 75, label: 'Tones fine' }] },
 *     reviewBelow: { tone: 60 },   // optional: also list units scored below these values
 *   });
 *
 * Guarantees:
 *  - An unassessable result is `status: 'not_assessed'`; no dimension gets a band
 *    (never a zero or a lowest band).
 *  - A null measurement (dimension not measured by the pack) is `no_measurement`.
 *  - The output is your labels on our measurements. It is not a proficiency
 *    level, a certification or a pass/fail decision by TonePerfect, and the
 *    `disclaimer` field says so.
 */
const DISCLAIMER = 'Bands are this rubric’s own labels applied to TonePerfect measurements. They are not a proficiency level or certification from TonePerfect; validate thresholds on your own learners.';

function validate(rubric) {
  if (!rubric || typeof rubric !== 'object' || !rubric.dimensions || typeof rubric.dimensions !== 'object') throw new TypeError('rubric.dimensions is required');
  for (const [dimension, bands] of Object.entries(rubric.dimensions)) {
    if (!Array.isArray(bands) || !bands.length) throw new TypeError(`rubric.dimensions.${dimension} must be a non-empty array of {min, label}`);
    let previous = -Infinity;
    for (const band of bands) {
      if (typeof band.min !== 'number' || !Number.isFinite(band.min) || typeof band.label !== 'string' || !band.label) throw new TypeError(`rubric.dimensions.${dimension}: every band needs a numeric min and a label`);
      if (band.min <= previous) throw new TypeError(`rubric.dimensions.${dimension}: bands must be in increasing min order`);
      previous = band.min;
    }
  }
}

function bandFor(value, bands) {
  let label = null;
  for (const band of bands) if (value >= band.min) label = band.label;
  return label; // below the first min: no band
}

function units(word) {
  const list = word.units || word.phones || [];
  return list.filter(u => u && typeof u === 'object');
}

function applyRubric(result, rubric) {
  validate(rubric);
  const data = result && typeof result === 'object' && result.data && typeof result.data === 'object' && 'assessable' in result.data ? result.data : result;
  if (!data || typeof data !== 'object' || typeof data.assessable !== 'boolean') throw new TypeError('Pass an assessment body (full or compact) or an Assessment');
  const scores = data.scores && typeof data.scores === 'object' ? data.scores : {};
  const base = { rubric: rubric.name || null, model_version: data.model_version ?? null, schema: data.schema || 'full', disclaimer: DISCLAIMER };
  if (!data.assessable) {
    return { ...base, status: 'not_assessed', reason: data.reason ?? null,
      dimensions: Object.fromEntries(Object.keys(rubric.dimensions).map(d => [d, { value: null, band: null, status: 'not_assessed' }])), units_to_review: [] };
  }
  const dimensions = {};
  for (const [dimension, bands] of Object.entries(rubric.dimensions)) {
    const raw = dimension === 'completeness' && scores.completeness == null ? scores.integrity : scores[dimension];
    const value = typeof raw === 'number' && Number.isFinite(raw) ? raw : null;
    if (value == null) { dimensions[dimension] = { value: null, band: null, status: 'no_measurement' }; continue; }
    const band = bandFor(value, bands);
    dimensions[dimension] = { value, band, status: band == null ? 'below_lowest_band' : 'banded' };
  }
  const reviewBelow = rubric.reviewBelow || {};
  const review = [];
  for (const word of Array.isArray(data.words) ? data.words : []) {
    for (const unit of units(word)) {
      const dimension = unit.dimension || 'phoneme';
      const why = [];
      if (unit.decision === 'review') why.push('engine_decision_review');
      if (typeof reviewBelow[dimension] === 'number' && typeof unit.score === 'number' && unit.score < reviewBelow[dimension]) why.push('below_rubric_threshold');
      if (why.length) review.push({ word: word.text ?? word.word ?? null, pinyin: word.pinyin ?? null, dimension,
        expected: unit.expected == null ? null : String(unit.expected), heard: unit.heard == null ? null : String(unit.heard),
        score: typeof unit.score === 'number' ? unit.score : null, why });
    }
  }
  return { ...base, status: 'scored', reason: null, dimensions, units_to_review: review };
}

module.exports = { applyRubric, DISCLAIMER };

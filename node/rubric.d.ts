export interface RubricBand { min: number; label: string }
export interface Rubric {
  name?: string;
  /** Per score dimension (overall, pronunciation, initial, final, tone, fluency, rhythm, completeness): bands in increasing `min`. */
  dimensions: Record<string, RubricBand[]>;
  /** Optional: list units whose score is below these values, per unit dimension (tone, initial, final, phoneme). */
  reviewBelow?: Record<string, number>;
}
export interface RubricDimension { value: number | null; band: string | null; status: 'banded' | 'below_lowest_band' | 'no_measurement' | 'not_assessed' }
export interface RubricUnit { word: string | null; pinyin: string | null; dimension: string; expected: string | null; heard: string | null; score: number | null; why: Array<'engine_decision_review' | 'below_rubric_threshold'> }
export interface RubricResult {
  rubric: string | null;
  model_version: string | null;
  schema: string;
  status: 'scored' | 'not_assessed';
  reason: string | null;
  dimensions: Record<string, RubricDimension>;
  units_to_review: RubricUnit[];
  /** Always present: the bands are the rubric's labels, not a TonePerfect proficiency claim. */
  disclaimer: string;
}
export declare const DISCLAIMER: string;
export declare function applyRubric(result: { assessable: boolean } | { data: { assessable: boolean } }, rubric: Rubric): RubricResult;

-- =============================================================
-- Evaluation | Step 13: Gate 3.1 smoke test + output-mode A/B (Phase 3)
-- Prereq: evaluation/11_, 12_; gold-layer-code/unstructured-data/03_answer_policy_question.sql
-- Questions (3, fixed before the run; not used to tune the prompt):
--   pq_01 golden answerable (cancellation refund window)
--   ho_06 held-out ticket, answerable (refund request after a flight-delay cancellation)
--   pq_35 golden out-of-scope, near-miss (additional driver; eligibility text exists)
-- Runs (golden and held-out are separate runs, as the eval procedure takes one question_set):
--   a1_smoke_schema[_ho] : output_mode = schema (response_format JSON schema)
--   a1_smoke_plain[_ho]  : output_mode = plain  (prompt-only JSON + TRY_PARSE_JSON)
--   a1_smoke_cache       : schema run repeated for the golden pair -> expect cached = TRUE, 0 tokens
-- A/B rule (plan §2.2a): adopt plain JSON for the generator only if all plain calls parse
--   (call_status ok) AND every decision matches the schema run.
-- Cost: 6 LLM calls (claude-sonnet-4-5, ~1.5-2.5k prompt + ~150 completion tokens each),
--       8 SEARCH_PREVIEW calls, 0 tokens for the cache run.
-- =============================================================

CALL RENTAL_OPS.EVALUATION.run_policy_answer_eval('a1_smoke_schema',    'golden',  5, 'claude-sonnet-4-5', 'schema', ARRAY_CONSTRUCT('pq_01', 'pq_35'));
CALL RENTAL_OPS.EVALUATION.run_policy_answer_eval('a1_smoke_schema_ho', 'holdout', 5, 'claude-sonnet-4-5', 'schema', ARRAY_CONSTRUCT('ho_06'));
CALL RENTAL_OPS.EVALUATION.run_policy_answer_eval('a1_smoke_plain',     'golden',  5, 'claude-sonnet-4-5', 'plain',  ARRAY_CONSTRUCT('pq_01', 'pq_35'));
CALL RENTAL_OPS.EVALUATION.run_policy_answer_eval('a1_smoke_plain_ho',  'holdout', 5, 'claude-sonnet-4-5', 'plain',  ARRAY_CONSTRUCT('ho_06'));
CALL RENTAL_OPS.EVALUATION.run_policy_answer_eval('a1_smoke_cache',     'golden',  5, 'claude-sonnet-4-5', 'schema', ARRAY_CONSTRUCT('pq_01', 'pq_35'));

-- ---------- Report 1: per run x question (compact) ----------
-- Expect: call_status ok everywhere; pq_01 + ho_06 answered, pq_35 not_covered;
--         citation_valid TRUE; a1_smoke_cache rows cached = TRUE with 0 tokens.
SELECT setup_version, question_id, call_status, decision, decision_correct AS dec_ok,
       citation_valid AS cit_ok, citation_hit AS cit_hit, cached,
       prompt_tokens AS p_tok, completion_tokens AS c_tok, llm_latency_ms AS llm_ms,
       ARRAY_TO_STRING(cited_chunk_ids, ',') AS cited
FROM RENTAL_OPS.EVALUATION.policy_answer_results
WHERE STARTSWITH(setup_version, 'a1_smoke_')
QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
ORDER BY question_id, setup_version;

-- ---------- Report 2: A/B summary (schema vs plain), cache run excluded ----------
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_answer_results
    WHERE setup_version IN ('a1_smoke_schema', 'a1_smoke_schema_ho', 'a1_smoke_plain', 'a1_smoke_plain_ho')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
)
SELECT output_mode,
       COUNT(*)                         AS calls,
       COUNT_IF(call_status = 'ok')     AS parsed_ok,
       ROUND(AVG(prompt_tokens))        AS avg_p_tok,
       ROUND(AVG(completion_tokens))    AS avg_c_tok,
       ROUND(AVG(llm_latency_ms))       AS avg_llm_ms
FROM latest
GROUP BY output_mode
ORDER BY output_mode;

-- ---------- Report 3: answers for review (schema run; plain shown only where the decision differs) ----------
SELECT s.question_id, s.decision, s.answer, s.uncovered_parts,
       IFF(p.decision IS DISTINCT FROM s.decision, p.decision || ': ' || p.answer, NULL) AS plain_if_different
FROM RENTAL_OPS.EVALUATION.policy_answer_results s
LEFT JOIN RENTAL_OPS.EVALUATION.policy_answer_results p
       ON p.question_id = s.question_id
      AND p.setup_version IN ('a1_smoke_plain', 'a1_smoke_plain_ho')
WHERE s.setup_version IN ('a1_smoke_schema', 'a1_smoke_schema_ho')
QUALIFY s.run_ts = MAX(s.run_ts) OVER (PARTITION BY s.setup_version)
    AND (p.run_ts IS NULL OR p.run_ts = MAX(p.run_ts) OVER (PARTITION BY p.setup_version))
ORDER BY s.question_id;

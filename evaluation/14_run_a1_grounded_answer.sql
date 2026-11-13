-- =============================================================
-- Evaluation | Step 14: Gate 3.2 generation run a1_grounded_answer (Phase 3)
-- Prereq: evaluation/09_, 11_, 12_; gold-layer-code/unstructured-data/03_answer_policy_question.sql
--         Run together with the redeploy of 03 + 12 (Gate 3.1 post-A/B edits: plain default,
--         stricter validation) and 11 (adds retrieval_setup), on one connection:
--           snow sql -c rental-dev -f src/gold-layer-code/unstructured-data/03_answer_policy_question.sql \
--                                  -f evaluation/11_policy_answer_results.sql \
--                                  -f evaluation/12_run_policy_answer_eval.sql \
--                                  -f evaluation/14_run_a1_grounded_answer.sql
-- Runs (one setup_version per question set; reports take the latest run of each):
--   a1_grounded_answer         : golden  gq_v2         (38 = 30 answerable + 8 OOS)
--   a1_grounded_answer_holdout : holdout ho_tickets_v1 (22 = 14 answerable + 8 OOS)
--   Naming: a* = answer setup on top of retrieval setup v* (retrieval_setup column); suffix
--   _holdout = held-out run of the same setup (the Phase 2a retrieval run predates this: _ho).
--   Setup: v1b_chunking retrieval, top_k 5, claude-sonnet-4-5, output_mode plain, prompt ga_p1.
-- Headline rule (plan §2.4): this first run's numbers are the headline result; no prompt change
--   before they are reported.
-- Cost: <= 60 LLM calls (~900 prompt + ~150 completion tokens each); pq_01, pq_35, ho_06 can be
--   cache hits from the Gate 3.1 plain smoke run (0 tokens). 60 SEARCH_PREVIEW calls.
--   Rerunnable: a rerun is served from GOLD.policy_answer_cache (0 tokens) except failed rows.
-- Expected (targets, plan §4): citation_valid 100%; golden OOS abstention >= 7/8, false
--   abstention <= 10%; held-out OOS abstention >= 6/8, false abstention <= 20%; failed = 0.
-- =============================================================

CALL RENTAL_OPS.EVALUATION.run_policy_answer_eval('a1_grounded_answer',         'golden',  5, 'claude-sonnet-4-5', 'plain', NULL, 'v1b_chunking');
CALL RENTAL_OPS.EVALUATION.run_policy_answer_eval('a1_grounded_answer_holdout', 'holdout', 5, 'claude-sonnet-4-5', 'plain', NULL, 'v1b_chunking');

-- ---------- Report 1: deterministic metrics per question set ----------
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_answer_results
    WHERE setup_version IN ('a1_grounded_answer', 'a1_grounded_answer_holdout')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
)
SELECT question_set, retrieval_setup,
       COUNT(*)                                                         AS n,
       COUNT_IF(call_status = 'failed')                                 AS failed,
       COUNT_IF(cached)                                                 AS cached,
       COUNT_IF(NOT is_answerable AND decision = 'not_covered') || '/' || COUNT_IF(NOT is_answerable) AS oos_abstain,
       COUNT_IF(is_answerable AND decision = 'not_covered')     || '/' || COUNT_IF(is_answerable)     AS false_abstain,
       COUNT_IF(citation_valid) || '/' || COUNT_IF(citation_valid IS NOT NULL)                       AS cit_valid,
       COUNT_IF(citation_hit)   || '/' || COUNT_IF(citation_hit IS NOT NULL)                         AS cit_hit,
       COUNT_IF(expected_in_top_k) || '/' || COUNT_IF(is_answerable)                                 AS exp_in_top5,
       ROUND(AVG(IFF(NOT cached, prompt_tokens, NULL)))                 AS avg_p_tok,
       ROUND(AVG(IFF(NOT cached, completion_tokens, NULL)))             AS avg_c_tok,
       SUM(prompt_tokens)                                               AS sum_p_tok,
       SUM(completion_tokens)                                           AS sum_c_tok,
       MEDIAN(IFF(NOT cached, llm_latency_ms, NULL))                    AS p50_llm_ms,
       MAX(llm_latency_ms)                                              AS max_llm_ms,
       MEDIAN(latency_ms)                                               AS p50_total_ms
FROM latest
GROUP BY question_set, retrieval_setup
ORDER BY question_set;

-- ---------- Report 2: flagged rows (wrong decision, invalid citation, missed expected chunk, failed) ----------
-- fail_side hint: answerable + expected chunk not in top 5 -> retrieval; otherwise -> answer step.
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_answer_results
    WHERE setup_version IN ('a1_grounded_answer', 'a1_grounded_answer_holdout')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
)
SELECT question_id, is_answerable AS ans, call_status, decision,
       citation_valid AS cit_ok, citation_hit AS cit_hit, expected_in_top_k AS exp_top5,
       IFF(is_answerable AND NOT expected_in_top_k, 'retrieval', 'answer_step') AS fail_side,
       ARRAY_TO_STRING(cited_chunk_ids, ',') AS cited,
       LEFT(COALESCE(NULLIF(uncovered_parts, ''), answer), 160) AS gist
FROM latest
WHERE call_status <> 'ok'
   OR decision_correct = FALSE
   OR citation_valid = FALSE
   OR citation_hit = FALSE
ORDER BY question_set, question_id;

-- ---------- Report 3: all answers for review (full text; read from the JSON output file) ----------
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_answer_results
    WHERE setup_version IN ('a1_grounded_answer', 'a1_grounded_answer_holdout')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
)
SELECT l.question_id, l.is_answerable AS ans, l.decision, g.question,
       l.answer, l.uncovered_parts, ARRAY_TO_STRING(l.cited_chunk_ids, ',') AS cited
FROM latest l
JOIN RENTAL_OPS.EVALUATION.policy_eval_questions g
  ON g.question_set = l.question_set AND g.question_id = l.question_id
ORDER BY l.question_set, l.question_id;

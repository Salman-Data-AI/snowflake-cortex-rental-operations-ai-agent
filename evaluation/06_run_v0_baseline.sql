-- =============================================================
-- Evaluation | Step 06: Baseline run (v0_baseline) + reports
-- Prereq: evaluation/01_ ... 05_ (schema, golden set, results, view, procedure)
-- Runs against the raw RENTAL_OPS.GOLD.policy_search service (no DT refresh needed).
--   v0_baseline         : top_k = 5, the metric run
--   v0_baseline_depth35 : top_k = 35 (whole corpus), diagnostic only, to see where missed
--                         expected chunks actually rank
-- Cost: 2 x 25 SEARCH_PREVIEW calls on COMPUTE_WH (X-Small); no LLM calls.
-- Each run appends new rows (new run_id); reports read the latest run per setup_version.
-- =============================================================

CALL RENTAL_OPS.EVALUATION.run_policy_retrieval_eval('v0_baseline', 5);
CALL RENTAL_OPS.EVALUATION.run_policy_retrieval_eval('v0_baseline_depth35', 35);

-- ---------- Report 1: summary (overall + per question_style) ----------
SELECT setup_version, question_style, questions, hit_at_1, hit_at_3, hit_at_5, mrr,
       precision_at_3, recall_at_5, oos_rejection_rate, avg_latency_ms
FROM RENTAL_OPS.EVALUATION.policy_retrieval_summary
WHERE setup_version = 'v0_baseline'
QUALIFY run_ts = MAX(run_ts) OVER ()
ORDER BY question_style = 'ALL' DESC, question_style;

-- ---------- Report 2: answerable questions missed in the top 5, with actual rank ----------
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_retrieval_results
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
)
SELECT q.question_id, q.question_style, q.question,
       q.expected_chunk_ids,
       d.first_hit_rank              AS actual_rank_of_expected,   -- from the depth-35 run
       b.retrieved_chunk_ids[0]::STRING AS retrieved_rank_1,
       ROUND(b.top_reranker_score, 2)   AS top_reranker_score
FROM latest b
JOIN latest d ON d.question_id = b.question_id AND d.setup_version = 'v0_baseline_depth35'
JOIN RENTAL_OPS.EVALUATION.policy_golden_questions q ON q.question_id = b.question_id
WHERE b.setup_version = 'v0_baseline'
  AND q.is_answerable
  AND NOT b.hit_at_5
ORDER BY q.question_id;

-- ---------- Report 3: rank-1 reranker score, answerable vs out-of-scope (threshold calibration) ----------
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_retrieval_results
    WHERE setup_version = 'v0_baseline'
    QUALIFY run_ts = MAX(run_ts) OVER ()
)
SELECT IFF(q.is_answerable, IFF(l.hit_at_1, 'answerable_hit@1', 'answerable_miss@1'), 'out_of_scope') AS grp,
       COUNT(*)                                      AS questions,
       ROUND(MIN(l.top_reranker_score), 2)           AS min_score,
       ROUND(MEDIAN(l.top_reranker_score), 2)        AS median_score,
       ROUND(MAX(l.top_reranker_score), 2)           AS max_score
FROM latest l
JOIN RENTAL_OPS.EVALUATION.policy_golden_questions q USING (question_id)
GROUP BY grp
ORDER BY grp;

-- Per-question scores for the same calibration (sorted high to low)
SELECT l.question_id, q.question_style, q.is_answerable, l.hit_at_1,
       ROUND(l.top_reranker_score, 2) AS top_reranker_score
FROM RENTAL_OPS.EVALUATION.policy_retrieval_results l
JOIN RENTAL_OPS.EVALUATION.policy_golden_questions q USING (question_id)
WHERE l.setup_version = 'v0_baseline'
QUALIFY l.run_ts = MAX(l.run_ts) OVER ()
ORDER BY l.top_reranker_score DESC;

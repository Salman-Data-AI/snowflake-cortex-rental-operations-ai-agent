-- =============================================================
-- Evaluation | Step 04: Summary view, one row per run x question_style (+ 'ALL')
-- Prereq: evaluation/02_..., evaluation/03_...
-- Rank metrics (hit@k, MRR, precision@3, recall@5) average over answerable questions only;
-- oos_rejection_rate averages correctly_rejected over out-of-scope questions only.
-- question_style = 'ALL' is the overall row; per-style rows follow.
-- Rerunnable (CREATE OR REPLACE VIEW).
-- =============================================================

CREATE OR REPLACE VIEW RENTAL_OPS.EVALUATION.policy_retrieval_summary AS
WITH r AS (
    SELECT r.*, q.question_style, q.is_answerable
    FROM RENTAL_OPS.EVALUATION.policy_retrieval_results r
    JOIN RENTAL_OPS.EVALUATION.policy_golden_questions q USING (question_id)
)
SELECT
    run_id,
    setup_version,
    retriever,
    MIN(run_ts)                                              AS run_ts,
    MIN(top_k)                                               AS top_k,
    COALESCE(question_style, 'ALL')                          AS question_style,
    COUNT(*)                                                 AS questions,
    COUNT_IF(is_answerable)                                  AS answerable_questions,
    ROUND(AVG(IFF(is_answerable, hit_at_1::INT, NULL)), 3)   AS hit_at_1,
    ROUND(AVG(IFF(is_answerable, hit_at_3::INT, NULL)), 3)   AS hit_at_3,
    ROUND(AVG(IFF(is_answerable, hit_at_5::INT, NULL)), 3)   AS hit_at_5,
    ROUND(AVG(IFF(is_answerable, reciprocal_rank, NULL)), 3) AS mrr,
    ROUND(AVG(IFF(is_answerable, precision_at_3, NULL)), 3)  AS precision_at_3,
    ROUND(AVG(IFF(is_answerable, recall_at_5, NULL)), 3)     AS recall_at_5,
    ROUND(AVG(IFF(NOT is_answerable, correctly_rejected::INT, NULL)), 3) AS oos_rejection_rate,
    ROUND(AVG(latency_ms))                                   AS avg_latency_ms,
    SUM(llm_call_count)                                      AS llm_calls
FROM r
GROUP BY GROUPING SETS (
    (run_id, setup_version, retriever),
    (run_id, setup_version, retriever, question_style)
);

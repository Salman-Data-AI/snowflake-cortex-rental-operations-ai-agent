-- =============================================================
-- Evaluation | Step 07: doc2query run (v1_doc2query) + v0 vs v1 reports + leakage check
-- Prereq: evaluation/01_ ... 06_ (v0 runs present);
--         silver 02_policy_chunk_generated_questions.sql, gold 01_ + 02_ rebuilt with search_text
-- Runs against the rebuilt RENTAL_OPS.GOLD.policy_search (indexes search_text).
--   v1_doc2query         : top_k = 5, the metric run
--   v1_doc2query_depth35 : top_k = 35 (whole corpus), diagnostic: actual rank of expected chunks
-- Chunks and chunk ids are unchanged from v0, so golden labels (gq_v2) need no re-derivation.
-- Cost: 2 x 38 SEARCH_PREVIEW calls on COMPUTE_WH; leakage check embeds 38 golden +
--       ~140 generated questions with AI_EMBED (~3k tokens, negligible). No LLM calls.
-- Each run appends new rows (new run_id); reports read the latest run per setup_version.
-- =============================================================

CALL RENTAL_OPS.EVALUATION.run_policy_retrieval_eval('v1_doc2query', 5);
CALL RENTAL_OPS.EVALUATION.run_policy_retrieval_eval('v1_doc2query_depth35', 35);

-- ---------- Report 1: v0 vs v1 summary, overall + per question_style, with deltas ----------
WITH s AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_retrieval_summary
    WHERE setup_version IN ('v0_baseline', 'v1_doc2query')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
)
SELECT v1.question_style, v1.questions,
       v0.hit_at_1 AS v0_hit1, v1.hit_at_1 AS v1_hit1, v1.hit_at_1 - v0.hit_at_1 AS d_hit1,
       v0.hit_at_5 AS v0_hit5, v1.hit_at_5 AS v1_hit5, v1.hit_at_5 - v0.hit_at_5 AS d_hit5,
       v0.mrr      AS v0_mrr,  v1.mrr      AS v1_mrr,  v1.mrr - v0.mrr           AS d_mrr,
       v0.recall_at_5 AS v0_recall5, v1.recall_at_5 AS v1_recall5,
       v0.avg_latency_ms AS v0_latency_ms, v1.avg_latency_ms AS v1_latency_ms
FROM s v1
JOIN s v0 ON v0.question_style = v1.question_style AND v0.setup_version = 'v0_baseline'
WHERE v1.setup_version = 'v1_doc2query'
ORDER BY v1.question_style = 'ALL' DESC, v1.question_style;

-- ---------- Report 2: per-question rank / score changes (flips, pq_05) ----------
-- Ranks come from the depth-35 runs (actual rank of the first expected chunk).
-- Lists every answerable question whose rank changed, any hit@1 flip, and pq_05 always.
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_retrieval_results
    WHERE setup_version IN ('v0_baseline', 'v0_baseline_depth35', 'v1_doc2query', 'v1_doc2query_depth35')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
),
p AS (
    SELECT question_id,
           MAX(IFF(setup_version = 'v0_baseline', hit_at_1, NULL))                 AS v0_hit1,
           MAX(IFF(setup_version = 'v1_doc2query', hit_at_1, NULL))                AS v1_hit1,
           MAX(IFF(setup_version = 'v0_baseline_depth35', first_hit_rank, NULL))   AS v0_rank,
           MAX(IFF(setup_version = 'v1_doc2query_depth35', first_hit_rank, NULL))  AS v1_rank,
           MAX(IFF(setup_version = 'v0_baseline', top_reranker_score, NULL))       AS v0_top_score,
           MAX(IFF(setup_version = 'v1_doc2query', top_reranker_score, NULL))      AS v1_top_score,
           MAX(IFF(setup_version = 'v1_doc2query', retrieved_chunk_ids[0]::STRING, NULL)) AS v1_rank1_chunk
    FROM latest
    GROUP BY question_id
)
SELECT p.question_id, q.question_style, q.question,
       CASE WHEN p.v0_hit1 AND NOT p.v1_hit1 THEN 'PASS->FAIL'
            WHEN NOT p.v0_hit1 AND p.v1_hit1 THEN 'FAIL->PASS'
            ELSE '' END                         AS flip,
       p.v0_rank, p.v1_rank,
       ROUND(p.v0_top_score, 2) AS v0_top_score,
       ROUND(p.v1_top_score, 2) AS v1_top_score,
       p.v1_rank1_chunk
FROM p
JOIN RENTAL_OPS.EVALUATION.policy_golden_questions q USING (question_id)
WHERE q.is_answerable
  AND (p.question_id = 'pq_05' OR p.v0_hit1 <> p.v1_hit1 OR p.v0_rank IS DISTINCT FROM p.v1_rank)
ORDER BY flip DESC, p.question_id;

-- ---------- Report 3: rank-1 score distribution shift, answerable vs out-of-scope ----------
-- Separation = min answerable-hit score minus max out-of-scope score (> 0 means a clean cut exists).
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_retrieval_results
    WHERE setup_version IN ('v0_baseline', 'v1_doc2query')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
)
SELECT l.setup_version,
       IFF(q.is_answerable, IFF(l.hit_at_1, 'answerable_hit@1', 'answerable_miss@1'), 'out_of_scope') AS grp,
       COUNT(*)                               AS questions,
       ROUND(MIN(l.top_reranker_score), 2)    AS min_score,
       ROUND(MEDIAN(l.top_reranker_score), 2) AS median_score,
       ROUND(MAX(l.top_reranker_score), 2)    AS max_score
FROM latest l
JOIN RENTAL_OPS.EVALUATION.policy_golden_questions q USING (question_id)
GROUP BY ALL
ORDER BY grp, l.setup_version;

-- ---------- Report 4: leakage check (generated questions vs golden questions) ----------
-- For each golden question, its most similar generated question (any chunk), by embedding cosine
-- and by Jaro-Winkler on lowercased text. Flag near-copies: cosine >= 0.90 or JW >= 92.
-- on_expected_chunk = TRUE matters most: a near-copy on the answer chunk inflates v1.
WITH gen AS (
    SELECT g.chunk_id, f.value::STRING AS gen_question
    FROM RENTAL_OPS.SILVER.policy_chunk_generated_questions g,
         LATERAL FLATTEN(INPUT => g.generated_questions) f
),
gen_e AS (
    SELECT gen.*, AI_EMBED('snowflake-arctic-embed-l-v2.0', gen_question) AS e FROM gen
),
gold_e AS (
    SELECT question_id, question, expected_chunk_ids,
           AI_EMBED('snowflake-arctic-embed-l-v2.0', question) AS e
    FROM RENTAL_OPS.EVALUATION.policy_golden_questions
),
pairs AS (
    SELECT g.question_id, g.question, ge.chunk_id, ge.gen_question,
           VECTOR_COSINE_SIMILARITY(g.e, ge.e)                         AS cosine,
           JAROWINKLER_SIMILARITY(LOWER(g.question), LOWER(ge.gen_question)) AS jw,
           ARRAY_CONTAINS(ge.chunk_id::VARIANT, g.expected_chunk_ids)  AS on_expected_chunk
    FROM gold_e g CROSS JOIN gen_e ge
)
SELECT question_id, question, gen_question, chunk_id, on_expected_chunk,
       ROUND(cosine, 3) AS cosine, jw,
       (cosine >= 0.90 OR jw >= 92) AS leakage_flag
FROM pairs
QUALIFY ROW_NUMBER() OVER (PARTITION BY question_id ORDER BY cosine DESC) = 1
ORDER BY cosine DESC;

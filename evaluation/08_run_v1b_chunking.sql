-- =============================================================
-- Evaluation | Step 08: chunking run (v1b_chunking) + v1 vs v1b reports + leakage check (FAQ)
-- Prereq: evaluation/01_ ... 07_ (v1 runs present);
--         silver 01_ (c2_structure) + 02_ (doc2query for the 8 new FAQ chunks),
--         gold 01_ + 02_ rebuilt (42 chunks), evaluation/02_ reloaded (pq_16 / pq_17 / pq_30
--         labels re-derived for c2_structure; its last validation query returns 0 rows).
-- Single change vs v1_doc2query: the loyalty FAQ is split into one chunk per Q and A (c2_structure).
-- Everything else is unchanged (same 34 non-FAQ chunks + their doc2query questions, same index).
--   v1b_chunking         : top_k = 5, the metric run
--   v1b_chunking_depth42 : top_k = 42 (whole corpus), diagnostic: actual rank of expected chunks
-- Watch: pq_16, pq_17, pq_30 (FAQ questions; pq_30 was rank 1 at only -8.09 in v1),
--        out-of-scope near-misses on the FAQ (scores should not rise with smaller chunks),
--        and the answerable vs out-of-scope score overlap.
-- Calibration comparison on the held-out set is deferred to Phase 2a; this is the golden-set
-- regression check (no ranking losses), reported with and without the 4 leak-flagged questions.
-- Cost: 2 x 38 SEARCH_PREVIEW calls on COMPUTE_WH; leakage check embeds 38 golden +
--       32 FAQ generated questions with AI_EMBED (~1k tokens, negligible). No LLM calls.
-- Each run appends new rows (new run_id); reports read the latest run per setup_version.
-- =============================================================

CALL RENTAL_OPS.EVALUATION.run_policy_retrieval_eval('v1b_chunking', 5);
CALL RENTAL_OPS.EVALUATION.run_policy_retrieval_eval('v1b_chunking_depth42', 42);

-- ---------- Report 1: v1 vs v1b summary, overall + per question_style, with deltas ----------
WITH s AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_retrieval_summary
    WHERE setup_version IN ('v1_doc2query', 'v1b_chunking')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
)
SELECT b.question_style, b.questions,
       a.hit_at_1 AS v1_hit1, b.hit_at_1 AS v1b_hit1, b.hit_at_1 - a.hit_at_1 AS d_hit1,
       a.hit_at_5 AS v1_hit5, b.hit_at_5 AS v1b_hit5, b.hit_at_5 - a.hit_at_5 AS d_hit5,
       a.mrr      AS v1_mrr,  b.mrr      AS v1b_mrr,  b.mrr - a.mrr           AS d_mrr,
       a.recall_at_5 AS v1_recall5, b.recall_at_5 AS v1b_recall5
FROM s b
JOIN s a ON a.question_style = b.question_style AND a.setup_version = 'v1_doc2query'
WHERE b.setup_version = 'v1b_chunking'
ORDER BY b.question_style = 'ALL' DESC, b.question_style;

-- ---------- Report 2: per-question rank / score changes ----------
-- Ranks from the whole-corpus depth runs. Lists any hit@1 flip or rank change, the FAQ questions
-- (pq_16, pq_17, pq_30) and pq_05 always. Expected-chunk labels differ per chunking (FAQ ids),
-- so each run's hit / rank was computed against the labels valid at its own run time.
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_retrieval_results
    WHERE setup_version IN ('v1_doc2query', 'v1_doc2query_depth35', 'v1b_chunking', 'v1b_chunking_depth42')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
),
p AS (
    SELECT question_id,
           MAX(IFF(setup_version = 'v1_doc2query', hit_at_1, NULL))                AS v1_hit1,
           MAX(IFF(setup_version = 'v1b_chunking', hit_at_1, NULL))                AS v1b_hit1,
           MAX(IFF(setup_version = 'v1_doc2query_depth35', first_hit_rank, NULL))  AS v1_rank,
           MAX(IFF(setup_version = 'v1b_chunking_depth42', first_hit_rank, NULL))  AS v1b_rank,
           MAX(IFF(setup_version = 'v1_doc2query', top_reranker_score, NULL))      AS v1_top_score,
           MAX(IFF(setup_version = 'v1b_chunking', top_reranker_score, NULL))      AS v1b_top_score,
           MAX(IFF(setup_version = 'v1b_chunking', retrieved_chunk_ids[0]::STRING, NULL)) AS v1b_rank1_chunk
    FROM latest
    GROUP BY question_id
)
SELECT p.question_id, q.question_style, q.question,
       CASE WHEN p.v1_hit1 AND NOT p.v1b_hit1 THEN 'PASS->FAIL'
            WHEN NOT p.v1_hit1 AND p.v1b_hit1 THEN 'FAIL->PASS'
            ELSE '' END                          AS flip,
       p.v1_rank, p.v1b_rank,
       ROUND(p.v1_top_score, 2)  AS v1_top_score,
       ROUND(p.v1b_top_score, 2) AS v1b_top_score,
       ROUND(p.v1b_top_score - p.v1_top_score, 2) AS d_score,
       p.v1b_rank1_chunk
FROM p
JOIN RENTAL_OPS.EVALUATION.policy_golden_questions q USING (question_id)
WHERE q.is_answerable
  AND (p.question_id IN ('pq_05', 'pq_16', 'pq_17', 'pq_30')
       OR p.v1_hit1 <> p.v1b_hit1 OR p.v1_rank IS DISTINCT FROM p.v1b_rank)
ORDER BY flip DESC, p.question_id;

-- ---------- Report 3: out-of-scope questions whose v1b rank-1 chunk is a FAQ chunk, or whose score moved ----------
-- Smaller FAQ chunks could match near-miss questions more sharply; this shows whether they did.
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_retrieval_results
    WHERE setup_version IN ('v1_doc2query', 'v1b_chunking')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
)
SELECT q.question_id, q.question,
       MAX(IFF(l.setup_version = 'v1_doc2query', l.retrieved_chunk_ids[0]::STRING, NULL)) AS v1_rank1_chunk,
       MAX(IFF(l.setup_version = 'v1b_chunking', l.retrieved_chunk_ids[0]::STRING, NULL)) AS v1b_rank1_chunk,
       ROUND(MAX(IFF(l.setup_version = 'v1_doc2query', l.top_reranker_score, NULL)), 2)   AS v1_top_score,
       ROUND(MAX(IFF(l.setup_version = 'v1b_chunking', l.top_reranker_score, NULL)), 2)   AS v1b_top_score
FROM latest l
JOIN RENTAL_OPS.EVALUATION.policy_golden_questions q USING (question_id)
WHERE NOT q.is_answerable
GROUP BY ALL
ORDER BY v1b_top_score DESC;

-- ---------- Report 4: rank-1 score distribution, answerable vs out-of-scope, with/without leak-flagged ----------
-- Separation = min answerable-hit score minus max out-of-scope score (> 0 means a clean cut exists).
-- Leak-flagged golden questions (07, Report 4): pq_06, pq_10, pq_11, pq_19.
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_retrieval_results
    WHERE setup_version IN ('v1_doc2query', 'v1b_chunking')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
),
g AS (
    SELECT l.setup_version, l.top_reranker_score,
           IFF(q.is_answerable, IFF(l.hit_at_1, 'answerable_hit@1', 'answerable_miss@1'), 'out_of_scope') AS grp,
           q.question_id IN ('pq_06', 'pq_10', 'pq_11', 'pq_19') AS leak_flagged
    FROM latest l
    JOIN RENTAL_OPS.EVALUATION.policy_golden_questions q USING (question_id)
)
SELECT setup_version, grp, 'all' AS subset, COUNT(*) AS questions,
       ROUND(MIN(top_reranker_score), 2) AS min_score, ROUND(MEDIAN(top_reranker_score), 2) AS median_score,
       ROUND(MAX(top_reranker_score), 2) AS max_score
FROM g GROUP BY ALL
UNION ALL
SELECT setup_version, grp, 'excl_leak_flagged', COUNT(*),
       ROUND(MIN(top_reranker_score), 2), ROUND(MEDIAN(top_reranker_score), 2), ROUND(MAX(top_reranker_score), 2)
FROM g WHERE NOT leak_flagged GROUP BY ALL
ORDER BY grp, subset, setup_version;

-- ---------- Report 5: leakage check for the regenerated FAQ questions ----------
-- Same rule as 07 Report 4 (cosine >= 0.90 or Jaro-Winkler >= 92), limited to the 32 questions
-- generated for the new FAQ chunks. Expect no flag on pq_16 / pq_17 / pq_30's expected chunk;
-- a flag there would inflate their v1b score.
WITH gen AS (
    SELECT g.chunk_id, f.value::STRING AS gen_question
    FROM RENTAL_OPS.SILVER.policy_chunk_generated_questions g,
         LATERAL FLATTEN(INPUT => g.generated_questions) f
    WHERE g.chunk_id LIKE 'loyalty_program_faq_%'
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
           VECTOR_COSINE_SIMILARITY(g.e, ge.e)                               AS cosine,
           JAROWINKLER_SIMILARITY(LOWER(g.question), LOWER(ge.gen_question)) AS jw,
           ARRAY_CONTAINS(ge.chunk_id::VARIANT, g.expected_chunk_ids)        AS on_expected_chunk
    FROM gold_e g CROSS JOIN gen_e ge
)
SELECT question_id, question, gen_question, chunk_id, on_expected_chunk,
       ROUND(cosine, 3) AS cosine, jw,
       (cosine >= 0.90 OR jw >= 92) AS leakage_flag
FROM pairs
QUALIFY ROW_NUMBER() OVER (PARTITION BY question_id ORDER BY cosine DESC) = 1
    AND (cosine >= 0.80 OR question_id IN ('pq_16', 'pq_17', 'pq_30'))
ORDER BY cosine DESC;

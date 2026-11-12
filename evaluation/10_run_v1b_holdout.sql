-- =============================================================
-- Evaluation | Step 10: held-out run (Phase 2a) for the reference setup v1b + calibration report
-- Prereq: evaluation/09_ (held-out set + view), 04_ + 05_ redeployed (question_set support),
--         08_ (v1b_chunking golden run present), Gold/search at c2_structure.
-- Runs (question_set = 'holdout', 22 queries):
--   v1b_chunking_ho          : top_k = 5, the metric run
--   v1b_chunking_ho_depth42  : top_k = 42 (whole corpus), diagnostic: actual rank of expected chunks
-- The question this answers: does the golden-set cut-off on the rank-1 reranker score still
-- separate answerable from out-of-scope on queries not written for this pipeline?
--   golden cut-off t = midpoint(min answerable-hit score, max out-of-scope score) of the latest
--   v1b_chunking golden run (currently (-5.83 + -6.54) / 2 = -6.19), computed, not hard-coded.
-- Calibration metrics per set (golden v1b vs held-out v1b):
--   separation      = min answerable-hit score - max out-of-scope score (> 0: a clean cut exists)
--   auc_ans_vs_oos  = P(score of a random answerable > score of a random out-of-scope)
--   auc_correct     = same, positives = answerable AND hit@1, negatives = everything else
--                     (what an abstention threshold really needs: answer only when rank 1 is right)
--   at cut-off t    : false_abstain = answerable hit@1 queries scoring < t,
--                     false_answer  = out-of-scope (or wrong rank-1) queries scoring >= t
-- Cost: 2 x 22 SEARCH_PREVIEW calls; overlap check embeds 22 + 38 + 168 short texts with AI_EMBED
--       (~4k tokens, negligible). No LLM calls.
-- =============================================================

CALL RENTAL_OPS.EVALUATION.run_policy_retrieval_eval('v1b_chunking_ho', 5, 'policy_search', 'holdout');
CALL RENTAL_OPS.EVALUATION.run_policy_retrieval_eval('v1b_chunking_ho_depth42', 42, 'policy_search', 'holdout');

-- ---------- Report 1: retrieval summary, held-out vs golden (v1b) ----------
SELECT setup_version, dataset_version, question_style, questions, answerable_questions,
       hit_at_1, hit_at_3, hit_at_5, mrr, recall_at_5
FROM RENTAL_OPS.EVALUATION.policy_retrieval_summary
WHERE setup_version IN ('v1b_chunking', 'v1b_chunking_ho')
QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
ORDER BY setup_version DESC, question_style = 'ALL' DESC, question_style;

-- ---------- Report 2: per-query detail (held-out), sorted by rank-1 score ----------
WITH latest AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_retrieval_results
    WHERE setup_version IN ('v1b_chunking_ho', 'v1b_chunking_ho_depth42')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
)
SELECT q.question_id, q.question_style, q.is_answerable,
       LEFT(q.question, 70)                                                            AS query,
       MAX(IFF(l.setup_version = 'v1b_chunking_ho', l.hit_at_1, NULL))                 AS hit1,
       MAX(IFF(l.setup_version = 'v1b_chunking_ho_depth42', l.first_hit_rank, NULL))   AS rank_depth42,
       ROUND(MAX(IFF(l.setup_version = 'v1b_chunking_ho', l.top_reranker_score, NULL)), 2) AS top_score,
       MAX(IFF(l.setup_version = 'v1b_chunking_ho', l.retrieved_chunk_ids[0]::STRING, NULL)) AS rank1_chunk,
       q.expected_chunk_ids
FROM latest l
JOIN RENTAL_OPS.EVALUATION.policy_holdout_questions q USING (question_id)
GROUP BY ALL
ORDER BY top_score DESC;

-- ---------- Report 3: calibration, golden vs held-out, incl. the golden cut-off applied to held-out ----------
WITH runs AS (
    SELECT r.setup_version, r.question_id, r.top_reranker_score AS s, r.hit_at_1, q.is_answerable
    FROM RENTAL_OPS.EVALUATION.policy_retrieval_results r
    JOIN RENTAL_OPS.EVALUATION.policy_eval_questions q USING (question_id)
    WHERE r.setup_version IN ('v1b_chunking', 'v1b_chunking_ho')
    QUALIFY r.run_ts = MAX(r.run_ts) OVER (PARTITION BY r.setup_version)
),
cutoff AS (   -- fitted on the golden set only
    SELECT (MIN(IFF(is_answerable AND hit_at_1, s, NULL)) + MAX(IFF(NOT is_answerable, s, NULL))) / 2 AS t
    FROM runs WHERE setup_version = 'v1b_chunking'
),
pairs AS (
    SELECT p.setup_version,
           AVG(IFF(p.is_answerable AND NOT n.is_answerable,
                   IFF(p.s > n.s, 1, IFF(p.s = n.s, 0.5, 0)), NULL))                    AS auc_ans_vs_oos,
           AVG(IFF(p.is_answerable AND p.hit_at_1 AND NOT (n.is_answerable AND n.hit_at_1),
                   IFF(p.s > n.s, 1, IFF(p.s = n.s, 0.5, 0)), NULL))                    AS auc_correct
    FROM runs p JOIN runs n ON n.setup_version = p.setup_version AND n.question_id <> p.question_id
    GROUP BY p.setup_version
)
SELECT r.setup_version,
       COUNT(*)                                                            AS queries,
       COUNT_IF(r.is_answerable)                                           AS answerable,
       ROUND(MIN(IFF(r.is_answerable AND r.hit_at_1, r.s, NULL)), 2)       AS min_answerable_hit,
       ROUND(MEDIAN(IFF(r.is_answerable AND r.hit_at_1, r.s, NULL)), 2)    AS median_answerable_hit,
       ROUND(MAX(IFF(NOT r.is_answerable, r.s, NULL)), 2)                  AS max_oos,
       ROUND(MEDIAN(IFF(NOT r.is_answerable, r.s, NULL)), 2)               AS median_oos,
       ROUND(MIN(IFF(r.is_answerable AND r.hit_at_1, r.s, NULL))
           - MAX(IFF(NOT r.is_answerable, r.s, NULL)), 2)                  AS separation,
       ROUND(ANY_VALUE(p.auc_ans_vs_oos), 3)                               AS auc_ans_vs_oos,
       ROUND(ANY_VALUE(p.auc_correct), 3)                                  AS auc_correct,
       ROUND(ANY_VALUE(c.t), 2)                                            AS golden_cutoff,
       COUNT_IF(r.is_answerable AND r.hit_at_1 AND r.s < c.t)              AS false_abstain,
       COUNT_IF(NOT r.is_answerable AND r.s >= c.t)                        AS false_answer_oos,
       COUNT_IF(r.is_answerable AND NOT r.hit_at_1 AND r.s >= c.t)         AS confident_wrong_chunk
FROM runs r
CROSS JOIN cutoff c
JOIN pairs p ON p.setup_version = r.setup_version
GROUP BY r.setup_version
ORDER BY r.setup_version;

-- ---------- Report 4: overlap check: held-out vs golden questions and vs generated questions ----------
-- Max cosine per held-out query. High values (>= 0.90) would mean the held-out query is not
-- independent of the golden set or of doc2query text. Expected: well below 0.90.
WITH ho AS (
    SELECT question_id, question, AI_EMBED('snowflake-arctic-embed-l-v2.0', question) AS e
    FROM RENTAL_OPS.EVALUATION.policy_holdout_questions
),
gold AS (
    SELECT question_id AS ref_id, question AS ref_text, AI_EMBED('snowflake-arctic-embed-l-v2.0', question) AS e
    FROM RENTAL_OPS.EVALUATION.policy_golden_questions
),
gen AS (
    SELECT g.chunk_id AS ref_id, f.value::STRING AS ref_text,
           AI_EMBED('snowflake-arctic-embed-l-v2.0', f.value::STRING) AS e
    FROM RENTAL_OPS.SILVER.policy_chunk_generated_questions g,
         LATERAL FLATTEN(INPUT => g.generated_questions) f
),
pairs AS (
    SELECT h.question_id, 'golden' AS ref_set, gold.ref_id, gold.ref_text, VECTOR_COSINE_SIMILARITY(h.e, gold.e) AS cosine
    FROM ho h CROSS JOIN gold
    UNION ALL
    SELECT h.question_id, 'generated', gen.ref_id, gen.ref_text, VECTOR_COSINE_SIMILARITY(h.e, gen.e)
    FROM ho h CROSS JOIN gen
)
SELECT question_id, ref_set, ref_id, LEFT(ref_text, 70) AS closest_text, ROUND(cosine, 3) AS max_cosine
FROM pairs
QUALIFY ROW_NUMBER() OVER (PARTITION BY question_id, ref_set ORDER BY cosine DESC) = 1
ORDER BY cosine DESC
LIMIT 12;

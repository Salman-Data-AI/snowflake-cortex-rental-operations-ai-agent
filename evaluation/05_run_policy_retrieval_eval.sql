-- =============================================================
-- Evaluation | Step 05: Eval procedure run_policy_retrieval_eval(setup_version, top_k, retriever, question_set)
-- Prereq: evaluation/02_..., evaluation/03_..., evaluation/09_... (view policy_eval_questions)
-- Two phases, so a new retrieval path never touches the metric logic:
--   1. Retrieval: per golden question, run the chosen retriever and store its response
--      ({"results": [{chunk_id, "@scores", ...}, ...]}) in a session temp table, with latency.
--      SEARCH_PREVIEW needs constant arguments, so each call is built as dynamic SQL.
--   2. Metrics: one INSERT ... SELECT scores every response against the golden set.
-- To add a retriever (v2: policy_search_retrieve), add a branch in phase 1 that returns
-- the same response shape; phase 2 stays unchanged.
-- question_set: 'golden' (default, gq_*) or 'holdout' (Phase 2a, ho_*); read from the view
--   policy_eval_questions. Use a distinct setup_version per set (e.g. v1b_chunking_ho), because
--   reports pick the latest run per setup_version.
-- EXECUTE AS CALLER so the temp table lives in the caller's session.
-- Returns the run_id. Rerunnable (CREATE OR REPLACE).
-- =============================================================

-- Migration (rerunnable): the 3-argument version (before question_set) would stay as an overload
-- and make 2- and 3-argument calls ambiguous.
DROP PROCEDURE IF EXISTS RENTAL_OPS.EVALUATION.run_policy_retrieval_eval(STRING, NUMBER, STRING);

CREATE OR REPLACE PROCEDURE RENTAL_OPS.EVALUATION.run_policy_retrieval_eval(
    setup_version STRING,
    top_k         INT,
    retriever     STRING DEFAULT 'policy_search',
    question_set  STRING DEFAULT 'golden'
)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    run_id   STRING;
    run_ts   TIMESTAMP_LTZ;
    request  STRING;
    stmt     STRING;
    t0       TIMESTAMP_LTZ;
    unknown_retriever EXCEPTION (-20001, 'Unknown retriever. Supported: policy_search');
    unknown_set       EXCEPTION (-20002, 'Unknown question_set. Supported: golden, holdout');
    qs  RESULTSET;
BEGIN
    IF (retriever <> 'policy_search') THEN
        RAISE unknown_retriever;
    END IF;
    IF (question_set NOT IN ('golden', 'holdout')) THEN
        RAISE unknown_set;
    END IF;
    qs := (SELECT question_id, question
           FROM RENTAL_OPS.EVALUATION.policy_eval_questions
           WHERE question_set = :question_set
           ORDER BY question_id);
    LET q_cur CURSOR FOR qs;

    SELECT UUID_STRING(), CURRENT_TIMESTAMP() INTO :run_id, :run_ts;

    CREATE OR REPLACE TEMPORARY TABLE RENTAL_OPS.EVALUATION.policy_eval_raw (
        question_id    STRING,
        response       VARIANT,
        latency_ms     NUMBER,
        llm_call_count NUMBER
    );

    -- ---------- Phase 1: retrieval ----------
    FOR q IN q_cur DO
        LET qid   STRING := q.question_id;
        LET qtext STRING := q.question;

        -- Raw Cortex Search service: one call, no LLM
        SELECT TO_JSON(OBJECT_CONSTRUCT(
                   'query',   :qtext,
                   'columns', ARRAY_CONSTRUCT('chunk_id', 'document_id', 'section_header'),
                   'limit',   :top_k))
        INTO :request;
        -- Escape for a single-quoted SQL literal: backslashes first, then quotes
        request := REPLACE(REPLACE(request, '\\', '\\\\'), '''', '''''');
        stmt := 'INSERT INTO RENTAL_OPS.EVALUATION.policy_eval_raw (question_id, response, llm_call_count) '
             || 'SELECT ''' || qid || ''', PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('
             || '''RENTAL_OPS.GOLD.policy_search'', ''' || request || ''')), 0';

        SELECT CURRENT_TIMESTAMP() INTO :t0;
        EXECUTE IMMEDIATE :stmt;
        UPDATE RENTAL_OPS.EVALUATION.policy_eval_raw
           SET latency_ms = DATEDIFF('millisecond', :t0, CURRENT_TIMESTAMP())
         WHERE question_id = :qid;
    END FOR;

    -- ---------- Phase 2: metrics (retriever-independent) ----------
    INSERT INTO RENTAL_OPS.EVALUATION.policy_retrieval_results (
        run_id, setup_version, retriever, run_ts, question_id, top_k, dataset_version,
        retrieved_chunk_ids, scores, result_count, first_hit_rank,
        hit_at_1, hit_at_3, hit_at_5, reciprocal_rank, precision_at_3, recall_at_5,
        top_reranker_score, correctly_rejected, latency_ms, llm_call_count, raw_response
    )
    WITH ranked AS (
        SELECT r.question_id,
               f.index + 1                AS rnk,
               f.value:chunk_id::STRING   AS chunk_id,
               f.value:"@scores"          AS sc,
               ARRAY_CONTAINS(f.value:chunk_id, g.expected_chunk_ids) AS is_expected
        FROM RENTAL_OPS.EVALUATION.policy_eval_raw r
        JOIN RENTAL_OPS.EVALUATION.policy_eval_questions g USING (question_id),
             LATERAL FLATTEN(INPUT => r.response:results, OUTER => TRUE) f
    ),
    agg AS (
        SELECT question_id,
               ARRAY_AGG(chunk_id) WITHIN GROUP (ORDER BY rnk)        AS retrieved_chunk_ids,
               ARRAY_AGG(sc)       WITHIN GROUP (ORDER BY rnk)        AS scores,
               COUNT(chunk_id)                                        AS result_count,
               MIN(IFF(is_expected, rnk, NULL))                       AS first_hit_rank,
               COUNT_IF(is_expected AND rnk <= 3)                     AS hits_top3,
               COUNT_IF(is_expected AND rnk <= 5)                     AS hits_top5,
               MAX(IFF(rnk = 1, sc:reranker_score::FLOAT, NULL))      AS top_reranker_score
        FROM ranked
        GROUP BY question_id
    )
    SELECT
        :run_id, :setup_version, :retriever, :run_ts, a.question_id, :top_k, g.dataset_version,
        a.retrieved_chunk_ids, a.scores, a.result_count, a.first_hit_rank,
        IFF(g.is_answerable, COALESCE(a.first_hit_rank <= 1, FALSE), NULL),
        IFF(g.is_answerable, COALESCE(a.first_hit_rank <= 3, FALSE), NULL),
        IFF(g.is_answerable, COALESCE(a.first_hit_rank <= 5, FALSE), NULL),
        IFF(g.is_answerable, COALESCE(1 / a.first_hit_rank, 0), NULL),
        IFF(g.is_answerable, a.hits_top3 / 3, NULL),
        IFF(g.is_answerable, a.hits_top5 / ARRAY_SIZE(g.expected_chunk_ids), NULL),
        a.top_reranker_score,
        IFF(g.is_answerable, NULL, a.result_count = 0),
        r.latency_ms, r.llm_call_count, r.response
    FROM agg a
    JOIN RENTAL_OPS.EVALUATION.policy_eval_questions g USING (question_id)
    JOIN RENTAL_OPS.EVALUATION.policy_eval_raw r USING (question_id);

    DROP TABLE IF EXISTS RENTAL_OPS.EVALUATION.policy_eval_raw;
    RETURN run_id;
END;
$$;

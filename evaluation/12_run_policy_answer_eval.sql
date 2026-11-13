-- =============================================================
-- Evaluation | Step 12: Eval procedure run_policy_answer_eval(setup_version, question_set, top_k,
--                       model, output_mode, question_ids, retrieval_setup)
-- Prereq: evaluation/09_ (view policy_eval_questions), 11_ (policy_answer_results),
--         gold-layer-code/unstructured-data/03_answer_policy_question.sql
-- Per question: CALL GOLD.answer_policy_question (retrieval + one LLM call, or a cache hit),
-- then one INSERT that scores the reply against the labels (see 11_ for the metric definitions).
-- Cost: the answer cache makes reruns free; only questions whose LLM input changed (question,
--   model, output_mode, prompt or retrieved excerpts) and earlier failed calls cost tokens.
-- question_ids: optional ARRAY to run a subset (Gate 3.1 smoke test); NULL = the whole set.
-- retrieval_setup: label of the retrieval setup GOLD.policy_search currently serves (it does not
--   change retrieval); stored per row so every answer run names the v* setup underneath it.
-- Use a distinct setup_version per question set (reports pick the latest run per setup_version).
-- EXECUTE AS CALLER (same as run_policy_retrieval_eval). Returns the run_id.
-- Rerunnable (CREATE OR REPLACE).
-- =============================================================

-- Gate 3.2: the signature gained retrieval_setup; drop the old 6-argument overload so only one exists.
DROP PROCEDURE IF EXISTS RENTAL_OPS.EVALUATION.run_policy_answer_eval(STRING, STRING, INT, STRING, STRING, ARRAY);

CREATE OR REPLACE PROCEDURE RENTAL_OPS.EVALUATION.run_policy_answer_eval(
    setup_version STRING,
    question_set  STRING  DEFAULT 'golden',
    top_k         INT     DEFAULT 5,
    model         STRING  DEFAULT 'claude-sonnet-4-5',
    output_mode   STRING  DEFAULT 'plain',
    question_ids  ARRAY   DEFAULT NULL,
    retrieval_setup STRING DEFAULT 'v1b_chunking'
)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    run_id  STRING;
    run_ts  TIMESTAMP_LTZ;
    res     VARIANT;
    unknown_set EXCEPTION (-20002, 'Unknown question_set. Supported: golden, holdout');
    qs RESULTSET;
BEGIN
    IF (question_set NOT IN ('golden', 'holdout')) THEN
        RAISE unknown_set;
    END IF;
    qs := (SELECT question_id, question
           FROM RENTAL_OPS.EVALUATION.policy_eval_questions
           WHERE question_set = :question_set
             AND (:question_ids IS NULL OR ARRAY_CONTAINS(question_id::VARIANT, :question_ids))
           ORDER BY question_id);
    LET q_cur CURSOR FOR qs;

    SELECT UUID_STRING(), CURRENT_TIMESTAMP() INTO :run_id, :run_ts;

    FOR q IN q_cur DO
        LET qid   STRING := q.question_id;
        LET qtext STRING := q.question;

        CALL RENTAL_OPS.GOLD.answer_policy_question(:qtext, :top_k, :model, :output_mode, TRUE)
            INTO :res;

        INSERT INTO RENTAL_OPS.EVALUATION.policy_answer_results (
            run_id, setup_version, retrieval_setup, question_set, dataset_version, run_ts, question_id, is_answerable,
            top_k, model, output_mode, prompt_version, retrieved_chunk_ids, retrieved_scores,
            decision, answer, cited_chunk_ids, uncovered_parts,
            decision_correct, citation_valid, citation_hit, expected_in_top_k,
            prompt_tokens, completion_tokens, latency_ms, llm_latency_ms, cached, call_status,
            input_sha, raw_response
        )
        WITH r AS (
            SELECT :res AS v
        ),
        ret AS (
            SELECT ARRAY_AGG(f.value:chunk_id::STRING)      WITHIN GROUP (ORDER BY f.index) AS ids,
                   ARRAY_AGG(f.value:reranker_score::FLOAT) WITHIN GROUP (ORDER BY f.index) AS scores
            FROM r, LATERAL FLATTEN(INPUT => r.v:retrieved) f
        )
        SELECT
            :run_id, :setup_version, :retrieval_setup, :question_set, g.dataset_version, :run_ts, :qid, g.is_answerable,
            :top_k, :model, :output_mode, r.v:prompt_version::STRING,
            COALESCE(ret.ids, ARRAY_CONSTRUCT()), COALESCE(ret.scores, ARRAY_CONSTRUCT()),
            r.v:decision::STRING, r.v:answer::STRING, r.v:cited_chunk_ids::ARRAY,
            r.v:uncovered_parts::STRING,
            IFF(r.v:call_status::STRING = 'ok',
                (r.v:decision::STRING = 'answered') = g.is_answerable, NULL),
            IFF(r.v:call_status::STRING = 'ok',
                ARRAY_SIZE(ARRAY_EXCEPT(COALESCE(r.v:cited_chunk_ids::ARRAY, ARRAY_CONSTRUCT()),
                                        COALESCE(ret.ids, ARRAY_CONSTRUCT()))) = 0, NULL),
            IFF(r.v:call_status::STRING = 'ok' AND g.is_answerable AND r.v:decision::STRING = 'answered',
                ARRAYS_OVERLAP(r.v:cited_chunk_ids::ARRAY, g.expected_chunk_ids), NULL),
            IFF(g.is_answerable,
                ARRAYS_OVERLAP(COALESCE(ret.ids, ARRAY_CONSTRUCT()), g.expected_chunk_ids), NULL),
            r.v:prompt_tokens::NUMBER, r.v:completion_tokens::NUMBER,
            r.v:latency_ms::NUMBER, r.v:llm_latency_ms::NUMBER,
            r.v:cached::BOOLEAN, r.v:call_status::STRING, r.v:input_sha::STRING, r.v:raw_response
        FROM r, ret
        JOIN RENTAL_OPS.EVALUATION.policy_eval_questions g
          ON g.question_set = :question_set AND g.question_id = :qid;
    END FOR;

    RETURN run_id;
END;
$$;

-- Validate (metadata only): expect 1 row
SHOW PROCEDURES LIKE 'RUN_POLICY_ANSWER_EVAL' IN SCHEMA RENTAL_OPS.EVALUATION;

-- =============================================================
-- Evaluation | Step 11: Answer-level results (one row per run x question), Phase 3
-- Prereq: evaluation/01_evaluation_schema.sql, 09_ (view policy_eval_questions)
-- Filled by RENTAL_OPS.EVALUATION.run_policy_answer_eval (evaluation/12_...), which calls
-- RENTAL_OPS.GOLD.answer_policy_question per question.
-- Deterministic metrics are computed against the labels at insert time and stored per row
-- (same rule as policy_retrieval_results: later label edits never rewrite history):
--   decision_correct = answerable -> 'answered', out-of-scope -> 'not_covered' (NULL if failed)
--   citation_valid   = every cited id is among the retrieved ids (NULL if failed)
--   citation_hit     = answered + answerable row citing >= 1 expected chunk (else NULL)
-- call_status 'failed' = NULL / unparseable LLM reply: excluded from metrics, never an abstention.
-- cached = TRUE: the answer came from GOLD.policy_answer_cache (0 tokens).
-- Judged metrics (correctness, groundedness) go to policy_answer_judgments in Gate 3.3.
-- Rerunnable (IF NOT EXISTS): never drops run history.
-- =============================================================

CREATE TABLE IF NOT EXISTS RENTAL_OPS.EVALUATION.policy_answer_results (
    run_id               STRING        NOT NULL,
    setup_version        STRING        NOT NULL,   -- a1_grounded_answer, a1_haiku, ... (smoke: a1_smoke_*)
    question_set         STRING        NOT NULL,   -- golden | holdout
    dataset_version      STRING,
    run_ts               TIMESTAMP_LTZ NOT NULL,
    question_id          STRING        NOT NULL,
    is_answerable        BOOLEAN,
    top_k                NUMBER        NOT NULL,
    model                STRING        NOT NULL,
    output_mode          STRING        NOT NULL,   -- schema | plain
    prompt_version       STRING        NOT NULL,
    retrieved_chunk_ids  ARRAY,                    -- ranked, as given to the LLM
    retrieved_scores     ARRAY,                    -- reranker_score per rank (diagnostic only)
    decision             STRING,                   -- answered | not_covered | NULL (failed)
    answer               STRING,
    cited_chunk_ids      ARRAY,
    uncovered_parts      STRING,
    decision_correct     BOOLEAN,
    citation_valid       BOOLEAN,
    citation_hit         BOOLEAN,
    expected_in_top_k    BOOLEAN,                  -- answerable only: an expected chunk was retrieved
    prompt_tokens        NUMBER,
    completion_tokens    NUMBER,
    latency_ms           NUMBER,
    llm_latency_ms       NUMBER,
    cached               BOOLEAN,
    call_status          STRING        NOT NULL,   -- ok | failed
    input_sha            STRING,                   -- cache key (GOLD.policy_answer_cache)
    raw_response         VARIANT,
    CONSTRAINT pk_policy_answer_results PRIMARY KEY (run_id, question_id)
);

-- Validate (metadata only): expect 1 row
SHOW TABLES LIKE 'POLICY_ANSWER_RESULTS' IN SCHEMA RENTAL_OPS.EVALUATION;

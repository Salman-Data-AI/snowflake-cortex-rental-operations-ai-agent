-- =============================================================
-- Evaluation | Step 03: Retrieval results (one row per run x question)
-- Prereq: evaluation/01_evaluation_schema.sql
-- Filled by RENTAL_OPS.EVALUATION.run_policy_retrieval_eval (evaluation/05_...).
-- Metrics are computed against the golden set at insert time and stored per row,
-- so later golden-set edits never rewrite history. Rank-based metrics are NULL
-- for out-of-scope questions; correctly_rejected is NULL for answerable ones.
-- latency_ms / llm_call_count: recorded from the baseline on, so v2 (query rewrite) cost is comparable.
-- Rerunnable (IF NOT EXISTS): never drops run history.
-- =============================================================

CREATE TABLE IF NOT EXISTS RENTAL_OPS.EVALUATION.policy_retrieval_results (
    run_id               STRING        NOT NULL,
    setup_version        STRING        NOT NULL,   -- v0_baseline | v1_doc2query | v2_query_rewrite | ...
    retriever            STRING        NOT NULL,   -- which retrieval path produced the results
    run_ts               TIMESTAMP_LTZ NOT NULL,
    question_id          STRING        NOT NULL,
    top_k                NUMBER        NOT NULL,
    retrieved_chunk_ids  ARRAY,                    -- ranked, rank 1 first
    scores               VARIANT,                  -- ranked array of @scores per result
    result_count         NUMBER,
    first_hit_rank       NUMBER,                   -- rank of the first expected chunk; NULL = not retrieved
    hit_at_1             BOOLEAN,
    hit_at_3             BOOLEAN,
    hit_at_5             BOOLEAN,
    reciprocal_rank      FLOAT,                    -- 1 / first_hit_rank, 0 when missed
    precision_at_3       FLOAT,                    -- expected chunks in top 3 / 3
    recall_at_5          FLOAT,                    -- expected chunks in top 5 / expected count
    top_reranker_score   FLOAT,                    -- reranker_score of rank 1
    correctly_rejected   BOOLEAN,                  -- out-of-scope only: TRUE when nothing was returned
    latency_ms           NUMBER,
    llm_call_count       NUMBER,                   -- 0 for the raw service
    raw_response         VARIANT,
    CONSTRAINT pk_policy_retrieval_results PRIMARY KEY (run_id, question_id)
);

-- =============================================================
-- Evaluation | Step 15: Judged answer metrics (Phase 3, Gate 3.3)
--   policy_answer_judgments : one row per judge run x answered row (LLM judge verdicts)
--   policy_answer_reviews   : one row per generated answer (human verdict, the final label)
-- Prereq: evaluation/11_ (policy_answer_results)
-- Filled by RENTAL_OPS.EVALUATION.run_policy_answer_judge (evaluation/16_...), one judge call per
--   answered row returning both metrics (plan §2.2, §2.2a):
--   correctness : the answer vs the label's expected_answer -> correct | partial | wrong
--   grounded    : every policy statement in the answer is supported by the excerpts it was given
--                 (judged against the excerpts only, not the reference) -> TRUE | FALSE
-- not_covered rows are not judged (abstention is scored deterministically in policy_answer_results).
-- Judge cache: judge_sha = SHA2(judge_model | full judge prompt). A rerun copies the verdict of an
--   earlier 'ok' row with the same judge_sha (cached = TRUE, 0 tokens); only a changed answer,
--   reference, excerpt text, judge prompt or judge model costs a call. 'failed' rows are retried.
-- Human review (plan §2.2: judged numbers are only reported after a human pass over every verdict):
--   policy_answer_reviews is keyed on answer_sha = policy_answer_results.input_sha, i.e. the exact
--   generated answer (the answer cache makes it stable across runs), so a review survives judge reruns
--   and applies to any run that served the same cached answer. Final label = human verdict;
--   judge-human agreement is computed by joining the two tables on answer_sha.
-- Rerunnable (IF NOT EXISTS): never drops judgments or reviews.
-- =============================================================

CREATE TABLE IF NOT EXISTS RENTAL_OPS.EVALUATION.policy_answer_judgments (
    judge_run_id          STRING        NOT NULL,
    judge_model           STRING        NOT NULL,   -- openai-gpt-5.4 | mistral-large3
    judge_prompt_version  STRING        NOT NULL,   -- judge_p1, ...
    run_ts                TIMESTAMP_LTZ NOT NULL,
    answer_run_id         STRING        NOT NULL,   -- policy_answer_results.run_id judged
    answer_setup_version  STRING        NOT NULL,   -- a1_grounded_answer, a1_grounded_answer_holdout, ...
    question_set          STRING        NOT NULL,   -- golden | holdout
    question_id           STRING        NOT NULL,
    is_answerable         BOOLEAN,
    answer_sha            STRING,                   -- policy_answer_results.input_sha (the answer's identity)
    judge_sha             STRING        NOT NULL,   -- judge cache key
    correctness           STRING,                   -- correct | partial | wrong | NULL (failed)
    correctness_rationale STRING,
    grounded              BOOLEAN,                  -- NULL if failed
    unsupported_claims    STRING,
    prompt_tokens         NUMBER,
    completion_tokens     NUMBER,
    llm_latency_ms        NUMBER,
    cached                BOOLEAN,
    call_status           STRING        NOT NULL,   -- ok | failed
    error_message         STRING,                   -- SQL error of the AI_COMPLETE call, if any
    raw_response          VARIANT,
    CONSTRAINT pk_policy_answer_judgments PRIMARY KEY (judge_run_id, question_id)
);

CREATE TABLE IF NOT EXISTS RENTAL_OPS.EVALUATION.policy_answer_reviews (
    answer_sha            STRING        NOT NULL,   -- policy_answer_results.input_sha
    question_set          STRING        NOT NULL,
    question_id           STRING        NOT NULL,
    human_correctness     STRING        NOT NULL,   -- correct | partial | wrong
    human_grounded        BOOLEAN       NOT NULL,
    review_note           STRING,                   -- why, esp. where the human overrides the judge
    reviewer              STRING,
    reviewed_at           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_policy_answer_reviews PRIMARY KEY (answer_sha)
);

-- Validate (metadata only): expect 3 rows (RESULTS, JUDGMENTS, REVIEWS)
SHOW TABLES LIKE 'POLICY_ANSWER_%' IN SCHEMA RENTAL_OPS.EVALUATION;

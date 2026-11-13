-- =============================================================
-- Evaluation | Step 17: Gate 3.3 judge run on the a1 headline runs (Phase 3)
-- Prereq: evaluation/11_, 14_ (a1 runs exist), 15_, 16_. Deploy and run in one batch:
--   snow sql -c rental-dev -f evaluation/15_policy_answer_judgments.sql \
--                          -f evaluation/16_run_policy_answer_judge.sql \
--                          -f evaluation/17_run_j1_judge.sql --format JSON
-- Judges the latest run of a1_grounded_answer (golden) and a1_grounded_answer_holdout (held-out):
--   answered rows only, expected ~43 (golden 30, held-out 12 answerable + ho_21 OOS answered).
--   Judge openai-gpt-5.4, prompt judge_p1.
-- Cost: ~43 judge calls (~1.5-2k prompt + ~100-400 completion incl. reasoning tokens each).
--   Rerunnable: a rerun is served from the judge cache (0 tokens) except failed rows.
-- The judged numbers below are PROVISIONAL: plan §2.2 reports them only after the human review
--   (verdicts go to policy_answer_reviews; agreement + final metrics in evaluation/18_).
-- =============================================================

CALL RENTAL_OPS.EVALUATION.run_policy_answer_judge('a1_grounded_answer',         'openai-gpt-5.4');
CALL RENTAL_OPS.EVALUATION.run_policy_answer_judge('a1_grounded_answer_holdout', 'openai-gpt-5.4');

-- ---------- Report 1: judge run health + provisional judged metrics per question set ----------
-- correct_of_answerable: abstentions on answerable rows count as not correct (plan §4 target >= 90% golden).
WITH j AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_answer_judgments
    WHERE answer_setup_version IN ('a1_grounded_answer', 'a1_grounded_answer_holdout')
      AND judge_prompt_version = 'judge_p1'
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY answer_setup_version)
),
n_ans AS (
    SELECT question_set, COUNT_IF(is_answerable) AS answerable
    FROM RENTAL_OPS.EVALUATION.policy_eval_questions GROUP BY question_set
)
SELECT j.question_set,
       COUNT(*)                                                  AS judged,
       COUNT_IF(call_status = 'failed')                          AS failed,
       COUNT_IF(cached)                                          AS cached,
       COUNT_IF(is_answerable AND correctness = 'correct')       AS ans_correct,
       COUNT_IF(is_answerable AND correctness = 'partial')       AS ans_partial,
       COUNT_IF(is_answerable AND correctness = 'wrong')         AS ans_wrong,
       COUNT_IF(is_answerable AND correctness = 'correct') || '/' || ANY_VALUE(n.answerable) AS correct_of_answerable,
       COUNT_IF(grounded) || '/' || COUNT_IF(grounded IS NOT NULL) AS grounded,
       COUNT_IF(NOT is_answerable)                               AS oos_judged,
       SUM(prompt_tokens)                                        AS sum_p_tok,
       SUM(completion_tokens)                                    AS sum_c_tok,
       ROUND(AVG(IFF(NOT cached, prompt_tokens, NULL)))          AS avg_p_tok,
       ROUND(AVG(IFF(NOT cached, completion_tokens, NULL)))      AS avg_c_tok,
       MEDIAN(IFF(NOT cached, llm_latency_ms, NULL))             AS p50_ms
FROM j JOIN n_ans n ON n.question_set = j.question_set
GROUP BY j.question_set
ORDER BY j.question_set;

-- ---------- Report 2: every verdict, for the human review ----------
WITH j AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_answer_judgments
    WHERE answer_setup_version IN ('a1_grounded_answer', 'a1_grounded_answer_holdout')
      AND judge_prompt_version = 'judge_p1'
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY answer_setup_version)
)
SELECT j.question_set, j.question_id, j.is_answerable AS ans, j.call_status,
       j.correctness, j.grounded, j.correctness_rationale, j.unsupported_claims,
       g.question, g.expected_answer, r.answer, r.uncovered_parts,
       ARRAY_TO_STRING(r.cited_chunk_ids, ',') AS cited, j.answer_sha, LEFT(j.error_message, 200) AS err
FROM j
JOIN RENTAL_OPS.EVALUATION.policy_answer_results r
  ON r.run_id = j.answer_run_id AND r.question_id = j.question_id
JOIN RENTAL_OPS.EVALUATION.policy_eval_questions g
  ON g.question_set = j.question_set AND g.question_id = j.question_id
ORDER BY j.question_set, j.question_id;

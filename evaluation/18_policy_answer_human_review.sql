-- =============================================================
-- Evaluation | Step 18: Gate 3.3 human review of the judge_p1 verdicts + final judged metrics
-- Prereq: evaluation/15_, 16_, 17_ (judge runs on a1_grounded_answer + a1_grounded_answer_holdout)
-- Review (2026-11-13, project owner, all 43 verdicts): agrees with the judge on every row except
--   three correctness overrides (partial -> correct); groundedness agreed on all 43:
--     pq_01: the extra fact (Sports/Convertible $50 non-refundable deposit) is true policy; the rubric
--            allows extra details that do not contradict the reference.
--     pq_10: the question asks only the daily CDW price; the $500 deductible is secondary.
--     pq_33: the help asked for (free orientation briefing at Andersonshire) is given; left-side
--            driving is implied by the question.
-- Human label = final label. Rows not overridden copy the judge's verdict (note 'agrees with judge').
-- Rerunnable: MERGE on answer_sha (updates the labels if this script changes).
-- Reports (plan 03 §6 item 6): strict (correct only; plan §4 pass rule), lenient (correct + partial),
--   partial credit (1 / 0.5 / 0). Denominator = all answerable questions: an abstention on an
--   answerable question scores 0. Judge-human agreement: percent agreement + Cohen's kappa.
-- Expected: agreement correctness 40/43, grounded 43/43; golden strict 29/30, held-out strict 8/14.
-- =============================================================

MERGE INTO RENTAL_OPS.EVALUATION.policy_answer_reviews t
USING (
    WITH j AS (
        SELECT * FROM RENTAL_OPS.EVALUATION.policy_answer_judgments
        WHERE answer_setup_version IN ('a1_grounded_answer', 'a1_grounded_answer_holdout')
          AND judge_prompt_version = 'judge_p1' AND call_status = 'ok'
        QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY answer_setup_version)
    ),
    o AS (
        SELECT column1 AS question_id, column2 AS human_correctness, column3 AS note
        FROM VALUES
        ('pq_01', 'correct', 'Override: extra Sports/Convertible deposit fact is true policy; rubric allows non-contradicting extra details'),
        ('pq_10', 'correct', 'Override: question asks only the daily CDW price; the $500 deductible is secondary'),
        ('pq_33', 'correct', 'Override: the requested help (free orientation briefing) is given; left-side driving is implied by the question')
    )
    SELECT j.answer_sha, j.question_set, j.question_id,
           COALESCE(o.human_correctness, j.correctness) AS human_correctness,
           j.grounded                                    AS human_grounded,
           COALESCE(o.note, 'agrees with judge')         AS review_note
    FROM j LEFT JOIN o ON o.question_id = j.question_id
) s
ON t.answer_sha = s.answer_sha
WHEN MATCHED THEN UPDATE SET human_correctness = s.human_correctness, human_grounded = s.human_grounded,
                             review_note = s.review_note, reviewed_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (answer_sha, question_set, question_id, human_correctness, human_grounded,
                              review_note, reviewer)
VALUES (s.answer_sha, s.question_set, s.question_id, s.human_correctness, s.human_grounded,
        s.review_note, 'project_owner');

-- ---------- Report 1: judge-human agreement (all judged rows, and per set) ----------
-- kappa = (p_o - p_e) / (1 - p_e); p_e from the two raters' label frequencies over 3 categories.
WITH jr AS (
    SELECT j.question_set, j.correctness AS jc, r.human_correctness AS hc,
           j.grounded AS jg, r.human_grounded AS hg
    FROM RENTAL_OPS.EVALUATION.policy_answer_judgments j
    JOIN RENTAL_OPS.EVALUATION.policy_answer_reviews r ON r.answer_sha = j.answer_sha
    WHERE j.answer_setup_version IN ('a1_grounded_answer', 'a1_grounded_answer_holdout')
      AND j.judge_prompt_version = 'judge_p1' AND j.call_status = 'ok'
    QUALIFY j.run_ts = MAX(j.run_ts) OVER (PARTITION BY j.answer_setup_version)
),
grp AS (
    SELECT 'all' AS question_set, jc, hc, jg, hg FROM jr
    UNION ALL SELECT question_set, jc, hc, jg, hg FROM jr
),
cats AS (SELECT column1 AS c FROM VALUES ('correct'), ('partial'), ('wrong')),
per_cat AS (   -- label counts per rater and category
    SELECT g.question_set, cats.c, COUNT_IF(g.jc = cats.c) AS nj, COUNT_IF(g.hc = cats.c) AS nh
    FROM grp g, cats GROUP BY g.question_set, cats.c
),
pe AS (
    SELECT question_set, SUM(nj * nh) / POWER(SUM(nj), 2) AS p_e
    FROM per_cat GROUP BY question_set
)
SELECT g.question_set,
       COUNT(*)                                        AS n,
       COUNT_IF(jc = hc) || '/' || COUNT(*)            AS correctness_agree,
       COUNT_IF(jg = hg) || '/' || COUNT(*)            AS grounded_agree,
       ROUND(COUNT_IF(jc = hc) / COUNT(*), 3)          AS p_o,
       ROUND(ANY_VALUE(p.p_e), 3)                      AS p_e,
       ROUND((COUNT_IF(jc = hc) / COUNT(*) - ANY_VALUE(p.p_e)) / NULLIF(1 - ANY_VALUE(p.p_e), 0), 3) AS kappa_correctness
FROM grp g
JOIN pe p ON p.question_set = g.question_set
GROUP BY g.question_set
ORDER BY g.question_set;

-- ---------- Report 2: final judged metrics (human labels), strict / lenient / partial credit ----------
WITH a AS (
    SELECT * FROM RENTAL_OPS.EVALUATION.policy_answer_results
    WHERE setup_version IN ('a1_grounded_answer', 'a1_grounded_answer_holdout')
    QUALIFY run_ts = MAX(run_ts) OVER (PARTITION BY setup_version)
),
x AS (
    SELECT a.question_set, a.question_id, a.is_answerable, a.decision, r.human_correctness AS hc,
           r.human_grounded AS hg
    FROM a LEFT JOIN RENTAL_OPS.EVALUATION.policy_answer_reviews r ON r.answer_sha = a.input_sha
)
SELECT question_set,
       COUNT_IF(is_answerable)                                               AS answerable,
       COUNT_IF(is_answerable AND hc = 'correct')                            AS correct,
       COUNT_IF(is_answerable AND hc = 'partial')                            AS partial,
       COUNT_IF(is_answerable AND hc = 'wrong')                              AS wrong,
       COUNT_IF(is_answerable AND decision = 'not_covered')                  AS abstained,
       ROUND(COUNT_IF(is_answerable AND hc = 'correct') / COUNT_IF(is_answerable), 3)                AS strict,
       ROUND(COUNT_IF(is_answerable AND hc IN ('correct', 'partial')) / COUNT_IF(is_answerable), 3)  AS lenient,
       ROUND(SUM(IFF(is_answerable, CASE hc WHEN 'correct' THEN 1 WHEN 'partial' THEN 0.5 ELSE 0 END, 0))
             / COUNT_IF(is_answerable), 3)                                                          AS partial_credit,
       COUNT_IF(hg) || '/' || COUNT_IF(hg IS NOT NULL)                       AS grounded_answered
FROM x
GROUP BY question_set
ORDER BY question_set;

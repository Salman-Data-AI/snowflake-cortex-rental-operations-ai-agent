-- =============================================================
-- Evaluation | Step 16: Judge procedure run_policy_answer_judge(answer_setup_version, judge_model,
--                       question_ids)  (Phase 3, Gate 3.3)
-- Prereq: evaluation/09_ (view policy_eval_questions), 11_ (policy_answer_results),
--         15_ (policy_answer_judgments); GOLD.policy_document_chunks (excerpt text)
-- Judges the LATEST run of answer_setup_version: every row with call_status = 'ok' and
--   decision = 'answered' (not_covered rows are scored deterministically, never judged).
-- Per row: one AI_COMPLETE call returning both metrics (correctness + groundedness), or a cache
--   hit on judge_sha (see 15_). Returns the judge_run_id.
-- Judge input (prompt judge_p1, fixed before the first run, names no golden/held-out example):
--   request, reference answer (expected_answer), the excerpts the generator was given (rebuilt from
--   retrieved_chunk_ids + GOLD.policy_document_chunks in the generator's format and rank order),
--   the generated answer and its uncovered_parts.
-- Design notes:
--   - Judge = a different model family than the generator (claude-sonnet-4-5) to avoid self-preference.
--     openai-gpt-5.4 (default) or mistral-large3 (fallback), Gate 3.0. Model is checked against the
--     allowlist and spliced in as a literal (AI_COMPLETE needs a literal model; dynamic SQL).
--   - JSON response_format schema with "additionalProperties": false (OpenAI returns NULL without it).
--   - model_parameters: temperature 0 for both judges (less run-to-run variance). openai-gpt-5.4:
--     max_tokens 2000 (GPT-5.x are reasoning models and spend completion tokens on reasoning, so the
--     cap is generous; only used tokens are billed). mistral-large3: max_tokens 400.
--     If Cortex rejects temperature for gpt-5.4, the rows land as 'failed' with error_message (no
--     tokens) and the parameter is dropped for that model.
--   - The cache key is the judge INPUT, so output randomness never changes it. The cache makes reruns
--     reproducible; it does not make the judge reliable (an unlucky first verdict is kept). That is
--     what the human review is for; the flip rate (cache bypassed) is measured only if judge-human
--     agreement is low.
--   - A SQL error from AI_COMPLETE (e.g. a rejected parameter) is caught: the row is stored as
--     'failed' with error_message, and the run continues.
--   - call_status 'ok' only if correctness in (correct, partial, wrong), grounded in (yes, no) and both
--     text fields are strings.
-- EXECUTE AS CALLER. Rerunnable (CREATE OR REPLACE).
-- =============================================================

CREATE OR REPLACE PROCEDURE RENTAL_OPS.EVALUATION.run_policy_answer_judge(
    answer_setup_version STRING,
    judge_model          STRING DEFAULT 'openai-gpt-5.4',
    question_ids         ARRAY  DEFAULT NULL
)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    judge_prompt_version STRING DEFAULT 'judge_p1';
    instructions   STRING;
    answer_run_id  STRING;
    judge_run_id   STRING;
    run_ts         TIMESTAMP_LTZ;
    full_prompt    STRING;
    sha            STRING;
    stmt           STRING;
    params         STRING;
    raw            VARIANT;
    parsed         VARIANT;
    status         STRING;
    err            STRING;
    is_cached      BOOLEAN;
    p_tok          NUMBER;
    c_tok          NUMBER;
    llm_ms         NUMBER;
    t_llm          TIMESTAMP_LTZ;
    bad_model  EXCEPTION (-20201, 'Unsupported judge_model. Allowed: openai-gpt-5.4, mistral-large3');
    no_run     EXCEPTION (-20202, 'No run found for answer_setup_version');
    rs RESULTSET;
BEGIN
    IF (judge_model NOT IN ('openai-gpt-5.4', 'mistral-large3')) THEN
        RAISE bad_model;
    END IF;
    params := IFF(judge_model = 'openai-gpt-5.4',
                  '{''temperature'': 0, ''max_tokens'': 2000}',
                  '{''temperature'': 0, ''max_tokens'': 400}');

    SELECT MAX_BY(run_id, run_ts) INTO :answer_run_id
    FROM RENTAL_OPS.EVALUATION.policy_answer_results
    WHERE setup_version = :answer_setup_version;
    IF (answer_run_id IS NULL) THEN
        RAISE no_run;
    END IF;
    SELECT UUID_STRING(), CURRENT_TIMESTAMP() INTO :judge_run_id, :run_ts;

    -- ---------- Prompt judge_p1 (fixed before the first run) ----------
    instructions :=
           'You evaluate answers written by the policy assistant of a car rental company. The assistant '
        || 'received a request from a customer or front-desk agent plus a few policy excerpts. It was told '
        || 'to answer only from the excerpts and to leave account-specific actions (refunds, account '
        || 'changes, confirmations) to Support.\n'
        || 'You get the request, a reference answer written by a policy expert, the excerpts the assistant '
        || 'was given (each starts with its id in square brackets) and the assistant''s answer.\n'
        || 'Judge two things independently.\n'
        || 'A. "correctness": compare the assistant''s answer with the reference answer.\n'
        || '- "correct": it states the key policy facts of the reference answer that the request needs and '
        || 'contradicts none of them. Extra details, other wording or another order are fine if they do '
        || 'not contradict the reference.\n'
        || '- "partial": it is on the right policy but misses or blurs a key fact of the reference (for '
        || 'example an amount, a time limit, a condition or an exception), or hedges where the reference '
        || 'is definite.\n'
        || '- "wrong": it contradicts the reference, misses its main point, or answers the request when the '
        || 'reference says the policy does not cover it.\n'
        || 'Referring account-specific actions to Support is neutral: neither required nor a fault.\n'
        || 'B. "grounded": compare the assistant''s answer with the excerpts only, not with the reference.\n'
        || '- "yes": every policy statement in the answer (rules, amounts, time limits, conditions, what is '
        || 'or is not covered) is stated in the excerpts or follows directly from them.\n'
        || '- "no": at least one policy statement is not supported by the excerpts or goes beyond them; '
        || 'quote it in "unsupported_claims".\n'
        || 'Referrals to Support and statements that the policy documents do not cover something are not '
        || 'policy statements; ignore them for groundedness.\n'
        || '"correctness_rationale" is one sentence naming the fact that decided the verdict. '
        || '"unsupported_claims" is an empty string when "grounded" is "yes".\n'
        || 'Reply with only a JSON object with exactly these keys: "correctness" ("correct", "partial" or '
        || '"wrong"), "correctness_rationale" (string), "grounded" ("yes" or "no"), '
        || '"unsupported_claims" (string).\n\n';

    rs := (
        WITH r AS (
            SELECT * FROM RENTAL_OPS.EVALUATION.policy_answer_results
            WHERE run_id = :answer_run_id
              AND call_status = 'ok' AND decision = 'answered'
              AND (:question_ids IS NULL OR ARRAY_CONTAINS(question_id::VARIANT, :question_ids))
        ),
        ex AS (
            SELECT r.question_id,
                   LISTAGG('[' || c.chunk_id || '] ' || c.document_title || ' / ' || c.section_header
                           || '\n' || c.chunk_text, '\n\n') WITHIN GROUP (ORDER BY f.index) AS excerpts
            FROM r, LATERAL FLATTEN(INPUT => r.retrieved_chunk_ids) f
            JOIN RENTAL_OPS.GOLD.policy_document_chunks c ON c.chunk_id = f.value::STRING
            GROUP BY r.question_id
        )
        SELECT r.question_id, r.question_set, r.is_answerable, r.input_sha AS answer_sha,
               g.question, g.expected_answer, r.answer, COALESCE(r.uncovered_parts, '') AS uncovered_parts,
               COALESCE(ex.excerpts, '(no excerpts found)') AS excerpts
        FROM r
        JOIN RENTAL_OPS.EVALUATION.policy_eval_questions g
          ON g.question_set = r.question_set AND g.question_id = r.question_id
        LEFT JOIN ex ON ex.question_id = r.question_id
        ORDER BY r.question_id);
    LET cur CURSOR FOR rs;

    FOR q IN cur DO
        LET qid   STRING  := q.question_id;
        LET qset  STRING  := q.question_set;
        LET qans  BOOLEAN := q.is_answerable;
        LET asha  STRING  := q.answer_sha;
        full_prompt := instructions
            || 'Request:\n"""\n' || q.question || '\n"""\n\n'
            || 'Reference answer:\n"""\n' || q.expected_answer || '\n"""\n\n'
            || 'Policy excerpts given to the assistant:\n"""\n' || q.excerpts || '\n"""\n\n'
            || 'Assistant''s answer:\n"""\n' || q.answer || '\n"""\n'
            || 'Parts of the request the assistant said are not covered: "' || q.uncovered_parts || '"';
        sha := SHA2(judge_model || '|' || full_prompt);
        raw := NULL; parsed := NULL; err := NULL; status := 'failed';
        is_cached := FALSE; p_tok := NULL; c_tok := NULL; llm_ms := NULL;

        -- ---------- Cache lookup ----------
        LET rs_cache RESULTSET := (
            SELECT OBJECT_CONSTRUCT('correctness', correctness,
                                    'correctness_rationale', correctness_rationale,
                                    'grounded', IFF(grounded, 'yes', 'no'),
                                    'unsupported_claims', unsupported_claims) AS p,
                   raw_response
            FROM RENTAL_OPS.EVALUATION.policy_answer_judgments
            WHERE judge_sha = :sha AND call_status = 'ok'
            QUALIFY ROW_NUMBER() OVER (ORDER BY run_ts) = 1);
        LET c_cache CURSOR FOR rs_cache;
        FOR c IN c_cache DO
            parsed := c.p; raw := c.raw_response; status := 'ok';
            is_cached := TRUE; p_tok := 0; c_tok := 0; llm_ms := 0;
        END FOR;

        -- ---------- Judge call (cache miss) ----------
        IF (NOT is_cached) THEN
            stmt := 'SELECT AI_COMPLETE(model => ''' || judge_model || ''', prompt => '''
                 || REPLACE(REPLACE(full_prompt, '\\', '\\\\'), '''', '''''') || ''', '
                 || 'model_parameters => ' || params || ', '
                 || 'response_format => {''type'': ''json'', ''schema'': {''type'': ''object'', '
                 || '''properties'': {'
                 || '''correctness'': {''type'': ''string'', ''enum'': [''correct'', ''partial'', ''wrong'']}, '
                 || '''correctness_rationale'': {''type'': ''string''}, '
                 || '''grounded'': {''type'': ''string'', ''enum'': [''yes'', ''no'']}, '
                 || '''unsupported_claims'': {''type'': ''string''}}, '
                 || '''required'': [''correctness'', ''correctness_rationale'', ''grounded'', ''unsupported_claims''], '
                 || '''additionalProperties'': false}}, '
                 || 'show_details => TRUE) AS resp';
            SELECT CURRENT_TIMESTAMP() INTO :t_llm;
            BEGIN
                LET rs_llm RESULTSET := (EXECUTE IMMEDIATE :stmt);
                LET c_llm CURSOR FOR rs_llm;
                FOR r IN c_llm DO
                    raw := r.resp;
                END FOR;
            EXCEPTION
                WHEN OTHER THEN
                    err := LEFT(SQLERRM, 1000);
            END;
            llm_ms := DATEDIFF('millisecond', t_llm, CURRENT_TIMESTAMP());

            SELECT IFF(IS_OBJECT(x.r:structured_output[0]:raw_message),
                       x.r:structured_output[0]:raw_message,
                       TRY_PARSE_JSON(x.r:structured_output[0]:raw_message::STRING)),
                   x.r:usage:prompt_tokens::NUMBER,
                   x.r:usage:completion_tokens::NUMBER
            INTO :parsed, :p_tok, :c_tok
            FROM (SELECT :raw AS r) x;

            SELECT IFF(x.p:correctness::STRING IN ('correct', 'partial', 'wrong')
                       AND x.p:grounded::STRING IN ('yes', 'no')
                       AND IS_VARCHAR(x.p:correctness_rationale)
                       AND IS_VARCHAR(x.p:unsupported_claims), 'ok', 'failed')
            INTO :status
            FROM (SELECT :parsed AS p) x;
            status := COALESCE(status, 'failed');
        END IF;

        INSERT INTO RENTAL_OPS.EVALUATION.policy_answer_judgments (
            judge_run_id, judge_model, judge_prompt_version, run_ts, answer_run_id, answer_setup_version,
            question_set, question_id, is_answerable, answer_sha, judge_sha,
            correctness, correctness_rationale, grounded, unsupported_claims,
            prompt_tokens, completion_tokens, llm_latency_ms, cached, call_status, error_message, raw_response)
        SELECT :judge_run_id, :judge_model, :judge_prompt_version, :run_ts, :answer_run_id,
               :answer_setup_version, :qset, :qid, :qans, :asha, :sha,
               IFF(:status = 'ok', x.p:correctness::STRING, NULL),
               IFF(:status = 'ok', x.p:correctness_rationale::STRING, NULL),
               IFF(:status = 'ok', x.p:grounded::STRING = 'yes', NULL),
               IFF(:status = 'ok', x.p:unsupported_claims::STRING, NULL),
               :p_tok, :c_tok, :llm_ms, :is_cached, :status, :err, :raw
        FROM (SELECT :parsed AS p) x;
    END FOR;

    RETURN judge_run_id;
END;
$$;

-- Validate (metadata only): expect 1 row
SHOW PROCEDURES LIKE 'RUN_POLICY_ANSWER_JUDGE' IN SCHEMA RENTAL_OPS.EVALUATION;

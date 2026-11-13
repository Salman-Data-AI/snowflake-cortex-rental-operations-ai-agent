-- =============================================================
-- Gold Layer (serving) | Grounded policy answer with abstention: answer_policy_question
--                        + answer cache GOLD.policy_answer_cache
-- Prereq: gold-layer-code/unstructured-data/02_policy_search_service.sql (GOLD.policy_search)
-- Plan  : docs/plans/03_phase3_grounded_answers.md §2.1, §2.2a (Phase 3, Gate 3.1)
-- Rerunnable: cache table IF NOT EXISTS (keeps cached answers), procedure CREATE OR REPLACE.
--
-- Flow per call:
--   1. SEARCH_PREVIEW on GOLD.policy_search, top_k (default 5): chunk_id, document_title,
--      section_header, chunk_text (+ @scores). The doc2query questions are NOT shown to the LLM
--      (matching only), so they can never be cited as policy.
--   2. Build prompt ga_p1: fixed instructions + the excerpts, each labelled with its chunk_id.
--   3. input_sha = SHA2(model | output_mode | full prompt). The full prompt contains the query,
--      the instructions and the retrieved excerpt texts, so any change to the question, prompt,
--      retrieval result or chunk text gives a new hash (stricter than hashing ids only).
--      Cache hit (use_cache = TRUE): return the stored answer, 0 tokens. Miss: one AI_COMPLETE call.
--   4. Parse the JSON reply. call_status = 'ok' only if it parsed, decision is answered | not_covered,
--      cited_chunk_ids is an array and answer / uncovered_parts are strings; otherwise 'failed'
--      (never counted as an abstention, never cached; a rerun retries it).
--   Gate 3.1 A/B (3 queries): plain parsed 3/3 with the same decisions at ~885 vs ~1,600 prompt
--   tokens, so the Phase 3 runs use output_mode = 'plain' (docs/design-knowledge/03_...).
-- Serving-layer exception (CLAUDE.md): query-time AI calls, one per user query, live in GOLD
--   procedures. No dynamic table calls this procedure.
-- Design notes:
--   - AI_COMPLETE's model must be a string literal, and SEARCH_PREVIEW needs constant arguments,
--     so both calls are dynamic SQL. model is checked against an allowlist before it is spliced in.
--   - output_mode: 'schema' = response_format JSON schema (+~700 prompt tokens, Gate 3.0);
--                  'plain'  = no response_format, the reply is parsed with TRY_PARSE_JSON after
--                             stripping any text around the outermost {...}.
--     Both modes send the identical prompt (it always states the JSON keys), so the Gate 3.1 A/B
--     isolates the response_format cost.
--   - temperature 0, max_tokens 600. show_details => TRUE returns usage tokens.
--   - The prompt is written before any run and names no golden or held-out example.
-- Returns VARIANT: {query, retrieved: [{chunk_id, reranker_score}], decision, answer,
--   cited_chunk_ids, uncovered_parts, call_status, cached, model, output_mode, prompt_version,
--   input_sha, prompt_tokens, completion_tokens, latency_ms, llm_latency_ms, raw_response}
-- =============================================================

CREATE TABLE IF NOT EXISTS RENTAL_OPS.GOLD.policy_answer_cache (
    input_sha            STRING        NOT NULL,   -- SHA2(model | output_mode | full prompt)
    model                STRING        NOT NULL,
    output_mode          STRING        NOT NULL,   -- schema | plain
    prompt_version       STRING        NOT NULL,   -- ga_p1, ...
    query                STRING        NOT NULL,
    retrieved_chunk_ids  ARRAY,                    -- ranked, as sent to the LLM
    decision             STRING        NOT NULL,   -- answered | not_covered
    answer               STRING,
    cited_chunk_ids      ARRAY,
    uncovered_parts      STRING,
    prompt_tokens        NUMBER,
    completion_tokens    NUMBER,
    llm_latency_ms       NUMBER,
    raw_response         VARIANT,
    created_at           TIMESTAMP_LTZ NOT NULL,
    CONSTRAINT pk_policy_answer_cache PRIMARY KEY (input_sha)
)
COMMENT = 'Cache of successful grounded answers (answer_policy_question), keyed on the full LLM input';

CREATE OR REPLACE PROCEDURE RENTAL_OPS.GOLD.answer_policy_question(
    query        STRING,
    top_k        INT     DEFAULT 5,
    model        STRING  DEFAULT 'claude-sonnet-4-5',
    output_mode  STRING  DEFAULT 'plain',
    use_cache    BOOLEAN DEFAULT TRUE
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    prompt_version  STRING DEFAULT 'ga_p1';
    instructions    STRING;
    request         STRING;
    stmt            STRING;
    search_resp     VARIANT;
    retrieved       ARRAY;
    retrieved_ids   ARRAY;
    excerpts        STRING;
    full_prompt     STRING;
    sha             STRING;
    raw             VARIANT;
    parsed          VARIANT;
    status          STRING;
    is_cached       BOOLEAN DEFAULT FALSE;
    t0              TIMESTAMP_LTZ;
    t_llm           TIMESTAMP_LTZ;
    llm_ms          NUMBER;
    p_tok           NUMBER;
    c_tok           NUMBER;
    result          VARIANT;
    bad_model  EXCEPTION (-20101, 'Unsupported model. Allowed: claude-sonnet-4-5, claude-haiku-4-5');
    bad_mode   EXCEPTION (-20102, 'Unsupported output_mode. Allowed: schema, plain');
    bad_query  EXCEPTION (-20103, 'query must be a non-empty string');
BEGIN
    IF (model NOT IN ('claude-sonnet-4-5', 'claude-haiku-4-5')) THEN
        RAISE bad_model;
    END IF;
    IF (output_mode NOT IN ('schema', 'plain')) THEN
        RAISE bad_mode;
    END IF;
    IF (query IS NULL OR TRIM(query) = '') THEN
        RAISE bad_query;
    END IF;
    SELECT CURRENT_TIMESTAMP() INTO :t0;

    -- ---------- 1. Retrieval ----------
    SELECT TO_JSON(OBJECT_CONSTRUCT(
               'query',   :query,
               'columns', ARRAY_CONSTRUCT('chunk_id', 'document_title', 'section_header', 'chunk_text'),
               'limit',   :top_k))
    INTO :request;
    request := REPLACE(REPLACE(request, '\\', '\\\\'), '''', '''''');
    stmt := 'SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('
         || '''RENTAL_OPS.GOLD.policy_search'', ''' || request || ''')) AS resp';
    LET rs_search RESULTSET := (EXECUTE IMMEDIATE :stmt);
    LET c_search CURSOR FOR rs_search;
    FOR r IN c_search DO
        search_resp := r.resp;
    END FOR;

    SELECT COALESCE(ARRAY_AGG(OBJECT_CONSTRUCT(
                        'chunk_id',       f.value:chunk_id::STRING,
                        'reranker_score', f.value:"@scores":reranker_score::FLOAT))
                      WITHIN GROUP (ORDER BY f.index), ARRAY_CONSTRUCT()),
           COALESCE(ARRAY_AGG(f.value:chunk_id::STRING) WITHIN GROUP (ORDER BY f.index),
                    ARRAY_CONSTRUCT()),
           COALESCE(LISTAGG(
                        '[' || f.value:chunk_id::STRING || '] '
                     || f.value:document_title::STRING || ' / ' || f.value:section_header::STRING
                     || '\n' || f.value:chunk_text::STRING, '\n\n')
                      WITHIN GROUP (ORDER BY f.index), '(no excerpts found)')
    INTO :retrieved, :retrieved_ids, :excerpts
    FROM (SELECT :search_resp AS s) x,
         LATERAL FLATTEN(INPUT => x.s:results) f;

    -- ---------- 2. Prompt ga_p1 (fixed before the first run) ----------
    instructions :=
           'You are the policy assistant of a car rental company. Front-desk agents and customers '
        || 'send you questions or support requests. Answer using ONLY the policy excerpts below; '
        || 'each excerpt starts with its id in square brackets.\n'
        || 'Rules:\n'
        || '1. Use only facts stated in the excerpts. Do not use general knowledge and do not guess '
        || 'what the company probably does.\n'
        || '2. If an excerpt states a rule that addresses the request, set "decision" to "answered", '
        || 'give a short answer (at most 3 sentences) and list the ids of the excerpts you used in '
        || '"cited_chunk_ids".\n'
        || '3. If the excerpts do not address the request, set "decision" to "not_covered", say plainly '
        || 'in "answer" that the policy documents do not cover it, and leave "cited_chunk_ids" empty. '
        || 'An excerpt on a related topic that does not answer the specific request does not count.\n'
        || '4. Many messages are requests rather than questions (for example asking for a refund, an '
        || 'account change or a confirmation). Answer the policy aspect of the request and say that '
        || 'account-specific actions are handled by Support. If no policy rule applies to the '
        || 'situation, use "not_covered".\n'
        || '5. If only part of the request is covered, answer that part and describe the rest in '
        || '"uncovered_parts"; otherwise "uncovered_parts" is an empty string.\n'
        || '6. Answer in English, whatever the language of the request.\n'
        || 'Reply with only a JSON object, no other text, with exactly these keys: '
        || '"decision" ("answered" or "not_covered"), "answer" (string), '
        || '"cited_chunk_ids" (array of excerpt ids), "uncovered_parts" (string).\n\n';
    full_prompt := instructions
        || 'Policy excerpts:\n"""\n' || excerpts || '\n"""\n\n'
        || 'Request:\n"""\n' || query || '\n"""';
    sha := SHA2(model || '|' || output_mode || '|' || full_prompt);

    -- ---------- 3. Cache lookup ----------
    IF (use_cache) THEN
        LET rs_cache RESULTSET := (
            SELECT OBJECT_CONSTRUCT('decision', decision, 'answer', answer,
                                    'cited_chunk_ids', cited_chunk_ids,
                                    'uncovered_parts', uncovered_parts) AS p,
                   raw_response
            FROM RENTAL_OPS.GOLD.policy_answer_cache
            WHERE input_sha = :sha);
        LET c_cache CURSOR FOR rs_cache;
        FOR r IN c_cache DO
            parsed    := r.p;
            raw       := r.raw_response;
            status    := 'ok';
            is_cached := TRUE;
            p_tok     := 0;
            c_tok     := 0;
            llm_ms    := 0;
        END FOR;
    END IF;

    -- ---------- 4. LLM call (cache miss) ----------
    IF (NOT is_cached) THEN
        stmt := 'SELECT AI_COMPLETE(model => ''' || model || ''', prompt => '''
             || REPLACE(REPLACE(full_prompt, '\\', '\\\\'), '''', '''''') || ''', '
             || 'model_parameters => {''temperature'': 0, ''max_tokens'': 600}, '
             || IFF(output_mode = 'schema',
                    'response_format => {''type'': ''json'', ''schema'': {''type'': ''object'', '
                 || '''properties'': {'
                 || '''decision'': {''type'': ''string'', ''enum'': [''answered'', ''not_covered'']}, '
                 || '''answer'': {''type'': ''string''}, '
                 || '''cited_chunk_ids'': {''type'': ''array'', ''items'': {''type'': ''string''}}, '
                 || '''uncovered_parts'': {''type'': ''string''}}, '
                 || '''required'': [''decision'', ''answer'', ''cited_chunk_ids'', ''uncovered_parts''], '
                 || '''additionalProperties'': false}}, ',
                    '')
             || 'show_details => TRUE) AS resp';
        SELECT CURRENT_TIMESTAMP() INTO :t_llm;
        LET rs_llm RESULTSET := (EXECUTE IMMEDIATE :stmt);
        LET c_llm CURSOR FOR rs_llm;
        FOR r IN c_llm DO
            raw := r.resp;
        END FOR;
        llm_ms := DATEDIFF('millisecond', t_llm, CURRENT_TIMESTAMP());

        -- schema mode: structured_output[0].raw_message (object or JSON string);
        -- plain mode : choices[0].messages (text; keep only the outermost {...})
        SELECT CASE
                   WHEN x.r:structured_output[0]:raw_message IS NOT NULL THEN
                       IFF(IS_OBJECT(x.r:structured_output[0]:raw_message),
                           x.r:structured_output[0]:raw_message,
                           TRY_PARSE_JSON(x.r:structured_output[0]:raw_message::STRING))
                   ELSE TRY_PARSE_JSON(REGEXP_SUBSTR(x.r:choices[0]:messages::STRING, '\\{.*\\}', 1, 1, 's'))
               END,
               x.r:usage:prompt_tokens::NUMBER,
               x.r:usage:completion_tokens::NUMBER
        INTO :parsed, :p_tok, :c_tok
        FROM (SELECT :raw AS r) x;

        SELECT IFF(x.p:decision::STRING IN ('answered', 'not_covered')
                   AND IS_ARRAY(x.p:cited_chunk_ids)
                   AND IS_VARCHAR(x.p:answer)
                   AND IS_VARCHAR(x.p:uncovered_parts), 'ok', 'failed')
        INTO :status
        FROM (SELECT :parsed AS p) x;

        IF (status = 'ok') THEN
            MERGE INTO RENTAL_OPS.GOLD.policy_answer_cache c
            USING (SELECT :sha AS input_sha, :parsed AS p) s
               ON c.input_sha = s.input_sha
            WHEN NOT MATCHED THEN INSERT (
                input_sha, model, output_mode, prompt_version, query, retrieved_chunk_ids,
                decision, answer, cited_chunk_ids, uncovered_parts,
                prompt_tokens, completion_tokens, llm_latency_ms, raw_response, created_at)
            VALUES (
                s.input_sha, :model, :output_mode, :prompt_version, :query, :retrieved_ids,
                s.p:decision::STRING, s.p:answer::STRING, s.p:cited_chunk_ids::ARRAY,
                s.p:uncovered_parts::STRING,
                :p_tok, :c_tok, :llm_ms, :raw, CURRENT_TIMESTAMP());
        END IF;
    END IF;

    SELECT OBJECT_CONSTRUCT_KEEP_NULL(
        'query',             :query,
        'retrieved',         :retrieved,
        'decision',          x.p:decision::STRING,
        'answer',            x.p:answer::STRING,
        'cited_chunk_ids',   x.p:cited_chunk_ids,
        'uncovered_parts',   x.p:uncovered_parts::STRING,
        'call_status',       :status,
        'cached',            :is_cached,
        'model',             :model,
        'output_mode',       :output_mode,
        'prompt_version',    :prompt_version,
        'input_sha',         :sha,
        'prompt_tokens',     :p_tok,
        'completion_tokens', :c_tok,
        'latency_ms',        DATEDIFF('millisecond', :t0, CURRENT_TIMESTAMP()),
        'llm_latency_ms',    :llm_ms,
        'raw_response',      :raw)
    INTO :result
    FROM (SELECT :parsed AS p) x;
    RETURN result;
END;
$$;

-- Validate (metadata only, no warehouse): procedure and cache table exist
SHOW PROCEDURES LIKE 'ANSWER_POLICY_QUESTION' IN SCHEMA RENTAL_OPS.GOLD;
SHOW TABLES LIKE 'POLICY_ANSWER_CACHE' IN SCHEMA RENTAL_OPS.GOLD;
-- Usage: CALL RENTAL_OPS.GOLD.answer_policy_question('Can I add a second driver?');

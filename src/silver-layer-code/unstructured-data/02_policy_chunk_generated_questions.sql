-- =============================================================
-- Silver Layer | Policy chunks: doc2query (AI-generated "questions this chunk answers")
-- Prereq: silver-layer-code/unstructured-data/01_policy_document_chunks.sql
-- Rerunnable and incremental: CREATE TABLE IF NOT EXISTS + DELETE stale + INSERT missing.
--   AI_COMPLETE runs only for chunks with no row for their current text (keyed on
--   chunk_id + SHA2(chunk_text_with_context)). A rerun with unchanged chunks makes 0 LLM calls;
--   after re-chunking (Phase 2b) only new/changed chunks are regenerated.
--   This is a plain Silver table (not CTAS) on purpose: CTAS would regenerate every chunk
--   on each run. AI calls stay in Silver; Gold only joins the result.
-- Design notes:
--   - Fixed model + prompt, recorded per row (doc2query_model, doc2query_prompt_version).
--     temperature 0 for reproducibility; JSON response_format so parsing is deterministic.
--   - The prompt is generic (everyday wording, synonyms for formal terms). It deliberately does
--     NOT name examples from the golden set (e.g. "late return"), so v1 is not tuned to the exam.
--   - search_text = chunk_text_with_context + generated questions; this is what Gold indexes.
--     chunk_text stays untouched for display / citation.
--   - search_text_token_count uses the embedding model's tokenizer. Budget: <= 512 per chunk;
--     the 491-token loyalty FAQ chunk is expected to exceed it slightly (fixed by Phase 2b split).
--   - Rows whose response did not parse are not inserted, so a rerun retries them.
-- =============================================================

CREATE TABLE IF NOT EXISTS RENTAL_OPS.SILVER.policy_chunk_generated_questions (
    chunk_id                  STRING        NOT NULL,   -- FK -> SILVER.policy_document_chunks.chunk_id
    source_text_sha           STRING        NOT NULL,   -- SHA2(chunk_text_with_context) at generation time
    generated_questions       ARRAY         NOT NULL,   -- 4 customer-style questions
    question_count            NUMBER,
    search_text               STRING        NOT NULL,   -- chunk_text_with_context + questions (indexed text)
    search_text_token_count   NUMBER,
    doc2query_model           STRING        NOT NULL,
    doc2query_prompt_version  STRING        NOT NULL,
    raw_response              VARIANT,
    generated_at              TIMESTAMP_LTZ NOT NULL
)
COMMENT = 'doc2query questions per policy chunk (AI_COMPLETE, generated once per chunk text)';

-- 1. Remove rows whose chunk was dropped or whose text changed
DELETE FROM RENTAL_OPS.SILVER.policy_chunk_generated_questions q
WHERE NOT EXISTS (
    SELECT 1
    FROM RENTAL_OPS.SILVER.policy_document_chunks c
    WHERE c.chunk_id = q.chunk_id
      AND SHA2(c.chunk_text_with_context) = q.source_text_sha
);

-- 2. Generate questions for chunks that have none for their current text
INSERT INTO RENTAL_OPS.SILVER.policy_chunk_generated_questions
WITH todo AS (
    SELECT c.chunk_id,
           c.chunk_text_with_context,
           SHA2(c.chunk_text_with_context) AS source_text_sha
    FROM RENTAL_OPS.SILVER.policy_document_chunks c
    WHERE NOT EXISTS (
        SELECT 1
        FROM RENTAL_OPS.SILVER.policy_chunk_generated_questions q
        WHERE q.chunk_id = c.chunk_id
          AND q.source_text_sha = SHA2(c.chunk_text_with_context)
    )
),
gen AS (
    SELECT t.*,
           AI_COMPLETE(
               model => 'claude-sonnet-4-5',
               prompt =>
                   'You help a car rental company index its policy documents for search.\n'
                || 'Below is one section of a policy document. Write exactly 4 questions that a '
                || 'customer or front-desk agent might type, which this section answers.\n'
                || 'Rules:\n'
                || '- Use everyday wording, the way people actually ask. Prefer common synonyms '
                || 'over the document''s formal terms (do not just copy its phrases).\n'
                || '- Mix styles: one plain direct question, two casual/conversational ones, '
                || 'and one short keyword-style query.\n'
                || '- Each question must be answerable from this section alone. Do not invent facts, '
                || 'numbers or situations the section does not cover.\n'
                || '- Each question at most 20 words. No numbering.\n\n'
                || 'Section:\n"""\n' || t.chunk_text_with_context || '\n"""',
               model_parameters => {'temperature': 0, 'max_tokens': 400},
               response_format => {
                   'type': 'json',
                   'schema': {
                       'type': 'object',
                       'properties': {
                           'questions': {'type': 'array', 'items': {'type': 'string'}}
                       },
                       'required': ['questions']
                   }
               }
           ) AS raw_response
    FROM todo t
),
parsed AS (
    SELECT g.*,
           TRY_PARSE_JSON(TO_VARCHAR(g.raw_response)):questions::ARRAY AS qs
    FROM gen g
),
built AS (
    SELECT p.*,
           p.chunk_text_with_context
             || '\n\nQuestions this section answers:\n- '
             || ARRAY_TO_STRING(p.qs, '\n- ') AS search_text
    FROM parsed p
    WHERE ARRAY_SIZE(p.qs) > 0
)
SELECT
    chunk_id,
    source_text_sha,
    qs,
    ARRAY_SIZE(qs),
    search_text,
    AI_COUNT_TOKENS('ai_embed', 'snowflake-arctic-embed-l-v2.0', search_text),
    'claude-sonnet-4-5',
    'd2q_p1',
    raw_response,
    CURRENT_TIMESTAMP()
FROM built;

-- Gold dynamic table joins this table: needs change tracking for incremental refresh
ALTER TABLE RENTAL_OPS.SILVER.policy_chunk_generated_questions SET CHANGE_TRACKING = TRUE;

-- Validate 1: coverage + token budget
-- Expect: chunks = 35, with_questions = 35, stale_rows = 0, questions_per_chunk = 4,
--         max_search_tokens around 550 (only the loyalty FAQ chunk > 512)
SELECT
    (SELECT COUNT(*) FROM RENTAL_OPS.SILVER.policy_document_chunks)          AS chunks,
    COUNT(c.chunk_id)                                                        AS with_questions,
    (SELECT COUNT(*) FROM RENTAL_OPS.SILVER.policy_chunk_generated_questions) - COUNT(c.chunk_id) AS stale_rows,
    MIN(q.question_count)                                                    AS min_questions_per_chunk,
    MAX(q.question_count)                                                    AS max_questions_per_chunk,
    MAX(q.search_text_token_count)                                           AS max_search_tokens,
    COUNT_IF(q.search_text_token_count > 512)                                AS chunks_over_512
FROM RENTAL_OPS.SILVER.policy_chunk_generated_questions q
LEFT JOIN RENTAL_OPS.SILVER.policy_document_chunks c
       ON c.chunk_id = q.chunk_id
      AND SHA2(c.chunk_text_with_context) = q.source_text_sha;

-- Validate 2: sample for review before the eval runs: the 2nd chunk of each document
-- plus the late-return chunk behind the v0 miss (pq_05)
SELECT c.chunk_id, c.section_header, q.generated_questions, q.search_text_token_count
FROM RENTAL_OPS.SILVER.policy_chunk_generated_questions q
JOIN RENTAL_OPS.SILVER.policy_document_chunks c USING (chunk_id)
QUALIFY ROW_NUMBER() OVER (PARTITION BY c.file_name ORDER BY c.chunk_index) = 2
     OR c.chunk_id = 'rental_agreement_terms_03'
ORDER BY c.chunk_id;

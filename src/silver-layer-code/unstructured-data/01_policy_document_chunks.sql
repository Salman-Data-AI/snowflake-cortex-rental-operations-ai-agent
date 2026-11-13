-- =============================================================
-- Silver Layer | Policy documents: chunk for RAG / Cortex Search
-- Prereq: bronze-layer-code/unstructured-data/01_load_policy_documents.sql
-- Rerunnable (CREATE OR REPLACE).
-- Split on markdown headers (# = document title, ## = section) with
-- SPLIT_TEXT_MARKDOWN_HEADER; chunk_size 2000 chars (~512 tokens, ~4 chars/token),
-- overlap 200 chars only applies when a section is long enough to be split.
-- Document-level metadata (type, applies to, last updated) is parsed from the
-- header block so Cortex Search can filter on it.
-- chunk_text_with_context prefixes title + section so each chunk is self-describing.
-- Chunking versions (chunking_version column; see docs/design-knowledge/02_chunking_guidelines.md):
--   c1_header    : # / ## headers only (v0, v1). The loyalty FAQ had no ## headers -> one 491-token chunk.
--   c2_structure : (Phase 2b, v1b) structure-aware: FAQ question lines (a whole line in bold ending
--                  with '?') are promoted to ## headers before the split, so each Q and A is one chunk
--                  and its question becomes section_header. Documents without such lines are
--                  unchanged (same chunk ids and text, so doc2query is not regenerated for them).
--                  Numbered procedure steps (roadside "What to Do") stay one unit on purpose.
-- Quality flags (G4), computed per chunk, expected all FALSE for c2_structure:
--   is_oversized   : chunk_token_count > 3x corpus median
--   is_undersized  : chunk_token_count < 30
--   is_multi_topic : >= 2 question lines, or >= 3 standalone bold lines, in chunk_text (FAQ structure the
--                    splitter missed). Bold list items ("- **Gold** ...") do not count.
--   Flagged chunks are kept (not dropped) and carried to Gold; the validation query lists them.
-- =============================================================

CREATE SCHEMA IF NOT EXISTS RENTAL_OPS.SILVER;

CREATE OR REPLACE TABLE RENTAL_OPS.SILVER.policy_document_chunks AS
WITH docs AS (
    SELECT
        "file_name"     AS file_name,
        "file_path"     AS file_path,
        -- c2_structure: promote FAQ question lines (**...?** on their own line) to ## headers
        REGEXP_REPLACE("document_text", '^\\*\\*([^*\\n]+\\?)\\*\\*[ \\t]*$', '## \\1', 1, 0, 'm') AS document_text,
        TRIM(REGEXP_SUBSTR("document_text", '^# (.*)$', 1, 1, 'm', 1))                        AS document_title,
        TRIM(REGEXP_SUBSTR("document_text", '\\*\\*Document type:\\*\\* *(.*)$', 1, 1, 'm', 1)) AS document_type,
        TRIM(REGEXP_SUBSTR("document_text", '\\*\\*Applies to:\\*\\* *(.*)$', 1, 1, 'm', 1))    AS applies_to,
        TRY_TO_DATE(REGEXP_SUBSTR("document_text", '\\*\\*Last updated:\\*\\* *([0-9-]+)', 1, 1, 'm', 1)) AS last_updated
    FROM RENTAL_OPS.BRONZE.bronze_policy_documents
),
chunks AS (
    SELECT
        d.*,
        c.index                       AS chunk_index,
        c.value:headers:header_2::STRING AS section_header,
        TRIM(c.value:chunk::STRING)   AS chunk_text
    FROM docs d,
         LATERAL FLATTEN(INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_MARKDOWN_HEADER(
             d.document_text,
             OBJECT_CONSTRUCT('#', 'header_1', '##', 'header_2'),
             2000,
             200
         )) c
),
kept AS (
    SELECT *
    FROM chunks
    WHERE chunk_text <> ''
      -- Drop metadata-only Overview chunks (header block, no body): they rank high on
      -- broad queries but answer nothing; the metadata is already in its own columns.
      -- Overview chunks with real body text (driving rules intro) are kept.
      AND NOT (
          section_header IS NULL
          AND TRIM(REGEXP_REPLACE(chunk_text, '^(# .*|\\*\\*[^*]+:\\*\\*.*)$', '', 1, 0, 'm'), ' \n\r\t') = ''
      )
),
sized AS (
    SELECT k.*,
           k.document_title || ' | ' || COALESCE(k.section_header, 'Overview') || '\n\n' || k.chunk_text AS chunk_text_with_context,
           AI_COUNT_TOKENS('ai_embed', 'snowflake-arctic-embed-l-v2.0', chunk_text_with_context)       AS chunk_token_count,
           REGEXP_COUNT(k.chunk_text, '\\?[*]*[ \t]*$', 1, 'm')                                         AS question_line_count,
           REGEXP_COUNT(k.chunk_text, '^\\*\\*[^*]+\\*\\*[ \t]*$', 1, 'm')                                AS bold_line_count
    FROM kept k
)
SELECT
    REPLACE(file_name, '.md', '') || '_' || LPAD(chunk_index::STRING, 2, '0') AS chunk_id,
    file_name,
    file_path,
    document_title,
    document_type,
    applies_to,
    last_updated,
    chunk_index,
    COALESCE(section_header, 'Overview')                                     AS section_header,
    chunk_text,
    chunk_text_with_context,
    LENGTH(chunk_text)                                                       AS chunk_char_length,
    chunk_token_count,
    'c2_structure'                                                           AS chunking_version,
    chunk_token_count > 3 * MEDIAN(chunk_token_count) OVER ()                AS is_oversized,
    chunk_token_count < 30                                                   AS is_undersized,
    (question_line_count >= 2 OR bold_line_count >= 3)                       AS is_multi_topic
FROM sized;

-- CREATE OR REPLACE resets change tracking; Gold dynamic table needs it for incremental refresh
ALTER TABLE RENTAL_OPS.SILVER.policy_document_chunks SET CHANGE_TRACKING = TRUE;

-- Validate 1: size distribution (c1_header was: 35 chunks, median 82, max 491)
-- Expect: 42 chunks, 6 documents, 8 loyalty FAQ chunks, min 49, median 81, max 183 (<= 512), flagged = 0
--         (is_oversized threshold = 3 x 81 = 243 tokens)
SELECT chunking_version,
       COUNT(*)                                        AS row_count,
       COUNT(DISTINCT file_name)                       AS document_count,
       COUNT_IF(file_name = 'loyalty_program_faq.md')  AS faq_chunks,
       MIN(chunk_token_count)                          AS min_tokens,
       MEDIAN(chunk_token_count)                       AS median_tokens,
       MAX(chunk_token_count)                          AS max_tokens,
       COUNT_IF(is_oversized OR is_undersized OR is_multi_topic) AS flagged
FROM RENTAL_OPS.SILVER.policy_document_chunks
GROUP BY chunking_version;

-- Validate 2: flagged chunks (expect 0 rows)
SELECT chunk_id, chunk_token_count, is_oversized, is_undersized, is_multi_topic
FROM RENTAL_OPS.SILVER.policy_document_chunks
WHERE is_oversized OR is_undersized OR is_multi_topic;

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
-- =============================================================

CREATE SCHEMA IF NOT EXISTS RENTAL_OPS.SILVER;

CREATE OR REPLACE TABLE RENTAL_OPS.SILVER.policy_document_chunks AS
WITH docs AS (
    SELECT
        "file_name"     AS file_name,
        "file_path"     AS file_path,
        "document_text" AS document_text,
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
    document_title || ' | ' || COALESCE(section_header, 'Overview') || '\n\n' || chunk_text AS chunk_text_with_context,
    LENGTH(chunk_text)                                                       AS chunk_char_length,
    AI_COUNT_TOKENS('ai_embed', 'snowflake-arctic-embed-l-v2.0', chunk_text_with_context) AS chunk_token_count
FROM chunks
WHERE chunk_text <> ''
  -- Drop metadata-only Overview chunks (header block, no body): they rank high on
  -- broad queries but answer nothing; the metadata is already in its own columns.
  -- Overview chunks with real body text (driving rules intro, loyalty FAQ) are kept.
  AND NOT (
      chunks.section_header IS NULL
      AND TRIM(REGEXP_REPLACE(chunk_text, '^(# .*|\\*\\*[^*]+:\\*\\*.*)$', '', 1, 0, 'm'), ' \n\r\t') = ''
  );

-- CREATE OR REPLACE resets change tracking; Gold dynamic table needs it for incremental refresh
ALTER TABLE RENTAL_OPS.SILVER.policy_document_chunks SET CHANGE_TRACKING = TRUE;

-- Validate: rows, docs, max tokens (expect <= 512)
SELECT COUNT(*) AS row_count,
       COUNT(DISTINCT file_name) AS document_count,
       MAX(chunk_token_count) AS max_tokens,
       ROUND(AVG(chunk_token_count)) AS avg_tokens
FROM RENTAL_OPS.SILVER.policy_document_chunks;

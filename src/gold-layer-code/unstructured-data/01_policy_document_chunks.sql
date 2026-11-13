-- =============================================================
-- Gold Layer | Policy document chunks (Dynamic Table, TARGET_LAG = 3 minutes)
-- Source: RENTAL_OPS.SILVER.policy_document_chunks (c2_structure: header + FAQ split, <=512 tokens)
--         LEFT JOIN RENTAL_OPS.SILVER.policy_chunk_generated_questions (doc2query, v1)
-- Prereq: silver-layer-code/unstructured-data/01_policy_document_chunks.sql,
--         silver-layer-code/unstructured-data/02_policy_chunk_generated_questions.sql
-- Business-ready corpus for the Cortex Search service; no AI calls here,
-- so refreshes cost no AI tokens (token counts + questions already computed in Silver).
-- Grain: 1 row per chunk. search_text is the column to index.
-- Questions join on chunk_id AND the chunk-text hash, so questions generated for an older
-- version of a chunk never attach to new text; such chunks fall back to chunk_text_with_context.
-- Chunk-quality flags are carried (not filtered): a flagged chunk stays searchable and visible;
-- the Silver validation lists flagged chunks (expected none).
-- Cost rule: all dynamic tables stay SUSPENDED; the script suspends the DT right after the
-- initial refresh. Refresh on demand with ALTER DYNAMIC TABLE ... REFRESH.
-- =============================================================

CREATE SCHEMA IF NOT EXISTS RENTAL_OPS.GOLD;

-- Silver sources are regular tables: enable change tracking for incremental refresh
ALTER TABLE RENTAL_OPS.SILVER.policy_document_chunks SET CHANGE_TRACKING = TRUE;
ALTER TABLE RENTAL_OPS.SILVER.policy_chunk_generated_questions SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE DYNAMIC TABLE RENTAL_OPS.GOLD.policy_document_chunks
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT
    c.chunk_id::STRING                AS chunk_id,                 -- PK: <document>_<chunk_index>
    REPLACE(c.file_name, '.md', '')   AS document_id,
    c.document_title::STRING          AS document_title,
    c.document_type::STRING           AS document_type,            -- search filter attribute
    c.applies_to::STRING              AS applies_to,               -- NULL when the document has no "Applies to"
    c.last_updated::DATE              AS last_updated,
    c.chunk_index::NUMBER             AS chunk_index,
    c.section_header::STRING          AS section_header,
    c.chunk_text::STRING              AS chunk_text,               -- raw section text (for display / citation)
    c.chunk_text_with_context::STRING AS chunk_text_with_context,  -- title | section + text
    c.chunk_token_count::NUMBER       AS chunk_token_count,
    c.chunking_version::STRING        AS chunking_version,         -- c2_structure (Phase 2b)
    (c.is_oversized OR c.is_undersized OR c.is_multi_topic)::BOOLEAN AS is_quality_flagged,
    q.generated_questions             AS generated_questions,      -- doc2query questions (NULL if none)
    q.doc2query_model::STRING         AS doc2query_model,
    COALESCE(q.search_text, c.chunk_text_with_context)::STRING  AS search_text,             -- index this
    COALESCE(q.search_text_token_count, c.chunk_token_count)::NUMBER AS search_text_token_count,
    c.file_path::STRING               AS source_file_path          -- path on @RENTAL_OPS.BRONZE.LANDING
FROM RENTAL_OPS.SILVER.policy_document_chunks c
LEFT JOIN RENTAL_OPS.SILVER.policy_chunk_generated_questions q
       ON q.chunk_id = c.chunk_id
      AND q.source_text_sha = SHA2(c.chunk_text_with_context);

-- Keep the DT suspended (cost); the initial refresh above already populated it
ALTER DYNAMIC TABLE RENTAL_OPS.GOLD.policy_document_chunks SUSPEND;

-- Validate: gold_rows = silver_rows = 42, unique chunk_id, with_questions = 42,
-- max_chunk_tokens = 183, max_search_tokens < 512, flagged = 0, chunking_version c2_structure,
-- scheduling SUSPENDED
SELECT
    (SELECT COUNT(*) FROM RENTAL_OPS.SILVER.policy_document_chunks) AS silver_rows,
    COUNT(*)                          AS gold_rows,
    COUNT(DISTINCT chunk_id)          AS distinct_chunk_ids,
    COUNT(DISTINCT document_id)       AS documents,
    COUNT(generated_questions)        AS with_questions,
    MAX(chunk_token_count)            AS max_chunk_tokens,
    MAX(search_text_token_count)      AS max_search_tokens,
    COUNT_IF(is_quality_flagged)      AS flagged,
    LISTAGG(DISTINCT chunking_version, ',') AS chunking_versions
FROM RENTAL_OPS.GOLD.policy_document_chunks;
SHOW DYNAMIC TABLES LIKE 'POLICY_DOCUMENT_CHUNKS' IN SCHEMA RENTAL_OPS.GOLD;

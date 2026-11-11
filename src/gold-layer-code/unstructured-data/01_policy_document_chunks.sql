-- =============================================================
-- Gold Layer | Policy document chunks (Dynamic Table, TARGET_LAG = 3 minutes)
-- Source: RENTAL_OPS.SILVER.policy_document_chunks (header-split, <=512 tokens)
-- Prereq: silver-layer-code/unstructured-data/01_policy_document_chunks.sql
-- Business-ready corpus for the Cortex Search service; no AI calls here,
-- so refreshes cost no AI tokens (token counts already computed in Silver).
-- Grain: 1 row per chunk. chunk_text_with_context is the column to index.
-- =============================================================

CREATE SCHEMA IF NOT EXISTS RENTAL_OPS.GOLD;

-- Silver source is a regular table: enable change tracking for incremental refresh
ALTER TABLE RENTAL_OPS.SILVER.policy_document_chunks SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE DYNAMIC TABLE RENTAL_OPS.GOLD.policy_document_chunks
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT
    chunk_id::STRING                AS chunk_id,                 -- PK: <document>_<chunk_index>
    REPLACE(file_name, '.md', '')   AS document_id,
    document_title::STRING          AS document_title,
    document_type::STRING           AS document_type,            -- search filter attribute
    applies_to::STRING              AS applies_to,               -- NULL when the document has no "Applies to"
    last_updated::DATE              AS last_updated,
    chunk_index::NUMBER             AS chunk_index,
    section_header::STRING          AS section_header,
    chunk_text::STRING              AS chunk_text,               -- raw section text (for display / citation)
    chunk_text_with_context::STRING AS chunk_text_with_context,  -- title | section + text (index this)
    chunk_token_count::NUMBER       AS chunk_token_count,
    file_path::STRING               AS source_file_path          -- path on @RENTAL_OPS.BRONZE.LANDING
FROM RENTAL_OPS.SILVER.policy_document_chunks;

-- Validate: row count must equal Silver (39), unique chunk_id, max tokens <= 512
SELECT
    (SELECT COUNT(*) FROM RENTAL_OPS.SILVER.policy_document_chunks) AS silver_rows,
    COUNT(*)                   AS gold_rows,
    COUNT(DISTINCT chunk_id)   AS distinct_chunk_ids,
    COUNT(DISTINCT document_id) AS documents,
    MAX(chunk_token_count)     AS max_tokens
FROM RENTAL_OPS.GOLD.policy_document_chunks;

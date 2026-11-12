-- =============================================================
-- Gold Layer | Cortex Search service over policy document chunks
-- Source: RENTAL_OPS.GOLD.policy_document_chunks (35 header-split chunks, <=512 tokens)
-- Prereq: gold-layer-code/unstructured-data/01_policy_document_chunks.sql
-- Search column : search_text (title | section + chunk text + doc2query questions, v1).
--                 v0 indexed chunk_text_with_context; chunk_text is still returned for citation.
-- Filter attr   : document_type (e.g. 'Customer-facing policy')
-- TARGET_LAG 1 day: policy library rarely changes. Worst-case staleness is
-- service lag + Gold DT lag (3 min) after a Silver reload.
--
-- Why user-provided vectors: this account blocks legacy SNOWFLAKE.CORTEX.EMBED_TEXT_*
-- functions, which the managed-embedding forms (ON ... / EMBEDDING_MODEL /
-- VECTOR INDEXES col(model=...)) call internally. So the source query embeds
-- with AI_EMBED, and query_model embeds the search query with the same model.
-- Hybrid search is kept: keyword index on the text + vector index on the embedding.
-- Same embedding model as chunk_token_count in Silver.
-- =============================================================

CREATE OR REPLACE CORTEX SEARCH SERVICE RENTAL_OPS.GOLD.policy_search
  TEXT INDEXES search_text
  VECTOR INDEXES search_embedding (query_model = 'snowflake-arctic-embed-l-v2.0')
  PRIMARY KEY (chunk_id)
  ATTRIBUTES document_type
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 day'
AS (
    SELECT
        search_text,
        AI_EMBED('snowflake-arctic-embed-l-v2.0', search_text) AS search_embedding,
        document_type,
        -- returned with results for citations / display (not searchable, not filterable)
        chunk_id,
        document_id,
        document_title,
        section_header,
        chunk_text,
        last_updated
    FROM RENTAL_OPS.GOLD.policy_document_chunks
);

-- Validate: service state and indexed row count (expect 35)
DESCRIBE CORTEX SEARCH SERVICE RENTAL_OPS.GOLD.policy_search;

-- Smoke test: filtered query
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'RENTAL_OPS.GOLD.policy_search',
        '{
            "query": "What happens if I cancel less than 24 hours before pickup?",
            "columns": ["chunk_id", "section_header", "chunk_text"],
            "filter": {"@eq": {"document_type": "Customer-facing policy"}},
            "limit": 3
        }'
    )
):results AS results;

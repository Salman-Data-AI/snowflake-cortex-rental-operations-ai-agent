-- =============================================================
-- Bronze Layer | Policy documents: stage + load data/Unstructured/policy_documents/*.md
-- Prereq: bronze-layer-code/01_setup_database_schema_stage.sql (DB, schema, LANDING stage)
-- One row per document, full markdown text stored exactly as written.
-- First step of the RAG pipeline (chunking + Cortex Search build on this table).
-- Rerunnable: table is replaced and the files reloaded (FORCE ignores load history).
-- =============================================================

USE SCHEMA RENTAL_OPS.BRONZE;

-- Whole file = one field, one record (no delimiters split the text)
CREATE FILE FORMAT IF NOT EXISTS FF_WHOLE_FILE_TEXT
    TYPE = CSV
    FIELD_DELIMITER = NONE
    RECORD_DELIMITER = NONE
    SKIP_HEADER = 0
    TRIM_SPACE = FALSE
    EMPTY_FIELD_AS_NULL = FALSE
    NULL_IF = ()
    ENCODING = 'UTF8';

-- Copy the source files from the workspace data/ folder to the landing stage
-- (land as Unstructured/policy_documents/<file> on the stage)
COPY FILES INTO @RENTAL_OPS.BRONZE.LANDING
FROM 'snow://workspace/USER$.PUBLIC."snowflake-cortex-rental-operations-ai-agent"/versions/live/data/'
FILES = (
    'Unstructured/policy_documents/cancellation_refund_policy.md',
    'Unstructured/policy_documents/driving_rules_by_region.md',
    'Unstructured/policy_documents/insurance_damage_waiver.md',
    'Unstructured/policy_documents/loyalty_program_faq.md',
    'Unstructured/policy_documents/rental_agreement_terms.md',
    'Unstructured/policy_documents/roadside_assistance_guide.md'
);

-- ---------- DDL ----------
CREATE OR REPLACE TABLE bronze_policy_documents (
    "file_name"     VARCHAR,
    "file_path"     VARCHAR,
    "document_text" VARCHAR,
    "loaded_at"     TIMESTAMP_LTZ
);

-- ---------- Load ----------
COPY INTO bronze_policy_documents
FROM (
    SELECT
        SPLIT_PART(METADATA$FILENAME, '/', -1),
        METADATA$FILENAME,
        $1,
        CURRENT_TIMESTAMP()
    FROM @RENTAL_OPS.BRONZE.LANDING/Unstructured/policy_documents/
)
FILE_FORMAT = (FORMAT_NAME = 'RENTAL_OPS.BRONZE.FF_WHOLE_FILE_TEXT')
PATTERN = '.*[.]md'
FORCE = TRUE;

-- Validate: expect 6 rows, text lengths matching the source files
SELECT "file_name", LENGTH("document_text") AS text_length
FROM bronze_policy_documents
ORDER BY "file_name";

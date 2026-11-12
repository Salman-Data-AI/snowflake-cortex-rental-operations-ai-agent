-- =============================================================
-- Bronze Layer | Reviews: stage + load data/Unstructured/reviews.csv
-- Prereq: bronze-layer-code/01_setup_database_schema_stage.sql (DB, schema, LANDING stage)
-- All columns VARCHAR, stored exactly as written (same pattern as FleetOps loads).
-- Rerunnable: table is replaced and the file reloaded (FORCE ignores load history).
-- =============================================================

USE SCHEMA RENTAL_OPS.BRONZE;

CREATE FILE FORMAT IF NOT EXISTS FF_CSV
    TYPE = CSV
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    TRIM_SPACE = FALSE
    EMPTY_FIELD_AS_NULL = FALSE
    NULL_IF = ()
    ENCODING = 'UTF8';

-- Copy the source file from the workspace data/ folder to the landing stage
-- (lands as Unstructured/<file> on the stage: path is relative to the FROM folder)
-- Snowsight Workspace only. From the local CLI use scripts/stage_source_files.sh instead.
COPY FILES INTO @RENTAL_OPS.BRONZE.LANDING
FROM 'snow://workspace/USER$.PUBLIC."snowflake-cortex-rental-operations-ai-agent"/versions/live/data/'
FILES = ('Unstructured/reviews.csv');

-- ---------- DDL ----------
CREATE OR REPLACE TABLE bronze_reviews (
    "review_id" VARCHAR, "reservation_id" VARCHAR, "customer_id" VARCHAR,
    "car_id" VARCHAR, "branch_id" VARCHAR, "rating" VARCHAR,
    "language" VARCHAR, "review_text" VARCHAR, "review_date" VARCHAR
);

-- ---------- Load ----------
COPY INTO bronze_reviews
FROM @RENTAL_OPS.BRONZE.LANDING/Unstructured/reviews.csv
FILE_FORMAT = (FORMAT_NAME = 'RENTAL_OPS.BRONZE.FF_CSV')
FORCE = TRUE;

-- Validate: expect 1400
SELECT COUNT(*) AS row_count FROM bronze_reviews;

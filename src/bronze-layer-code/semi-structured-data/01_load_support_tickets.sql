-- =============================================================
-- Bronze Layer | Support tickets: stage + load Unstructured/support_tickets.csv
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

-- Copy the source file from the workspace to the landing stage
COPY FILES INTO @RENTAL_OPS.BRONZE.LANDING
FROM 'snow://workspace/USER$.PUBLIC."snowflake-cortex-rental-operations-ai-agent"/versions/live/'
FILES = ('Unstructured/support_tickets.csv');

-- ---------- DDL ----------
CREATE OR REPLACE TABLE bronze_support_tickets (
    "ticket_id" VARCHAR, "customer_id" VARCHAR, "reservation_id" VARCHAR,
    "category" VARCHAR, "channel" VARCHAR, "status" VARCHAR,
    "created_date" VARCHAR, "ticket_body" VARCHAR
);

-- ---------- Load ----------
COPY INTO bronze_support_tickets
FROM @RENTAL_OPS.BRONZE.LANDING/Unstructured/support_tickets.csv
FILE_FORMAT = (FORMAT_NAME = 'RENTAL_OPS.BRONZE.FF_CSV')
FORCE = TRUE;

-- Validate: expect 300
SELECT COUNT(*) AS row_count FROM bronze_support_tickets;

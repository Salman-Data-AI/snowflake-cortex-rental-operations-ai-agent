-- =============================================================
-- Gold Layer | Support tickets enriched (Dynamic Table, TARGET_LAG = 3 minutes)
-- Source: RENTAL_OPS.SILVER.support_tickets_enriched (AI_CLASSIFY + AI_REDACT already applied)
-- Prereq: silver-layer-code/semi-structured-data/01_support_tickets_enriched.sql
-- Typed, business-ready; no AI calls here, so refreshes cost no AI tokens.
-- Grain: 1 row per ticket. Joins to GOLD dims via customer_id / reservation_id.
-- =============================================================

CREATE SCHEMA IF NOT EXISTS RENTAL_OPS.GOLD;

-- Silver source is a regular table: enable change tracking for incremental refresh
ALTER TABLE RENTAL_OPS.SILVER.support_tickets_enriched SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE DYNAMIC TABLE RENTAL_OPS.GOLD.support_tickets_enriched
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT
    TRY_TO_NUMBER(TRIM(ticket_id))      AS ticket_id,
    TRY_TO_NUMBER(TRIM(customer_id))    AS customer_id,      -- FK -> dim_customers.id
    TRY_TO_NUMBER(TRIM(reservation_id)) AS reservation_id,   -- FK -> fact_reservations.id (NULL when not given)
    TRIM(category)                      AS category,         -- category assigned in source system
    TRIM(ai_category)                   AS ai_category,      -- AI_CLASSIFY on raw ticket text
    TRIM(channel)                       AS channel,
    TRIM(status)                        AS status,
    TRY_TO_DATE(TRIM(created_date))     AS created_date,
    ticket_body::STRING                 AS ticket_body       -- PII-redacted (AI_REDACT); cast from VARIANT
FROM RENTAL_OPS.SILVER.support_tickets_enriched;

-- Validate: row count must equal Silver (300) and Bronze
SELECT
    (SELECT COUNT(*) FROM RENTAL_OPS.BRONZE.bronze_support_tickets)   AS bronze_rows,
    (SELECT COUNT(*) FROM RENTAL_OPS.SILVER.support_tickets_enriched) AS silver_rows,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.support_tickets_enriched)   AS gold_rows;

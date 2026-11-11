-- =============================================================
-- Gold Layer | Reviews enriched (Dynamic Table, TARGET_LAG = 3 minutes)
-- Source: RENTAL_OPS.SILVER.reviews_enriched (AI_SENTIMENT + AI_TRANSLATE already applied)
-- Prereq: silver-layer-code/semi-structured-data/02_reviews_enriched.sql
-- Typed, business-ready; no AI calls here, so refreshes cost no AI tokens.
-- Grain: 1 row per review. Joins to GOLD via reservation_id / customer_id / car_id / branch_id.
-- =============================================================

CREATE SCHEMA IF NOT EXISTS RENTAL_OPS.GOLD;

-- Silver source is a regular table: enable change tracking for incremental refresh
ALTER TABLE RENTAL_OPS.SILVER.reviews_enriched SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE DYNAMIC TABLE RENTAL_OPS.GOLD.reviews_enriched
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT
    TRY_TO_NUMBER(TRIM(review_id))      AS review_id,
    TRY_TO_NUMBER(TRIM(reservation_id)) AS reservation_id,   -- FK -> fact_reservations.id
    TRY_TO_NUMBER(TRIM(customer_id))    AS customer_id,      -- FK -> dim_customers.id
    TRY_TO_NUMBER(TRIM(car_id))         AS car_id,           -- FK -> dim_cars.id
    TRY_TO_NUMBER(TRIM(branch_id))      AS branch_id,        -- FK -> dim_branches.id
    TRY_TO_NUMBER(TRIM(rating))         AS rating,           -- 1-5 stars
    LOWER(TRIM(language))               AS language,         -- en | de | es | fr
    TRY_TO_DATE(TRIM(review_date))      AS review_date,
    review_text,                                             -- original language
    review_text_en,                                          -- English (AI_TRANSLATE for non-en)
    sentiment,                                               -- AI_SENTIMENT overall label
    CASE sentiment WHEN 'positive' THEN 1 WHEN 'negative' THEN -1 ELSE 0 END AS sentiment_score
FROM RENTAL_OPS.SILVER.reviews_enriched;

-- Validate: row count must equal Silver and Bronze (1400)
SELECT
    (SELECT COUNT(*) FROM RENTAL_OPS.BRONZE.bronze_reviews)   AS bronze_rows,
    (SELECT COUNT(*) FROM RENTAL_OPS.SILVER.reviews_enriched) AS silver_rows,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.reviews_enriched)   AS gold_rows;

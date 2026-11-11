-- =============================================================
-- Silver Layer | Reviews: enrich with Cortex AI
-- Prereq: bronze-layer-code/semi-structured-data/02_load_reviews.sql
-- Rerunnable (CREATE OR REPLACE). Re-runs AI on all rows (~1,400 reviews, ~200K input tokens).
-- sentiment      : AI_SENTIMENT overall label on the ORIGINAL text (multilingual;
--                  avoids translation drift). positive | negative | neutral | mixed | unknown
-- review_text_en : AI_TRANSLATE to English where language <> 'en', else original copied
-- Other columns carried over as-is from Bronze; original review_text kept.
-- Plain table (not a dynamic table) so AI functions run once, not per refresh.
-- =============================================================

CREATE OR REPLACE TABLE RENTAL_OPS.SILVER.reviews_enriched AS
SELECT
    "review_id"      AS review_id,
    "reservation_id" AS reservation_id,
    "customer_id"    AS customer_id,
    "car_id"         AS car_id,
    "branch_id"      AS branch_id,
    "rating"         AS rating,
    "language"       AS language,
    "review_text"    AS review_text,
    "review_date"    AS review_date,
    AI_SENTIMENT("review_text"):categories[0]:sentiment::STRING AS sentiment,
    CASE WHEN "language" <> 'en'
         THEN AI_TRANSLATE("review_text", "language", 'en')
         ELSE "review_text"
    END AS review_text_en
FROM RENTAL_OPS.BRONZE.bronze_reviews;

-- Validate: expect 1400 rows, no NULL enrichment, 113 translated
SELECT COUNT(*)                        AS row_count,
       COUNT(DISTINCT review_id)       AS distinct_review_ids,
       COUNT_IF(sentiment IS NULL)     AS null_sentiment,
       COUNT_IF(review_text_en IS NULL) AS null_review_text_en,
       COUNT_IF(language <> 'en')      AS translated_rows
FROM RENTAL_OPS.SILVER.reviews_enriched;

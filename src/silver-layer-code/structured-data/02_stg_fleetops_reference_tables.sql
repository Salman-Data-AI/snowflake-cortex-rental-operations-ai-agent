-- =============================================================
-- Silver Layer | Step 02: Conform FleetOps reference tables
-- Grain preserved (one row per Bronze row). Cleanup = trim/uppercase codes,
-- cast to proper types. Boolean is_* flags surface referential inconsistencies;
-- a FALSE flag means the row needs attention. Flag joins use DISTINCT-key
-- subqueries so they can never duplicate rows.
-- =============================================================

-- Dynamic tables require change tracking on every base table they read
ALTER TABLE RENTAL_OPS.BRONZE.bronze_currencies                   SET CHANGE_TRACKING = TRUE;
ALTER TABLE RENTAL_OPS.BRONZE.bronze_countries                    SET CHANGE_TRACKING = TRUE;
ALTER TABLE RENTAL_OPS.BRONZE.bronze_branches                     SET CHANGE_TRACKING = TRUE;
ALTER TABLE RENTAL_OPS.BRONZE.bronze_car_categories               SET CHANGE_TRACKING = TRUE;
ALTER TABLE RENTAL_OPS.BRONZE.bronze_branch_category_availability SET CHANGE_TRACKING = TRUE;

-- ---------- Currencies: 1 row per currency ----------
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.SILVER.stg_fleetops_currencies
  TARGET_LAG = '1 minute'
  WAREHOUSE = COMPUTE_WH
  REFRESH_MODE = INCREMENTAL
  INITIALIZE = ON_CREATE
AS
SELECT
    UPPER(TRIM(u."currency_code"))                    AS currency_code,
    TRIM(u."currency_name")                           AS currency_name,
    TRIM(u."symbol")                                  AS currency_symbol,
    TRY_TO_DECIMAL(TRIM(u."usd_exchange_rate"), 18, 6) AS usd_exchange_rate,
    TRY_TO_NUMBER(TRIM(u."decimals"))                 AS decimal_places,
    (c.currency_code IS NOT NULL)                     AS is_referenced_by_country
FROM RENTAL_OPS.BRONZE.bronze_currencies u
LEFT JOIN (SELECT DISTINCT UPPER(TRIM("currency_code")) AS currency_code
           FROM RENTAL_OPS.BRONZE.bronze_countries) c
       ON c.currency_code = UPPER(TRIM(u."currency_code"));

-- ---------- Countries: 1 row per country ----------
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.SILVER.stg_fleetops_countries
  TARGET_LAG = '1 minute'
  WAREHOUSE = COMPUTE_WH
  REFRESH_MODE = INCREMENTAL
  INITIALIZE = ON_CREATE
AS
SELECT
    TRY_TO_NUMBER(TRIM(c."country_id"))   AS country_id,
    UPPER(TRIM(c."country_code"))         AS country_code,
    TRIM(c."country_name")                AS country_name,
    TRIM(c."region")                      AS region,
    UPPER(TRIM(c."currency_code"))        AS currency_code,
    (u.currency_code IS NOT NULL)         AS is_currency_valid,
    (b.country_id IS NOT NULL)            AS has_branch
FROM RENTAL_OPS.BRONZE.bronze_countries c
LEFT JOIN (SELECT DISTINCT UPPER(TRIM("currency_code")) AS currency_code
           FROM RENTAL_OPS.BRONZE.bronze_currencies) u
       ON u.currency_code = UPPER(TRIM(c."currency_code"))
LEFT JOIN (SELECT DISTINCT TRIM("country_id") AS country_id
           FROM RENTAL_OPS.BRONZE.bronze_branches) b
       ON b.country_id = TRIM(c."country_id");

-- ---------- Branch x category availability: 1 row per branch/category ----------
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.SILVER.stg_fleetops_branch_category_availability
  TARGET_LAG = '1 minute'
  WAREHOUSE = COMPUTE_WH
  REFRESH_MODE = INCREMENTAL
  INITIALIZE = ON_CREATE
AS
SELECT
    TRY_TO_NUMBER(TRIM(a."branch_id"))                AS branch_id,
    TRIM(a."branch_name")                             AS branch_name,
    TRY_TO_NUMBER(TRIM(a."category_id"))              AS category_id,
    TRIM(a."category_name")                           AS category_name,
    TRY_TO_BOOLEAN(TRIM(a."is_offered"))              AS is_offered,
    (b.branch_id IS NOT NULL)                         AS is_branch_valid,
    (k.category_id IS NOT NULL)                       AS is_category_valid,
    COALESCE(b.branch_name = TRIM(a."branch_name"), FALSE)       AS is_branch_name_consistent,
    COALESCE(k.category_name = TRIM(a."category_name"), FALSE)   AS is_category_name_consistent,
    COALESCE(b.is_currency_valid, FALSE)              AS is_branch_currency_valid
FROM RENTAL_OPS.BRONZE.bronze_branch_category_availability a
LEFT JOIN (
    -- branch -> country -> currency resolution, one row per branch id
    SELECT TRIM(br."id")    AS branch_id,
           MAX(TRIM(br."name")) AS branch_name,
           BOOLOR_AGG(cu.currency_code IS NOT NULL) AS is_currency_valid
    FROM RENTAL_OPS.BRONZE.bronze_branches br
    LEFT JOIN RENTAL_OPS.BRONZE.bronze_countries co
           ON TRIM(co."country_id") = TRIM(br."country_id")
    LEFT JOIN (SELECT DISTINCT UPPER(TRIM("currency_code")) AS currency_code
               FROM RENTAL_OPS.BRONZE.bronze_currencies) cu
           ON cu.currency_code = UPPER(TRIM(co."currency_code"))
    GROUP BY TRIM(br."id")
) b ON b.branch_id = TRIM(a."branch_id")
LEFT JOIN (SELECT TRIM("id") AS category_id, MAX(TRIM("name")) AS category_name
           FROM RENTAL_OPS.BRONZE.bronze_car_categories
           GROUP BY TRIM("id")) k
       ON k.category_id = TRIM(a."category_id");

-- ---------- Validation ----------
-- Expect: all 3 INCREMENTAL / ACTIVE, 1 minute lag
SHOW DYNAMIC TABLES LIKE 'STG_FLEETOPS_%' IN SCHEMA RENTAL_OPS.SILVER;

-- Expect row counts 6 / 7 / 60 (same as Bronze) and 0 in every flag_failures column
SELECT 'currencies' AS tbl, COUNT(*) AS row_count,
       COUNT_IF(NOT is_referenced_by_country OR usd_exchange_rate IS NULL OR decimal_places IS NULL) AS flag_failures
FROM RENTAL_OPS.SILVER.stg_fleetops_currencies
UNION ALL
SELECT 'countries', COUNT(*),
       COUNT_IF(NOT is_currency_valid OR NOT has_branch OR country_id IS NULL)
FROM RENTAL_OPS.SILVER.stg_fleetops_countries
UNION ALL
SELECT 'branch_category_availability', COUNT(*),
       COUNT_IF(NOT is_branch_valid OR NOT is_category_valid OR NOT is_branch_name_consistent
                OR NOT is_category_name_consistent OR NOT is_branch_currency_valid OR is_offered IS NULL)
FROM RENTAL_OPS.SILVER.stg_fleetops_branch_category_availability;

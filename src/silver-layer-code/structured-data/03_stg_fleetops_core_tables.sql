-- =============================================================
-- Silver Layer | Step 03: Conform remaining FleetOps tables
-- branches, car_categories, cars, customers. Grain preserved.
-- Boolean is_* flags surface inconsistencies (FALSE = needs attention).
-- =============================================================

-- Change tracking (branches & car_categories already enabled in step 02)
ALTER TABLE RENTAL_OPS.BRONZE.bronze_cars      SET CHANGE_TRACKING = TRUE;
ALTER TABLE RENTAL_OPS.BRONZE.bronze_customers SET CHANGE_TRACKING = TRUE;

-- ---------- Car categories: 1 row per category ----------
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.SILVER.stg_fleetops_car_categories
  TARGET_LAG = '1 minute' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT
    TRY_TO_NUMBER(TRIM("id"))                    AS category_id,
    TRIM("name")                                 AS category_name,
    TRY_TO_DECIMAL(TRIM("daily_rate"), 12, 2)    AS daily_rate_usd,  -- assumed USD; source has no currency
    COALESCE(TRY_TO_DECIMAL(TRIM("daily_rate"), 12, 2) > 0, FALSE) AS is_daily_rate_valid
FROM RENTAL_OPS.BRONZE.bronze_car_categories;

-- ---------- Branches: 1 row per branch ----------
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.SILVER.stg_fleetops_branches
  TARGET_LAG = '1 minute' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT
    TRY_TO_NUMBER(TRIM(b."id"))          AS branch_id,
    TRIM(b."name")                       AS branch_name,
    TRIM(b."city")                       AS city,
    TRY_TO_NUMBER(TRIM(b."capacity"))    AS capacity,
    TRY_TO_NUMBER(TRIM(b."country_id"))  AS country_id,
    (c.country_id IS NOT NULL)           AS is_country_valid,
    COALESCE(TRY_TO_NUMBER(TRIM(b."capacity")) > 0, FALSE) AS is_capacity_valid
FROM RENTAL_OPS.BRONZE.bronze_branches b
LEFT JOIN (SELECT DISTINCT TRIM("country_id") AS country_id
           FROM RENTAL_OPS.BRONZE.bronze_countries) c
       ON c.country_id = TRIM(b."country_id");

-- ---------- Cars: 1 row per car ----------
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.SILVER.stg_fleetops_cars
  TARGET_LAG = '1 minute' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT
    TRY_TO_NUMBER(TRIM(c."id"))                 AS car_id,
    UPPER(TRIM(c."license_plate"))              AS license_plate,
    TRIM(c."model")                             AS model,
    TRY_TO_NUMBER(TRIM(c."year"))               AS model_year,
    TRY_TO_NUMBER(TRIM(c."category_id"))        AS category_id,
    TRY_TO_NUMBER(TRIM(c."current_branch_id"))  AS current_branch_id,
    (k.category_id IS NOT NULL)                 AS is_category_valid,
    (b.branch_id IS NOT NULL)                   AS is_branch_valid,
    COALESCE(a.is_offered, FALSE)               AS is_category_offered_at_branch,
    (p.license_plate IS NULL)                   AS is_license_plate_unique
FROM RENTAL_OPS.BRONZE.bronze_cars c
LEFT JOIN (SELECT DISTINCT TRIM("id") AS category_id FROM RENTAL_OPS.BRONZE.bronze_car_categories) k
       ON k.category_id = TRIM(c."category_id")
LEFT JOIN (SELECT DISTINCT TRIM("id") AS branch_id FROM RENTAL_OPS.BRONZE.bronze_branches) b
       ON b.branch_id = TRIM(c."current_branch_id")
LEFT JOIN (SELECT TRIM("branch_id") AS branch_id, TRIM("category_id") AS category_id,
                  BOOLOR_AGG(TRIM("is_offered") = 'True') AS is_offered
           FROM RENTAL_OPS.BRONZE.bronze_branch_category_availability
           GROUP BY 1, 2) a
       ON a.branch_id = TRIM(c."current_branch_id") AND a.category_id = TRIM(c."category_id")
LEFT JOIN (SELECT UPPER(TRIM("license_plate")) AS license_plate
           FROM RENTAL_OPS.BRONZE.bronze_cars GROUP BY 1 HAVING COUNT(*) > 1) p
       ON p.license_plate = UPPER(TRIM(c."license_plate"));

-- ---------- Customers: 1 row per customer ----------
-- Phone: main number = digits before 'x'; leading '001' / '1' country prefix stripped
-- to a 10-digit number; extension kept separately. phone_e164 assumes +1 (NANP).
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.SILVER.stg_fleetops_customers
  TARGET_LAG = '1 minute' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
WITH base AS (
    SELECT
        TRY_TO_NUMBER(TRIM("id"))                                         AS customer_id,
        TRIM("name")                                                      AS customer_name,
        LOWER(TRIM("email"))                                              AS email,
        TRIM("phone")                                                     AS phone_raw,
        REGEXP_REPLACE(SPLIT_PART(LOWER(TRIM("phone")), 'x', 1), '[^0-9]', '') AS phone_digits,
        NULLIF(REGEXP_REPLACE(SPLIT_PART(LOWER(TRIM("phone")), 'x', 2), '[^0-9]', ''), '') AS phone_extension,
        UPPER(TRIM("driver_license_number"))                              AS driver_license_number,
        TRY_TO_DATE(TRIM("date_of_birth"), 'YYYY-MM-DD')                  AS date_of_birth
    FROM RENTAL_OPS.BRONZE.bronze_customers
), norm AS (
    SELECT *,
        CASE WHEN LENGTH(phone_digits) = 13 AND STARTSWITH(phone_digits, '001') THEN SUBSTR(phone_digits, 4)
             WHEN LENGTH(phone_digits) = 11 AND STARTSWITH(phone_digits, '1')   THEN SUBSTR(phone_digits, 2)
             ELSE phone_digits END AS phone_number
    FROM base
)
SELECT
    n.customer_id,
    n.customer_name,
    n.email,
    n.phone_raw,
    n.phone_number,
    n.phone_extension,
    IFF(LENGTH(n.phone_number) = 10, '+1' || n.phone_number, NULL)      AS phone_e164,
    n.driver_license_number,
    n.date_of_birth,
    COALESCE(REGEXP_LIKE(n.email, '^[^@\\s]+@[^@\\s]+\\.[a-z]{2,}$'), FALSE) AS is_email_valid,
    COALESCE(REGEXP_LIKE(n.phone_number, '^[2-9][0-9]{9}$'), FALSE)      AS is_phone_valid,   -- NANP: area code can't start 0/1
    (n.date_of_birth IS NOT NULL)                                        AS is_date_of_birth_valid,
    (dn.customer_name IS NULL)                                           AS is_name_unique,
    (de.email IS NULL)                                                   AS is_email_unique,
    (dl.driver_license_number IS NULL)                                   AS is_license_unique
FROM norm n
LEFT JOIN (SELECT TRIM("name") AS customer_name FROM RENTAL_OPS.BRONZE.bronze_customers
           GROUP BY 1 HAVING COUNT(*) > 1) dn ON dn.customer_name = n.customer_name
LEFT JOIN (SELECT LOWER(TRIM("email")) AS email FROM RENTAL_OPS.BRONZE.bronze_customers
           GROUP BY 1 HAVING COUNT(*) > 1) de ON de.email = n.email
LEFT JOIN (SELECT UPPER(TRIM("driver_license_number")) AS driver_license_number FROM RENTAL_OPS.BRONZE.bronze_customers
           GROUP BY 1 HAVING COUNT(*) > 1) dl ON dl.driver_license_number = n.driver_license_number;

-- ---------- Validation ----------
-- Expect: all 4 INCREMENTAL / ACTIVE, 1 minute lag; rows 6 / 10 / 210 / 500 (same as Bronze)
SHOW DYNAMIC TABLES LIKE 'STG_FLEETOPS_%' IN SCHEMA RENTAL_OPS.SILVER;

SELECT 'car_categories' AS tbl, COUNT(*) AS row_count, COUNT_IF(NOT is_daily_rate_valid) AS flag_failures
FROM RENTAL_OPS.SILVER.stg_fleetops_car_categories
UNION ALL SELECT 'branches', COUNT(*), COUNT_IF(NOT is_country_valid OR NOT is_capacity_valid)
FROM RENTAL_OPS.SILVER.stg_fleetops_branches
UNION ALL SELECT 'cars', COUNT(*), COUNT_IF(NOT is_category_valid OR NOT is_branch_valid
                                            OR NOT is_category_offered_at_branch OR NOT is_license_plate_unique)
FROM RENTAL_OPS.SILVER.stg_fleetops_cars
UNION ALL SELECT 'customers', COUNT(*), COUNT_IF(NOT is_email_valid OR NOT is_phone_valid OR NOT is_date_of_birth_valid
                                                 OR NOT is_name_unique OR NOT is_email_unique OR NOT is_license_unique)
FROM RENTAL_OPS.SILVER.stg_fleetops_customers;

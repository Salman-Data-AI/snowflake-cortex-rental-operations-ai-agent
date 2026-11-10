-- =============================================================
-- Bronze Layer | Step 05: Validation
-- Expected row counts (from source files):
--   branches 10, cars 210, car_categories 6, countries 7, currencies 6,
--   customers 500, availability 60, reservations 2000
-- ISSUES column should be 0 for every table:
--   CSVs: no stray carriage returns in the last column (line-ending check);
--         currencies also checks multi-byte symbols survived (UTF-8).
--   JSON: every record keeps its nested paymentDetails and DD/MM/YYYY dates.
-- =============================================================

USE SCHEMA RENTAL_OPS.BRONZE;

SELECT 'branches' AS tbl, COUNT(*) AS row_count, COUNT_IF(CONTAINS("country_id", '\r')) AS issues FROM bronze_branches
UNION ALL SELECT 'cars',           COUNT(*), COUNT_IF(CONTAINS("current_branch_id", '\r')) FROM bronze_cars
UNION ALL SELECT 'car_categories', COUNT(*), COUNT_IF(CONTAINS("daily_rate", '\r'))        FROM bronze_car_categories
UNION ALL SELECT 'countries',      COUNT(*), COUNT_IF(CONTAINS("currency_code", '\r'))     FROM bronze_countries
UNION ALL SELECT 'currencies',     COUNT(*), COUNT_IF(CONTAINS("decimals", '\r')
                                                     OR "symbol" NOT IN ('$','CA$','€','£','¥','A$')) FROM bronze_currencies
UNION ALL SELECT 'customers',      COUNT(*), COUNT_IF(CONTAINS("date_of_birth", '\r'))     FROM bronze_customers
UNION ALL SELECT 'availability',   COUNT(*), COUNT_IF(CONTAINS("is_offered", '\r'))        FROM bronze_branch_category_availability
UNION ALL SELECT 'reservations',   COUNT(*), COUNT_IF(raw:paymentDetails[0]:paymentId IS NULL
                                                     OR raw:rentalStart::STRING NOT LIKE '__/__/____') FROM bronze_bookwave_reservations_raw;

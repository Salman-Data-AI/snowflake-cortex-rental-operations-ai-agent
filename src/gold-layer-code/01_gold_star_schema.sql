-- =============================================================
-- Gold Layer | Star schema (Dynamic Tables, TARGET_LAG = 3 minutes)
-- Source: RENTAL_OPS.SILVER dynamic tables (lag 1 minute).
-- fact_reservations joins dim_branches twice (pickup + return role).
-- All lookups are LEFT JOINs on unique keys: grain is never changed.
-- =============================================================

CREATE SCHEMA IF NOT EXISTS RENTAL_OPS.GOLD;

-- ---------- dim_currencies ----------
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.GOLD.dim_currencies
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT currency_code, currency_name, currency_symbol AS symbol, usd_exchange_rate, decimal_places
FROM RENTAL_OPS.SILVER.stg_fleetops_currencies;

-- ---------- dim_countries ----------
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.GOLD.dim_countries
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT country_id, country_code, country_name, region, currency_code
FROM RENTAL_OPS.SILVER.stg_fleetops_countries;

-- ---------- dim_branches (enriched with country, region, currency) ----------
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.GOLD.dim_branches
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT
    b.branch_id   AS id,
    b.branch_name AS name,
    b.city,
    b.capacity,
    b.country_id,
    c.country_code,
    c.country_name,
    c.region,
    c.currency_code   -- derived via country
FROM RENTAL_OPS.SILVER.stg_fleetops_branches b
LEFT JOIN RENTAL_OPS.SILVER.stg_fleetops_countries c ON c.country_id = b.country_id;

-- ---------- dim_car_categories ----------
-- Conformed parent for dim_cars.category_id and bridge.category_id
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.GOLD.dim_car_categories
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT category_id, category_name, daily_rate_usd
FROM RENTAL_OPS.SILVER.stg_fleetops_car_categories;

-- ---------- dim_cars ----------
-- is_new_fleet: Convertible pilot units (documented in cars_fleet_expansion.csv)
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.GOLD.dim_cars
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT
    c.car_id            AS id,
    c.license_plate,
    c.model,
    c.model_year        AS year,
    c.category_id,
    k.category_name     AS category,
    k.daily_rate_usd,
    c.current_branch_id,
    COALESCE(k.category_name = 'Convertible', FALSE) AS is_new_fleet
FROM RENTAL_OPS.SILVER.stg_fleetops_cars c
LEFT JOIN RENTAL_OPS.SILVER.stg_fleetops_car_categories k ON k.category_id = c.category_id;

-- ---------- dim_customers ----------
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.GOLD.dim_customers
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT
    customer_id     AS id,
    customer_name   AS name,
    email,
    phone_e164      AS phone,
    phone_extension,
    is_phone_valid,
    driver_license_number,
    date_of_birth
FROM RENTAL_OPS.SILVER.stg_fleetops_customers;

-- ---------- bridge_branch_category_availability ----------
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.GOLD.bridge_branch_category_availability
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT branch_id, category_id, category_name, is_offered
FROM RENTAL_OPS.SILVER.stg_fleetops_branch_category_availability;

-- ---------- fact_reservations ----------
-- total_days = nights (end_date - start_date).
-- total_amount_usd uses the current (undated) usd_exchange_rate snapshot.
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.GOLD.fact_reservations
  TARGET_LAG = '3 minutes' WAREHOUSE = COMPUTE_WH REFRESH_MODE = INCREMENTAL INITIALIZE = ON_CREATE
AS
SELECT
    r.reservation_id                                      AS id,
    r.pickup_branch_id,                                   -- FK -> dim_branches.id (pickup role)
    r.return_branch_id,                                   -- FK -> dim_branches.id (return role)
    r.customer_id,                                        -- FK -> dim_customers.id
    r.car_id,                                             -- FK -> dim_cars.id
    r.rental_start_date                                   AS start_date,
    r.rental_end_date                                     AS end_date,
    r.booked_date                                         AS booking_date,
    r.paid_date,
    r.payment_id,
    r.payment_method,
    DATEDIFF(day, r.rental_start_date, r.rental_end_date) AS total_days,
    r.amount_paid                                         AS amount_local,
    r.payment_currency                                    AS currency_code,  -- FK -> dim_currencies
    ROUND(r.amount_paid * u.usd_exchange_rate, 2)         AS total_amount_usd
FROM RENTAL_OPS.SILVER.stg_bookwave_reservations r
LEFT JOIN RENTAL_OPS.SILVER.stg_fleetops_currencies u ON u.currency_code = r.payment_currency;

-- ---------- Validation ----------
-- Expect: 8 DTs, 3 minute lag, INCREMENTAL, ACTIVE
SHOW DYNAMIC TABLES IN SCHEMA RENTAL_OPS.GOLD;

-- Expect: fact 2000, branches 10, cars 210, customers 500, countries 7, currencies 6, car_categories 6, bridge 60
-- and every orphan/null count = 0
SELECT
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.fact_reservations)                   AS fact_rows,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.dim_branches)                        AS dim_branches,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.dim_cars)                            AS dim_cars,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.dim_customers)                       AS dim_customers,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.dim_countries)                       AS dim_countries,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.dim_currencies)                      AS dim_currencies,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.dim_car_categories)                  AS dim_car_categories,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.dim_cars c
       WHERE NOT EXISTS (SELECT 1 FROM RENTAL_OPS.GOLD.dim_car_categories k WHERE k.category_id = c.category_id)) AS car_category_orphans,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.bridge_branch_category_availability a
       WHERE NOT EXISTS (SELECT 1 FROM RENTAL_OPS.GOLD.dim_car_categories k WHERE k.category_id = a.category_id)) AS bridge_category_orphans,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.bridge_branch_category_availability) AS bridge_rows,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.fact_reservations f
       LEFT JOIN RENTAL_OPS.GOLD.dim_branches pb ON pb.id = f.pickup_branch_id
       LEFT JOIN RENTAL_OPS.GOLD.dim_branches rb ON rb.id = f.return_branch_id
       LEFT JOIN RENTAL_OPS.GOLD.dim_customers c ON c.id = f.customer_id
       LEFT JOIN RENTAL_OPS.GOLD.dim_cars k     ON k.id = f.car_id
       LEFT JOIN RENTAL_OPS.GOLD.dim_currencies u ON u.currency_code = f.currency_code
     WHERE pb.id IS NULL OR rb.id IS NULL OR c.id IS NULL OR k.id IS NULL OR u.currency_code IS NULL) AS fact_orphans,
    (SELECT COUNT_IF(total_amount_usd IS NULL OR total_days IS NULL) FROM RENTAL_OPS.GOLD.fact_reservations) AS fact_null_measures,
    (SELECT COUNT(*) FROM RENTAL_OPS.GOLD.fact_reservations f
       JOIN RENTAL_OPS.GOLD.dim_branches pb ON pb.id = f.pickup_branch_id
     WHERE pb.currency_code <> f.currency_code)                                AS currency_mismatch_vs_pickup;

-- USD sanity check by currency
SELECT currency_code, COUNT(*) AS reservations, SUM(amount_local) AS amount_local, SUM(total_amount_usd) AS amount_usd
FROM RENTAL_OPS.GOLD.fact_reservations GROUP BY 1 ORDER BY amount_usd DESC;

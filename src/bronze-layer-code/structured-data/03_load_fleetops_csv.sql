-- =============================================================
-- Bronze Layer | Step 03: Load the 7 FleetOps CSVs, one table per file
-- Column names = exact (quoted, lowercase) source headers.
-- All columns VARCHAR so values are stored exactly as written:
-- no trimming, no empty-string-to-NULL conversion, no type casting.
-- =============================================================

USE SCHEMA RENTAL_OPS.BRONZE;

CREATE OR REPLACE FILE FORMAT FF_CSV
    TYPE = CSV
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    TRIM_SPACE = FALSE
    EMPTY_FIELD_AS_NULL = FALSE
    NULL_IF = ()
    ENCODING = 'UTF8';

-- ---------- DDL ----------
CREATE OR REPLACE TABLE bronze_branches (
    "id" VARCHAR, "name" VARCHAR, "city" VARCHAR, "capacity" VARCHAR, "country_id" VARCHAR
);

CREATE OR REPLACE TABLE bronze_cars (
    "id" VARCHAR, "license_plate" VARCHAR, "model" VARCHAR, "year" VARCHAR,
    "category_id" VARCHAR, "current_branch_id" VARCHAR
);

CREATE OR REPLACE TABLE bronze_car_categories (
    "id" VARCHAR, "name" VARCHAR, "daily_rate" VARCHAR
);

CREATE OR REPLACE TABLE bronze_countries (
    "country_id" VARCHAR, "country_code" VARCHAR, "country_name" VARCHAR,
    "region" VARCHAR, "currency_code" VARCHAR
);

CREATE OR REPLACE TABLE bronze_currencies (
    "currency_code" VARCHAR, "currency_name" VARCHAR, "symbol" VARCHAR,
    "usd_exchange_rate" VARCHAR, "decimals" VARCHAR
);

CREATE OR REPLACE TABLE bronze_customers (
    "id" VARCHAR, "name" VARCHAR, "email" VARCHAR, "phone" VARCHAR,
    "driver_license_number" VARCHAR, "date_of_birth" VARCHAR
);

CREATE OR REPLACE TABLE bronze_branch_category_availability (
    "branch_id" VARCHAR, "branch_name" VARCHAR, "category_id" VARCHAR,
    "category_name" VARCHAR, "is_offered" VARCHAR
);

-- ---------- DML (load) ----------
COPY INTO bronze_branches                     FROM @LANDING/FleetOps/branches.csv                     FILE_FORMAT = FF_CSV ON_ERROR = ABORT_STATEMENT;
COPY INTO bronze_cars                         FROM @LANDING/FleetOps/cars.csv                         FILE_FORMAT = FF_CSV ON_ERROR = ABORT_STATEMENT;
COPY INTO bronze_car_categories               FROM @LANDING/FleetOps/car_categories.csv               FILE_FORMAT = FF_CSV ON_ERROR = ABORT_STATEMENT;
COPY INTO bronze_countries                    FROM @LANDING/FleetOps/countries.csv                    FILE_FORMAT = FF_CSV ON_ERROR = ABORT_STATEMENT;
COPY INTO bronze_currencies                   FROM @LANDING/FleetOps/currencies.csv                   FILE_FORMAT = FF_CSV ON_ERROR = ABORT_STATEMENT;
COPY INTO bronze_customers                    FROM @LANDING/FleetOps/customers.csv                    FILE_FORMAT = FF_CSV ON_ERROR = ABORT_STATEMENT;
COPY INTO bronze_branch_category_availability FROM @LANDING/FleetOps/branch_category_availability.csv FILE_FORMAT = FF_CSV ON_ERROR = ABORT_STATEMENT;

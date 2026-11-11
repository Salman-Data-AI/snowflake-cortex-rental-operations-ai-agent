-- =============================================================
-- Bronze Layer | Step 01: Database, schema and landing stage
-- Run as: ACCOUNTADMIN (or a role with CREATE DATABASE)
-- =============================================================

CREATE DATABASE IF NOT EXISTS RENTAL_OPS;
CREATE SCHEMA IF NOT EXISTS RENTAL_OPS.BRONZE;

-- Internal stage holding the raw source files as they arrived
CREATE STAGE IF NOT EXISTS RENTAL_OPS.BRONZE.LANDING;

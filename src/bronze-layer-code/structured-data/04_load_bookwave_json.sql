-- =============================================================
-- Bronze Layer | Step 04: Land BookWave reservations_export.json
-- One row per top-level element of "records"; each full nested record
-- (including paymentDetails) kept intact in a single VARIANT column.
-- Nothing inside a record is parsed or flattened.
-- Note: export header fields (source, export_type, export_date,
-- field_mapping_note) are not stored; the original file remains on @LANDING.
-- =============================================================

USE SCHEMA RENTAL_OPS.BRONZE;

CREATE OR REPLACE FILE FORMAT FF_JSON TYPE = JSON;

CREATE OR REPLACE TABLE bronze_bookwave_reservations_raw (raw VARIANT);

INSERT INTO bronze_bookwave_reservations_raw
SELECT r.value
FROM @LANDING/BookWave/reservations_export.json (FILE_FORMAT => 'FF_JSON') s,
     LATERAL FLATTEN(input => s.$1:records) r
ORDER BY r.index;

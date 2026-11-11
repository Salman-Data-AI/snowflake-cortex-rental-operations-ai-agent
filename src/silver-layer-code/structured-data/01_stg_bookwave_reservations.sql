-- =============================================================
-- Silver Layer | Step 01: stg_bookwave_reservations (Dynamic Table)
-- Flattens bronze_bookwave_reservations_raw: one row per reservation,
-- nested payment fields pulled up as columns, DD/MM/YYYY strings -> DATE.
-- Kept in sync with Bronze automatically (TARGET_LAG = 1 minute).
-- =============================================================

CREATE SCHEMA IF NOT EXISTS RENTAL_OPS.SILVER;

-- Dynamic tables require change tracking on their base table
ALTER TABLE RENTAL_OPS.BRONZE.bronze_bookwave_reservations_raw SET CHANGE_TRACKING = TRUE;

-- Notes:
--   * Every reservation currently has exactly 1 payment; paymentDetails[0] is used
--     and payment_count is exposed so multi-payment records can be detected.
--   * Ids renamed per the export's field_mapping_note (customer_id, car_id, ...).
--   * TRY_TO_DATE: an unparseable date becomes NULL rather than failing every refresh.
--   * amount_paid stays in local (pickup branch) currency; see payment_currency.
CREATE OR ALTER DYNAMIC TABLE RENTAL_OPS.SILVER.stg_bookwave_reservations
  TARGET_LAG = '1 minute'
  WAREHOUSE = COMPUTE_WH
  REFRESH_MODE = INCREMENTAL
  INITIALIZE = ON_CREATE
AS
SELECT
    raw:reservationId::NUMBER                                             AS reservation_id,
    raw:customerRef::NUMBER                                               AS customer_id,
    raw:vehicleId::NUMBER                                                 AS car_id,
    raw:pickupBranch::NUMBER                                              AS pickup_branch_id,
    raw:dropoffBranch::NUMBER                                             AS return_branch_id,
    TRY_TO_DATE(raw:rentalStart::STRING, 'DD/MM/YYYY')                    AS rental_start_date,
    TRY_TO_DATE(raw:rentalEnd::STRING,   'DD/MM/YYYY')                    AS rental_end_date,
    TRY_TO_DATE(raw:bookedOn::STRING,    'DD/MM/YYYY')                    AS booked_date,
    raw:paymentDetails[0]:paymentId::NUMBER                               AS payment_id,
    raw:paymentDetails[0]:amountPaid::NUMBER(18,2)                        AS amount_paid,
    raw:paymentDetails[0]:currency::STRING                                AS payment_currency,
    raw:paymentDetails[0]:method::STRING                                  AS payment_method,
    TRY_TO_DATE(raw:paymentDetails[0]:paidOn::STRING, 'DD/MM/YYYY')       AS paid_date,
    ARRAY_SIZE(raw:paymentDetails)                                        AS payment_count
FROM RENTAL_OPS.BRONZE.bronze_bookwave_reservations_raw;

-- ---------- Validation ----------
-- Expect: target_lag = 1 minute, refresh_mode = INCREMENTAL, scheduling_state = ACTIVE
SHOW DYNAMIC TABLES LIKE 'STG_BOOKWAVE_RESERVATIONS' IN SCHEMA RENTAL_OPS.SILVER;

-- Expect: 2000 rows, 2000 distinct ids, 0 null dates, 0 multi-payment rows
SELECT COUNT(*)                        AS row_count,
       COUNT(DISTINCT reservation_id)  AS distinct_reservations,
       COUNT_IF(rental_start_date IS NULL OR rental_end_date IS NULL
                OR booked_date IS NULL OR paid_date IS NULL) AS null_dates,
       COUNT_IF(payment_count <> 1)    AS multi_payment_rows
FROM RENTAL_OPS.SILVER.stg_bookwave_reservations;

-- =============================================================
-- Silver Layer | Support tickets: enrich with Cortex AI
-- Prereq: bronze-layer-code/semi-structured-data/01_load_support_tickets.sql
-- Rerunnable (CREATE OR REPLACE). Re-runs AI on all rows (~300 tickets).
-- ai_category  : AI_CLASSIFY on the raw ticket body
-- ticket_body  : AI_REDACT'd (names, phones, emails); raw body is NOT kept
-- Other columns carried over as-is from Bronze.
-- Plain table (not a dynamic table) so AI functions run once, not per refresh.
-- =============================================================

CREATE OR REPLACE TABLE RENTAL_OPS.SILVER.support_tickets_enriched AS
SELECT
    "ticket_id"      AS ticket_id,
    "customer_id"    AS customer_id,
    "reservation_id" AS reservation_id,
    "category"       AS category,
    "channel"        AS channel,
    "status"         AS status,
    "created_date"   AS created_date,
    AI_CLASSIFY(
        "ticket_body",
        ['Billing Question', 'Vehicle Issue', 'General Feedback', 'Roadside Assistance',
         'Damage Claim', 'Account Access', 'Refund Request', 'Booking Change'],
        {'task_description': 'Classify a car rental customer support ticket by the main reason the customer contacted support.'}
    ):labels[0]::STRING AS ai_category,
    AI_REDACT("ticket_body", ['NAME', 'PHONE_NUMBER', 'EMAIL'])::STRING AS ticket_body  -- AI_REDACT returns VARIANT
FROM RENTAL_OPS.BRONZE.bronze_support_tickets;

-- Validate
SELECT COUNT(*) AS row_count,
       COUNT_IF(ai_category IS NULL) AS null_ai_category,
       COUNT_IF(ticket_body IS NULL) AS null_ticket_body,
       COUNT_IF(ai_category <> category) AS ai_vs_source_mismatch
FROM RENTAL_OPS.SILVER.support_tickets_enriched;

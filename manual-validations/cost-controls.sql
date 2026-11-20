-- =============================================================
-- Account ops | Cost controls (one-off, run as ACCOUNTADMIN)
-- Purpose : cap warehouse spend hard and get alerted on all spend
--           (including AI) after the trial AI allowance went away with the
--           2026-11-19 account upgrade.
-- Prereq  : ACCOUNTADMIN. For email alerts, enable notifications with a
--           verified email in your Snowsight user profile.
-- Rerun   : yes. CREATE OR REPLACE / SET / ACTIVATE are idempotent.
--           NOTE: CREATE OR REPLACE on the monitor resets its used credits
--           for the current period.
-- Design notes:
--   * Resource monitor = the only HARD stop, and it covers warehouses only.
--     At 100 percent COMPUTE_WH suspends: no SQL that needs a warehouse can
--     run, including the SQL Cortex Analyst generates for the agent.
--   * Budget = alerts on ALL credit usage (warehouse, serverless, AI
--     functions, Cortex Analyst/Agent, CoCo). It never stops anything and
--     can lag by a few hours.
--   * AI spend has no hard cap: the controls for it are the agent's own
--     budget (60 s / 16k tokens per question), the answer cache, and not
--     using CoCo (20.4 of ~33 credits used up to 2026-11-19).
--   * No model restriction: ACCOUNTADMIN bypasses it (section 3).
--   * Limits: warehouse 4 credits/month, account 10 credits/month.
--     Change the numbers below to adjust.
-- =============================================================

-- -------------------------------------------------------------
-- 1) Hard cap on the warehouse: resource monitor
-- -------------------------------------------------------------
CREATE OR REPLACE RESOURCE MONITOR rental_ops_monthly
  WITH CREDIT_QUOTA = 4
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 75 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND               -- running queries finish
           ON 110 PERCENT DO SUSPEND_IMMEDIATE;    -- running queries are cancelled

ALTER WAREHOUSE COMPUTE_WH SET RESOURCE_MONITOR = rental_ops_monthly;

-- To unblock early after a suspend: raise the quota, e.g.
--   ALTER RESOURCE MONITOR rental_ops_monthly SET CREDIT_QUOTA = 8;


-- -------------------------------------------------------------
-- 2) Alerts on all spend: account budget (monthly, in credits)
-- -------------------------------------------------------------
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!ACTIVATE();
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SET_SPENDING_LIMIT(10);

-- Email recipient: easiest in Snowsight, Admin > Cost Management > Budgets >
-- account budget > edit > notifications. (The SQL route,
-- !SET_EMAIL_NOTIFICATIONS, needs an email notification integration first.)


-- -------------------------------------------------------------
-- 3) Model restriction: deliberately NOT used (decided 2026-11-19)
-- -------------------------------------------------------------
-- Tried: ALTER ACCOUNT SET CORTEX_MODELS_ALLOWLIST = '<model list>'.
-- Rejected by Snowflake: the parameter is deprecated and only accepts NONE;
-- access is now controlled per model with
--   GRANT APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-<MODEL>" TO ROLE <role>;
-- Not adopted because "The ACCOUNTADMIN role always has access to all models
-- on the account, regardless of the CORTEX_MODELS_ALLOWLIST parameter or model
-- RBAC grants" (Snowflake docs, model access control). This project runs as
-- ACCOUNTADMIN, so it would cap nothing. Revisit if a non-admin role (e.g. an
-- agent-user role) is introduced: set the allowlist to NONE, revoke
-- CORTEX-MODEL-ROLE-ALL from PUBLIC with
--   CALL SNOWFLAKE.LOCAL.REVOKE_FROM_PUBLIC_APPLICATION_ROLE('APP_ROLE', 'CORTEX-MODEL-ROLE-ALL');
-- and grant only the model roles that role needs.


-- -------------------------------------------------------------
-- Validation (metadata only, no warehouse)
-- -------------------------------------------------------------
SHOW RESOURCE MONITORS LIKE 'RENTAL_OPS_MONTHLY';
-- Expected: credit_quota 4, frequency MONTHLY, warehouses COMPUTE_WH,
--           notify_at 75%, suspend_at 100%, suspend_immediately_at 110%.

SHOW WAREHOUSES LIKE 'COMPUTE_WH';
-- Expected: resource_monitor = RENTAL_OPS_MONTHLY; size X-Small; auto_suspend 60.

CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!GET_SPENDING_LIMIT();
-- Expected: 10

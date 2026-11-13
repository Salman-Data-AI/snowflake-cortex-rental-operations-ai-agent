-- =============================================================
-- Manual validation | Cost reconciliation from ACCOUNT_USAGE (actual credits)
-- Purpose: fill sf_credits_actual in cost-tracking/ledger.csv once per phase (CLAUDE.md "Cost tracking").
-- Read-only; resumes COMPUTE_WH once (~0.02 cr). ACCOUNT_USAGE lags 45 min - 3 h: the latest hours
--   may be missing, mark them "pending" and re-check at the next reconciliation.
-- Set the window in each query (account time zone, America/Los_Angeles).
-- Not part of the pipeline; rerunnable.
-- =============================================================

-- 1. Credits per day by service type (warehouse, AI functions, Cortex Search, cloud services, ...)
--    usage_date is a UTC day (PST evening work lands on the next date).
SELECT usage_date, service_type,
       ROUND(SUM(credits_used), 4)                      AS credits_used,
       ROUND(SUM(credits_adjustment_cloud_services), 4) AS cs_adjustment,
       ROUND(SUM(credits_billed), 4)                    AS credits_billed
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE usage_date >= '2026-11-12'
GROUP BY ALL
HAVING SUM(credits_used) > 0
ORDER BY usage_date, service_type;

-- 2. Warehouse credits per hour (COMPUTE_WH), to attribute bursts to sessions / gates
SELECT start_time, ROUND(credits_used_compute, 4) AS compute_cr,
       ROUND(credits_used_cloud_services, 4)      AS cs_cr
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_name = 'COMPUTE_WH' AND start_time >= '2026-11-12 12:00:00'
ORDER BY start_time;

-- 3. AI function credits per hour and model (AI_COMPLETE, AI_EMBED, ...)
--    CORTEX_AI_FUNCTIONS_USAGE_HISTORY (one row per query; METRICS holds token counts).
--    The older CORTEX_FUNCTIONS_USAGE_HISTORY returned no rows for AI_COMPLETE on this account (2026-11-13).
SELECT DATE_TRUNC('hour', start_time) AS hour, function_name, model_name,
       COUNT(*) AS queries, ROUND(SUM(credits), 5) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
WHERE start_time >= '2026-11-12 12:00:00'
GROUP BY ALL
ORDER BY hour, function_name, model_name;

-- 3b. Shape of METRICS (token counts) for one row, to read tokens per model
SELECT model_name, metrics
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
WHERE start_time >= '2026-11-13 00:00:00' AND model_name = 'openai-gpt-5.4'
LIMIT 1;

-- 4. Cortex Search serving credits per day
SELECT usage_date, service_name, consumption_type, ROUND(SUM(credits), 5) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_DAILY_USAGE_HISTORY
WHERE usage_date >= '2026-11-12'
GROUP BY ALL
ORDER BY usage_date, service_name, consumption_type;

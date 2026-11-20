-- =============================================================
-- Manual validation | Cortex Agent observability: traces of GOLD.AVELTO_AGENT
-- Purpose : read the agent's native traces (one trace per agent:run turn) from
--           SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS via the GET_AI_OBSERVABILITY_EVENTS
--           table function. Plan: docs/plans/04_ai_observability.md (gates O1a / O1b).
-- Prereq  : ACCOUNTADMIN (owns the agent: MONITOR + CORTEX_USER implied).
--           Full tool inputs/outputs need READ UNREDACTED AI OBSERVABILITY EVENTS TABLE.
-- Rerun   : yes, read-only. One batch resumes COMPUTE_WH once (~0.02-0.04 cr), 0 AI tokens.
-- Design notes:
--   * Agent span names and attribute keys are NOT documented, so section 1-2 discover
--     them from real rows; section 4 (per-trace summary) is written after that (O1b).
--   * Telemetry is best effort: spend comes from ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY,
--     not from summed trace tokens (section 3).
--   * Output kept compact (counts, keys, one example value cut to 120 chars).
--   * No ampersand characters in this file (snow CLI templating).
-- =============================================================

-- 1. Volume: traces and records per UTC day and record type
--    Expected: rows for the cowork test runs (2026-11-20); empty = no traces (plan 04 O1c).
SELECT TO_DATE(timestamp)                 AS day_utc,
       record_type,
       COUNT(*)                           AS records,
       COUNT(DISTINCT trace:trace_id)     AS traces,
       MIN(timestamp)                     AS first_ts,
       MAX(timestamp)                     AS last_ts
FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
       'RENTAL_OPS', 'GOLD', 'AVELTO_AGENT', 'CORTEX AGENT'))
GROUP BY ALL
ORDER BY day_utc, record_type;

-- 2. Anatomy: per span/record name, which RECORD_ATTRIBUTES keys occur, with one example value
--    Expected: names for planning, tool calls (Analyst, search), SQL execution, response;
--    keys for tool name, SQL, tokens, model, version, thread/request ids.
WITH ev AS (
  SELECT record_type, record:name::STRING AS rec_name, record_attributes
  FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
         'RENTAL_OPS', 'GOLD', 'AVELTO_AGENT', 'CORTEX AGENT'))
)
SELECT ev.record_type,
       ev.rec_name,
       f.key                                         AS attribute_key,
       COUNT(*)                                      AS n,
       LEFT(ANY_VALUE(f.value)::STRING, 120)         AS example_value
FROM ev, LATERAL FLATTEN(input => ev.record_attributes) f
GROUP BY ALL
ORDER BY ev.record_type, ev.rec_name, attribute_key;

-- 2b. Resource attributes (session context) and RECORD keys, once
SELECT 'resource_attributes' AS source, f.key, COUNT(*) AS n,
       LEFT(ANY_VALUE(f.value)::STRING, 120) AS example_value
FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
       'RENTAL_OPS', 'GOLD', 'AVELTO_AGENT', 'CORTEX AGENT')) e,
     LATERAL FLATTEN(input => e.resource_attributes) f
GROUP BY ALL
UNION ALL
SELECT 'record', f.key, COUNT(*), LEFT(ANY_VALUE(f.value)::STRING, 120)
FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
       'RENTAL_OPS', 'GOLD', 'AVELTO_AGENT', 'CORTEX AGENT')) e,
     LATERAL FLATTEN(input => e.record) f
GROUP BY ALL
ORDER BY source, key;

-- 3. Billing source of truth: column layout + latest rows (lags 45 min - 3 h)
--    Expected: one row per agent request with credits/tokens; columns are compared
--    with the trace keys in O1b.
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
ORDER BY 1 DESC
LIMIT 5;

-- =============================================================
-- Gate O1b: per-turn view, using the keys discovered in O1a (plan 04 section 5).
-- Key notes (from real rows, 2026-11-20):
--   * RECORD_ATTRIBUTES keys are flat strings containing dots, so they are quoted:
--     record_attributes:"snow.ai.observability.agent.thread_id".
--   * Spans carry TRACE:trace_id (one trace = one turn). The CORTEX_AGENT_REQUEST
--     EVENT has no trace id: it is matched to its turn by thread id + message id.
--   * Trace to billing: span "Agent" attribute request_id = CORTEX_AGENT_USAGE_HISTORY.REQUEST_ID.
--   * Duration units of agent.duration are not documented; the span clock
--     (TIMESTAMP - START_TIMESTAMP) is reported next to it as a check.
-- =============================================================

-- 4a. One row per turn: question, routing, retries, tokens, time, billed credits
--     Expected: 5 rows (2026-11-20 cowork turns), version LIVE; billed_* NULL while
--     ACCOUNT_USAGE still lags.
WITH ev AS (
  SELECT * FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
           'RENTAL_OPS', 'GOLD', 'AVELTO_AGENT', 'CORTEX AGENT'))
),
spans AS (
  SELECT trace:trace_id::STRING      AS trace_id,
         record:name::STRING         AS span_name,
         record:status:code::STRING  AS status_code,
         start_timestamp, timestamp,
         record_attributes           AS a,
         CASE WHEN record:name::STRING LIKE 'CortexSearchService_%'           THEN 'search'
              WHEN record:name::STRING LIKE 'SemanticContextTool_%'           THEN 'analyst_ctx'
              WHEN record:name::STRING = 'SystemExecuteSQLTool_system_execute_sql' THEN 'analyst_sql'
         END                         AS tool_step
  FROM ev WHERE record_type = 'SPAN'
),
turns AS (
  SELECT trace_id,
         MIN(start_timestamp)                                                       AS start_utc,
         DATEDIFF('millisecond', MIN(start_timestamp), MAX(timestamp)) / 1000       AS span_clock_s,
         MAX(IFF(span_name = 'Agent', a:"request_id"::STRING, NULL))                AS request_id,
         MAX(a:"snow.ai.observability.agent.thread_id"::STRING)                     AS thread_id,
         MAX(IFF(span_name = 'Agent', a:"snow.ai.observability.agent.message_id"::STRING, NULL)) AS message_id,
         MAX(a:"snow.ai.observability.object.version.name"::STRING)                 AS version,
         LEFT(MAX(a:"ai.observability.record_root.input"::STRING), 90)              AS question,
         MAX(a:"snow.ai.observability.agent.duration"::STRING)                      AS agent_duration_raw,
         MAX(a:"snow.ai.observability.agent.status"::STRING)                        AS agent_status,
         COUNT_IF(span_name LIKE 'ReasoningAgentStepPlanning-%')                    AS planning_steps,
         LISTAGG(tool_step, ' > ') WITHIN GROUP (ORDER BY start_timestamp)          AS tool_sequence,
         COUNT_IF(tool_step = 'search')                                             AS search_calls,
         COUNT_IF(tool_step = 'analyst_sql')                                        AS analyst_sql_calls,
         COUNT_IF(a:"snow.ai.observability.agent.tool.sql_execution.error_correction" IS NOT NULL)          AS sql_error_corrections,
         COUNT_IF(a:"snow.ai.observability.agent.tool.sql_execution.validation_error.0.message" IS NOT NULL) AS sql_validation_errors,
         COUNT_IF(status_code = 'STATUS_CODE_ERROR')                                AS error_spans
  FROM spans
  GROUP BY trace_id
),
req AS (   -- whole-turn token counts (EVENT, one per turn)
  SELECT timestamp                                                                   AS event_ts,
         record_attributes:"snow.ai.observability.agent.thread_id"::STRING          AS thread_id,
         record_attributes:"snow.ai.observability.agent.message_id"::STRING         AS message_id,
         record_attributes:"snow.ai.observability.agent.parent_message_id"::STRING  AS parent_message_id,
         record_attributes:"snow.ai.observability.token_count.input"::NUMBER        AS tok_input,
         record_attributes:"snow.ai.observability.token_count.cache_read_input"::NUMBER AS tok_cache_read,
         record_attributes:"snow.ai.observability.token_count.output"::NUMBER       AS tok_output,
         record_attributes:"snow.ai.observability.token_count.total"::NUMBER        AS tok_total
  FROM ev WHERE record:name::STRING = 'CORTEX_AGENT_REQUEST'
),
billing AS (
  SELECT request_id, tokens AS billed_tokens, token_credits AS billed_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY
  WHERE agent_name = 'AVELTO_AGENT' AND start_time >= '2026-11-19'
)
SELECT t.start_utc, t.version, t.question, t.agent_status,
       t.planning_steps, t.tool_sequence, t.search_calls, t.analyst_sql_calls,
       t.sql_error_corrections, t.sql_validation_errors, t.error_spans,
       r.tok_input, r.tok_cache_read, r.tok_output, r.tok_total,
       t.agent_duration_raw, t.span_clock_s,
       b.billed_tokens, ROUND(b.billed_credits, 4) AS billed_credits,
       t.request_id
FROM turns t
-- Matched by time: the event is stamped at its turn's first span start (O1b finding).
-- A message-id rule (span message_id IN event message_id / parent_message_id) matched
-- each event to its own turn AND the next one (9 rows for 5 turns), so it is not used.
LEFT JOIN req r
  ON r.thread_id = t.thread_id
 AND r.event_ts BETWEEN DATEADD('second', -2, t.start_utc) AND DATEADD('second', 2, t.start_utc)
LEFT JOIN billing b ON b.request_id = t.request_id
ORDER BY t.start_utc;

-- 4b. Drill-down: every span of the turn with the most planning steps, in time order
--     Expected: the retry pattern (planning step, Analyst SQL, validation error or
--     error correction, next step) and where the time and tokens go.
WITH ev AS (
  SELECT * FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
           'RENTAL_OPS', 'GOLD', 'AVELTO_AGENT', 'CORTEX AGENT'))
  WHERE record_type = 'SPAN'
),
longest AS (
  SELECT trace:trace_id::STRING AS trace_id
  FROM ev
  GROUP BY 1
  ORDER BY COUNT_IF(record:name::STRING LIKE 'ReasoningAgentStepPlanning-%') DESC
  LIMIT 1
)
SELECT DATEDIFF('millisecond', MIN(e.start_timestamp) OVER (), e.start_timestamp) / 1000 AS t_offset_s,
       DATEDIFF('millisecond', e.start_timestamp, e.timestamp) / 1000                   AS span_s,
       e.record:name::STRING                                                            AS span_name,
       e.record_attributes:"snow.ai.observability.agent.planning.tool.name"::STRING      AS planned_tool,
       e.record_attributes:"snow.ai.observability.agent.planning.token_count.total"::NUMBER AS step_tokens,
       LEFT(COALESCE(
         e.record_attributes:"snow.ai.observability.agent.tool.sql_execution.final_sql"::STRING,
         e.record_attributes:"snow.ai.observability.agent.tool.cortex_search.query"::STRING), 150) AS sql_or_search_query,
       e.record_attributes:"snow.ai.observability.agent.tool.sql_execution.status"::STRING AS sql_status,
       LEFT(e.record_attributes:"snow.ai.observability.agent.tool.sql_execution.validation_error.0.message"::STRING, 120) AS validation_error,
       LEFT(e.record_attributes:"snow.ai.observability.agent.tool.sql_execution.error_correction"::STRING, 120) AS error_correction
FROM ev e JOIN longest l ON e.trace:trace_id::STRING = l.trace_id
WHERE e.record:name::STRING NOT IN ('Agent', 'UserMemoryInjection', 'CortexSearchSingleToolImpl')
ORDER BY e.start_timestamp;

-- 4c. Billing breakdown per request: which services the credits went to
--     Expected: one row per (request, leaf path) with a numeric value, e.g. orchestration
--     model tokens/credits vs Cortex Analyst; NULL-free once ACCOUNT_USAGE has caught up.
SELECT h.start_time, h.request_id,
       h.metadata:agent_version_alias::STRING AS version_alias,
       f.path                                  AS credit_path,
       ROUND(f.value::FLOAT, 6)                AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY h,
     LATERAL FLATTEN(input => h.credits_granular, recursive => TRUE) f
WHERE h.agent_name = 'AVELTO_AGENT' AND h.start_time >= '2026-11-19'
  AND TYPEOF(f.value) IN ('DECIMAL', 'DOUBLE', 'INTEGER')
ORDER BY h.start_time, f.path;

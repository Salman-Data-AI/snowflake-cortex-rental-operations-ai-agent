# 04 — AI Observability for the Cortex Agent (native traces)

| | |
|---|---|
| **Date** | 2026-11-20 |
| **Builds on** | `03_phase3_grounded_answers.md` §2.3 (AI Observability deferred to the agent stage); `docs/design-knowledge/06_cortex_agent.md` |
| **Scope (user decision 2026-11-20)** | Gates O1 + O2 only. O3 (TruLens on the hand-built RAG) is not pursued now. Agent *evaluation* is deferred |
| **Status** | **Done 2026-11-20**: O1a, O1b, O2 complete. Design write-up: `docs/design-knowledge/07_ai_observability.md`. Open: credits for the 2026-11-20 turns (ACCOUNT_USAGE lag) |
| **Object observed** | `RENTAL_OPS.GOLD.AVELTO_AGENT` (default version `VERSION$1`, created 2026-11-20 00:56 PST) |
| **Working mode** | One gate at a time; SQL shown and approved before running; results reviewed before the next gate |

## 1. Why, and what changed since plan 03 §2.3

Plan 03 deferred "Snowflake AI Observability (TruLens)" to the agent stage, assuming observability
meant instrumenting a Python app with the TruLens SDK. The Snowflake docs (checked 2026-11-20) now
offer three separate pieces:

| Piece | What it does | Used here |
|---|---|---|
| **Cortex Agent monitoring** | Automatic for native agents, no instrumentation. Each turn (one `agent:run` request) is one trace in `SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS`, with spans for planning, tool calls (Cortex Analyst, Cortex Search), SQL execution and response generation; tokens, latency, model, agent version per turn. Read with the `GET_AI_OBSERVABILITY_EVENTS` table function or the Snowsight Observability pane | **Yes: O1** |
| **Cortex Agent evaluations** (GA 2026-03-13; version targeting GA 2026-08-21) | Runs the agent on a dataset; built-in metrics answer correctness (vs an expected answer) and logical consistency (reference-free), plus custom LLM-judge metrics | Later, when the deferred agent evaluation is done (documented in O2, not run) |
| **TruLens AI Observability** | For apps that are *not* native agents: instrument Python, register an External Agent, run on tasks; RAG-triad metrics with an `AI_COMPLETE` judge | **No (O3 dropped)**. Snowflake's docs say TruLens is not needed for native agents. For `GOLD.answer_policy_question` it would cost ≈ 0.4–0.5 cr plus a Python setup (venv is Python 3.14, no `trulens`/`snowpark`), and adds little: our SQL-native harness already measures groundedness with a human-reviewed judge (κ 0.77), and the managed metrics do not use our abstention labels |

## 2. Design

### 2.1 What we want from the traces

For each agent turn (one trace):

1. **Routing**: which tool(s) the orchestrator called (Analyst, search, both, none) and in which order.
2. **Tool evidence**: SQL that Analyst generated (and its row count / error), the chunk ids search returned.
3. **Cost and speed**: tokens (orchestration, Analyst), latency per span and per turn, model, agent version.
4. **Errors**: span status, error messages, budget cut-offs (60 s / 16k tokens).

This gives later work a cheap base: the deferred agent evaluation can read routing from traces
instead of parsing `:run` responses, and per-question agent cost can be taken from actuals.

### 2.2 How to read them

```sql
SELECT ... FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
  'RENTAL_OPS', 'GOLD', 'AVELTO_AGENT', 'CORTEX AGENT'));
```

- Columns follow the event-table model: `TIMESTAMP` (span end, UTC), `START_TIMESTAMP`, `TRACE`
  (`trace_id`, `span_id`), `RECORD_TYPE` (SPAN, SPAN_EVENT, LOG, …), `RECORD` (`name`, `kind`,
  `parent_span_id`, `status`), `RECORD_ATTRIBUTES`, `RESOURCE_ATTRIBUTES` (user, role, warehouse,
  query id), `VALUE`.
- **The agent-specific span names and attribute keys are not documented.** O1 therefore starts with
  a discovery query (distinct span names and attribute keys) and only then writes the per-trace
  summary with the real keys. No keys are assumed from memory.
- The UDTF is preferred over selecting the table directly (it enforces object privileges).
- Privileges: `CORTEX_USER` + `MONITOR` (or ownership) on the agent; full text needs
  `READ UNREDACTED AI OBSERVABILITY EVENTS TABLE`. This project runs as ACCOUNTADMIN, which owns the
  agent, so no grants are expected. If content comes back redacted, that is a finding, and any grant
  needs approval.
- Telemetry is best effort (spans can be dropped or late), so **spend comes from
  `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY`** (the documented source of truth), not from
  summed trace tokens. The two are compared once in O1.

### 2.3 Risks / open questions

| Risk | Check |
|---|---|
| The cowork test runs did not land as traces (different entry point, or before the 2026-11-20 `CREATE OR REPLACE` and so tied to the old object) | O1a row counts by date. If empty: one smoke-test `:run` per route (≈ 3 turns, needs approval; est. below) |
| Content redacted for ACCOUNTADMIN | O1a shows whether tool inputs/outputs carry text |
| `CORTEX_AGENT_USAGE_HISTORY` columns unknown | O1a uses `SELECT *` with a small `LIMIT` first |
| Retention period of the events table not documented | Note it in doc 07; export findings to the design doc, not to new tables |

## 3. Gates

| Gate | Work | Est. cost |
|---|---|---|
| **O1a** | Discovery, read-only, one batch: `manual-validations/agent-observability.sql` §1–§3: trace/span counts by day, distinct span names, distinct `RECORD_ATTRIBUTES` / `RESOURCE_ATTRIBUTES` keys with an example value, one sample of `CORTEX_AGENT_USAGE_HISTORY` | 1 warehouse burst ≈ 0.02–0.04 cr (~$0.06–0.12), 0 AI tokens |
| **O1b** | Write §4 with the discovered keys: one row per trace (time, question, tools called, Analyst SQL, search chunk ids, tokens, latency, version, status) + one span-level drill-down per route; compare trace tokens with `CORTEX_AGENT_USAGE_HISTORY`. Show results for review | 1 burst ≈ 0.02–0.04 cr, 0 AI tokens |
| *(O1c, only if O1a finds no traces)* | Smoke test via `:run` REST (JWT from `snow connection generate-jwt`): 3 sample questions, one per route | ≈ 3 turns × (orchestration + ≤ 1 Analyst message ≈ 0.067 cr) ≈ 0.1–0.25 cr, plus warehouse |
| **O2** | Design doc `docs/design-knowledge/07_ai_observability.md`: the three pieces, why TruLens was dropped for the agent (plan 03 §2.3 kept as history), trace anatomy with real span names/keys, how trace fields map to `policy_answer_results` columns, how Agent evaluations will host the deferred agent eval (golden set → dataset, `expected_answer` → answer correctness, routing from traces). Primer (§4 object map, §5 status table, reading order, Last updated), doc 06 §5, plan 03 §2.3 pointer | 0 |

Total ≈ 0.04–0.08 cr (~$0.12–0.24) without O1c.

## 4. Decision criteria

- **O1 done** when: traces for `AVELTO_AGENT` are found (or produced by O1c), span names and attribute
  keys are documented from real rows, and the per-trace query returns routing, SQL / chunk evidence,
  tokens and latency for every recorded turn.
- **O2 done** when doc 07 lets a reader with no repo access understand what is traced, how to query
  it, what it costs, and why TruLens and Agent evaluations were or were not used now.

## 5. Results

### Gate O1a (2026-11-20): discovery

Ran `manual-validations/agent-observability.sql` §1–§3 in one batch (1 warehouse burst, 0 AI tokens).

**Traces exist; O1c (smoke test) is not needed.** The cowork test runs were recorded:
5 traces, 96 SPAN + 5 EVENT records, 2026-11-20 10:15–10:26 UTC, role ACCOUNTADMIN. All span
statuses `STATUS_CODE_OK`. Content is **not redacted** for ACCOUNTADMIN (question text, SQL,
results, planning text all present). Cowork ran the agent's **`LIVE`** version
(`object.version.name`), not the default `VERSION$1`.

**Trace anatomy** (record name → what it holds; prefix `snow.ai.observability.` omitted):

| Record (`RECORD:name`) | Type | Key attributes |
|---|---|---|
| `CORTEX_AGENT_REQUEST` | EVENT, 1 per turn | `agent.thread_id`, `agent.message_id`, `agent.parent_message_id`, `object.version.name`, **`token_count.{input,output,cache_read_input,cache_write_input,total}`** (whole turn) |
| `Agent` | root span | `request_id`, thread / message ids |
| `AgentV2RequestResponseInfo` | span, 1 per turn | `ai.observability.record_root.input` (**question**), `ai.observability.record_root.output`, `agent.response`, `agent.duration`, `agent.status(.code/.description)`, `agent.first_message_in_thread`, `agent.tool_choice.type`, `agent.warnings` |
| `ReasoningAgentStepPlanning-<n>` | span per orchestration step | `agent.planning.model`, `.step_number`, `.duration`, `.tool.name` / `.tool.type`, `.tool_selection.argument.*`, `.tool_execution.argument.*`, `.token_count.*`, `.response`, `.thinking_response` |
| `ReasoningAgentStepResponseGeneration-<n>` | final answer step | same `agent.planning.*` keys |
| `CortexSearchService_search_policies` (+ `CortexSearchSingleToolImpl`) | search tool | `agent.tool.cortex_search.query`, `.results`, `.limit`, `.duration`, `.status` |
| `SemanticContextTool_analyst_reservations` | Analyst context lookup | `agent.tool.semantic_context.semantic_model`, `.tables`, `.user_question`, `.duration` |
| `SystemExecuteSQLTool_system_execute_sql` | Analyst SQL | `agent.tool.sql_execution.final_sql`, `.query`, `.query_id`, `.result`, `.result_truncated`, `.error_correction`, `.validation_error.<i>.*`, `.analyst_tool_name`, `.duration`, `.status` |
| `SqlExecution_SystemSQL` | SQL run on the warehouse | `agent.tool.sql_execution.query`, `.result.num_rows`, `.warehouse`, `.duration` |
| `LLM Suggested Queries` | follow-up suggestions | `agent.suggested_queries.token_count.*` (3 of 5 turns) |
| `UserMemoryInjection`, `ServerSkillTool_si-plan-mode` | platform internals | memory injection count/state; a server-side plan-mode skill (1 turn) |

`RECORD` holds `name`, `kind`, `parent_span_id`, `status`; `RESOURCE_ATTRIBUTES` holds only
session, role and user (no warehouse or query id).

**Findings:**

1. **Orchestration is long for some turns.** Planning steps go up to `ReasoningAgentStepPlanning-19`
   (20 steps in one turn). Analyst SQL ran 15 times across 5 turns, with `error_correction` on 4 and
   `validation_error` on 3. Worth a closer look in O1b (per-turn steps, retries).
2. **Turns are token-heavy.** One example turn: 165,381 input tokens (143,996 of them cache reads),
   1,107 output. The 60 s / 16k token budget clearly does not cap the *input* side.
3. **Billing view.** `ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` columns: `START_TIME`, `END_TIME`,
   `USER_*`, `REQUEST_ID`, `PARENT_REQUEST_ID`, `AGENT_*`, `TOKEN_CREDITS`, `TOKENS`,
   `TOKENS_GRANULAR`, `CREDITS_GRANULAR`, `METADATA` (`agent_version_id`, `agent_version_alias`, …),
   `THREAD_ID`. Only one row so far: the 2026-11-19 first `:run` attempt, **252,625 tokens =
   0.168 cr (~$0.50) for one request**. Today's 5 cowork turns are not in the view yet (lag):
   **pending**, reconcile in O1b.
4. Join path for O1b: trace ↔ billing via `request_id` (span `Agent`) = `REQUEST_ID`, and
   `agent.thread_id` = `THREAD_ID`.

### Gate O1b (2026-11-20): per-turn view

Ran `manual-validations/agent-observability.sql` §4a–§4c (§4a twice, see the fix below), 2 warehouse
bursts, 0 AI tokens.

**Fix during the gate.** The first §4a joined the `CORTEX_AGENT_REQUEST` event to its turn by
message id (span `message_id` in the event's `message_id` / `parent_message_id`). It returned 9 rows
for 5 turns: each event matched its own turn *and* the next one (the message ids chain across
turns). The event is stamped at its turn's first span start, so the join now uses thread id + event
time within ±2 s of the turn start: 5 rows, one event each.

**§4a: the 5 cowork turns (one thread, version `LIVE`, all `SUCCESS`, 0 error spans):**

| Start (UTC) | Question (cut) | Planning steps | Analyst SQL | Search | SQL error corr. / validation err. | Tokens in (cache read) / out | Total tokens | Time |
|---|---|---|---|---|---|---|---|---|
| 10:15:01 | Why might revenue from Germany have looked weaker…, what are cus[tomers saying] | 8 | 7 | 0 | 3 / 1 | 287,810 (249,512) / 3,865 | 291,675 | 66.7 s |
| 10:18:42 | Using Deep Research, investigate why customer satisfaction in Europe is lower… | 4 | 2 | 0 | 0 / 0 | 165,381 (143,996) / 1,107 | 166,488 | 23.0 s |
| 10:21:30 | "Proceed?: Yes" (Deep Research confirmation) | 20 | 6 | 5 | 1 / 2 | 1,210,486 (1,137,271) / 8,746 | 1,219,232 | 139.5 s |
| 10:24:48 | Can you give this chat results in a file format? | 0 | 0 | 0 | 0 / 0 | 137,060 (84,335) / 580 | 137,640 | 11.7 s |
| 10:25:13 | .md file will do | 1 | 0 | 0 | 0 / 0 | 211,367 (203,971) / 3,532 | 214,899 | 43.8 s |

Total **2,029,934 tokens** for 5 turns (≈ 90% cache reads). `agent.duration` is in **milliseconds**
(66696 = span clock 66.697 s). Billing rows for these turns are not in
`CORTEX_AGENT_USAGE_HISTORY` yet: credits **pending**.

**§4b: drill-down of the 20-step turn (10:21:30, 139.5 s):**

- Pattern: planning step → Analyst SQL → planning step … 6 SQL calls in the first 63 s, then 5
  searches (the first with an empty query; then "Europe … country-specific fees", "cancellation
  policy refund fees penalties", "damage waiver deductible …", "additional fees one-way …"), then a
  **39.9 s response-generation step** (the single longest span).
- Context grows every step: planning step tokens rise from 44,283 (step 0) to 66,920 (response
  step). Each step re-sends the whole conversation, so the cost of a turn grows roughly with
  steps × context: the 20-step turn alone is 60% of the 5 turns' tokens.
- First SQL call failed (`ERROR`), retried successfully. Two Analyst queries were **rejected by the
  semantic view with "potential double counting"** (a column from the reservation side aggregated
  across a review/ticket join): the fan-out guard of the semantic view working as designed, but each
  rejection costs a planning round trip. Candidate for doc 05 (semantic view) follow-up.
- `agent.planning.tool.name` lists the tools *offered* at each step, not the one chosen:
  `analyst_reservations`, `search_policies`, plus two platform tools the spec does not declare,
  **`system_execute_sql`** and **`ask_user_question`** (cowork / Snowflake Intelligence adds them;
  Deep Research used `ask_user_question` for "Proceed?"). The chosen tool is in
  `.tool_selection.argument.*` / `.tool_execution.*`.
- SQL ran on `COMPUTE_WH` (warehouse time also billed, outside the agent's token credits).

**§4c: billing breakdown (only the 2026-11-19 request so far):** all credits under
`cortex_agents['claude-sonnet-4-5']`: cache write 0.0870, cache read 0.0426, output 0.0383,
input 0.0001 cr (total 0.168 cr). Cache **writes** are the largest item, then cache reads.

**What this means for cost:** the 16k-token orchestration budget does not bound a turn's spend;
Deep Research and multi-step plans multiply context re-reads. For the deferred agent evaluation,
budget per question from these actuals (once billed), not from the Gate 3 per-call numbers
(≈ 0.0025 cr per `a1` answer).

### Gate O2 (2026-11-20): design doc

Written `docs/design-knowledge/07_ai_observability.md` (three Snowflake pieces, trace anatomy from real
rows, query traps, first findings, decision log O-D1–O-D6, how the deferred agent evaluation will use
Cortex Agent evaluations, implementation map). Updated: primer (§1, object map, status table, plans
list, reading order, Last updated), doc 06 (status, §5 open items), doc 05 §5 (double-counting
rejections), plan 03 §2.3 (pointer, original text kept as history). No Snowflake cost.

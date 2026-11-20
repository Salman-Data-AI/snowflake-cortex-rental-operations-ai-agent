# AI Observability: Reading What the Cortex Agent Did

How every turn of `avelto_agent` is recorded by Snowflake, what a trace contains, how to query it,
what the first five recorded turns showed, and why TruLens and Agent evaluations were not used (yet).

| | |
|---|---|
| **Applies to** | `RENTAL_OPS.GOLD.avelto_agent` (observed), `SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS` (Snowflake-managed) |
| **Implemented in** | `manual-validations/agent-observability.sql` (read-only queries; no objects created) |
| **Plan / raw results** | `docs/plans/04_ai_observability.md` (gates O1a, O1b, O2) |
| **Companion docs** | `06_cortex_agent.md` (the agent being observed); `05_semantic_views.md` (the Analyst tool); `03_grounded_answers_and_abstention.md` §2.3 history (why observability was deferred); `04_answer_evaluation_methods.md` (how answers are judged, for the later agent evaluation) |
| **Status** | O1 + O2 done 2026-11-20. Agent traces readable per turn; credits for the observed turns pending in `ACCOUNT_USAGE` |

**Last updated:** 2026-11-20 (doc created; later the same day O-D2 reversed by O-D7: TruLens on the hand-built RAG, plan 05, T0–T2 done, new §5b)

---

## 1. What problem this solves

An agent answers a question in several hidden steps: it plans, picks a tool, Cortex Analyst writes
SQL, the SQL runs, the search service returns chunks, the agent plans again, and finally writes the
answer. The `:run` response shows only part of that. To debug a wrong answer, to know what a question
cost, or (later) to score whether the agent picked the right tool, we need the steps themselves.

**Observability** = recording those steps as a **trace** (one per question / turn) made of **spans**
(one per step), with inputs, outputs, tokens, timings and status. Snowflake does this automatically for
native Cortex Agents.

## 2. Three Snowflake pieces, and which one we use

Checked against the Snowflake docs on 2026-11-20.

| Piece | What it is | Needs | Used |
|---|---|---|---|
| **Cortex Agent monitoring** | Automatic tracing of every agent turn into the Snowflake-managed event table `SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS`; read via the `GET_AI_OBSERVABILITY_EVENTS` table function or the Snowsight Observability pane | Nothing to build; `CORTEX_USER` + `MONITOR` on the agent (ACCOUNTADMIN owns it) | **Yes** |
| **Cortex Agent evaluations** (GA 2026-03-13; version targeting GA 2026-08-21) | Runs the agent over a dataset and scores it: **answer correctness** (vs an expected answer), **logical consistency** (reference-free), custom LLM-judge metrics; can pin an agent version | A dataset table + an evaluation config; LLM judge calls (credits) | **Not yet**: the agent evaluation is deferred (user, 2026-11-20). Planned home for it, §7 |
| **TruLens AI Observability** | SDK for apps that are *not* native agents: instrument Python functions, register an *External Agent*, run on tasks; RAG-triad metrics (context relevance, groundedness, answer relevance) with an `AI_COMPLETE` judge | Python env with `trulens` + Snowpark, `CREATE EXTERNAL AGENT`, `CREATE TASK` / `EXECUTE TASK` | ~~No (O-D2)~~ → **Yes, for `GOLD.answer_policy_question` only** (O-D7, plan 05). Still not for the native agent (O-D1) |

## 3. Anatomy of a trace (from real rows, not from docs)

Snowflake does **not document** the agent's span names or attribute keys. Everything below was read
from the five recorded turns (plan 04, Gate O1a), by listing every record name and attribute key.

Each row of the event table has the event-table columns: `TIMESTAMP` (span end, UTC),
`START_TIMESTAMP`, `TRACE` (`trace_id`, `span_id`), `RECORD_TYPE` (`SPAN`, `EVENT`, …), `RECORD`
(`name`, `kind`, `parent_span_id`, `status`), `RECORD_ATTRIBUTES` (the payload), `RESOURCE_ATTRIBUTES`
(session, role, user only).

One turn = one `trace_id`. Spans of one turn (prefix `snow.ai.observability.` omitted from keys):

| Record name | What it is | Useful attributes |
|---|---|---|
| `CORTEX_AGENT_REQUEST` (EVENT, **no trace id**) | turn-level usage | `token_count.{input, cache_read_input, cache_write_input, output, total}`, `agent.thread_id`, `agent.message_id`, `agent.parent_message_id`, `object.version.name` |
| `Agent` | root span | `request_id` (= billing `REQUEST_ID`) |
| `AgentV2RequestResponseInfo` | the turn as a whole | `ai.observability.record_root.input` (the **question**), `agent.response`, `agent.duration` (**ms**), `agent.status`, `agent.tool_choice.type`, `agent.first_message_in_thread` |
| `ReasoningAgentStepPlanning-<n>` | one orchestration LLM call | `agent.planning.model`, `.step_number`, `.duration`, `.token_count.*`, `.tool_selection.*` / `.tool_execution.*` (the chosen tool and its arguments), `.tool.name` (tools *offered*, not chosen), `.response`, `.thinking_response` |
| `ReasoningAgentStepResponseGeneration-<n>` | final answer LLM call | same keys as planning |
| `SemanticContextTool_analyst_reservations` | Analyst reads the semantic view | `agent.tool.semantic_context.{semantic_model, tables, user_question, duration}` |
| `SystemExecuteSQLTool_system_execute_sql` | Analyst-generated SQL | `agent.tool.sql_execution.{final_sql, query_id, result, result_truncated, status, error_correction, validation_error.<i>.message, duration}` |
| `SqlExecution_SystemSQL` | the SQL run on the warehouse | `agent.tool.sql_execution.{query, result.num_rows, warehouse, duration}` |
| `CortexSearchService_search_policies` (+ `CortexSearchSingleToolImpl`) | policy search | `agent.tool.cortex_search.{query, results, limit, duration, status}` |
| `LLM Suggested Queries` | follow-up suggestions | own `token_count.*` |
| `UserMemoryInjection`, `ServerSkillTool_si-plan-mode` | platform internals | memory injection; a server-side planning skill |

Visibility: ACCOUNTADMIN sees full text (questions, SQL, results, reasoning). Other roles see only
metadata (tool names, tokens, latency) unless granted `READ UNREDACTED AI OBSERVABILITY EVENTS TABLE`.

## 4. How to query it (and two traps)

```sql
FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
       'RENTAL_OPS', 'GOLD', 'AVELTO_AGENT', 'CORTEX AGENT'))
```

- Prefer this table function to selecting the event table directly: it enforces object privileges.
- Attribute keys contain dots, so they must be quoted:
  `record_attributes:"snow.ai.observability.agent.thread_id"::STRING`.
- **Trap 1: matching the usage event to its turn.** The `CORTEX_AGENT_REQUEST` event has no trace id.
  Matching it by message id (span message id ∈ event message id / parent message id) looked right but
  matched each event to its own turn *and* the next one (9 rows for 5 turns), because message ids chain
  across turns. The event is stamped at its turn's first span start, so the working join is
  **same thread + event time within ±2 s of the turn start**.
- **Trap 2: "tool name" is not "tool chosen".** `agent.planning.tool.name` lists every tool offered at
  that step. The tool actually used is in `.tool_selection.*` / `.tool_execution.*`, or simply in which
  tool spans follow the step.
- Trace tokens are best effort (spans may be dropped). **Credits come from
  `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY`** (`TOKEN_CREDITS`, `TOKENS`,
  `CREDITS_GRANULAR` per model and token type, `METADATA` with the agent version), joined on
  `REQUEST_ID`. It lags 45 min–3 h.

`manual-validations/agent-observability.sql` holds the discovery queries (§1–§3), the per-turn
summary (§4a), a span-by-span drill-down of the longest turn (§4b) and the credit breakdown (§4c).

## 5. What the first five turns showed (2026-11-20, cowork / Snowflake Intelligence)

| Question (cut) | Planning steps | Analyst SQL / search | Total tokens | Time |
|---|---|---|---|---|
| Why might revenue from Germany have looked weaker…, what are customers saying | 8 | 7 / 0 (3 error corrections, 1 validation error) | 291,675 | 66.7 s |
| Using Deep Research, investigate why customer satisfaction in Europe is lower… | 4 | 2 / 0 | 166,488 | 23.0 s |
| "Proceed?: Yes" (Deep Research confirmation) | 20 | 6 / 5 | 1,219,232 | 139.5 s |
| Can you give this chat results in a file format? | 0 | 0 / 0 | 137,640 | 11.7 s |
| .md file will do | 1 | 0 / 0 | 214,899 | 43.8 s |

All `SUCCESS`, version `LIVE`, 2.03 M tokens in total, ≈ 90% cache reads.

1. **A turn's cost grows with its number of steps, not just with the question.** Every planning step
   re-sends the whole conversation; in the 20-step turn the per-step context grew from 44k to 67k
   tokens, and that turn alone was 60% of all tokens. The agent's budget (60 s / 16k tokens) did not
   bound this. Earlier billing (2026-11-19, one request, 252,625 tokens) cost **0.168 cr (~$0.50)**,
   with cache *writes* the largest item (0.087 cr), then cache reads (0.043), output (0.038).
   Compare: the hand-built RAG answer step costs ≈ 0.0025 cr per answer (doc 03).
2. **The semantic view rejected two Analyst queries for "potential double counting"** (a reservation
   column aggregated across a review/ticket join). The fan-out guard did its job, but each rejection
   costs a full planning round trip. Follow-up noted in doc 05 §5.
3. **The client adds tools.** Cowork / Snowflake Intelligence offered `system_execute_sql` and
   `ask_user_question` besides the spec's `analyst_reservations` and `search_policies`; Deep Research
   used `ask_user_question` to ask "Proceed?". Traces therefore depend on the client, not only on the
   agent spec.
4. **The longest single step is the answer**: 39.9 s of the 139.5 s turn was response generation.

## 5b. TruLens on the hand-built RAG (plan 05, O-D7)

What it is: `observability/trulens/policy_rag_app.py` wraps `GOLD.answer_policy_question` (no logic of its own) and
`TruApp` registers it as **`EXTERNAL AGENT RENTAL_OPS.EVALUATION.POLICY_RAG`** (version = SQL answer setup,
`a1_grounded_answer`). A run takes questions from `EVALUATION.policy_eval_questions` as a DataFrame, invokes the
app (spans exported to `SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS`), then Snowflake computes the metrics server-side
with the chosen judge. Read with `GET_AI_OBSERVABILITY_EVENTS('RENTAL_OPS','EVALUATION','POLICY_RAG','EXTERNAL AGENT')`
or Snowsight *AI → Evaluations* (the docs still say *AI & ML*; the nav was renamed by 2026-11-20). **Open:** on 2026-11-20 the page showed no runs for ACCOUNTADMIN although `SYSTEM$AIML_RUN_OPERATION('LIST', …)` lists `t2_smoke_20261120` with invocation and all 4 metrics `COMPLETED`; the SQL queries work. Cause unknown (see §9)

Trace of one record: `record_root` (`PolicyRAG.answer`: input, output, ground truth) → `generation`
(`call_answer_procedure`, our `rental_ops.policy_rag.*` keys: decision, cached, tokens, input_sha, cited ids) →
`retrieval` (`retrieve`: query, the 5 chunk texts the LLM saw). Metrics: one `eval_root` span per record × metric
(`eval_root.score` 0–1), one `eval` span per judge call (`eval.score` 0–3 + `eval.explanation`), joined by
`eval.target_record_id` = `record_id`. Queries: `manual-validations/trulens-observability.sql`.

**How to read the four metrics here (from the 3-question smoke run, plan 05 T2):**

| Metric | What it measures | Reading for this RAG |
|---|---|---|
| context_relevance | mean relevance of **each** retrieved chunk (top 5) | precision of top-5, not recall: a perfect rank-1 hit still gave 0.27 (4 neighbour chunks irrelevant). Retrieval quality stays measured by hit@k (doc 01) |
| groundedness | are the answer's claims supported by the chunks | 1.0 on correct answers; **0 on a correct abstention** (nothing to support "not covered") |
| answer_relevance | does the output address the question | 1.0 answered; 0.67 on the abstention |
| correctness | output vs `expected_answer` | 1.0 on all 3, including the abstention |

Rule: report TruLens metrics **split by `is_answerable`**. For out-of-scope questions, low context relevance and
groundedness are the expected values, not failures. The decision itself (answer vs abstain) is still measured by the SQL
harness (doc 03), because no managed metric uses the abstention labels.

## 6. Decision log

| # | Decision | Belief before | Evidence | Choice and why |
|---|---|---|---|---|
| **O-D1** | Observability for the agent = native agent monitoring | Plan 03 §2.3 (2026-11-13): "adopt AI Observability (TruLens) when the Cortex Agent arrives", i.e. observability meant instrumenting Python with TruLens. *(Kept as history.)* | Snowflake docs (2026-11-20): native agents are traced automatically; the TruLens pages say TruLens is not needed for native agent monitoring | Read native traces with SQL. No objects, no Python, ≈ 0.02–0.04 cr per query batch |
| **O-D2** | TruLens on the hand-built RAG (`GOLD.answer_policy_question`) **not pursued** (user, 2026-11-20; option O3 in plan 04) | It would add managed RAG-triad metrics and a Snowsight UI | Cost ≈ 0.4–0.5 cr judge calls + Python setup (local venv is Python 3.14 without `trulens` / Snowpark; version support unchecked) + External Agent + task privileges. Our SQL harness already measures groundedness with a human-validated judge (κ 0.77); managed context/answer relevance do not use our abstention labels, which are the open question | Not now. Revisit only if a UI for the hand-built RAG or a managed-vs-ours judge comparison is wanted. **Superseded the same day by O-D7** (kept as history) |
| **O-D3** | Discover span names/keys from real rows before writing the summary query | — | Snowflake does not document agent span names or keys | Discovery gate first (O1a), summary second (O1b). A query on guessed keys returns empty columns that look like results |
| **O-D4** | Join the usage event to its turn by time, not by message id | Message id looked like the natural key | 9 rows for 5 turns with the message-id rule | Thread + ±2 s of turn start; reason kept in the SQL file |
| **O-D5** | Credits from `CORTEX_AGENT_USAGE_HISTORY`, tokens/routing from traces | Summing trace tokens would give cost | Docs: telemetry is best effort; the usage view is the source of truth and splits credits per model and token type | Both, joined on `REQUEST_ID` |
| **O-D6** | Agent evaluation stays deferred (user, 2026-11-20) | Plan 03: agent eval at the agent stage | User tested the agent interactively in cowork | When it is done, use **Cortex Agent evaluations** (§7) rather than a new SQL harness |
| **O-D7** | **TruLens / TruApp on the hand-built RAG, reversing O-D2** (user, 2026-11-20, plan 05). Scope: `answer_policy_question` only, gates T0–T2 now, full runs (T3) a separate decision; judge `openai-gpt-5.4` | O-D2: Python setup unverified, ≈ 0.4–0.5 cr, adds little next to the SQL harness | Setup blocker gone: `trulens-*` 2.16.0 + Snowpark 1.58.0 resolve on py 3.11/3.12/3.14 and import on 3.12 once `sqlalchemy<2.1` is pinned (`snowflake-sqlalchemy` 1.11.1 breaks on SQLAlchemy 2.1). T1: wrapper returns the cached a1 answer (0 tokens) and 5/5 chunk texts | The user wants the TruLens trace UI and managed RAG-triad scores *beside* the SQL harness (the revisit condition O-D2 named). Rejected: wrapping `avelto_agent` as an external app (duplicates native traces, O-D1); Snowflake's default judge (no clean comparison with j1); full runs before a 3-question cost check |

## 7. When the agent evaluation is picked up

- **Dataset:** golden `gq_v2` + held-out `ho_tickets_v1` policy questions (with `expected_answer`) plus
  new structured / combined questions with expected numbers (doc 06 §5, doc 05 §5 "Cortex Analyst
  evaluation"). Same discipline: tune on held-out, golden is a regression check.
- **Metrics:** Snowflake's answer correctness (vs `expected_answer`) and logical consistency; routing
  accuracy from traces (`tool_sequence` in §4a); cost per question from the usage view. Compare policy
  answers with `a1_grounded_answer` on the same questions.
- **Version:** pin the evaluated agent version (the spec has `LIVE` and `VERSION$1`; cowork used `LIVE`).
- **Budget first:** at ≈ 0.17 cr per multi-step question, 60 questions could cost ≈ 5–10 cr plus judge
  calls, above the account budget of 10 cr/month. Measure a few questions and agree a budget before
  running a full set.

## 8. Implementation map

| What | Object / file |
|---|---|
| Trace storage (Snowflake-managed) | `SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS`, read via `SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(...)` |
| Billing per agent request | `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AGENT_USAGE_HISTORY` |
| Discovery queries (counts, span names, keys, billing columns) | `manual-validations/agent-observability.sql` §1–§3 |
| Per-turn summary, drill-down, credit breakdown | `manual-validations/agent-observability.sql` §4a–§4c |
| Plan, gate results, raw numbers | `docs/plans/04_ai_observability.md` |
| Agent being observed | `GOLD.avelto_agent`, `src/gold-layer-code/agent/01_avelto_agent.sql` (doc 06) |
| TruLens wrapper of the hand-built RAG (O-D7): instrumented `PolicyRAG` (GENERATION span = one `CALL GOLD.answer_policy_question`, RETRIEVAL span = chunk texts from `GOLD.policy_document_chunks`; record root via `TruApp(main_method=answer)`) | `observability/trulens/policy_rag_app.py` |
| TruLens run CLI (`--dry-run` = no TruLens objects; otherwise `TruApp` → `EXTERNAL AGENT policy_rag` in `RENTAL_OPS.EVALUATION`, run on a DataFrame from `EVALUATION.policy_eval_questions`, metrics with judge `openai-gpt-5.4`) | `observability/trulens/run_eval.py` |
| Python env (py 3.12, gitignored `.venv-trulens/`), pinned versions incl. `sqlalchemy<2.1` | `observability/trulens/requirements.txt` |
| Plan, gate results (T0–T4) | `docs/plans/05_trulens_observability.md` |
| Registered app + runs (created by `TruApp`, T2) | `EXTERNAL AGENT RENTAL_OPS.EVALUATION.POLICY_RAG` (version `a1_grounded_answer`), run `t2_smoke_20261120` |
| TruLens trace / score queries (discovery, per-record scores, judge explanations) | `manual-validations/trulens-observability.sql` §1–§4 |

## 9. Open items

| Item | Why |
|---|---|
| Fill credits for the five 2026-11-20 turns (§4c, `ACCOUNT_USAGE` lag) | real cost per question type, input for the evaluation budget |
| TruLens run not visible in Snowsight *AI → Evaluations* (2026-11-20) | data and run metadata verified complete via SQL; not explained by role (ACCOUNTADMIN owns `POLICY_RAG`). Unverified guesses: the page may only list runs from a table dataset (ours used `source_type DATAFRAME`), or external agents may surface elsewhere. Next: check *AI → Agents*; else a Snowflake support case. Do not rerun just to test (judge credits) |
| Retention of the event table | not documented; findings live in this doc and plan 04, not in new tables |
| Reduce steps per turn | double-counting rejections (doc 05), Deep Research use, budget settings: only once the evaluation exists to measure the effect |

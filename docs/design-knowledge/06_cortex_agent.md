# Cortex Agent: One Entry Point over Numbers and Policy Text

What a Snowflake Cortex Agent is, how `avelto_agent` combines the semantic view (Cortex Analyst) with
the policy search service (Cortex Search), how it is told to route questions, and the decisions and
known gaps. This is step 3 of the project goal ("combine both"; see `00_project_context.md` §1).

| | |
|---|---|
| **Applies to** | `RENTAL_OPS.GOLD.avelto_agent` |
| **Implemented in** | `src/gold-layer-code/agent/01_avelto_agent.sql` |
| **Built over** | `GOLD.avelto_semantic_view` (doc 05), `GOLD.policy_search` (docs 01, 02) |
| **Companion docs** | `05_semantic_views.md` (the structured tool); `03_grounded_answers_and_abstention.md` (the hand-built policy answer step this agent does *not* use yet) |
| **Status** | Created 2026-11-19 (version `VERSION$1`); spec verified with `DESCRIBE AGENT`. Run interactively by the user in cowork on 2026-11-20 (version `LIVE`; traces: doc 07). Agent evaluation deferred. Spec update for reviews/tickets deployed 2026-11-20 (§3.6); `CREATE OR REPLACE` reset the version list to `VERSION$1` |

**Last updated:** 2026-11-20 (instructions + analyst tool description for reviews and tickets deployed; first runs observed via traces, doc 07)

## Implementation map

| What | Object | File |
|---|---|---|
| Agent: orchestration model, budget, instructions, 2 tools | `GOLD.avelto_agent` | `src/gold-layer-code/agent/01_avelto_agent.sql` |
| Structured tool `analyst_reservations` (Cortex Analyst text-to-SQL) | `GOLD.avelto_semantic_view` | `src/gold-layer-code/structured-data/02_avelto_semantic_view.sql` |
| Unstructured tool `search_policies` (Cortex Search) | `GOLD.policy_search` | `src/gold-layer-code/unstructured-data/02_policy_search_service.sql` |
| Validation (`DESCRIBE AGENT`) | — | end of `01_avelto_agent.sql` |

---

## 1. What a Cortex Agent is

A **Cortex Agent** is a schema-level Snowflake object (`CREATE AGENT … FROM SPECIFICATION $$<yaml>$$`)
that holds an LLM **orchestration** setup and a list of **tools**. On each request the orchestration
model plans: it picks one or more tools, calls them, reads the results and writes the final answer.
The object stores configuration only; it holds no data.

| Part of the spec | Meaning | Here |
|---|---|---|
| `models.orchestration` | LLM that plans, calls tools and writes the answer | `claude-sonnet-4-5` |
| `orchestration.budget` | per-request cap on time and tokens | 60 s, 16,000 tokens |
| `instructions.orchestration` | how to choose tools | routing rules (§2) |
| `instructions.response` | how to write the answer | units, pickup-branch meaning, no dates, cite, say "don't know" |
| `instructions.sample_questions` | examples shown in clients (e.g. Snowflake Intelligence) | 3: one per route |
| `tools[].tool_spec` | tool type, name and **description** (what the planner reads to choose) | `analyst_reservations`, `search_policies` |
| `tool_resources` | the Snowflake object behind each tool | semantic view + warehouse; search service + result columns |

It is called through the REST API (`POST /api/v2/databases/RENTAL_OPS/schemas/GOLD/agents/AVELTO_AGENT:run`)
or from Snowflake Intelligence. Each `CREATE OR REPLACE` creates a new version (`VERSION$1`, …) with
aliases `FIRST` / `LAST` / `DEFAULT`.

**How it differs from what Phase 3 built:** `GOLD.answer_policy_question` is a hand-built RAG step:
fixed retrieval (top-k), a fixed prompt with an explicit abstention decision, JSON output, an input-hash
cache, and evaluation on golden + held-out sets. The agent swaps all of that for Snowflake-managed
orchestration: the prompt, the number of search calls and the answer format are decided by the agent
at run time. It is more flexible, but there is no cache and no explicit `decision` field to evaluate.

---

## 2. Tools and routing

| Tool | Type | Backed by | Use for |
|---|---|---|---|
| `analyst_reservations` | `cortex_analyst_text_to_sql` | `RENTAL_OPS.GOLD.AVELTO_SEMANTIC_VIEW`; SQL runs on `COMPUTE_WH`, 60 s query timeout | numbers: counts, revenue, averages, rankings, breakdowns by branch / country / region / car category / currency |
| `search_policies` | `cortex_search` | `RENTAL_OPS.GOLD.POLICY_SEARCH`, `max_results` 5, `id_column` CHUNK_ID, `title_column` DOCUMENT_TITLE | what policy documents say: rules, fees, procedures, requirements |

Orchestration instructions (as requested 2026-11-19):
1. numeric or structured question → semantic view;
2. "what documents describe" question → search;
3. a question that needs both → call both and **combine** the results into one answer;
4. never compute business numbers from search text, never answer policy questions from the semantic view.

Response instructions repeat the semantic view's known limits so the answer states them instead of
silently assuming (doc 05 §4.1 showed Analyst silently chose the pickup role and "entire time period"):
revenue is USD; branch / country / region mean the pickup branch; there is no date dimension.

Sample questions, one per route: revenue by country (Analyst), late cancellation (search), and "branch
with the most one-way rentals + what the policy says about one-way fees" (both; one-way rules are in
`rental_agreement_terms.md`).

---

## 3. Decisions and alternatives (decision log)

### 3.1 Reviews and support tickets are not searchable: deploy policy-only (2026-11-19)

The request said `policy_search` should answer questions about "policy documents, reviews, and support
tickets". Checking the deployed service (`SHOW CORTEX SEARCH SERVICES`) showed it indexes **only the 42
policy chunks** (`GOLD.policy_document_chunks`). Reviews and tickets are in `GOLD.reviews_enriched` and
`GOLD.support_tickets_enriched`, but no search service covers them.

Options put to the user:

| # | Option | Outcome |
|---|---|---|
| 1 | Deploy as drafted: the tool description says "policy documents only, does NOT contain reviews or tickets"; the response instructions tell the agent to say it does not know | **Chosen** by the user |
| 2 | New `feedback_search` service over reviews + tickets, as a third tool | Deferred (open item §5): needs a new search service and embedding cost for ~300 tickets + reviews |
| 3 | Union reviews and tickets into `policy_search` | Not recommended: every retrieval and answer result from Phases 1–3 (`v1b_chunking`, `a1_*`) was measured on a policy-only index and would no longer describe the service |

Why the description was not worded as requested: the planner chooses tools **by their descriptions**.
A description that promises customer feedback would send "what do customers complain about?" to a
policy index, and the agent would answer from policy text as if it were feedback.

*Follow-up 2026-11-20:* the structured half of this gap is being closed in the semantic view
(doc 05 §3.7) and the agent spec (§3.6). The text half (option 2) is still open.

### 3.2 Orchestration model `claude-sonnet-4-5` (2026-11-19)

Same model family as the Phase 3 generator, which Gate 3.0 confirmed is available in this region
(AWS_US_WEST_2). Alternative: `auto` (Snowflake picks). Rejected for now so that behaviour stays
reproducible and comparable with Phase 3.

### 3.3 `max_results` 5 (2026-11-19)

Follows the Phase 3 principle "pass top 3–5 chunks"; held-out hit@3 was 0.93 with v1b
(doc 01), so 5 leaves headroom without flooding the context.

### 3.4 Agent lives in `GOLD` (2026-11-19)

It is a serving-layer object over Gold objects, like `answer_policy_question`. Alternative: the
`SNOWFLAKE_INTELLIGENCE.AGENTS` schema, which Snowflake Intelligence lists by default. Not created now;
an agent can be exposed to Snowflake Intelligence later without moving it.

### 3.5 Budget 60 s / 16k tokens (2026-11-19)

A cost guard: one "both tools" question is at most a few tool calls plus one answer. The cap stops a
runaway planning loop from spending tokens. It may need to be raised if combined questions time out.

---

### 3.6 Reviews and tickets reachable through the analyst tool (deployed 2026-11-20)

Trigger: the user noted that reviews were connected to nothing, so CoWork (which reaches the data
through this agent) could not answer any review question. Doc 05 §3.7 adds reviews and tickets to the
semantic view. The agent spec must change with it, because **the planner routes by tool description**:
with the old description ("structured reservation data") and the old response rule ("reviews and tickets
are not searchable, say you do not know"), review questions would still be declined.

Changes (metadata only, `CREATE OR REPLACE AGENT`):
- `analyst_reservations` description lists the review and ticket metrics and dimensions and says it
  holds **no review or ticket text**. Tool name kept, to avoid churn in docs and any client config.
- Orchestration instructions: reviews (rating, sentiment) and tickets (category, channel, status) are
  analyst questions.
- Response instructions: reviews/tickets belong to the branch of their reservation; tickets without a
  reservation show as a blank branch; review/ticket dates exist but rental dates do not; sentiment is
  an AI label; "what do customers write" gets the available numbers plus a note that the text is not
  searchable yet (replaces the flat "say you do not know").
- `search_policies` description: "does not contain the **text** of reviews or tickets".
- 4th sample question: average rating and unresolved tickets by branch.

Verified with `DESCRIBE AGENT`: 2 tools, `claude-sonnet-4-5`, 4 sample questions, new descriptions and
response rule present. Not yet run on a question (smoke test, §5).

Rejected: renaming the tool to `analyst_operations` (cosmetic, touches every reference); pointing the
agent at a second semantic view for feedback (doc 05 §3.7, alternatives).

## 4. Validation (2026-11-19)

`DESCRIBE AGENT RENTAL_OPS.GOLD.avelto_agent`: one version (`VERSION$1`, aliases FIRST/LAST/DEFAULT),
orchestration `claude-sonnet-4-5`, budget 60 s / 16,000 tokens, 2 tools with the resources above.
The spec round-trips exactly (YAML folded strings stored as plain text).

**Not yet done:** running the agent on questions. Routing (Analyst / search / both) and answer quality
are unverified.

### 4.1 First run attempt: blocked by the trial AI-credit limit (2026-11-19)

Test question (user's): *"Why might revenue from Germany have looked weaker than expected recently, and
what are customers renting from our German branches actually complaining about?"* sent to
`POST /api/v2/databases/RENTAL_OPS/schemas/GOLD/agents/AVELTO_AGENT:run` (password session-token auth,
scratch helper not in the repo). The stream returned one `error` event and no tool calls:
`"Your trial account has used its included AI credits. Please upgrade to a paid account to continue."`
(code `399588`, request id `98afae83-1e09-4387-b9f3-6ddac55acd7a`). The agent did not plan or call
any tool, so this says nothing about the agent's design. It is an account limit, and it probably also
blocks the other AI functions used in this project (AI_COMPLETE, AI_EMBED; not tested, to avoid spend).

What the question should show once it can run (written before any result, so it can't be fitted to one):
- **"recently"** cannot be answered: the semantic view has no date dimension. Expected: Germany's
  all-time revenue (293,730.14 USD, 2nd of 7 countries; doc 05 §4.1), plus a clear statement that no
  period comparison is possible. A fail is any claim of a recent decline.
- **"complaining about"** cannot be answered: reviews and tickets are not indexed (§3.1). Expected:
  "don't know / not available". A fail is complaints made up from policy text.
- It is a both-tools question by wording, so it also tests whether the agent avoids answering with a
  plausible story when neither tool supports one.

---

## 5. Open items / next steps

| Item | Why it matters |
|---|---|
| ~~**Smoke test** via the `:run` REST API~~ | **Superseded 2026-11-20:** the user tested the agent interactively in cowork (Snowflake Intelligence); 5 turns traced, all `SUCCESS`, routes Analyst-only and Analyst + search seen (doc 07 §5). Systematic routing checks belong to the agent evaluation |
| **Feedback search service** (option 2, §3.1) | "what do customers say" questions can only get numbers (rating, sentiment, category), not the text |
| Agent evaluation | routing accuracy + answer correctness on golden and held-out questions; compare policy answers with `a1_grounded_answer` (same questions, agent vs hand-built step) |
| Time dimension in the semantic view (doc 05 §5) | the agent cannot answer period questions |
| ~~AI Observability (TruLens)~~ | **Done 2026-11-20** with native agent monitoring instead of TruLens: every turn is traced; per-turn routing, SQL, tokens and time are readable in SQL. See doc 07 |
| Cost per turn (from doc 07 §5) | multi-step turns are expensive (one billed request 0.168 cr; a 20-step Deep Research turn used 1.22 M tokens). The 60 s / 16k budget does not bound input re-reads. Measure before any evaluation run |

---

## 6. Cost

`CREATE AGENT` and `DESCRIBE AGENT` are metadata only (cloud services, ≈ 0 credits). Each agent run
costs orchestration tokens (`claude-sonnet-4-5`), plus Cortex Analyst for SQL generation and one
warehouse burst for the generated SQL (≈ 0.02–0.04 cr if the warehouse was suspended), plus Cortex
Search query cost for search calls. Agent runs are not cached, unlike `answer_policy_question`.

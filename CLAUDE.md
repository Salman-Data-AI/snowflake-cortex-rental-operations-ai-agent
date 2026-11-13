# CLAUDE.md — Snowflake Cortex Rental Operations AI Agent

AI rental-operations assistant on Snowflake (medallion pipeline + Cortex AI functions,
Cortex Search RAG, later Semantic Views / Cortex Analyst / Cortex Agent).
Originally built through Snowflake CoCo; SQL in `src/` is the record of what is deployed.

## Layout
- `data/` — source files (FleetOps CSVs, BookWave JSON, Unstructured reviews/tickets/policy markdown)
- `src/{bronze,silver,gold}-layer-code/{structured,semi-structured,unstructured}-data/NN_*.sql` — pipeline DDL, numbered in run order
- `evaluation/` — retrieval-eval objects/scripts (schema `RENTAL_OPS.EVALUATION`), numbered in run order
- `scripts/` — CLI helpers (`stage_source_files.sh` uploads `data/` to `@RENTAL_OPS.BRONZE.LANDING`)
- `manual-validations/` — ad-hoc checks and one-off ops (not part of the pipeline)
- `docs/plans/` — numbered implementation plans (current roadmap: `02_policy_rag_roadmap_revision.md`; `01_…` is the historical assessment)
- `docs/design-knowledge/` — methodology/design explainers; `00_project_context.md` is the primer (start here)
- `cost-tracking/ledger.csv` — local cost ledger (gitignored), see "Cost tracking"
- `docs/prompts/` — planned feature prompts; `docs/GOLD_LAYER_DOCUMENTATION.md` — Gold reference

## Snowflake access
- `snow sql -c rental-dev -q "..."` or `-f <file>`; add `--format JSON` when parsing output.
- Connection: role ACCOUNTADMIN, warehouse `COMPUTE_WH` (X-Small, auto-suspend 60s), database `RENTAL_OPS`.
- `snow://workspace/...` paths in Bronze scripts only work in Snowsight; locally use `scripts/stage_source_files.sh`.
- Always use fully qualified names (`RENTAL_OPS.<SCHEMA>.<OBJECT>`).

## Working rules
- Work one phase at a time: write SQL files → show the DDL → run only after approval → show results → stop for review.
- Read-only queries (SHOW / DESCRIBE / GET_DDL / small SELECTs) are fine; any CREATE / ALTER / DROP / REFRESH / RESUME needs explicit approval.
- All dynamic tables are **intentionally SUSPENDED** for cost. Do not resume them. When fresh data is needed,
  use a one-off `ALTER DYNAMIC TABLE <fqn> REFRESH` (with approval).
- Prefer metadata commands (SHOW/DESCRIBE need no warehouse) over SELECTs that resume the warehouse.
- Don't push, and don't change branches, without being asked.

## Knowledge docs (keep current, part of every task)
This is a learning repo: `docs/design-knowledge/` must let a reader (or another LLM with no repo access)
understand what was built, why, the alternatives, the trade-offs and the decision points.
- Whenever a task changes objects, files, results or decisions, update the affected design-knowledge
  doc(s) **in the same task**, before reporting it done. Not a separate follow-up.
- `00_project_context.md`: keep the object map, phase status table, constraints/quirks and "Last updated" current.
- Every design doc keeps an **Implementation map** (what → object → file); add new files/objects to it.
- Decisions go into the topic doc's decision log with evidence (numbers), alternatives considered and why
  the choice was made, including options discussed and rejected. Superseded beliefs are kept and marked
  as history, not deleted.
- A new topic gets a new numbered doc (`NN_<topic>.md`) linked from the primer's reading order.
- Plans (`docs/plans/`) hold gate-by-gate work and raw results; design-knowledge holds the explanation.

## Cost tracking (every session)
- **Before each Snowflake task:** give a one-line estimate, e.g. "Snowflake: ~2 warehouse bursts ≈ 0.03–0.05 cr (~$0.09–0.15); 0 AI tokens".
  - Warehouse: X-Small = 1 credit/hour, per-second billing, 60 s minimum per resume + 60 s auto-suspend idle ⇒ ≈ 0.02–0.04 cr per burst of queries.
  - AI functions (AI_COMPLETE etc.): estimated tokens × model credit rate, stated before running.
  - Metadata-only commands (SHOW / DESCRIBE / GET_DDL / LIST) use cloud services only: ≈ 0.
- **Price:** Enterprise edition, **$3 per credit**.
- **Claude cost + tokens:** read `~/.claude/cost-log/<session_id>.json` (cumulative for the session; written by the
  status line script `~/.claude/statusline-cost.py` on every update):
  - `total_cost_usd`: the user is on a **Pro subscription**, so this is an API-equivalent estimate, not a charge. Label it that way.
  - `tokens`: `total`, `output`, `input` (uncached), `cache_write`, `cache_read`, `requests`, summed per API request from the transcript.
    Cache reads dominate the total and are the cheapest; output and cache writes drive most of the API-equivalent cost.
  - `plan_usage_5h_pct` / `plan_usage_7d_pct`: real Pro plan consumption (rolling 5-hour and 7-day limits).
- **Snowflake actuals:** reconcile once per phase or at the end of a session (not after every task; each check resumes the
  warehouse ≈ 0.02 cr) from `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` (hourly, COMPUTE_WH),
  `METERING_DAILY_HISTORY` (by service type), `CORTEX_SEARCH_DAILY_USAGE_HISTORY` and the AI function usage views.
  These lag 45 min–3 h, so mark late numbers as "pending" and fill them in at the next check.
- **Ledger:** append rows to `cost-tracking/ledger.csv` (gitignored, local only):
  `date,session,phase_task,sf_credits_est,sf_credits_actual,sf_usd_actual,claude_usd_api_equiv,claude_tokens_total,claude_tokens_output,plan_5h_pct,plan_7d_pct,notes`.
  `session` = first 8 chars of the session id; Claude columns = cumulative session values at that row.
- **Running tally:** end every phase/task summary with one footer line:
  `💰 This session: Snowflake <cr> cr (~$<usd>) actual + <cr> est. pending · Claude ~$<usd> API-equiv, <tok> tokens (<out> output) · Pro plan 5h <p>% / 7d <p>% · Total ~$<usd>`

## SQL conventions
- Every script starts with the `-- ====` comment block: layer | purpose, Prereq, rerunnability, design notes.
- Scripts are rerunnable: `CREATE OR REPLACE` / `CREATE OR ALTER` / `IF NOT EXISTS`. End with a validation query and its expected values.
- Bronze: values stored as written (VARCHAR, quoted lowercase source column names); the original files stay on `@LANDING`.
- Silver: conform/clean. **AI functions (AI_CLASSIFY, AI_REDACT, AI_SENTIMENT, AI_TRANSLATE, AI_COMPLETE, AI_EMBED for token counts)
  run only in Silver plain tables (CTAS)**, so they run once and not on every refresh.
- After a Silver CTAS, re-run `ALTER TABLE ... SET CHANGE_TRACKING = TRUE` (CREATE OR REPLACE resets it; Gold DTs need it).
- Gold: Dynamic Tables, `TARGET_LAG = '3 minutes'`, `REFRESH_MODE = INCREMENTAL`, no AI calls.
- Serving-layer exception: query-time AI calls (one call per user query, e.g. `GOLD.answer_policy_question`)
  may live in GOLD **stored procedures**, with an input-hash answer cache (`GOLD.policy_answer_cache`).
  No dynamic table ever calls them.
- Cortex Search: legacy `SNOWFLAKE.CORTEX.EMBED_TEXT_*` is blocked on this account, so use user-provided vectors via
  `AI_EMBED('snowflake-arctic-embed-l-v2.0', ...)` + `VECTOR INDEXES col (query_model = ...)`; chunks are kept <= 512 tokens.
- Eval runs are tagged with a `setup_version` (`v0_baseline`, `v1_doc2query` = current reference, `v1b_chunking`, ...).
- Calibration and design choices are tuned on a held-out set, never on the golden set (leakage); the golden set is a regression check.

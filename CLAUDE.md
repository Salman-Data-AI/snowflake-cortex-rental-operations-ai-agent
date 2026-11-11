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
- `docs/plans/` — numbered implementation plans (current: `01_resume_assessment_and_roadmap.md`)
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

## SQL conventions
- Every script starts with the `-- ====` comment block: layer | purpose, Prereq, rerunnability, design notes.
- Scripts are rerunnable: `CREATE OR REPLACE` / `CREATE OR ALTER` / `IF NOT EXISTS`. End with a validation query and its expected values.
- Bronze: values stored as written (VARCHAR, quoted lowercase source column names); the original files stay on `@LANDING`.
- Silver: conform/clean. **AI functions (AI_CLASSIFY, AI_REDACT, AI_SENTIMENT, AI_TRANSLATE, AI_COMPLETE, AI_EMBED for token counts)
  run only in Silver plain tables (CTAS)**, so they run once and not on every refresh.
- After a Silver CTAS, re-run `ALTER TABLE ... SET CHANGE_TRACKING = TRUE` (CREATE OR REPLACE resets it; Gold DTs need it).
- Gold: Dynamic Tables, `TARGET_LAG = '3 minutes'`, `REFRESH_MODE = INCREMENTAL`, no AI calls.
- Cortex Search: legacy `SNOWFLAKE.CORTEX.EMBED_TEXT_*` is blocked on this account, so use user-provided vectors via
  `AI_EMBED('snowflake-arctic-embed-l-v2.0', ...)` + `VECTOR INDEXES col (query_model = ...)`; chunks are kept <= 512 tokens.
- Eval runs are tagged with a `setup_version` (`v0_baseline`, `v1_doc2query`, `v2_query_rewrite`).

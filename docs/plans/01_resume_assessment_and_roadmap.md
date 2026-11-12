# Rental Ops AI Agent — Assessment & Plan (resuming from CoCo → Claude Code)

> **Status (2026-11-12):** Phases 0 and 1 are **DONE**. Phase 2 continues unchanged. Phase 3 is **RETIRED** and the forward roadmap is now [`02_policy_rag_roadmap_revision.md`](02_policy_rag_roadmap_revision.md). This document is kept as the historical assessment.

## Context
The project was built through Snowflake CoCo, which ran SQL directly in Snowsight. Work now moves to Claude Code in the local repo, using `snow sql -c rental-dev`. Before building further, we need to confirm the repo matches what is deployed, find any gaps, and set up the local tooling. The next planned feature is the retrieval-evaluation work in `docs/prompts/01_policy_rag_retrieval_evaluation.md`, Steps 2–4.

## Assessment findings (all read-only)

### Repo vs. Snowflake: no material drift
Account `NMFXJHD-AIB97847` (AWS_US_WEST_2), role ACCOUNTADMIN, warehouse `COMPUTE_WH` (X-Small, auto-suspend 60s, currently SUSPENDED).

| Layer | Live objects | Matches `src/`? |
|---|---|---|
| Bronze | 8 structured tables (2000/10/210/6/7/6/500/60 rows); `BRONZE_SUPPORT_TICKETS` 300; `BRONZE_REVIEWS` 1400; `BRONZE_POLICY_DOCUMENTS` 6; stage `LANDING` (16 files); file formats FF_CSV, FF_JSON, FF_WHOLE_FILE_TEXT | Yes. Policy doc text MD5 = local `data/` files |
| Silver | 8 STG_* dynamic tables (1-min lag); plain tables `SUPPORT_TICKETS_ENRICHED` 300, `REVIEWS_ENRICHED` 1400, `POLICY_DOCUMENT_CHUNKS` 35 (change tracking ON) | Yes. Columns match; latest CTAS (07:52 Nov 11) is the Overview-filter version |
| Gold | 8 star-schema DTs + `SUPPORT_TICKETS_ENRICHED`, `REVIEWS_ENRICHED`, `POLICY_DOCUMENT_CHUNKS` DTs (3-min lag, INCREMENTAL) | Yes. `GET_DDL` matches the script logic |
| Cortex Search | `RENTAL_OPS.GOLD.POLICY_SEARCH`: hybrid, user-provided `AI_EMBED` arctic-embed-l-v2.0 vectors, attr `DOCUMENT_TYPE`, lag 1 day, 35 rows, indexing/serving ACTIVE | Yes |

- `ACCOUNT_USAGE.QUERY_HISTORY` since Nov 11 06:00 shows no DDL that the repo is missing. There are no views, semantic views, agents, procedures, UDFs, Streamlits, git repos or an `EVALUATION` schema.
- All 19 dynamic tables are **SUSPENDED** (done manually, as in `manual-validations/disable-dyn-tables.sql`). Their data is frozen as of Nov 11 13:55. `POLICY_SEARCH` keeps serving because it only needs the existing index.
- `GITHUB_API_INTEGRATION` exists, but no Git repository object uses it.

### Small inconsistencies in the repo
1. `src/gold-layer-code/unstructured-data/01_policy_document_chunks.sql`: the validation comment says "Silver (39)". The actual count is 35.
2. The Bronze load scripts (structured, semi-structured and policy) use `COPY FILES ... FROM 'snow://workspace/USER$.PUBLIC."snowflake-cortex-rental-operations-ai-agent"/...'`. That only works inside a Snowsight Workspace, so it fails from the local CLI.
3. `docs/GOLD_LAYER_DOCUMENTATION.md` covers the star schema, tickets and reviews. It does not cover the policy chunks or the search service.
4. The README is a single line.
5. `.gitignore` has an uncommitted change (adds `.venv/`, `.vscode/`). `.venv` is an empty Python 3.14 venv.

### Completed vs. remaining
- **Done:** Bronze/Silver/Gold for structured, semi-structured and policy docs; AI enrichment (AI_CLASSIFY, AI_REDACT, AI_SENTIMENT, AI_TRANSLATE); baseline Cortex Search (prompt Step 1, committed in c07f9a0).
- **Not started:** Step 2 eval framework (`evaluation/`, `RENTAL_OPS.EVALUATION`); Step 3 doc2query; Step 4 query rewrite + RRF + threshold; Step 5 observability.
- **Roadmap items not yet in prompts:** Semantic View + Cortex Analyst over the Gold star schema, a Cortex Agent combining Analyst and Search, and a UI.

### Claude Code environment gaps
- `snow` is installed at `~/.local/share/snowflake-cli/bin/snow` (v3.33.0). Its PATH entry is in `~/.bashrc`, but Claude's non-interactive shell does not pick it up, so `snow` is "command not found".
- There is no `CLAUDE.md`. CoCo kept the conventions in its chat context (comment-block headers, rerunnable DDL, AI calls only in Silver, change tracking after CTAS, cost guardrails).
- There is no permission allowlist, so every read-only `snow sql` call prompts.

## Implementation plan

**Working mode:** we go one phase at a time; nothing runs in bulk.
- First action: save this plan as `docs/plans/01_resume_assessment_and_roadmap.md`, numbered like `docs/prompts/`.
- Within each phase I write the SQL files, show you the DDL, and run it via `snow sql -c rental-dev` once you approve.
- I show you the query results and validation output here, then **stop for your review** before the next phase.

### Phase 0: Claude Code setup (small, low-risk) — ✅ DONE (commit 0d9a771)
1. Make `snow` resolvable. Either symlink it into `~/.local/bin` or set PATH in `.claude/settings.json` `env`, via the `update-config` skill.
2. Add `CLAUDE.md` with:
   - project layout and layer conventions;
   - the `snow sql -c rental-dev -f <file>` workflow;
   - guardrails: DTs stay suspended; use `ALTER DYNAMIC TABLE … REFRESH` for one-off refreshes; ask before any CREATE/ALTER/DROP; use fully qualified names;
   - a cost note on AI functions.
3. Add a `.claude/settings.json` allowlist for read-only commands (`snow sql … SHOW/DESCRIBE/SELECT`, `git status/diff/log`).
4. Commit the pending `.gitignore` change with this setup.
5. Fix the "39" comment. Add a CLI-friendly alternative to the `snow://workspace` loads: either a `snow stage copy data/... @RENTAL_OPS.BRONZE.LANDING/...` note in each Bronze script, or a `scripts/stage_source_files.sh`. Keep the Workspace path for Snowsight use.

### Phase 1: Step 2, evaluation framework and baseline (from `docs/prompts/01_…md`) — ✅ DONE (golden set extended to `gq_v2`)
- New `evaluation/` folder with numbered scripts:
  - `01_schema.sql` (`RENTAL_OPS.EVALUATION`)
  - `02_policy_golden_questions.sql`
  - `03_policy_retrieval_results.sql`
  - `04_policy_retrieval_summary.sql` (view)
  - `05_run_policy_retrieval_eval.sql` (Snowflake Scripting proc: builds the SEARCH_PREVIEW JSON and runs it with dynamic SQL; the retrieval call is isolated so Step 4 can swap it)
  - `06_run_v0_baseline.sql`
- About 20 golden questions, written by hand from the `data/Unstructured/policy_documents/*.md` sources and labelled by document + section + chunk_id. **Draft shown to you for review before INSERT.**
- Needs only the active search service, no DT resume. Cost is about 20 SEARCH_PREVIEW calls on X-Small.
- Report: summary metrics, failed questions with the actual rank of the expected chunk, and the reranker-score distribution.

### Phase 2: Step 3, doc2query (v1) — ▶ NEXT (unchanged; see plan 02)
- Silver CTAS adds `generated_questions ARRAY` + `question_model` via AI_COMPLETE, a one-time AI cost of about 35 calls.
- Keep the token budget; re-enable change tracking; carry the new columns through the Gold DT.
- Refresh the Gold DT manually (`ALTER DYNAMIC TABLE … REFRESH`, without resuming), then rebuild `POLICY_SEARCH`.
- Show you 5 sample chunks before the eval. Run `v1_doc2query` and compare with v0, including a leakage check.

### ~~Phase 3: Step 4, query rewrite + RRF + threshold (v2)~~ — ⛔ RETIRED
> Retired 2026-11-12 by plan 02: ranking is already strong (hit@1 0.967 on `gq_v2`) and reranker-score thresholds proved poorly calibrated. Kept only as a *conditional* Phase 4 in plan 02, triggered by answer-level evaluation results. Original text below for reference.
- `RENTAL_OPS.GOLD.policy_search_retrieve(question, top_k)`, plus the eval proc extension. Run `v2_query_rewrite` and compare v0/v1/v2.

### Later (separate planning)
Docs update for the policy RAG objects, Semantic View/Cortex Analyst, the Cortex Agent, and Step 5 observability.
> Superseded in part: Step 5 (answer-level evaluation) is **brought forward** to Phase 3 of plan 02.

Each phase ends at a commit point. Commits stay on `feat/build-cortex-search`; I push nothing and create nothing in Snowflake without your approval for each DDL step.

## Verification
- Phase 0: `snow --version` and `snow sql -c rental-dev -q "SELECT CURRENT_ROLE()"` work from Claude's shell without the full path.
- Phase 1: row counts in `EVALUATION` tables; the summary view returns one row for `v0_baseline`; the late-return question is visibly failing (it is the known failure).
- Phases 2–3 (Phase 3 retired; see plan 02 for current verification): `DESCRIBE CORTEX SEARCH SERVICE` shows 35 rows ACTIVE after the rebuild; the summary view compares v0/v1/v2 side by side; DTs are still SUSPENDED afterwards (`SHOW DYNAMIC TABLES`).

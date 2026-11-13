# Project Context — Start Here

A self-contained primer for anyone, human or LLM, picking up this project without access to the code
or earlier conversations. It explains what the project is, how it is built, where it stands, and which
constraints shape the design. The other design-knowledge documents go deep on one topic each; this
one ties them together and says where each piece is implemented.

| | |
|---|---|
| **Last updated** | 2026-11-13 (after Phase 3 Gate 3.3) |
| **Repo purpose** | Learning repo: build a rental-operations AI assistant on Snowflake, and record *why* each design choice was made |
| **Maintenance** | Kept current per `CLAUDE.md` ("Knowledge docs"): update with every change to objects, results or decisions |

---

## 1. What the project is

**Avelto Rentals** is a fictional car rental company (10 branches, 7 countries). The goal is an AI
assistant for rental operations that can:

1. **Answer policy questions** (cancellation, insurance, roadside help, loyalty, …) from the company's
   policy documents, and say "not covered" when the documents don't answer. This is the **policy RAG**
   (retrieval-augmented generation) track and the current focus.
2. **Answer data questions** ("revenue by branch last month") over a star schema. This is planned via
   Semantic Views + Cortex Analyst.
3. **Combine both** in a Cortex Agent, later.

Everything runs inside Snowflake: SQL pipelines, Cortex AI functions, Cortex Search. The project was
started in Snowflake's CoCo assistant and continued in Claude Code; the SQL in `src/` and `evaluation/`
is the record of what is deployed.

---

## 2. Architecture

```
 data/ (local files) ──scripts/stage_source_files.sh──► @RENTAL_OPS.BRONZE.LANDING (stage)
                                                              │
 BRONZE   raw tables, values stored as written (VARCHAR)       │  FleetOps CSV, BookWave JSON,
          + the original files stay on the stage               ▼  tickets, reviews, policy markdown
 SILVER   cleaned / conformed. Structured: dynamic tables.
          Unstructured: plain tables (CTAS) because AI functions run here, ONCE
          (AI_CLASSIFY, AI_REDACT, AI_SENTIMENT, AI_TRANSLATE, AI_COMPLETE for doc2query)
 GOLD     dynamic tables, no AI calls: star schema + enriched tickets/reviews + policy chunks
          + Cortex Search service (policy_search)
          + serving procedure answer_policy_question (query-time AI call, the one exception)
 EVALUATION  question sets, eval procedures, per-run results (retrieval and answers)
```

### 2.1 The policy RAG pipeline (current focus)

```
 6 policy .md files ─► BRONZE.bronze_policy_documents (1 row per document)
   ─► SILVER.policy_document_chunks          structure-aware split (c2_structure): 42 chunks, ≤ 512 tokens,
                                             title | section prefix, quality flags
   ─► SILVER.policy_chunk_generated_questions doc2query: 4 AI-written "questions this chunk answers"
                                             per chunk (claude-sonnet-4-5), cached by chunk-text hash
   ─► GOLD.policy_document_chunks (DT)       chunk + questions → search_text
   ─► GOLD.policy_search (Cortex Search)     hybrid: keyword index on search_text + vector index on
                                             AI_EMBED('snowflake-arctic-embed-l-v2.0') + reranker
   ─► GOLD.answer_policy_question (proc)     top-5 chunks → AI_COMPLETE (claude-sonnet-4-5) →
                                             {decision answered|not_covered, answer, cited ids}
                                             with an input-hash cache (GOLD.policy_answer_cache)
```

---

## 3. Data

| Source | Files | Content |
|---|---|---|
| FleetOps (CSV) | `data/FleetOps/*.csv` (8) | branches, cars, car categories, customers, countries, currencies, branch × category availability, fleet expansion |
| BookWave (JSON) | `data/BookWave/reservations_export.json` | reservations with payment |
| Policy documents | `data/Unstructured/policy_documents/*.md` (6) | cancellation/refund, rental agreement terms, insurance/damage waiver, roadside assistance, driving rules by region, loyalty FAQ |
| Support tickets | `data/Unstructured/support_tickets.csv` | 300 tickets generated from **15 templates** (categories: billing, vehicle issue, refund, roadside, account access, …) |
| Reviews | `data/Unstructured/reviews.csv` | reviews from **32 templates**, some in German / French |

The template structure matters: the held-out evaluation set uses one verbatim instance per template.

---

## 4. Object map (where everything is implemented)

All objects live in database `RENTAL_OPS`. Scripts are numbered in run order and are rerunnable; each
begins with a comment block giving its purpose, prerequisites and design notes.

### 4.1 Pipeline

| Layer | Object(s) | Implemented in |
|---|---|---|
| Bronze | schemas, stage `LANDING`, file formats | `src/bronze-layer-code/structured-data/01_setup_database_schema_stage.sql`, `02_stage_source_files.sql` (Snowsight only; locally `scripts/stage_source_files.sh`) |
| Bronze | `bronze_branches`, `bronze_cars`, `bronze_customers`, … (FleetOps) | `src/bronze-layer-code/structured-data/03_load_fleetops_csv.sql` |
| Bronze | `bronze_bookwave_reservations_raw` | `src/bronze-layer-code/structured-data/04_load_bookwave_json.sql` |
| Bronze | `bronze_support_tickets`, `bronze_reviews` | `src/bronze-layer-code/semi-structured-data/01_…`, `02_…` |
| Bronze | `bronze_policy_documents` | `src/bronze-layer-code/unstructured-data/01_load_policy_documents.sql` |
| Silver | `stg_fleetops_*`, `stg_bookwave_reservations` (DTs) | `src/silver-layer-code/structured-data/01_…` to `03_…` |
| Silver | `support_tickets_enriched` (AI_CLASSIFY category, AI_REDACT body), `reviews_enriched` | `src/silver-layer-code/semi-structured-data/01_…`, `02_…` |
| Silver | `policy_document_chunks` (split, prefix, token count, quality flags, `chunking_version`) | `src/silver-layer-code/unstructured-data/01_policy_document_chunks.sql` |
| Silver | `policy_chunk_generated_questions` (doc2query, prompt `d2q_p1`, hash-cached) | `src/silver-layer-code/unstructured-data/02_policy_chunk_generated_questions.sql` |
| Gold | star schema: `fact_reservations`, `dim_*`, `bridge_branch_category_availability` | `src/gold-layer-code/structured-data/01_gold_star_schema.sql`; reference: `docs/GOLD_LAYER_DOCUMENTATION.md` |
| Gold | `support_tickets_enriched`, `reviews_enriched` | `src/gold-layer-code/semi-structured-data/01_…`, `02_…` |
| Gold | `policy_document_chunks` (DT: chunk + questions → `search_text`) | `src/gold-layer-code/unstructured-data/01_policy_document_chunks.sql` |
| Gold | `policy_search` (Cortex Search service) | `src/gold-layer-code/unstructured-data/02_policy_search_service.sql` |
| Gold | `answer_policy_question` (procedure), `policy_answer_cache` (table) | `src/gold-layer-code/unstructured-data/03_answer_policy_question.sql` |

### 4.2 Evaluation (schema `RENTAL_OPS.EVALUATION`)

| Object | Purpose | Implemented in |
|---|---|---|
| `policy_golden_questions` | golden set `gq_v2`: 38 hand-written questions (30 answerable, 8 out-of-scope) | `evaluation/02_policy_golden_questions.sql` |
| `policy_holdout_questions`, view `policy_eval_questions` | held-out set `ho_tickets_v1`: 22 verbatim tickets/reviews (14 + 8); the view unions both sets | `evaluation/09_policy_holdout_questions.sql` |
| `policy_retrieval_results`, view `policy_retrieval_summary` | one row per run × question with rank metrics; scorecard view | `evaluation/03_…`, `04_…` |
| `run_policy_retrieval_eval` | retrieval eval procedure (retrieve, then grade) | `evaluation/05_run_policy_retrieval_eval.sql` |
| retrieval runs + reports | v0 / v1 / v1b golden; v1b held-out + calibration | `evaluation/06_…`, `07_…`, `08_…`, `10_…` |
| `policy_answer_results` | one row per run × question: decision, answer, citations, per-row metrics, tokens | `evaluation/11_policy_answer_results.sql` |
| `run_policy_answer_eval` | answer eval procedure (calls `answer_policy_question` per question) | `evaluation/12_run_policy_answer_eval.sql` |
| Gate 3.1 smoke test + schema/plain A/B | 3 questions | `evaluation/13_run_a1_smoke.sql` |
| Gate 3.2 generation run (golden + held-out) | `a1_grounded_answer`, `a1_grounded_answer_holdout` | `evaluation/14_run_a1_grounded_answer.sql` |
| `policy_answer_judgments`, `policy_answer_reviews` | LLM-judge verdicts (correctness + groundedness, cached on input hash); human verdicts keyed on the answer (final labels) | `evaluation/15_policy_answer_judgments.sql` |
| `run_policy_answer_judge` | judge procedure (`judge_p1`, `openai-gpt-5.4`, answered rows only) | `evaluation/16_run_policy_answer_judge.sql` |
| Gate 3.3 judge run + human review | judge on both a1 runs; agreement, strict / lenient / partial credit | `evaluation/17_run_j1_judge.sql`, `18_policy_answer_human_review.sql` |

### 4.3 Key table shapes

| Table | Key columns |
|---|---|
| `policy_golden_questions` / `policy_holdout_questions` | `question_id` (pq_NN / ho_NN), `question`, `question_style` (direct, paraphrase, casual, ticket, review, out_of_scope), `is_answerable`, `expected_document_id`, `expected_section_header`, `expected_chunk_ids`, `expected_evidence` (verbatim spans), `expected_answer`, `dataset_version`; held-out adds `source_type`, `source_id`, `source_category`, `language` |
| `GOLD.policy_document_chunks` | `chunk_id` (`<document>_<NN>`), `document_id`, `document_title`, `section_header`, `chunk_text` (raw, for citation), `search_text` (indexed: context + chunk + generated questions), `document_type`, `chunking_version`, `is_quality_flagged` |
| `policy_retrieval_results` | `run_id`, `setup_version`, `question_id`, `retrieved_chunk_ids`, `scores`, `first_hit_rank`, `hit_at_1/3/5`, `reciprocal_rank`, `top_reranker_score`, `raw_response` (full list: doc 01 §5.3) |
| `policy_answer_results` | `run_id`, `setup_version`, `retrieval_setup`, `question_set`, `question_id`, `model`, `output_mode`, `prompt_version`, `retrieved_chunk_ids`, `decision`, `answer`, `cited_chunk_ids`, `uncovered_parts`, `decision_correct`, `citation_valid`, `citation_hit`, `expected_in_top_k`, tokens, latency, `cached`, `call_status` |
| `GOLD.policy_answer_cache` | `input_sha` (PK: SHA2 of model, output mode and full prompt), the parsed answer fields, tokens, `raw_response` |

---

## 5. Where the project stands

| Phase | What | setup_version | Headline result |
|---|---|---|---|
| 0 | Claude Code setup, snow CLI, cost tracking | — | done |
| 1 | Retrieval eval framework + golden set + baseline | `v0_baseline` | hit@1 0.967 (gq_v2); one miss (pq_05, rank 24) |
| 2 | doc2query | `v1_doc2query` | ranking unchanged; median answerable rank-1 score −3.94 → −1.25 |
| 2b | Structure-aware chunking (35 → 42 chunks) | `v1b_chunking` | hit@5 1.000, MRR 0.978; golden score separation +0.71 |
| 2a | Held-out set (tickets/reviews) + calibration check | `v1b_chunking_ho` | hit@3 0.93, but score AUC 0.62: **no score threshold works** |
| 3 | Grounded answers with LLM abstention + answer-level eval | `a1_grounded_answer` (+ `_holdout`) | Gate 3.3 done: golden OOS abstention 8/8, false abstention 0/30, strict correctness 29/30 (human-reviewed); held-out 7/8, 2/14, strict 8/14 (lenient 12/14); citations 100% valid; judge–human κ 0.77. Report (3.4) next |
| 4 | Query rewrite (conditional) | `v2_query_rewrite` | only if Phase 3 failures trace to retrieval |
| later | Semantic View + Cortex Analyst; Cortex Agent | — | separate planning |

Plans: `docs/plans/02_policy_rag_roadmap_revision.md` (why the roadmap changed, Phase 2–2a results),
`docs/plans/03_phase3_grounded_answers.md` (Phase 3 gates). `01_…` is historical.

---

## 6. Constraints and platform quirks that shape the design

| Constraint | Effect on the design |
|---|---|
| **Cost:** Enterprise edition, $3/credit; X-Small warehouse (1 cr/h, 60 s minimum per resume) | All dynamic tables are **intentionally suspended**; refreshes are one-off `ALTER DYNAMIC TABLE … REFRESH`. Each gate's work is batched into one script. Every LLM call per row is cached by input hash |
| **AI calls only in Silver plain tables** (run once, not on every refresh) | Gold dynamic tables never call AI. Exception: query-time answering in GOLD **procedures** (one call per user query), with a cache |
| CTAS resets change tracking | Re-run `ALTER TABLE … SET CHANGE_TRACKING = TRUE` after a Silver CTAS (Gold incremental DTs need it) |
| Legacy `SNOWFLAKE.CORTEX.EMBED_TEXT_*` is **blocked** on this account | Cortex Search uses **user-provided vectors**: `AI_EMBED('snowflake-arctic-embed-l-v2.0', …)` + `VECTOR INDEXES col (query_model = …)`; chunks ≤ 512 tokens |
| `SEARCH_PREVIEW` needs **constant arguments** | Search calls inside procedures are built as dynamic SQL |
| `AI_COMPLETE`'s `model` must be a **string literal** | Dynamic SQL, with the model checked against an allowlist |
| `AI_COMPLETE` structured output fails **silently with NULL** | NULL is stored as `call_status = 'failed'`, never counted as an abstention, never cached |
| OpenAI models return JSON only if the schema has `"additionalProperties": false` | All schemas include it |
| Usable models (AWS_US_WEST_2, Gate 3.0) | Generator `claude-sonnet-4-5`; judge `openai-gpt-5.4` (fallback `mistral-large3`). `gemini-3.1-pro`, `openai-gpt-4.1` return NULL in JSON mode; `llama4-maverick` errors; `openai-gpt-5.5` is listed but not allowed |
| snow CLI legacy templating reads `&name` as a variable, even in comments | Write "Q and A", not the ampersand form, or run with `--enable-templating NONE` |
| `snow://workspace/…` paths only work in Snowsight | Local staging uses `scripts/stage_source_files.sh` |

---

## 7. Evaluation principles (apply to every phase)

- **Two question sets.** Golden (`gq_v2`, hand-written from the documents) is the **regression check**.
  Held-out (`ho_tickets_v1`, verbatim tickets) is where **design and calibration choices are judged**:
  the golden set is saturated for ranking (29/30 at rank 1) and mildly contaminated (4 near-copies
  among doc2query questions).
- **Labels survive re-chunking:** each answerable question carries verbatim evidence spans, and chunk ids
  are re-derived from them by a validation query.
- **Every run is tagged** with a `setup_version` and stored per question; metrics are frozen at insert time.
  `v*` = retrieval setups (`policy_retrieval_results`), `a*` = answer setups (`policy_answer_results`),
  each answer row names its retrieval setup in `retrieval_setup`. Held-out runs: suffix `_holdout`
  (older `v1b_chunking_ho` kept). Details: doc 03 §7.4.
- **No tuning on the exam:** prompts are fixed before the first run; the first run is the headline; at
  most one revision, only for a failure class; labels are never changed after seeing results.

---

## 8. Reading order

| Read | For |
|---|---|
| this doc | the map: what exists, where, why the constraints |
| `01_policy_retrieval_evaluation.md` | how retrieval is measured, metrics, results v0 → v1b → held-out |
| `02_chunking_guidelines.md` | how documents are split and quality-checked, and why |
| `03_grounded_answers_and_abstention.md` | the answer step: decision history from baseline to now, cache, output format, answer evaluation |
| `04_answer_evaluation_methods.md` | how answers are judged: LLM judge, human validation (kappa), scoring partly-right answers (strict/lenient, partial credit, nuggets, claim-level), randomness, small-sample intervals |
| `docs/plans/02_…`, `03_…` | gate-by-gate plans and raw results |
| `CLAUDE.md` | working rules, conventions, cost tracking |

For implementation questions, each design doc has an **Implementation map** listing the files that
implement it; the SQL files' header comments explain the logic in plain language.

# 05 — TruLens / TruApp observability for the hand-built policy RAG

| | |
|---|---|
| **Date** | 2026-11-20 |
| **Builds on** | `04_ai_observability.md` (option O3, dropped the same morning as decision O-D2); `docs/design-knowledge/07_ai_observability.md` §2, §6 |
| **Status** | **Approved 2026-11-20** (all three §4 recommendations: hand-built RAG only, T0–T2 now, judge `openai-gpt-5.4`). T0, T1, T2 done (T2 approved 2026-11-20). T3 = separate decision, after T2 actual credits are in. T4 docs kept current per gate |
| **Object observed** | `RENTAL_OPS.GOLD.answer_policy_question` (hand-built RAG: `SEARCH_PREVIEW` on `GOLD.policy_search` → `AI_COMPLETE` `claude-sonnet-4-5`, prompt `ga_p1`, plain mode) |
| **Working mode** | One gate at a time; code/SQL shown and approved before running; results reviewed before the next gate |

## 1. Why now, and what changed since O-D2

O-D2 (2026-11-20) dropped TruLens for three reasons. Two have changed or turned out smaller than assumed:

| O-D2 reason | Status now (checked 2026-11-20) |
|---|---|
| "Local venv is Python 3.14 without `trulens` / Snowpark; version support unchecked" | **Resolved**: `uv pip compile` resolves `trulens-core`, `trulens-connectors-snowflake`, `trulens-providers-cortex` **2.16.0** + `snowflake-snowpark-python` 1.58.0 + `snowflake-ml-python` 1.54.0 on 3.11, 3.12 and 3.14. uv already has CPython **3.12.15** installed |
| Cost ≈ 0.4–0.5 cr for judge calls | Unchanged, so the work is gated: a 3-question smoke run (T2) comes before any full run (T3) |
| Our SQL harness already measures groundedness (κ 0.77); managed metrics ignore abstention labels | Unchanged. TruLens is **added beside** the SQL harness, not as a replacement. What it adds: the TruLens trace UI in Snowsight (*AI & ML → Evaluations*), per-span RAG-triad scores, and a managed-vs-ours judge comparison (the revisit condition O-D2 named) |

TruLens is still **not** used for `GOLD.avelto_agent`, because native agents are traced automatically
(doc 07 §2, O-D1).

## 2. Design

### 2.1 How the pieces fit

```
local Python (.venv-trulens, py3.12)                       Snowflake (RENTAL_OPS.EVALUATION)
┌──────────────────────────────────────┐                   ┌───────────────────────────────────┐
│ PolicyRAG.answer(query)   RECORD_ROOT│── CALL ──────────▶│ GOLD.answer_policy_question       │
│   ├─ retrieve(query)      RETRIEVAL  │◀─ chunk texts ────│ GOLD.policy_document_chunks       │
│   └─ generate(...)        GENERATION │                   │                                   │
│ TruApp(app_name, app_version,        │── spans (OTEL) ──▶│ EXTERNAL AGENT  (TruApp registers)│
│        connector=SnowflakeConnector) │── run / metrics ─▶│ AI_OBSERVABILITY_EVENTS + judge   │
└──────────────────────────────────────┘                   └───────────────────────────────────┘
```

- **Thin wrapper, no logic changes**: the Python app calls the deployed procedure once per question
  (one `CALL`, so the answer is identical to the SQL harness and **cache hits cost 0 tokens**). It
  then reads the text of the `retrieved` chunk ids from `GOLD.policy_document_chunks` so that the
  RETRIEVAL span carries the contexts the LLM actually saw. (The procedure returns ids only, see its header.)
- Span mapping: `RECORD_ROOT.INPUT` = question, `RECORD_ROOT.OUTPUT` = answer (or the abstention text),
  `RETRIEVAL.QUERY_TEXT` / `RETRIEVAL.RETRIEVED_CONTEXTS` = query / chunk texts,
  `RECORD_ROOT.GROUND_TRUTH_OUTPUT` = `expected_answer`. Extra attributes: decision, cited ids,
  cached, tokens, so traces can be joined back to `EVALUATION.policy_answer_results`.
- **Dataset**: the existing view `EVALUATION.policy_eval_questions` (golden 30 + held-out 22),
  filtered by `question_set`; no new table unless TruLens refuses a view (then a CTAS copy, with approval).
- **Naming**: `app_name = policy_rag`, `app_version = a1_grounded_answer` (same as the SQL setup it
  wraps); run names `t1_<set>_<yyyymmdd>`.
- **Metrics**: `context_relevance`, `groundedness`, `answer_relevance`, `correctness` (vs `expected_answer`).
  Judge model: explicit, `openai-gpt-5.4` (our accepted judge, j1) if TruLens accepts it, else
  `mistral-large3` (our fallback). It is never left to the default.
- **Known mismatch to report, not fix**: for out-of-scope questions the right output is an
  abstention. Managed answer relevance / correctness may score correct abstentions low. T3 reports
  metrics split by `is_answerable` and compares them with our strict/lenient verdicts.

### 2.2 Files

| File | Purpose |
|---|---|
| `observability/trulens/requirements.txt` | pinned versions (2.16.0 / 1.58.0) |
| `observability/trulens/policy_rag_app.py` | instrumented `PolicyRAG` class + `TruApp` registration |
| `observability/trulens/run_eval.py` | CLI: `--question-set golden|holdout --limit N --run-name ...`; adds run, `start()`, `compute_metrics()` |
| `manual-validations/trulens-observability.sql` | read-only checks: external agent, runs, metric rows, join to `policy_answer_results` |

Snowpark session from the existing `rental-dev` connection (`~/.snowflake` config); no credentials in the repo.
`.venv-trulens/` is gitignored. The existing `.venv` (3.14, empty) is left alone.

### 2.3 Risks / open questions

| Risk | Check |
|---|---|
| Exact TruLens 2.16 API (`instrument`, `RunConfig`, `dataset_spec` keys, judge argument) differs from what's assumed here | T0 reads the installed package source / docstrings before T1 code is written. No API is taken from memory |
| AI credits: 2026-11-19 `:run` failed with *trial AI credits exhausted* (399588); 2026-11-20 cowork turns did run | T1 smoke `CALL` on one cached question shows whether AI is available (0 tokens if cached) |
| Privileges: TruApp creates an `EXTERNAL AGENT` and the run uses tasks | ACCOUNTADMIN; any failure is reported, never worked around with new grants without approval |
| Judge cost higher than estimated (per-claim groundedness, per-chunk context relevance) | T2 measures actual tokens on 3 questions and re-estimates T3 before it runs |
| Warehouse stays busy longer (metric computation runs in Snowflake) | Measure in T2 |

## 3. Gates

| Gate | Work | Est. cost |
|---|---|---|
| **T0** | Local only: `uv venv .venv-trulens --python 3.12`, install pinned packages, read the installed API, gitignore entry | 0 Snowflake |
| **T1** | Write `policy_rag_app.py` + `run_eval.py` (shown for approval). Run **one** question **without TruLens export**, as a plain wrapper call, to validate the CALL + chunk-text lookup | 1 burst ≈ 0.02–0.04 cr; 0 AI tokens if the question is a cache hit |
| **T2** | First TruLens run: register `TruApp` (creates the EXTERNAL AGENT in `RENTAL_OPS.EVALUATION`), 3 golden questions (2 answerable, 1 out-of-scope), compute the 4 metrics; check the Snowsight Evaluations UI + `manual-validations/trulens-observability.sql`; measure judge tokens | ≈ 3 × (5 context-rel. + ~4 groundedness + 2) ≈ 35 judge calls ≈ 0.02–0.05 cr AI + 2–3 bursts ≈ 0.05–0.1 cr |
| **T3** *(separate approval, re-estimated from T2)* | Full runs: golden 30, then held-out 22. Compare TruLens scores with the j1 verdicts + human review (agreement per metric, split by answerable / OOS) | ≈ 0.4–0.5 cr AI (O-D2 estimate) + warehouse ≈ 0.1 cr |
| **T4** | Docs: doc 07 (§2 table, new §TruLens section, decision O-D7 *reverses* O-D2 with the evidence above, O-D2 kept as history, implementation map), primer (object map, status, Last updated), memory | 0 |

Total without T3 ≈ 0.1–0.2 cr (~$0.30–0.60); with T3 ≈ 0.6–0.8 cr (~$1.80–2.40).

## 4. Decisions needed before T0

1. **Scope**: hand-built RAG only (recommended) vs also wrapping `avelto_agent` as an external app (not
   recommended: duplicates native traces, see O-D1).
2. **Stop point**: T0–T2 now (traces + smoke metrics, ≈ $0.30–0.60), and T3 later as its own decision (recommended), or all through T3.
3. **Judge**: `openai-gpt-5.4` (matches j1, gives a clean managed-vs-ours comparison) vs Snowflake's default.

## 5. Results

### Gate T0 (2026-11-20): local environment

- `uv venv .venv-trulens --python 3.12` (CPython 3.12.15) + `observability/trulens/requirements.txt`; `.venv-trulens/` gitignored.
- **Finding:** the first install failed on import: `trulens.connectors.snowflake` → `snowflake-sqlalchemy` 1.11.1 →
  `AttributeError: sqlalchemy.orm.context has no attribute 'ORMSelectCompileState'` (SQLAlchemy **2.1.9** was resolved; the
  class was renamed). Fix: pin `sqlalchemy>=2.0,<2.1` (→ 2.0.58). All imports OK.
- Installed API read before writing code (not from memory): `RunConfig(run_name, dataset_name, source_type, dataset_spec,
  llm_judge_name, mode, invocation_max_workers, …)`; `run.start(input_df)` returns **before** server-side ingestion, so
  `compute_metrics()` must wait for `INVOCATION_COMPLETED` (else it silently computes nothing); `instrument(span_type=RECORD_ROOT)`
  is refused (TruApp sets the record root from `main_method`); attribute callables get `(ret, exception, *args, **kwargs)` with
  named args in kwargs. With OTEL + account event table the connector creates only a TEMP stage and the `EXTERNAL AGENT`
  (no TruLens SQLAlchemy tables).
- Snowflake cost 0.

### Gate T1 (2026-11-20): wrapper dry run

Files: `observability/trulens/policy_rag_app.py`, `observability/trulens/run_eval.py`. Offline test with a fake session: rank
order kept, abstention rendered `[not_covered] …`.

`run_eval.py --dry-run --question-ids pq_01` (session via `rental-dev` key-pair): `decision=answered status=ok cached=True
tokens=0/0 contexts=5`, answer = the a1 answer (50% refund 24–48 h). Chunk lookup: 5 ids → 5 texts (227–326 chars), rank order kept.
1–2 warehouse bursts (≈ 0.02–0.04 cr est., actual pending), 0 AI tokens. No objects created.

**Not yet proven:** that AI functions run on this account (cache hit = no `AI_COMPLETE`); the first judge call in T2 shows it.

### Gate T2 (2026-11-20): first TruLens run (`t2_smoke_20261120`)

`run_eval.py --question-ids pq_01,pq_02,pq_23 --run-name t2_smoke_20261120`: `TruApp` created
**`EXTERNAL AGENT RENTAL_OPS.EVALUATION.POLICY_RAG`** (version `a1_grounded_answer`, 05:13 PST); invocation
`INVOCATION_COMPLETED` within ~1 min; `compute_metrics` ran server-side and was done before the check ~4 min later.
All 3 answers were answer-cache hits (0 generation tokens). **Judge `openai-gpt-5.4` ran, so AI functions work on
this account.** Checks: `manual-validations/trulens-observability.sql` §1–§4 (2 warehouse bursts).

**Trace anatomy (discovered, §2a/§2b):** per record: `record_root` span `policy_rag_app.PolicyRAG.answer`
(`record_root.input/output/ground_truth_output`), `generation` span `call_answer_procedure` (our
`rental_ops.policy_rag.*` attributes: decision, cached, tokens, input_sha, cited ids), `retrieval` span `retrieve`
(`retrieval.query_text`, `retrieved_contexts`, `num_contexts`), 2 `collect` spans (Snowpark auto-instrumented).
Metrics: one `eval_root` span per record × metric (`eval.metric_name`, `eval_root.score` 0–1, `eval_root.n_calls`,
`eval.target_record_id` = `record_id`), one `eval` span per judge call (`eval.score` 0–3, `eval.explanation`,
`eval.criteria`, `eval.llm_judge_name`). 12 eval roots + 26 judge calls (estimate was ~35).

**Scores (§3, 0–1):**

| Question | Truth | Our decision | context_relevance | groundedness | answer_relevance | correctness | judge calls |
|---|---|---|---|---|---|---|---|
| pq_01 (refund 24–48 h) | answerable | answered (j1 correct) | **0.27** | 1.00 | 1.00 | 1.00 | 9 |
| pq_02 (convertible deposit) | answerable | answered (j1 correct) | 0.53 | 1.00 | 1.00 | 1.00 | 9 |
| pq_23 (child seats) | out of scope | not_covered (correct abstention) | **0.00** | **0.00** | 0.67 | 1.00 | 8 |

**Findings:**

1. **Context relevance is a top-5 precision score, not "was the evidence retrieved".** It scores each of the 5 chunks
   and averages: pq_01 has the right chunk at rank 1 (scored 3/3) but 4 neighbouring cancellation/refund chunks scored
   0–1, so 0.27. With `top_k = 5` and one-chunk answers, low values are expected for correct retrievals. Our hit@k /
   rank metrics (doc 01) remain the retrieval measure; this one only says how much noise the LLM sees.
2. **Correct abstentions get groundedness 0 and context relevance 0**, as predicted in §2.1: the judge finds "NOTHING
   FOUND" to support "the documents do not cover child car seats". For out-of-scope questions both scores are
   *expected* to be 0 (nothing relevant retrieved = the reason to abstain). Correctness (vs `expected_answer`) did
   recognise the abstention (1.0). **Any T3 summary must split by `is_answerable`**; averaged over all questions,
   groundedness would punish correct abstention.
3. Answerable answers: groundedness, answer relevance and correctness all 1.0, consistent with the j1 verdicts for
   pq_01 / pq_02 (correct).
4. Judge tokens are not on the spans: T2 AI credits come from `ACCOUNT_USAGE` (lag): **pending**. The T3 re-estimate
   needs that number: T3 ≈ 52 questions × ~8.7 calls ≈ 450 judge calls ≈ **17× T2's AI cost**.

Cost: ≈ 3 warehouse bursts (run, ingestion and metric procedures, 2 checks) ≈ 0.06–0.1 cr est. + judge ≈ 0.01–0.04 cr
est.; actuals pending.

**UI check (2026-11-20, user):** Snowsight nav is now *AI → Evaluations* (not *AI & ML*). The page shows **no runs**
(ACCOUNTADMIN), while the SQL queries in Snowsight return the data and `SYSTEM$AIML_RUN_OPERATION('LIST', {POLICY_RAG,
EXTERNAL AGENT})` returns `t2_smoke_20261120`: run_status ACTIVE, invocation COMPLETED (3/3), 4 metrics COMPLETED (3/3),
judge openai-gpt-5.4, source_type DATAFRAME. Cause open (doc 07 §9). Not rerun.

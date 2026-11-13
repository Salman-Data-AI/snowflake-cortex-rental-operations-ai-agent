# Policy RAG — Grounded Answers and Abstention: How We Got Here

What the answer step does, why it is built this way, and how the design changed from the first
retrieval baseline to the current build. The main focus is the **decision points**: what we
believed at each stage, what evidence changed it, which alternatives were on the table, and how
the trade-off was made.

| | |
|---|---|
| **Applies to** | `RENTAL_OPS.GOLD.answer_policy_question`, `GOLD.policy_answer_cache`, `EVALUATION.policy_answer_results`, `EVALUATION.run_policy_answer_eval` |
| **Implemented in** | `src/gold-layer-code/unstructured-data/03_…`, `evaluation/11_…` to `13_…` |
| **Plans** | `docs/plans/02_policy_rag_roadmap_revision.md` (why), `docs/plans/03_phase3_grounded_answers.md` (how, gates) |
| **Companion docs** | `01_policy_retrieval_evaluation.md` (retrieval metrics), `02_chunking_guidelines.md` |
| **Status** | Gate 3.1 done (2026-11-13): built + smoke-tested. Full runs (3.2), judge (3.3) and report (3.4) pending |

**Last updated:** 2026-11-13 (after Gate 3.1)

## Implementation map

| What | Object | File |
|---|---|---|
| Answer procedure: retrieve top 5, prompt `ga_p1`, cache lookup, one `AI_COMPLETE` call, validate, return | `GOLD.answer_policy_question` | `src/gold-layer-code/unstructured-data/03_answer_policy_question.sql` |
| Answer cache (key = SHA2 of model, output mode, full prompt; `ok` answers only) | `GOLD.policy_answer_cache` | same file |
| Per-question answer results + deterministic metrics | `EVALUATION.policy_answer_results` | `evaluation/11_policy_answer_results.sql` |
| Answer eval procedure (loop + scoring insert) | `EVALUATION.run_policy_answer_eval` | `evaluation/12_run_policy_answer_eval.sql` |
| Gate 3.1 smoke test + schema/plain A/B + cache check | runs `a1_smoke_*` | `evaluation/13_run_a1_smoke.sql` |
| Question sets used (golden + held-out union) | view `EVALUATION.policy_eval_questions` | `evaluation/09_policy_holdout_questions.sql` |
| Retrieval being consumed | `GOLD.policy_search` | `src/gold-layer-code/unstructured-data/02_policy_search_service.sql` |
| Serving-layer rule (AI calls in GOLD procedures only) | — | `CLAUDE.md` "SQL conventions" |
| Gate plan, targets, Gate 3.0 model results | — | `docs/plans/03_phase3_grounded_answers.md` |

---

## 1. The problem in one paragraph

A RAG assistant has two jobs: **find** the right policy text, and **decide what to say** with it,
including "our policies don't cover that". The first job (retrieval) is now good: the right chunk is
almost always in the top 5. The second job is the open problem. The system must not answer a question
the policies don't cover (a confident made-up answer is worse than no answer), and it must not refuse
a question they do cover. This "answer or abstain" decision is called **abstention**. This doc
explains why abstention moved from a **score threshold in retrieval** (the original plan) to the
**answering LLM itself**, and how that answer step is built, cached and evaluated.

---

## 2. The journey: decision points from baseline to Gate 3.1

Each row is a point where evidence changed the plan. Numbers are from `EVALUATION.policy_retrieval_results`
and `policy_answer_results`.

| # | Stage | What we believed | Evidence | Decision |
|---|---|---|---|---|
| **D1** | v0 baseline on `gq_v1` (21 answerable + 4 OOS) | Retrieval needs two fixes: doc2query (ingest time) and query rewrite + a **reranker-score threshold** (query time) to reject out-of-scope (OOS) questions | hit@1 0.952; clean score gap: answerable ≥ −5.59, OOS ≤ −8.18 | Keep the plan; a threshold looked easy |
| **D2** | Harder golden set `gq_v2` (30 + 8, with near-miss OOS) | The gap was real | Gap gone: lowest answerable −8.36 < highest OOS −6.87. Best cut-off still rejects a correct answer (pq_30). Margin (rank 1 − rank 2) was worse: rejects 7/8 OOS but also 3/30 answerable | **Retire the query-time threshold plan (old Step 4). Move abstention into the answer step. Bring answer-level evaluation forward.** (plan 02, decisions 2–4) |
| **D3** | doc2query (`v1_doc2query`) | Generated questions close the vocabulary gap and lift confidence | Median answerable score −3.94 → **−1.25**; OOS −9.26 → −9.64 (gap 5.3 → 8.4). But scores still overlap; ranking unchanged (0.967) | v1 becomes the reference. **Calibration is a goal, judged on a held-out set, not on the golden set** (golden is saturated: 29/30 at rank 1, and 4 near-copies leaked into generated questions) |
| **D4** | Chunking (`v1b_chunking`) | Splitting the big FAQ chunk fixes diluted scores | hit@5 1.000; lowest answerable −8.09 → −5.83; golden separation turns **positive (+0.71)** | Kept. But "separation on 38 curated questions" is a hint, not a calibrated threshold → test on held-out |
| **D5** | Held-out set `ho_tickets_v1` (22 verbatim tickets / reviews) | The golden cut-off might work after all | It does not transfer: separation **−4.70**, AUC **0.62** (≈ coin-flip is 0.5), golden cut-off −6.18 would refuse **7 of 9** correct held-out answers. Ticket wording scores ~**7 points lower** for the *same* correct chunk. Yet retrieval still finds it: hit@3 **0.93** | **No score threshold at all, not even as a pre-filter.** The LLM decides, reading the top **5** chunks (covers rank 2–3 hits). Evaluate on **both** sets |
| **D6** | Gate 3.0 model check | Any Cortex model can be the generator or judge | Several models fail silently in JSON mode (§7.1) | Generator `claude-sonnet-4-5`; judge `openai-gpt-5.4` (different family), fallback `mistral-large3` |
| **D7** | Cost controls (plan 03 §2.2a) | Each eval rerun pays for every LLM call again | 60 questions × reruns while iterating would add up | Input-hash **answer cache**; one judge call per answered row; batch each gate in one script; A/B the JSON format before full runs |
| **D8** | Gate 3.1 build | Cache in the eval table, keyed on question + chunk ids | Building it showed a better place and key (§5) | Cache lives in **GOLD**, used by the answer procedure itself; key = **hash of the full prompt** |
| **D9** | Gate 3.1 A/B: schema vs plain JSON | The schema is needed for reliable JSON | Plain parsed **3/3**, same decisions, **~885 vs ~1,600** prompt tokens (§6) | Use **plain** for Phase 3 runs, with stricter validation; measure the failure rate on 60 calls. A schema fallback was considered and **not built** (§6.4) |

The thread through all of it: **every time a clean-looking result came from a small or curated set,
a harder or independent set broke it** (D1 → D2, D4 → D5). That is why the held-out set now judges
design choices, and why the golden set is only a regression check.

---

## 3. How the answer step relates to retrieval

### 3.1 Division of labour

```
 user request / ticket
        │
        ▼
 ┌───────────────────────────┐   job: RECALL. Get the right chunk somewhere in the top 5.
 │ Cortex Search (policy_    │   Measured: hit@5 golden 1.000, hit@3 held-out 0.93.
 │ search), top_k = 5        │   No threshold: always returns 5 chunks.
 └────────────┬──────────────┘
              │ 5 excerpts: chunk_id + title/section + chunk_text
              ▼
 ┌───────────────────────────┐   job: PRECISION + ABSTENTION. Read the 5 excerpts,
 │ AI_COMPLETE (Sonnet 4.5)  │   decide "answered" or "not_covered", answer only from the
 │ prompt ga_p1, temp 0      │   excerpts, cite the ids used.
 └────────────┬──────────────┘
              ▼
 {decision, answer, cited_chunk_ids, uncovered_parts}
```

Retrieval is tuned to **not miss**; the LLM is responsible for **ignoring irrelevant excerpts and
refusing when none apply**. This is why `top_k` is 5 and not 1: on the held-out set, 4 of 14 correct
chunks were at rank 2–3 (9 at rank 1, 1 at rank 6). A score cut-off would have thrown them away (D5); the LLM can still use them.

### 3.2 Why the LLM can do what the score could not

The reranker score answers "how similar is this text to this query?" That depends heavily on how the
query is *written*: a ticket full of reservation numbers and "ASAP" scores lower than a clean question
for the same chunk. The LLM answers a different question: "does this text state a rule that addresses
this request?" That is the actual abstention decision, and it does not depend on wording style the
same way. This is a hypothesis Phase 3 tests, not a proven fact: the Gate 3.2 numbers (OOS abstention,
false abstention per set) decide.

### 3.3 Telling retrieval failures from answer failures

Each result row stores `expected_in_top_k` (was a labelled chunk among the 5 given to the LLM?):

| `expected_in_top_k` | LLM outcome | Failure belongs to | Fix |
|---|---|---|---|
| FALSE | wrong / not_covered | **Retrieval** | Phase 4 (query rewrite) |
| TRUE | not_covered (false abstention) or unsupported claim | **Answer step** | prompt revision `ga_p2` |
| TRUE | answered, cites expected chunk | — | — |

This is the Phase 4 trigger from plan 03 §4, made checkable per row.

---

## 4. The answer path (`GOLD.answer_policy_question`)

### 4.1 Steps

1. **Retrieve**: `SEARCH_PREVIEW`, top 5, columns `chunk_id`, `document_title`, `section_header`,
   `chunk_text`, plus the rerank score (diagnostic only, never used to decide).
2. **Build prompt `ga_p1`**: fixed instructions + excerpts labelled `[chunk_id]` + the request.
3. **Hash** the full input (§5); return a cached answer if one exists.
4. **Call** `AI_COMPLETE` once (temperature 0, max 600 tokens, token usage returned).
5. **Validate**: JSON parses, `decision` ∈ {answered, not_covered}, `cited_chunk_ids` is an array,
   `answer` and `uncovered_parts` are strings. Else `call_status = 'failed'`.
6. **Return** one VARIANT with the answer, retrieved ids + scores, status, tokens, latency.

### 4.2 Prompt rules and why each exists

| Rule in `ga_p1` | Why |
|---|---|
| Use only facts in the excerpts; no general knowledge | Groundedness: a rental company's policy is specific, and general knowledge is a source of plausible but wrong answers |
| If an excerpt addresses the request → `answered` + cite ids | Citations make answers checkable (citation validity is measured) |
| Else → `not_covered`, say so plainly; **a related topic doesn't count** | Targets near-misses: the held-out set showed out-of-scope tickets retrieve related chunks (ho_15 login → loyalty "check balance") |
| Requests ≠ questions: answer the policy aspect, leave account actions to Support | Tickets ask for refunds, resets, confirmations. The policy part is answerable; the action is not the assistant's to promise |
| Partial coverage → `uncovered_parts` | Avoids a forced binary on mixed requests; keeps what wasn't answered visible |
| Answer in English | Held-out has German and French reviews; staff read English |
| Reply as JSON with 4 named keys | Parseable output (needed in plain mode, harmless in schema mode, keeps the A/B fair) |

**What the LLM does *not* see:** the doc2query questions. They were added to the search index for
*matching*; they are AI-written and not policy. Showing them could make the model cite a generated
question as if it were a rule.

**Written before any run, with no golden or held-out examples** (plan 03 §2.4). At most one revision
(`ga_p2`), only for a whole failure class, with p1 and p2 both reported.

### 4.3 Why a stored procedure in GOLD

- `SEARCH_PREVIEW` needs constant arguments, and `AI_COMPLETE`'s `model` must be a literal, so both
  are built as dynamic SQL. That needs a procedure (a UDF cannot do it). `model` is checked against
  an allowlist before it goes into the SQL text.
- The project rule says AI calls run once in Silver, never in Gold dynamic tables. Answering is
  different: **one call per user query, by design**. CLAUDE.md now records this serving-layer
  exception: query-time AI calls may live in GOLD **procedures**; no dynamic table calls them.

---

## 5. The answer cache

### 5.1 Why a cache

Evaluation is iterative: rerun a report, fix one failed row, change the metric SQL. Without a cache,
each rerun repeats every LLM call. Same pattern as doc2query in Silver (generate once per chunk text).

### 5.2 Design decisions

| Decision | Chosen | Alternatives considered | Why |
|---|---|---|---|
| **Where** | `GOLD.policy_answer_cache`, used by the answer procedure itself | (a) the eval procedure looks up `policy_answer_results` (plan 03's first design); (b) no cache | (a) would only help the eval; production could not reuse it, and the eval would need its own retrieval + prompt logic to compute the key. One cache in the serving procedure helps both, and the eval stays a thin loop |
| **Key** | `SHA2(model \| output_mode \| full prompt)` | `SHA2(question \| model \| prompt_version \| retrieved chunk ids)` | The full prompt contains the instructions, every excerpt's *text* and the question. If a chunk's text changes but its id doesn't, or someone edits the prompt and forgets to bump `prompt_version`, the id-based key would serve a stale answer. Cost: retrieval must run before the lookup, but retrieval is cheap (no LLM) |
| **What is stored** | Successful (`ok`) answers only | Store failures too | A failed call must be retried, never served from cache. Failures are still visible in `policy_answer_results` |
| **Bypass** | `use_cache` parameter (default TRUE) | — | Lets a test force fresh calls, e.g. to measure variance |

Evidence (Gate 3.1): the repeated smoke run returned both answers with `cached = TRUE`, **0 tokens, 0 ms LLM time**.

### 5.3 Trade-offs

- **Pro:** reruns cost ~0 AI tokens; only changed inputs pay; production can reuse it for repeated ticket templates.
- **Con:** temperature 0 is not perfectly deterministic, so the cache freezes *one* sample. That is
  fine for regression comparison, but it hides run-to-run variance. Measuring variance needs `use_cache => FALSE`.
- **Con:** a GOLD table written by a procedure is a new kind of object in a layer that otherwise holds
  dynamic tables. This is accepted and documented as part of the serving-layer exception.

---

## 6. Output format: schema vs plain JSON (D9)

### 6.1 What the two modes are

Both modes send **the same prompt**, which already says "reply with only a JSON object with these keys".

| | **Schema mode** | **Plain mode** |
|---|---|---|
| Mechanism | `AI_COMPLETE(..., response_format => {JSON Schema})`: types, allowed `decision` values, required keys, `additionalProperties: false`. Snowflake adds it to the request and checks the reply | No `response_format`. Our procedure keeps the outermost `{…}` (strips ```json fences or chatter), `TRY_PARSE_JSON`, then validates |
| Who guarantees the shape | The platform | Our validation |
| On a bad reply | **NULL, no reason, no raw text** (Gate 3.0) | Raw text kept; row marked `failed` with something to inspect |
| Token cost | ~700 extra prompt tokens per call (the schema is injected) | No overhead |
| Cross-model | One contract for every vendor (OpenAI needed it for JSON at all) | Depends on each model following the instruction |

### 6.2 The A/B (Gate 3.1, 3 queries × 2 modes)

| Query | Expected | Schema | Plain |
|---|---|---|---|
| pq_01 (refund if cancelled 24–48 h ahead) | answer | answered, cites `cancellation_refund_policy_01` | answered, cites `_01` + `_02` |
| ho_06 (ticket: refund after flight-delay cancellation) | answer | answered, cites `_01` + `_06` | same |
| pq_35 (second driver, near-miss OOS) | abstain | not_covered | not_covered |

| Mode | Parsed | Avg prompt tokens | Avg completion tokens | Avg LLM latency |
|---|---|---|---|---|
| schema | 3/3 | 1,602 | 152 | 3.6 s |
| plain | 3/3 | **885** | 121 | 3.8 s |

The adoption rule was fixed before the run: plain wins only if **all** plain calls parse **and every
decision matches**. Both held. Citations were valid in all 6 calls; all decisions were correct.

### 6.3 Decision

Phase 3 runs use **plain mode** (now the default of both procedures), with the stricter validation
from §4.1. The plain-mode failure rate over 60 calls is reported in Gate 3.2. A failed row is not lost:
it is never cached, so rerunning the eval retries only that row.

### 6.4 The fallback question (considered, not built)

**Alternative:** plain first, and if validation fails, retry once in schema mode.

**Does it fix the "silent NULL"?** Only partly. "Silent NULL" means two different things:
1. *Snowflake returns NULL without an error.* The fallback makes this rarer (it now needs two failures
   in a row) and keeps the failed plain reply as evidence, but it cannot make the schema call explain itself.
2. *Our results quietly treat NULL as something it isn't* (e.g. as an abstention). This was the
   dangerous one for evaluation, and it is already fixed without any fallback: NULL → `failed`,
   excluded from metrics, never cached, retried.

**Is it overengineering?** It depends on context, not on corpus size. A bigger corpus changes
retrieval, not the answer call: the LLM still sees only the top-k excerpts.

| Context | Fit |
|---|---|
| High volume, answers feed automation (routing, auto-reply, agent tool calls), models get swapped | **Worth it.** 0.5% failures × 100k requests/day = 500 broken answers/day with no "rerun" step; the fallback recovers them in-request. Plus: log which path answered and the failure rate |
| Long prompts anyway (many/long excerpts), modest volume | **Schema-only** is simpler: 700 tokens is a small share of a 10k prompt, one code path, platform contract; accept opaque failures and log their rate |
| Low volume, a human reviews every answer (suggested replies) | **Plain-only.** A failure means one retry or "no suggestion" |
| A central LLM gateway already does validation/retries | Put it there, not in each procedure |

For this repo, Phase 3 is an *evaluation* with a rerun loop and zero observed failures, so the
fallback would add a second code path and mixed-mode results without fixing an observed problem.
**Decision:** keep it simple: plain-only, measure, and revisit only if the measured failure rate
calls for it.

---

## 7. Supporting decisions

### 7.1 Model choice (Gate 3.0, AWS_US_WEST_2)

| Model | JSON mode | Role |
|---|---|---|
| `claude-sonnet-4-5` | ok | **Generator** (same model as doc2query) |
| `openai-gpt-5.4` | ok **only** with `additionalProperties: false` | **Judge**: different family from the generator, to limit "grading your own homework" bias |
| `mistral-large3` | ok | Fallback judge |
| `openai-gpt-4.1`, `gemini-3.1-pro` | NULL | not used |
| `llama4-maverick` | error 400 | not usable |
| `openai-gpt-5.5` | "not allowed" for this account (but listed in `SHOW MODELS`) | not usable |

Lesson: **"listed" is not "usable", and "returns text" is not "returns JSON".** Test the exact call
shape before designing around a model. Planned next setup: `a1_haiku` (`claude-haiku-4-5`), the same
harness with a cheaper generator, adopted if abstention and correctness hold.

### 7.2 Evaluation design (SQL-native)

| Metric | Type | Definition | Target (golden / held-out) |
|---|---|---|---|
| OOS abstention | deterministic | OOS rows with `not_covered` | ≥ 7/8 / ≥ 6/8 |
| False abstention | deterministic | answerable rows with `not_covered` | ≤ 10% / ≤ 20% |
| Citation validity | deterministic | cited ⊆ retrieved (else a made-up citation) | 100% |
| Citation hit | deterministic | answered + answerable rows citing an expected chunk | reported |
| Correctness | judged (3.3) | vs `expected_answer`: correct / partial / wrong | ≥ 90% golden |
| Groundedness | judged (3.3) | every claim supported by the given excerpts | reported |

- Deterministic metrics are computed **at insert time and stored per row**, like retrieval metrics,
  so later label edits never rewrite history.
- The judge is checked by a **human pass over every verdict** (≈ 45 rows); judged numbers are not
  reported without it.
- **SQL-native vs Snowflake AI Observability (TruLens):** AI Observability gives managed RAG-triad
  metrics and a UI, but needs a Python app instrumented with the TruLens SDK, and its metrics don't
  use our labels (`expected_answer`, answerable/OOS). Our open question is abstention against labels,
  which the existing harness already handles. AI Observability is planned for the Cortex Agent stage,
  where tracing multi-step agents adds the most.

### 7.3 Guarding against tuning on the exam

With 60 labelled queries there is no separate tuning set, so: prompts are fixed before the first run
and **the first run is the headline result**; at most one prompt revision, only for a failure class;
labels are never changed after seeing answers. The smoke-test questions (pq_01, ho_06, pq_35) were
used to test plumbing only, not to adjust the prompt.

---

## 8. Pros and cons of LLM abstention (vs a score threshold)

| | LLM decides (chosen) | Score threshold (retired) |
|---|---|---|
| **Pros** | Reads the actual text, so it judges "does this answer it?" rather than "how similar is it?"; uses rank 2–5 hits; explains *why* (`uncovered_parts`); no calibration constant to drift | Free (no LLM call); deterministic; easy to explain |
| **Cons** | One LLM call per query (~0.9k prompt + ~120 completion tokens in plain mode, ~3–4 s); not perfectly deterministic; can be too cautious (false abstention) or persuaded by a near-miss chunk; needs its own evaluation (judge + human review) | **Failed on independent data**: AUC 0.62 on held-out, 7 of 9 correct answers refused at the golden cut-off; depends on query wording; would need re-calibration per corpus and per query channel |
| **Mitigations** | Cache; cheaper model setup (`a1_haiku`); deterministic metrics + judged metrics + human review; `ga_p2` only for a failure class | — |

---

## 9. What's open (decided by Gates 3.2–3.4)

- Do OOS abstention and false abstention meet the targets on **both** sets, especially held-out tickets?
- Are failures retrieval-side (→ Phase 4 query rewrite) or answer-side (→ `ga_p2`)? See §3.3.
- Plain-mode failure rate over 60 calls (§6.3).
- Judge–human agreement, and whether correctness reaches 90% on golden.
- Actual credits per call (from the AI usage views, not assumed).

---

## 10. Glossary

| Term | Meaning |
|---|---|
| **Abstention** | The system declines to answer ("not covered") instead of guessing |
| **False abstention** | Declining a question the policies do answer |
| **Grounded answer** | An answer whose every claim is supported by the provided excerpts |
| **Citation validity** | Every cited id was actually among the retrieved excerpts (no invented sources) |
| **Calibration** | Whether a confidence signal means the same thing across inputs; the reranker score did not (golden vs tickets) |
| **AUC** | Probability that a random positive outscores a random negative; 0.5 = no signal, 1.0 = perfect separation |
| **Held-out set** | Labelled queries not used to make design choices, so results on it estimate real-world behaviour |
| **Structured output / schema mode** | Asking the platform to enforce a JSON Schema on the model's reply |
| **LLM-as-judge** | Using a (different) LLM to grade answers against a reference; validated by a human pass |
| **Input-hash cache** | Storing an LLM result under a hash of its exact input, so identical inputs never pay twice |

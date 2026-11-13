# Policy RAG — Retrieval Evaluation Methodology

How we measure whether the policy search finds the right text, why it is built this way,
what each metric means, and what the approach can and cannot tell us.

| | |
|---|---|
| **Applies to** | `RENTAL_OPS.GOLD.policy_search` (Cortex Search over 42 policy chunks, `c2_structure`; 35 chunks before Phase 2b) |
| **Implemented in** | `evaluation/01_…` to `evaluation/10_…`, schema `RENTAL_OPS.EVALUATION` (see §0) |
| **Roadmap** | `docs/plans/02_policy_rag_roadmap_revision.md` (current); `docs/prompts/01_policy_rag_retrieval_evaluation.md` (original Steps 2–5, partly retired) |
| **Question sets** | golden `gq_v2`: 38 questions (30 answerable, 8 out-of-scope); held-out `ho_tickets_v1`: 22 (14 + 8) |
| **Last updated** | 2026-11-13 (status through Phase 2a; answer-level evaluation is in `03_grounded_answers_and_abstention.md`) |

**Naming note:** this doc was first written against the original prompt's *Steps* (Step 3 = doc2query,
Step 4 = query rewrite + score threshold, Step 5 = answer evaluation). The roadmap now uses *Phases*
(plan 02): Step 3 = Phase 2, Step 4 = conditional Phase 4, Step 5 = Phase 3. Step names below are kept
where they describe history.

---

## 0. Implementation map

| What | Object | File |
|---|---|---|
| Evaluation schema | `RENTAL_OPS.EVALUATION` | `evaluation/01_evaluation_schema.sql` |
| Golden set + label checks (evidence spans ↔ chunk ids) | `policy_golden_questions` | `evaluation/02_policy_golden_questions.sql` |
| Per-question results | `policy_retrieval_results` | `evaluation/03_policy_retrieval_results.sql` |
| Scorecard | view `policy_retrieval_summary` | `evaluation/04_policy_retrieval_summary.sql` |
| Eval procedure (retrieve, then grade; `question_set` parameter) | `run_policy_retrieval_eval` | `evaluation/05_run_policy_retrieval_eval.sql` |
| v0 run + diagnosis + threshold calibration | 2 CALLs + reports | `evaluation/06_run_v0_baseline.sql` |
| v1 doc2query run, deltas, leakage check | 2 CALLs + reports | `evaluation/07_run_v1_doc2query.sql` |
| v1b chunking run (golden regression) | CALLs + reports | `evaluation/08_run_v1b_chunking.sql` |
| Held-out set + union view | `policy_holdout_questions`, view `policy_eval_questions` | `evaluation/09_policy_holdout_questions.sql` |
| Held-out run + calibration report (separation, AUC, cut-off transfer) | CALLs + reports | `evaluation/10_run_v1b_holdout.sql` |
| The system under test | `GOLD.policy_search` | `src/gold-layer-code/unstructured-data/02_policy_search_service.sql` |

---

## 1. The problem in one paragraph

The future AI agent will answer customer policy questions by first **retrieving** a few
policy chunks and then **writing an answer from them**. If retrieval hands the model the
wrong chunks, even a perfect model gives a wrong or made-up answer. So before tuning
anything (better chunking, generated questions, query rewriting), we need a **repeatable
score for retrieval alone**. Without it, every change is judged by trying a few questions
by hand, which is how the known failure ("return the car more than an hour late") was
found, and also how regressions go unnoticed.

The approach: **a fixed exam (golden dataset), a fixed grading procedure, and a log of
every exam result**, so any two retrieval setups can be compared on the same questions
with the same rules.

---

## 2. The big picture

```
 data/Unstructured/policy_documents/*.md        (the human-readable source)
            │  questions + labels written by hand from these
            ▼
 ┌──────────────────────────────────┐
 │ policy_golden_questions          │  the exam: question, style, what counts as correct
 └──────────────┬───────────────────┘
                │  CALL run_policy_retrieval_eval('v0_baseline', 5)
                ▼
 ┌──────────────────────────────────┐   Phase 1: ask the retriever each question
 │ run_policy_retrieval_eval        │──────────► Cortex Search (policy_search)
 │   (stored procedure)             │◄────────── ranked chunks + scores, latency
 │                                  │   Phase 2: grade every answer against the labels
 └──────────────┬───────────────────┘
                ▼
 ┌──────────────────────────────────┐
 │ policy_retrieval_results         │  one row per (run, question): what came back + grades
 └──────────────┬───────────────────┘
                ▼
 ┌──────────────────────────────────┐
 │ policy_retrieval_summary (view)  │  one row per run (+ per question style): the scorecard
 └──────────────────────────────────┘
```

Each run is tagged with a **setup_version** that names the retrieval setup being tested
(`v*`; answer-level runs use a separate `a*` sequence on top of a `v*` setup: doc 03 §7.4):

| setup_version | What is being tested | Status |
|---|---|---|
| `v0_baseline` | The raw search service as first built | Done (on `gq_v1` and `gq_v2`) |
| `v0_baseline_depth35` | Same service, all 35 chunks returned, used for diagnosis only | Done |
| `v1_doc2query` | Chunks enriched with AI-generated "questions this chunk answers" (Phase 2) | Done |
| `v1b_chunking` | Structure-aware chunking, 42 chunks (Phase 2b); **current reference** | Done |
| `v1b_chunking_ho` (+ `_depth42`) | v1b on the held-out set (Phase 2a) | Done |
| `v2_query_rewrite` | User question rewritten into policy wording, results fused (old Step 4) | Conditional (Phase 4) |

---

## 3. Methodology

### 3.1 Offline evaluation against a golden dataset

We do not wait for real user traffic. We write a set of realistic questions where **we
already know the correct answer location**, run them through retrieval, and check whether
the correct chunk comes back near the top. This is called **offline retrieval
evaluation**, and it is the standard first measurement for any RAG (retrieval-augmented
generation) system.

### 3.2 What makes the golden dataset useful

| Design choice | Why |
|---|---|
| **Written by hand from the source markdown**, not from chunk text and not by an AI | The exam must be independent of what we are testing. Step 3 will make an AI generate questions per chunk; if the exam were AI-generated the same way, v1 would partly be graded on questions it had already seen (leakage) and would look better than it is. |
| **Four question styles**: `direct`, `paraphrase`, `casual`, `out_of_scope` | Real customers rarely use policy wording. The style split shows *where* retrieval breaks. The baseline is perfect on direct questions; the one failure is casual. |
| **At least a third casual/paraphrase** (gq_v2: 23 of 30) | These carry the "vocabulary gap" (e.g. "an hour late" vs "59 minutes past the agreed return time") that the next two steps are meant to fix. |
| **Out-of-scope questions** (8) | A good system should say "no policy covers that" instead of confidently returning unrelated text. These questions measure that. (They were also meant to calibrate a Step 4 score cut-off; that plan was retired, see §4.3.) |
| **Near-miss out-of-scope** (gq_v2: pq_24, pq_25, pq_35–38) | Easy out-of-scope questions ("child seats") are rejected by any threshold. Near-misses mention things that *are* in the corpus (Davidstad branch, "speed limit", earning points) without the answer. They are the real test of a rejection threshold. |
| **Every document and most sections covered** | Prevents a setup that is great on one document and weak on others from looking good on average. |

### 3.3 Four layers of "correct answer" labels

Each question records *where the answer is* at four levels, from most precise to most durable:

| Label | Example (pq_05) | Survives re-chunking? | Used for |
|---|---|---|---|
| `expected_chunk_ids` | `["rental_agreement_terms_03"]` | **No.** IDs are `<document>_<chunk number>` | Exact grading today |
| `expected_document_id` + `expected_section_header` | `rental_agreement_terms` / `3. Rental Period and Daily Rates` | While chunks follow headers | Human-readable fallback |
| `expected_evidence` | `"returns more than 59 minutes past the agreed return time are billed as an additional full day"` | **Yes.** Verbatim text from the source | Re-deriving chunk IDs after any re-chunking |
| `expected_answer` | "Returns more than 59 minutes past … billed as an additional full day." | Yes | Grading *answers* (Phase 3, doc 03) |

**Why the evidence span matters:** if the chunking ever changes (different size, overlap or
splitter), the chunk IDs shift, and hand labels would silently grade against the wrong
chunks. Instead, "the correct chunk is whichever chunk contains this sentence" is
recomputed by one query (the last validation query in `02_policy_golden_questions.sql`).
Today that query returns zero mismatches, which proves the hand labels and the evidence agree.
Each span was checked to occur exactly once in the corpus, so it cannot point at two places.

### 3.4 Two-phase evaluation procedure

`run_policy_retrieval_eval` deliberately separates **asking** from **grading**:

1. **Retrieval phase.** For each golden question, call the retriever and store its raw response
   (ranked results with scores) plus how long it took.
2. **Grading phase.** One SQL statement grades every stored response against the labels and
   writes the metrics.

The retriever is a parameter (`retriever => 'policy_search'`). A future retrieval path (e.g. the
conditional Phase 4 query rewrite) is added as a new branch in phase 1 that returns the same response
shape. The question set is a second parameter (`question_set => 'golden' | 'holdout'`). **The grading SQL never changes**, so v0, v1 and v2 are guaranteed to be scored by
identical rules. That is the core of a fair comparison.

### 3.5 Results are stored, not just displayed

Every run writes one row per question to `policy_retrieval_results`, including the full raw
response. Runs are appended and never overwritten, and metrics are frozen at run time. This gives:

- **History**: v0 vs v1 vs v2 side by side, months later.
- **Explainability**: for any failed question you can see exactly what was returned instead.
- **Reproducible grading**: changing the golden set later does not rewrite old results.
  `dataset_version` records which golden-set version each run was graded against.

---

## 4. Metrics explained

All rank metrics are computed **only over answerable questions**. The rejection metric is
computed **only over out-of-scope questions**. Mixing them would let "nothing found" count
as a success for answerable questions, or count as a failure for unanswerable ones.

### 4.1 A worked example

Question pq_05 expects chunk **C** (`rental_agreement_terms_03`). Suppose retrieval returned:

| Rank | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| Chunk | A | **C** | B | D | E |

| Metric | Value here | Plain-English meaning |
|---|---|---|
| `first_hit_rank` | 2 | The correct chunk was the 2nd result |
| `hit_at_1` | FALSE | Was the *very first* result correct? |
| `hit_at_3` | TRUE | Was a correct chunk anywhere in the top 3? |
| `hit_at_5` | TRUE | …in the top 5 (everything the agent would see)? |
| `reciprocal_rank` | 1/2 = 0.5 | Credit that shrinks the lower the correct chunk sits: rank 1 → 1.0, rank 2 → 0.5, rank 3 → 0.33, missed → 0 |
| `precision_at_3` | 1/3 = 0.33 | Of the top 3 results, what share were correct? |
| `recall_at_5` | 1/1 = 1.0 | Of all correct chunks, what share made the top 5? |

In the real baseline, C was at **rank 24**: hit@1/3/5 all FALSE, reciprocal rank 0.

### 4.2 Each metric: what it tells you, and when to use it

| Metric (summary column) | Question it answers | Why it matters here | Caveat |
|---|---|---|---|
| **hit@1** (`hit_at_1`) | How often is the top result right? | If the agent ever relies mainly on the first chunk, this is its accuracy | Strict: rank 2 counts as a total miss |
| **hit@3** (`hit_at_3`) | How often is the right chunk in the top 3? | Typical number of chunks put in a tight prompt | — |
| **hit@5** (`hit_at_5`) | How often does the agent get the right chunk at all (top_k = 5)? | **The main "can it answer?" metric.** A miss here means the model cannot answer correctly | Says nothing about position within the 5 |
| **MRR** (`mrr`, mean reciprocal rank) | On average, how high does the first correct chunk sit? | One number combining "found?" and "how high?". Best single metric to compare setups | Hard to read in absolute terms; use it for comparisons |
| **precision@3** (`precision_at_3`) | How much of the top 3 is relevant? | Measures noise handed to the model | **Capped at ~0.33** when a question has one correct chunk, which is most of ours. Read it as a tie-breaker, not a goal |
| **recall@5** (`recall_at_5`) | Of all the correct chunks, how many made the top 5? | Matters for questions with 2 correct chunks (pq_18, pq_21) | Equals hit@5 for single-chunk questions |
| **OOS rejection rate** (`oos_rejection_rate`) | For unanswerable questions, how often did retrieval return *nothing*? | Measures the ability to say "I don't know" instead of returning junk | The raw service always returns top_k results, so it scores **0 by design**. No threshold is planned any more: abstention is measured at the answer step (doc 03) |
| **avg latency** (`avg_latency_ms`) | How long a retrieval took | A query-rewrite path (Phase 4) would add LLM calls; this shows the speed cost | Measured inside SQL (includes statement overhead), so compare runs to each other, not to REST API latency |
| **LLM calls** (`llm_calls`) | How many LLM calls were made in the run | Cost of query rewriting (Phase 4), if built | 0 for v0, v1 and v1b |

### 4.3 The reranker score: our confidence signal

Cortex Search returns three scores per result in `@scores`:

| Score | What it is |
|---|---|
| `text_match` | Keyword (lexical) match strength |
| `cosine_similarity` | Meaning (embedding/vector) similarity |
| `reranker_score` | A dedicated relevance model's judgment of the (question, chunk) pair. Unbounded, higher = more relevant |

We store the rank-1 `reranker_score` as `top_reranker_score`. On its own it is not a metric;
it is the **confidence signal we calibrate** (originally planned as the input for a Step 4
rejection threshold, now retired; abstention moves to answer generation).

The score is an unbounded relevance logit, so its sign alone means little; what matters is
*separation*: how far correct hits sit above near-misses, and whether the two ranges overlap.
On v0 the median correct hit scored −3.94; v1 (doc2query) raised it to −1.25 while out-of-scope
questions barely moved (§7). Calibration is optimised on a held-out set, not on this golden set
(plan 02, decision 7).

On `gq_v1` there was a clean gap (answerable ≥ −5.59, out-of-scope ≤ −8.18), so any cut-off in
between looked perfect. **`gq_v2` showed that gap was an artifact of easy questions:**

```
                     -11      -10      -9       -8       -7       -6       -5   …   +2.7
 answerable (30)                         ●pq_30(-8.36)    ●●● pq_28/27/32  ●●●●●●●●●●●…●
 out-of-scope (8)     ●pq_23  ●●● ●●     ●pq_24(-8.18)  ●pq_38(-6.87)
                      ← less relevant                                        more relevant →
```

| Cut-off | Out-of-scope rejected | Answerable wrongly rejected |
|---|---|---|
| −6.8 | 8 / 8 | 1 / 30 (pq_30, a *correct* rank-1 hit with low confidence) |
| −7.0 | 7 / 8 (pq_38 slips through) | 1 / 30 (pq_30) |
| −8.5 | 6 / 8 (pq_38, pq_24 slip through) | 0 / 30 |

No single score separates the two groups any more. A threshold alone is a precision/recall
trade-off: reject every near-miss and you lose some real answers, or keep every real answer and
let some near-misses through. This is exactly why the near-miss questions were added.

**What happened next:** v1b chunking made the golden ranges separate again (+0.71), but the held-out
ticket set (Phase 2a) showed the score does not transfer: ticket wording scores ~7 points lower for
the same correct chunk, AUC 0.62, and the golden cut-off would refuse 7 of 9 correct held-out answers
(§7). The threshold plan was dropped entirely; the answering LLM now decides whether to abstain.
Full decision history: `03_grounded_answers_and_abstention.md` §2.

Note: the final order is Cortex Search's own ranking, which blends signals. It is *not*
strictly sorted by reranker score; in the baseline, ranks 4 and 5 occasionally invert.

---

## 5. Objects and columns

### 5.1 How methodology maps to objects

| Methodology concept | Object | Script |
|---|---|---|
| Separate home for evaluation | schema `RENTAL_OPS.EVALUATION` | `evaluation/01_evaluation_schema.sql` |
| The exam + answer key | table `policy_golden_questions` | `evaluation/02_policy_golden_questions.sql` |
| Label integrity check (evidence ↔ chunk ids) | validation queries at the end of 02 | `evaluation/02_…` |
| Per-question results log | table `policy_retrieval_results` | `evaluation/03_policy_retrieval_results.sql` |
| The scorecard | view `policy_retrieval_summary` | `evaluation/04_policy_retrieval_summary.sql` |
| Ask, then grade (two-phase, retriever-pluggable) | procedure `run_policy_retrieval_eval` | `evaluation/05_run_policy_retrieval_eval.sql` |
| Baseline run + diagnosis + threshold calibration | 2 CALLs + 3 report queries | `evaluation/06_run_v0_baseline.sql` |
| doc2query run, v0 vs v1 deltas, flips, score shift, leakage check | 2 CALLs + 4 report queries | `evaluation/07_run_v1_doc2query.sql` |
| Chunking run (v1b vs v1, golden regression) | CALLs + reports | `evaluation/08_run_v1b_chunking.sql` |
| Held-out set + union view used by the procedure | table `policy_holdout_questions`, view `policy_eval_questions` | `evaluation/09_policy_holdout_questions.sql` |
| Held-out run + calibration (separation, AUC, cut-off transfer) | 2 CALLs + reports | `evaluation/10_run_v1b_holdout.sql` |

### 5.2 `policy_golden_questions` (the exam)

| Column | Meaning |
|---|---|
| `question_id` | Stable ID `pq_NN`; never reused |
| `question` | What the customer asks, in their words |
| `question_style` | `direct` (policy wording), `paraphrase` (same meaning, different words), `casual` (everyday or story-like phrasing), `out_of_scope` (no answer exists) |
| `is_answerable` | FALSE for out-of-scope; decides which metrics apply |
| `expected_document_id`, `expected_section_header` | Where the answer lives, readable form |
| `expected_chunk_ids` | All chunks that fully answer; a hit on any one counts |
| `expected_evidence` | Verbatim source sentence(s) proving the answer |
| `expected_answer` | Short reference answer (for answer grading later) |
| `notes` | Why the question is interesting (e.g. "brand name vs policy term") |
| `dataset_version` | `gq_v1`, `gq_v2`, … |

### 5.3 `policy_retrieval_results` (one row per run × question)

| Column | Meaning |
|---|---|
| `run_id`, `run_ts` | Unique ID and time of the run (returned by the procedure) |
| `setup_version` | Which setup was tested (`v0_baseline`, …) |
| `retriever` | Which retrieval path produced the results (`policy_search`; a Phase 4 retriever if one is built) |
| `dataset_version` | Golden-set version it was graded against |
| `top_k` | How many results were requested |
| `retrieved_chunk_ids` | The returned chunk IDs in rank order |
| `scores` | `@scores` per returned chunk, in rank order |
| `result_count` | How many results came back (can be < top_k once a threshold exists) |
| `first_hit_rank` … `recall_at_5` | Metrics from §4; NULL for out-of-scope questions |
| `top_reranker_score` | Reranker score of the rank-1 result |
| `correctly_rejected` | Out-of-scope only: TRUE if nothing was returned |
| `latency_ms`, `llm_call_count` | Speed and LLM cost of the retrieval |
| `raw_response` | The full untouched response, for debugging |

### 5.4 `policy_retrieval_summary` (the scorecard)

One row per run with `question_style = 'ALL'`, plus one row per style. Columns are the
averages described in §4 plus `questions` and `answerable_questions` counts.

---

## 6. How to run it and read it

```bash
# Full baseline: golden set + run + reports (scripts are rerunnable)
snow sql -c rental-dev -f evaluation/02_policy_golden_questions.sql   # (re)load the exam
snow sql -c rental-dev -f evaluation/06_run_v0_baseline.sql           # run + reports
```

```sql
-- Any setup, any depth: returns the run_id
CALL RENTAL_OPS.EVALUATION.run_policy_retrieval_eval('v0_baseline', 5);

-- Scorecard for every run so far
SELECT * FROM RENTAL_OPS.EVALUATION.policy_retrieval_summary
WHERE question_style = 'ALL' ORDER BY run_ts;
```

**Reading the reports in `06_…`:**
1. **Summary**: overall and per-style scorecard. Look first at hit@5 (can the agent answer?)
   and MRR (how cleanly), then at which *style* is weakest.
2. **Failures**: every answerable question missed in the top 5, with the rank its correct
   chunk actually reached in the depth-35 run. "Rank 6" means a tuning problem; "rank 24"
   means retrieval does not understand the question at all.
3. **Reranker distribution**: confidence scores for hits, misses and out-of-scope questions.
   (Originally meant to place a Step 4 threshold; now a diagnostic only, see §4.3.)

**Cost:** one Cortex Search call per question per run (38 for gq_v2, 22 for held-out) on the
X-Small warehouse; no LLM calls in retrieval evaluation. Dynamic tables do not need to be resumed: evaluation
only reads the live search service.

---

## 7. Effectiveness: what it has shown so far

Baseline (`v0_baseline`, top_k = 5):

| | `gq_v1` hit@1 / MRR | `gq_v2` hit@1 / MRR | OOS rejection |
|---|---|---|---|
| All answerable | 0.952 (21 q) | 0.967 (30 q) | — |
| direct | 1.000 (7) | 1.000 (7) | — |
| paraphrase | 1.000 (5) | 1.000 (8) | — |
| casual | 0.889 (9) | 0.933 (15) | — |
| out-of-scope | — | — | 0.000 (4 → 8 q) |

hit@1 = hit@5 = MRR in both versions: every question is either found at rank 1 or not found
in the top 5 at all.

What the framework surfaced that ad-hoc testing would not:

- **The failure is severe, not marginal.** The late-return chunk ranks 24 of 35, so tuning
  top_k cannot fix it; only closing the vocabulary gap (Steps 3–4) can.
- **Failures cluster in casual wording.** That confirms the hypothesis behind doc2query and
  query rewriting, with evidence rather than intuition.
- **The out-of-scope problem is real but solvable.** The raw service always returns 5
  chunks for "Can I bring my dog?", but the reranker scores separate answerable from
  out-of-scope cleanly, so a threshold is promising. *(gq_v1 only; disproved by gq_v2 and the
  held-out set, see below.)*
- **The first set was too easy to show improvements** (20 of 21 at rank 1). That is why
  `gq_v2` adds 9 harder answerable and 4 near-miss out-of-scope questions.
- **`gq_v2`: the harder questions were still found, but with less confidence.** All 9 new
  answerable questions hit at rank 1, yet four of them (pq_27, pq_28, pq_30, pq_32) have top
  scores of −6.3 to −8.4, in the range where out-of-scope questions sit. The hybrid search
  ranks robustly; its *confidence* is what suffers from casual wording.
- **`gq_v2` broke the "clean threshold" assumption** (see §4.3). Without the near-miss
  questions, Step 4 would have shipped a threshold that silently drops real answers.
- **Ranking headroom is still small** (one miss in 30). The more valuable targets for v1/v2 are
  raising the confidence of correct hits and rejecting near-misses.

doc2query (`v1_doc2query`, top_k = 5), now the reference setup:

| | v0 | v1 |
|---|---|---|
| hit@1 = hit@5 = MRR (30 answerable) | 0.967 | 0.967 (no flips) |
| pq_05 rank (depth 35) | 24 | 17 |
| Median rank-1 score: answerable hits / out-of-scope | −3.94 / −9.26 | −1.25 / −9.64 |
| Lowest answerable hit vs highest out-of-scope | −8.36 vs −6.87 | −8.09 vs −6.62 (still overlap) |

- **doc2query improved confidence, not ranking.** Correct hits gained +1.57 (median, non-leaked)
  while out-of-scope questions gained +0.22, widening the median gap from 5.3 to 8.4.
- **It did not fix the vocabulary-gap miss.** pq_05's chunk got a well-matching generated question
  (cosine 0.82 to the golden question), but four appended questions are diluted inside one chunk
  embedding, and another chunk's question ("running late") won rank 1.
- **The leakage check found 4 near-copies** (pq_19 0.996, pq_10 0.97, pq_11 0.956 on the expected
  chunk; pq_06 0.915 on a wrong chunk). They were rank 1 already, so metrics are not inflated, but
  the golden set is now mildly contaminated for any doc2query-based variant.
- **The golden set is saturated for ranking.** Further comparisons of retrieval designs, and all
  calibration work, use a held-out set (plan 02, Phase 2a); the golden set stays a regression check.

Structure-aware chunking (`v1b_chunking`, 42 chunks), the **current reference setup**:

| | v1 | v1b |
|---|---|---|
| hit@1 / hit@5 / MRR (30 answerable) | 0.967 / 0.967 / 0.967 | 0.967 / **1.000** / 0.978 |
| pq_30 rank-1 score (FAQ question, diluted chunk) | −8.09 | **−4.37** |
| Lowest answerable hit vs highest out-of-scope | −8.09 vs −6.62 (overlap) | −5.83 vs −6.54 (**+0.71**, no overlap) |

Splitting the loyalty FAQ into one chunk per Q and A removed the dilution. The pq_05 gain (rank 17 → 3)
is not explained by the change (its chunks are byte-identical) and is treated as incidental.
Details: `02_chunking_guidelines.md` §6, plan 02 "Phase 2b results".

Held-out set (`v1b_chunking_ho`, 22 verbatim tickets/reviews):

| | Golden (gq_v2) | Held-out (ho_tickets_v1) |
|---|---|---|
| hit@1 / hit@3 / MRR | 0.967 / 1.000 / 0.978 | **0.643** / 0.929 / 0.750 |
| Rank-1 score, answerable hits: median | −1.25 | **−8.78** |
| Separation (min answerable hit − max OOS) | +0.71 | **−4.70** |
| AUC (answerable vs OOS) | 1.000 | **0.625** |
| At the golden cut-off: correct answers refused | 0 | **7 of 9** |

- **Retrieval still finds the answer** on ticket wording (hit@3 0.93), but **the score is not a usable
  confidence signal**: it reflects how a query is written as much as whether it is answerable.
- Consequence: no score threshold; top 5 chunks go to an answering LLM that decides whether to
  abstain (Phase 3, doc 03). Query rewrite (Phase 4) has some evidence in its favour and is tested
  on the held-out set if Phase 3 failures trace to retrieval.

---

## 8. Advantages and disadvantages

### Advantages

| Advantage | Why it matters |
|---|---|
| **Objective, repeatable comparison** | v0/v1/v2 are graded on the same exam by the same SQL; "better" becomes a number, not an impression |
| **Fully inside Snowflake** | No extra tooling, credentials or data movement; results are queryable tables next to the pipeline |
| **Cheap** | ~38 search calls per run, no LLM calls; runs in seconds on X-Small |
| **Diagnoses, not just scores** | Raw responses, per-style splits and the depth-35 rank show *why* something failed |
| **Pluggable retrievers** | New retrieval strategies plug into phase 1; grading is untouched |
| **Durable labels** | Evidence spans let labels survive re-chunking; reference answers are ready for answer grading |
| **Calibrates decisions** | Reranker distributions turn the rejection threshold into a measured choice |
| **Leakage-aware** | Hand-written questions keep the exam independent of AI-generated enrichment |

### Disadvantages and limitations

| Limitation | Effect | Mitigation |
|---|---|---|
| **Saturated + mildly contaminated after v1** (29/30 at rank 1; 4 near-copies among generated questions) | Cannot show further ranking gains; doc2query variants would be graded partly on seen questions | Held-out set for design/calibration decisions (plan 02, Phase 2a); report golden results with and without the leak-flagged questions |
| **Small dataset** (30 answerable, 8 out-of-scope) | One question flips hit@1 by ~3 points; small differences are noise | Compare *which questions* flipped, not only averages; grow the set as real questions appear |
| **Author bias** | Questions written by people (and an assistant) who know the documents may be easier than real customer questions | Held-out set of verbatim support tickets/reviews (`ho_tickets_v1`), which indeed scored much lower |
| **Binary relevance** | A chunk is either correct or not; a partially helpful chunk scores 0 | Acceptable for short, section-sized chunks; multi-chunk labels where two sections both answer |
| **Retrieval only** | A perfect hit@5 does not guarantee a correct *answer* | Phase 3 adds answer grading (abstention, citations, correctness, groundedness) using `expected_answer`: doc 03 |
| **precision@3 is structurally capped** | Looks low (≈0.33) even when retrieval is perfect | Treat as a tie-breaker; rely on hit@k and MRR |
| **Score calibration did not generalise** | The golden cut-off failed on held-out tickets (AUC 0.62) | Threshold dropped; abstention moved to the answer step (doc 03) |
| **Chunk-ID labels are tied to chunking** | Re-chunking silently breaks exact labels | Evidence spans + the re-derivation query |
| **Latency measured in SQL** | Includes statement overhead, not the agent's real API latency | Use only for relative comparisons between setups |
| **Single corpus snapshot** | Results describe today's 6 documents | Re-run the eval whenever documents or chunking change |
| **Held-out set is small and template-based** | 22 queries (one per template); a single query moves rates by ~5–7 points | Read per-query detail; compare which queries changed |

### Key trade-offs we chose deliberately

- **Hand-written vs AI-generated golden questions:** slower to build, but independent of the
  doc2query step it must judge. We chose independence over volume.
- **Small curated set vs large synthetic set:** fewer questions with precise, verified labels
  beat many noisy ones at this corpus size (35 chunks).
- **Metrics frozen per row vs computed live in the view:** storing them costs some
  duplication but keeps history stable when the golden set evolves.
- **SQL procedure vs external framework (e.g. TruLens):** SQL is simpler and native for
  retrieval metrics. Phase 3 kept answer evaluation SQL-native too (doc 03 §7.2); an observability
  framework earns its place with the Cortex Agent (tracing multi-step runs), and the SQL results stay
  as ground truth alongside it.

---

## 9. How later steps plug in

| Step | Change to the pipeline | Change to the evaluation |
|---|---|---|
| 3: doc2query (`v1_doc2query`) — **done** | Silver adds AI-generated questions per chunk; search index rebuilt | None. Ran the procedure with a new setup_version; leakage check in `07_…` (4 near-copies found) |
| 2a: held-out set — **done** | None | `ho_tickets_v1` (verbatim tickets/reviews), `question_set` parameter + union view (`09_…`); calibration report (`10_…`): the score threshold does not transfer |
| 2b: chunk hardening (`v1b_chunking`) — **done** | Structure-aware split (FAQ → one chunk per question), quality flags; see `02_chunking_guidelines.md` | None. Re-derived `expected_chunk_ids` from `expected_evidence` with the validation query in `02_…`, then ran as usual |
| 3 (was Step 5, brought forward): grounded answers (`a1_grounded_answer`) — **in progress** (Gate 3.1 done) | The agent answers from retrieved chunks and says "not covered" when they don't answer | Grade answers against `expected_answer` (correctness, groundedness) and measure abstention on the out-of-scope questions; keep these retrieval results as ground truth. Design + decision history: `03_grounded_answers_and_abstention.md` |
| ~~4: query rewrite (`v2_query_rewrite`)~~ (**retired; conditional only**) | New `policy_search_retrieve` function: rewrite, fuse, threshold | Only if Phase 3 shows out-of-scope answers or casual misses: add one retriever branch in phase 1; grading unchanged |

Sequence and rationale: `docs/plans/02_policy_rag_roadmap_revision.md`.

---

## 10. Glossary

| Term | Meaning |
|---|---|
| **RAG** | Retrieval-augmented generation: find relevant text first, then have an LLM answer from it |
| **Chunk** | A section-sized piece of a policy document (here ≤ 512 tokens, split on `##` headers and, since `c2_structure`, on FAQ question lines) |
| **Golden dataset** | Questions with known correct answers, used as a fixed exam |
| **Hybrid search** | Combining keyword matching and meaning (vector) matching |
| **Reranker** | A second model that re-scores the top candidates for relevance to the question |
| **Vocabulary gap** | User and document say the same thing with different words ("an hour late" vs "59 minutes") |
| **doc2query** | Generating likely user questions for each chunk and indexing them with it |
| **RRF (reciprocal rank fusion)** | Merging several ranked lists by summing 1/(constant + rank) per item |
| **Leakage** | When the exam overlaps with what the system was tuned on, inflating scores |
| **Out-of-scope** | A question the documents do not answer; the right response is "not covered" |

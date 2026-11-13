# 03 — Phase 3: Grounded Answers with Abstention + Answer-Level Evaluation

| | |
|---|---|
| **Date** | 2026-11-12 |
| **Builds on** | `02_policy_rag_roadmap_revision.md` (decisions 3–4, Phase 2a results) |
| **setup_version** | `a1_grounded_answer` (retrieval = `v1b_chunking`, unchanged) |
| **Question sets** | golden `gq_v2` (38: 30 answerable, 8 OOS) + held-out `ho_tickets_v1` (22: 14 answerable, 8 OOS) |
| **Working mode** | One gate at a time; DDL shown and approved before running; results reviewed before the next gate |

## 1. Why this phase, and what 2a changed

Retrieval is good enough: golden hit@5 = 1.0, held-out hit@3 = 0.93. The open problem is the
answer/abstain decision. Phase 2a showed that the rank-1 reranker score cannot make that decision:
ticket-style input scores ~7 points lower for the same correct chunk, held-out AUC is 0.62, and the
golden cut-off would refuse 7 of 9 correct held-out answers. So:

- **Abstention is decided by the answering LLM**, which reads the retrieved policy text and states
  whether it addresses the request. No score threshold, not even as a pre-filter.
- **The LLM gets the top 5 chunks**, not just the top 1 (covers held-out misses at rank 2–3).
- **Both question sets are evaluated**, reported side by side; they behave differently.

## 2. Design

### 2.1 Answer path (the reusable piece)

`RENTAL_OPS.GOLD.answer_policy_question(query STRING, top_k INT DEFAULT 5)` → `VARIANT`, a stored
procedure (SEARCH_PREVIEW needs constant arguments, so a UDF cannot call it):

1. `SEARCH_PREVIEW` on `GOLD.policy_search`, top 5, returning `chunk_id`, `document_title`,
   `section_header`, `chunk_text` (the raw text; doc2query questions are for matching only and are
   **not** shown to the LLM, so they can never be cited as policy).
2. One `AI_COMPLETE` call, temperature 0, JSON `response_format`:

   ```json
   {"decision": "answered | not_covered",
    "answer": "short answer for a front-desk agent / customer",
    "cited_chunk_ids": ["..."],
    "uncovered_parts": "what the request asks that the policy text does not address (may be empty)"}
   ```

3. Returns `{query, retrieved: [...ids + scores], decision, answer, cited_chunk_ids, uncovered_parts,
   model, prompt_version, usage tokens, latency_ms}`.

Prompt `ga_p1` rules: answer only from the numbered policy excerpts; cite the excerpt ids used;
if the excerpts do not address the request, `decision = not_covered` and say so plainly (no guess,
no general knowledge); tickets are often requests, not questions: answer the policy aspect and
leave account-specific actions (refunds, resets, confirmations) to Support. The prompt is written
**before** any run and contains no golden or held-out examples.

Rule note: CLAUDE.md keeps AI functions out of Gold dynamic tables and runs pipeline AI calls once in
Silver. Query-time answering is a different layer (one call per user query, by design); the
procedure lives in GOLD as a serving object, and no dynamic table calls it. Add this distinction to
CLAUDE.md in this phase.

### 2.2 Evaluation (SQL-native, same pattern as retrieval eval)

`RENTAL_OPS.EVALUATION.run_policy_answer_eval(setup_version, question_set, top_k)` calls the answer
procedure per question and stores one row per run × question in
`EVALUATION.policy_answer_results` (run_id, setup_version, question_set, dataset_version,
question_id, retrieved ids, decision, answer, cited ids, uncovered_parts, model, prompt_version,
tokens in/out, latency, raw response, `call_status` ok | failed, `input_sha`).

**Answer cache (cost):** `input_sha = SHA2(question || model || prompt_version || retrieved chunk ids)`.
The eval procedure calls the LLM only when no `ok` row with the same `input_sha` exists; otherwise it
copies the stored answer into the new run (marked `cached = TRUE`, 0 tokens). Reruns of reports, of
a single failed row, or of the eval after an unrelated change cost no LLM tokens; only a changed
question, model, prompt or retrieval result triggers a new call. `failed` rows (NULL response) are
always retried.

**Deterministic metrics (no judge, computed in SQL):**

| Metric | Definition |
|---|---|
| OOS abstention rate | OOS questions with `decision = not_covered` (target: golden ≥ 7/8, held-out ≥ 7/8) |
| False abstention rate | answerable questions with `not_covered` (target ≤ 10% golden, ≤ 20% held-out) |
| Citation validity | cited ids ⊆ retrieved ids (target 100%; anything else is a fabricated citation) |
| Citation hit | answered + answerable rows citing ≥ 1 expected chunk |
| Cost / latency | tokens in/out per query, credits per query, p50/max latency |

**Judged metrics (`EVALUATION.policy_answer_judgments`, one row per answered row, one judge call
returning both metrics; `not_covered` rows are not judged; cached on the answer's hash the same way):**

| Metric | Judge input | Scale |
|---|---|---|
| Correctness | question, `expected_answer`, generated answer | correct / partial / wrong |
| Groundedness | generated answer + the excerpts it was given | every claim supported: yes / no, + unsupported claim |

Judge = `AI_COMPLETE`, temperature 0, JSON output with a one-line rationale; prompt `judge_p1`
written before the first run. **Judge validation:** the sets are small enough (≈ 45 answered rows)
for a human pass over every verdict; report judge–human agreement and use the human label where they
disagree. Without that pass the judged numbers are not reported as results.

### 2.2a Cost controls (adopted 2026-11-13)

| Control | Effect |
|---|---|
| Answer + judgment cache on input hash (above) | iterations and reruns cost ~0 AI tokens |
| One judge call per answered row (both metrics), skip `not_covered` rows | ~45 judge calls instead of up to 120 |
| Smoke test A/B: `response_format` schema vs plain "reply in JSON" + `TRY_PARSE_JSON` on the same 3 queries | the schema cost ~700 prompt tokens per Claude call in Gate 3.0; adopt plain JSON for the generator only if all 6 calls parse and decisions match. The judge keeps the schema (OpenAI needs it to be reliable). |
| One batched `snow sql -f` script per gate | 1–2 warehouse bursts per gate instead of one per command |
| Compact report output (only the columns needed) | fewer Claude tokens per review |
| `top_k` 5 kept for `a1` (quality first); top 3 measured later as its own setup | |
| Cheaper generator as the next setup: `a1_haiku` (`claude-haiku-4-5`) on the same harness | production choice if abstention / correctness hold |

Production (later, not in this eval): skip the LLM for ticket categories that need no policy answer
(General Feedback, from the Silver categories), and cache answers for repeated ticket templates.
Actual credits per call are taken from the AI usage views at the next reconciliation, not assumed.

### 2.3 Why SQL-native and not Snowflake AI Observability (TruLens) now

The old Step 5 named AI Observability. It gives managed RAG-triad metrics (context relevance,
groundedness, answer relevance) and a Snowsight UI, but needs a Python app instrumented with the
TruLens SDK, and its metrics do not use our `expected_answer` / abstention labels. Our open question
is precisely abstention and correctness against labels, and the existing harness already stores
comparable runs in SQL. Recommendation: SQL-native for Phase 3; adopt AI Observability when the
Cortex Agent arrives (agent tracing is where it adds most). Check current Snowflake docs then.

### 2.4 Guarding against tuning on the exam

With only 60 labelled queries there is no separate tuning set. Rules:

- Prompts `ga_p1` / `judge_p1` are fixed before the first run; the **first run's numbers are the
  headline result**.
- At most one prompt revision (`ga_p2`), only for a failure class (e.g. "answers OOS from a
  near-miss chunk"), never for an individual question, with the reason recorded; report p1 and p2.
- Labels are not changed after seeing answers (same rule as 2a). Disputed labels go into `notes`.

## 3. Gates

| Gate | Work | Approval / cost (estimate, to confirm per gate) |
|---|---|---|
| **3.0** | Confirm models available in the account/region (generator, judge) and that `AI_COMPLETE` returns token usage | **Done**: see Gate 3.0 results |
| **3.1** | DDL: `GOLD.answer_policy_question`, `EVALUATION.policy_answer_results` (with cache), eval procedure; CLAUDE.md serving-layer note; smoke test on 3 questions (1 answerable, 1 ticket, 1 OOS), run twice (schema vs plain JSON) | ≈ 0.03–0.04 cr |
| **3.2** | **Done** (2026-11-13): generation run `a1_grounded_answer` (+ `_holdout`) on golden + held-out (60 questions, 57 live calls); deterministic metrics report; see Gate 3.2 results | ≈ 0.10–0.2 cr (60 × ~1–2k in / ~150 out tokens, depending on the A/B) + warehouse |
| **3.3** | **Done** (2026-11-13): judge run (43 calls, both metrics per call) + human review of every verdict; judged metrics + agreement; see Gate 3.3 results | ≈ 0.10–0.15 cr; your review time ~20 min |
| **3.4** | Report + decide next: Phase 4 trigger check (below), CLAUDE.md rule note, design-knowledge doc for answer eval | ~0 |

Total ≈ 0.15–0.3 cr (~$0.45–0.9) for one full pass with the cost controls; with the cache, a
`ga_p2` revision only pays for the calls whose input changed. Credit rates per model are confirmed
from the AI usage views at the next reconciliation.

### Gate 3.0 results (2026-11-13)

Region AWS_US_WEST_2, `CORTEX_MODELS_ALLOWLIST = ALL`, `CORTEX_ENABLED_CROSS_REGION = ANY_REGION`.

| Model | Plain call | JSON `response_format` | Role |
|---|---|---|---|
| `claude-sonnet-4-5` | ok | ok (`structured_output[0].raw_message`) | **Generator** |
| `openai-gpt-5.4` | ok | ok **only with `"additionalProperties": false`** in the schema; NULL without it | **Judge** (different family) |
| `mistral-large3` | ok | ok | Fallback judge |
| `openai-gpt-4.1`, `gemini-3.1-pro` | ok | NULL (Gemini also with `additionalProperties: false`) | not used |
| `llama4-maverick` | error 400 | error | not usable |
| `openai-gpt-5.5` | "account is not allowed to access this model" | | not usable (listed in `SHOW MODELS` anyway) |

Implications for the build:
- `AI_COMPLETE`'s `model` argument must be a **string literal** (a column or variable fails to
  compile), so the procedure builds the call as dynamic SQL or fixes the model per setup.
- A failed structured-output call returns **NULL silently**: store it as `call_status = 'failed'`
  and rerun failed rows; never count NULL as an abstention.
- `show_details => TRUE` returns `usage` (prompt / completion tokens): stored per row for cost.
- The JSON schema itself costs ~700 prompt tokens per Claude call (747 tokens for a ~60-token
  prompt). Revised estimate per generation call ≈ 1.5–2k prompt + ~150 completion tokens.
- All schemas set `"additionalProperties": false` (required by OpenAI, accepted by Claude).

### Gate 3.2 results (2026-11-13): headline run, prompt `ga_p1`

Script `evaluation/14_run_a1_grounded_answer.sql`, run in one batch with the redeploy of 03, 11 (new
column `retrieval_setup`) and 12. Runs: `a1_grounded_answer` (golden), `a1_grounded_answer_holdout`
(held-out; renamed from `_ho` before the run). Retrieval `v1b_chunking`, top 5,
`claude-sonnet-4-5`, plain JSON. Run ids `691f0d9e…` (golden), `fbc4bc29…` (held-out).

| Metric | Golden (38) | Held-out (22) | Target golden / held-out |
|---|---|---|---|
| Failed calls (plain JSON) | **0** | **0** | 0 |
| Cache hits (Gate 3.1 smoke rows) | 2 | 1 | |
| OOS abstention | **8/8** | **7/8** | ≥ 7/8 / ≥ 6/8 ✅ |
| False abstention | **0/30** | **2/14** (14%) | ≤ 10% / ≤ 20% ✅ |
| Citation validity | **38/38** | **22/22** | 100% ✅ |
| Citation hit (answered + answerable) | 30/30 | 11/12 | reported |
| Expected chunk in top 5 | 30/30 | 13/14 | (retrieval) |
| Avg prompt / completion tokens (uncached) | 898 / 89 | 934 / 100 | |
| Total tokens | 32,331 / 3,195 | 19,615 / 2,109 | |
| LLM latency p50 / max | 2.8 s / 4.2 s | 3.1 s / 5.2 s | |
| End-to-end p50 (search + LLM) | 4.3 s | 4.6 s | |

Flagged rows (all held-out; golden has none):

| Row | Label | Outcome | Expected chunk in top 5 | Side | Note |
|---|---|---|---|---|---|
| ho_01 | answerable (license rule) | `not_covered` | yes | answer step | Ticket asks for an action ("confirm it's updated"); the label expects the rule behind it (valid license on file before pickup). The model abstained on the action. |
| ho_07 | answerable (category not provided) | `not_covered` | yes | answer step | "Model didn't match what we booked". The policy speaks of the reserved *category*; the model read model ≠ category as not covered. Label kept (no label edits after seeing answers); disputable. |
| ho_08 | answerable (roadside, dead battery) | answered, cites `roadside_assistance_guide_02` + `insurance_damage_waiver_04` | **no** (`_01` missed) | retrieval | Answer looks substantively right (contact Support, breakdowns covered); the judge decides correctness in 3.3. |
| ho_21 | OOS (wait time + dirty interior, review) | answered (partial) | — | answer step | Near-miss: answered the cleanliness part from the cleaning-fee / walk-through text and listed wait time as uncovered. |

Observations:
- Golden is perfect on every deterministic metric. Held-out meets both targets. The 3 answer-step
  failures share one class: **ticket-style requests where the policy gives the rule behind an
  action or covers only part of the complaint**. Two are over-cautious (ho_01, ho_07), one is
  over-eager (ho_21). This is the candidate class for `ga_p2` (decided in Gate 3.4, after judging).
- Only 1 retrieval-side failure (ho_08), and its answer still looks usable. On deterministic
  numbers alone, the Phase 4 trigger (false abstention > 20%) is not met. Correctness is still pending (3.3).
- Plain-mode JSON: 57 live calls, **0 parse failures** (D9 confirmed at scale).
- `uncovered_parts` is empty on `not_covered` rows: the model puts the explanation in `answer`.
  Harmless for metrics; noted for the judge prompt.
- AI cost (estimate until the usage views catch up): 51.9k prompt + 5.3k completion tokens over 57 calls.

### Gate 3.3 results (2026-11-13): judge `judge_p1` + human review

Scripts `evaluation/15_` (tables), `16_` (procedure), `17_run_j1_judge.sql` (run + provisional
report), `18_policy_answer_human_review.sql` (labels, agreement, final metrics). Judge
`openai-gpt-5.4`, temperature 0 (accepted), JSON schema, max_tokens 2000. Judge run ids
`b2dd9372…` (golden), `92421e6f…` (held-out). 43 answered rows judged, **0 failed**, 0 cached.
Judge tokens: 46.2k prompt / 2.7k completion (avg ~1.07k / 62 per call); p50 latency 1.7 s.

Provisional (judge only): golden 26 correct / 4 partial / 0 wrong (26/30 = 87%, below the 90% target);
held-out 8 / 4 / 0 among answerable + ho_21 wrong; grounded 30/30 and 12/13.

Human review (project owner, all 43 rows; same rubric as the judge): agrees except 3 correctness
overrides, all partial -> correct:

| Row | Judge | Human | Reason |
|---|---|---|---|
| pq_01 | partial | correct | Extra fact (Sports/Convertible $50 deposit) is true policy; rubric allows non-contradicting extras |
| pq_10 | partial | correct | Question asks only the daily CDW price; the $500 deductible is secondary |
| pq_33 | partial | correct | The requested help (free orientation briefing) is given; left-side driving implied by the question |

Agreement: correctness 40/43 (p_o 0.930, p_e 0.703, **κ 0.77**); golden 27/30 (κ 0.37, kappa paradox:
p_e 0.84 because almost all labels are `correct`); held-out 13/13 (κ 1.0). Groundedness 43/43.
All disagreements are one-directional: the judge treats every reference fact as key (systematic
strictness, not noise). See `docs/design-knowledge/04_answer_evaluation_methods.md` §3.

Final judged metrics (human labels; denominator = all answerable questions, abstention = 0):

| | Golden | Held-out |
|---|---|---|
| Correct / partial / wrong / abstained | 29 / 1 / 0 / 0 | 8 / 4 / 0 / 2 |
| **Strict** (pass rule §4) | **29/30 = 0.967** (95% Wilson 0.83–0.99) | **8/14 = 0.571** (0.33–0.79) |
| Lenient (correct + partial) | 1.000 | 0.857 |
| Partial credit (1 / 0.5 / 0) | 0.983 | 0.714 |
| Grounded (answered rows) | 30/30 | 12/13 (ho_21: "note cleanliness on the inspection form" unsupported) |

Held-out non-correct answerable rows: ho_01, ho_07 (abstained; answer step), ho_02 (missed one-way
repositioning fee), ho_06 (did not say a flight delay is no exception), ho_09 (missed response time)
— all answer step, expected chunk retrieved; ho_08 (missed "phone fastest overnight") — retrieval
(`roadside_assistance_guide_01` not in top 5). Preliminary for Gate 3.4: Phase 3 "done" criteria are
met on golden (citations 100%, OOS 8/8, false abstention 0/30, strict correctness 96.7%). Held-out
strict correctness 57% < 70%, but 5 of 6 failures are answer-step, so the §4 rule points to `ga_p2`,
not Phase 4. Final call in Gate 3.4.

## 4. Decision criteria (fixed now, before results)

- **Phase 3 done** when: citation validity 100%; golden OOS abstention ≥ 7/8; golden false
  abstention ≤ 10%; golden correctness (judged + reviewed) ≥ 90%. Held-out numbers are reported,
  with targets OOS abstention ≥ 6/8 and false abstention ≤ 20%.
- **Trigger Phase 4 (query rewrite)** if, on held-out answerable tickets, false abstention > 20% or
  correctness < 70%, and the failures trace to retrieval (expected chunk not in the top 5, or answer
  built from a wrong chunk) rather than to the prompt.
- **Revisit the prompt (`ga_p2`)** if failures trace to the answer step (right chunk retrieved, wrong
  decision or unsupported claim).

## 5. What Phase 3 must report

Per question set: OOS abstention, false abstention, citation validity/hit, correctness, groundedness
(judge + human-reviewed), judge–human agreement, tokens + credits per query, latency; failure list
classified as retrieval vs answer step; the Phase 4 trigger outcome. Plus Snowflake credits
(estimate + actual) and Claude cost per CLAUDE.md.

## 6. Decisions (confirmed 2026-11-12)

1. **Generator:** `claude-sonnet-4-5`; next setup `a1_haiku` (`claude-haiku-4-5`) on the same harness.
2. **Judge:** a different family: `openai-gpt-5.4` (fallback `mistral-large3`), per Gate 3.0.
3. **Evaluation:** SQL-native now; AI Observability with the Cortex Agent later.
4. **CLAUDE.md:** add the serving-layer exception (query-time AI calls in GOLD procedures, never in
   dynamic tables) during this phase.
5. **Cost controls** in §2.2a adopted (2026-11-13). Gate 3.1 starts in a fresh Claude Code session.
6. **Correctness reporting (2026-11-13, Gate 3.3):** the judge keeps three levels (correct / partial /
   wrong). Reports show **strict** (correct only, the §4 pass rule), **lenient** (correct + partial)
   and **partial credit** (correct = 1, partial = 0.5, wrong = 0) side by side. Reason: a binary
   score hides answers that are right but incomplete; the three views are the user's own
   methodology choice for judging the RAG process fairly. Study material on all conventions:
   `docs/design-knowledge/04_answer_evaluation_methods.md` §4.

### Open decision (user, before the next answer setup `a1_haiku` / `ga_p2`)

**D-open-1: correctness scoring method.** Options to study:
- partial credit (1 / 0.5 / 0): simple, but the 0.5 weight is arbitrary;
- strict + lenient pair (current reporting);
- **nugget / key-point recall** (TREC QA nuggets, TREC RAG 2024): split each `expected_answer` into
  atomic facts tagged *vital* or *okay*; correct = all vital nuggets covered, completeness = share
  covered. Separates "missed a vital fact" (ho_06, ho_02) from "missed a nice-to-have" (ho_09,
  pq_10), which the single "partial" bucket mixes;
- claim-level scores (RAGAS answer correctness / faithfulness, FActScore): continuous 0-1.
If nuggets are chosen, the vital/okay tags are added to the labels **before** the next setup runs.
Variance is handled separately (repeated runs, pass^k), not by looser criteria.

# Answer Evaluation Methods: Judging RAG Answers, Partial Credit and Judge Validation

How this project scores generated answers (not retrieval), the conventions that exist for scoring
answers that are *partly* right, how an LLM judge is checked against a human, and what small sample
sizes and model randomness mean for the numbers. Written as study material: each method has its
definition, where it comes from, pros and cons, and a worked example on this project's data.

| | |
|---|---|
| **Applies to** | `EVALUATION.policy_answer_judgments`, `EVALUATION.policy_answer_reviews`, `EVALUATION.run_policy_answer_judge` |
| **Implemented in** | `evaluation/15_…` to `18_…` |
| **Plans** | `docs/plans/03_phase3_grounded_answers.md` (Gate 3.3 results, §6 item 6, open decision D-open-1) |
| **Companion docs** | `03_grounded_answers_and_abstention.md` (the answer step being evaluated), `01_policy_retrieval_evaluation.md` (retrieval metrics) |
| **Status** | Gate 3.3 done (2026-11-13): judge run + human review of all 43 verdicts. Scoring method for future setups is an open user decision (D-open-1, §4.6) |

**Last updated:** 2026-11-13 (after Gate 3.3)

## Implementation map

| What | Object | File |
|---|---|---|
| Judge verdicts (one row per judge run × answered row), judge cache on `judge_sha` | `EVALUATION.policy_answer_judgments` | `evaluation/15_policy_answer_judgments.sql` |
| Human verdicts, keyed on the answer (`answer_sha`), final labels | `EVALUATION.policy_answer_reviews` | same file |
| Judge procedure: prompt `judge_p1`, one call per answered row, both metrics | `EVALUATION.run_policy_answer_judge` | `evaluation/16_run_policy_answer_judge.sql` |
| Gate 3.3 judge run + provisional report + review listing | judge runs on `a1_grounded_answer` (+ `_holdout`) | `evaluation/17_run_j1_judge.sql` |
| Human review labels, agreement (percent + Cohen's kappa), strict / lenient / partial-credit report | — | `evaluation/18_policy_answer_human_review.sql` |

---

## 1. What is being measured

The answer step has two kinds of metrics (see `03_…` §7.2):

- **Deterministic**, computed in SQL against labels: OOS abstention, false abstention, citation
  validity, citation hit. No judgement needed; these were final after Gate 3.2.
- **Judged**, which need someone to read the answer:
  - **Correctness**: does the answer say what the reference answer (`expected_answer`) says?
  - **Groundedness** (also called *faithfulness*): is every policy statement in the answer supported
    by the excerpts the model was given? It is judged **against the excerpts, not the reference**:
    an answer can be correct but ungrounded (it got lucky from general knowledge), or grounded but
    incomplete.

Keeping the two separate tells you where a failure comes from: an ungrounded answer is a
hallucination problem (prompt / model); a grounded but incomplete answer is a retrieval or
summarisation problem.

## 2. LLM-as-judge: the setup used here

| Choice | What we did | Why / alternatives |
|---|---|---|
| Judge model | `openai-gpt-5.4`, a **different family** from the generator (`claude-sonnet-4-5`) | LLM judges tend to prefer text that resembles their own output (*self-preference / self-enhancement bias*, Zheng et al. 2023, MT-Bench paper). A different family reduces it. Fallback `mistral-large3`. |
| Reference-based | The judge sees `expected_answer` for correctness | Reference-free judging ("is this a good answer?") is easier to set up but drifts toward rewarding fluent, long answers (*verbosity bias*). With a reference, the judge compares facts. |
| Both metrics in one call | One call per answered row returns correctness + groundedness | Halves the calls (cost control §2.2a). Risk: one verdict could influence the other; the prompt says to judge them independently. |
| Only answered rows | `not_covered` rows are not judged | Abstention is already scored deterministically; judging "I don't know" against a reference adds nothing. |
| Fixed rubric, written before the first run | `judge_p1` defines correct / partial / wrong and grounded yes / no (below) | A rubric fixed in advance is what makes scores comparable across runs and setups. |
| Structured output | JSON schema with an enum per verdict, `additionalProperties: false` | The verdicts are parsed reliably; free-text verdicts need fragile parsing. |
| `temperature 0` | Accepted by gpt-5.4 in Cortex (Gate 3.3, 0 errors) | Reduces run-to-run variance; does not guarantee identical output (§5). |
| Cache | `judge_sha = SHA2(judge model | full judge prompt)` | The key is the **input**, so model randomness never changes it. The cache makes reruns **reproducible**, not the judge **reliable**: an unlucky first verdict is kept until the input changes. Reliability comes from the human review (§3). |

**Rubric `judge_p1`** (the human reviewer applies the same one, otherwise agreement is meaningless):

- **correct**: states the reference's key policy facts that the request needs, contradicts none.
  Extra details, other wording or order are fine if they do not contradict.
- **partial**: right policy, but misses or blurs a key fact (amount, time limit, condition,
  exception), or hedges where the reference is definite.
- **wrong**: contradicts the reference, misses its main point, or answers when the reference says
  the policy does not cover the request.
- **grounded yes**: every policy statement is stated in or follows directly from the excerpts.
  Referrals to Support and "the policy does not cover X" are not policy statements.

## 3. Validating the judge against a human

An LLM judge is itself a model with errors, so its verdicts are not results until checked. With
43 rows, the human reviewed **every** verdict (for larger sets you would review a random sample and
report agreement on it).

### 3.1 Percent agreement

Share of rows where judge and human gave the same label. Simple, but it ignores agreement that would
happen by chance.

### 3.2 Cohen's kappa

κ = (p_o − p_e) / (1 − p_e), where p_o = observed agreement and p_e = the agreement two raters would
reach by chance given how often each uses each label (Cohen 1960). For each label, multiply the two
raters' frequencies and sum: p_e = Σ_c (n_judge,c × n_human,c) / n².

Common reading (Landis & Koch 1977, a convention, not a law): < 0.2 slight, 0.21–0.40 fair,
0.41–0.60 moderate, 0.61–0.80 substantial, > 0.80 almost perfect.

**Worked example (Gate 3.3, correctness, all 43 rows):**

| | Judge | Human |
|---|---|---|
| correct | 34 | 37 |
| partial | 8 | 5 |
| wrong | 1 | 1 |

p_o = 40/43 = 0.930. p_e = (34·37 + 8·5 + 1·1) / 43² = 1299/1849 = 0.703.
κ = (0.930 − 0.703) / (1 − 0.703) = **0.77** (substantial).

### 3.3 The kappa paradox (seen in our data)

On the golden set alone: agreement 27/30 = **90%**, yet κ = **0.37** ("fair"). On held-out: 13/13,
κ = 1.0. Why? Almost every golden answer is `correct` (judge 26/30, human 29/30), so chance
agreement is already high (p_e = 0.84) and the 3 disagreements eat most of the remaining room.
Kappa is low when one label dominates even if the raters rarely disagree (Feinstein & Cicchetti
1990, "high agreement but low kappa"). Lesson: **report kappa together with percent agreement and
the label counts**; neither number alone tells the story. Alternatives that are less sensitive to
skewed labels: Gwet's AC1, or reporting agreement per label.

### 3.4 What the disagreements say about the judge

All 3 disagreements (pq_01, pq_10, pq_33) go the same way: the judge said `partial`, the human said
`correct`. In each, the judge treated **every fact in the reference as a key fact** (pq_10: the
deductible next to the asked-for daily price) or penalised a true extra fact (pq_01), which the
rubric explicitly allows. So the judge is **systematically strict**, not random. A systematic bias
can be fixed by the rubric (e.g. marking which reference facts are vital, §4.4); random disagreement
cannot.

## 4. Scoring answers that are partly right

A binary right/wrong score throws information away: "missed a secondary detail" and "said something
false" both become 0. The question is how to keep the information **without** making the score
vague. These are the main conventions.

### 4.1 Binary (exact) scoring

Correct = 1, anything else = 0. Used where answers are short and checkable (exact match in QA
benchmarks, unit tests in code generation).
- Pros: unambiguous; easy to set a pass threshold.
- Cons: hides near-misses; small rubric decisions (is this fact "key"?) flip whole points.

### 4.2 Strict + lenient pair

Report two numbers: strict (only fully correct counts) and lenient (correct + partial counts).
Classic example: SQuAD reports **Exact Match** (strict) and token-level **F1** (lenient, gives credit
for overlap) side by side; TREC QA tracks also reported strict and lenient judgements.
- Pros: no arbitrary weight; the gap between the two numbers *is* the information ("how many
  answers are close but incomplete").
- Cons: two numbers, so a single pass rule must pick one (ours: strict, plan §4).

### 4.3 Partial credit (ordinal → numeric)

Map labels to points, e.g. correct = 1, partial = 0.5, wrong = 0, and report the mean. Same idea as
Likert-scale grading (MT-Bench grades 1–10; G-Eval weights scores by the judge's token
probabilities).
- Pros: one number that keeps the middle category.
- Cons: the weight (0.5) is a choice, not a measurement; "partial" can mean "missed a vital fact" or
  "missed a nice-to-have", and both get 0.5.

### 4.4 Nugget / key-point evaluation

Split each reference answer into atomic facts (**nuggets**) and tag each **vital** (must be present)
or **okay** (good to have). Score which nuggets the answer contains.
- Origin: TREC QA "definition / other" questions (Voorhees 2003): nugget recall over vital nuggets,
  nugget precision approximated by answer length; extended with weighted "pyramid" nuggets (Lin &
  Demner-Fushman 2006).
- Today: the **TREC 2024 RAG Track** evaluates RAG answers with nuggets (AutoNuggetizer, Pradeep et
  al.): an LLM proposes nuggets and tags vital/okay, then judges each nugget as supported / partially
  supported / not supported by the answer; scores include "vital-only" and strict vs non-strict
  variants.
- Pros: separates the two kinds of "partial"; the vital/okay tag is set **before** seeing answers, so
  the judge no longer decides on its own what is "key" (exactly the judge bias in §3.4); gives a
  natural pass rule ("all vital nuggets present") plus a completeness fraction.
- Cons: more labelling (each `expected_answer` must be split and tagged); nugget boundaries are
  themselves judgement calls.

Worked example on our partials (tags shown are illustrative, not decided):

| Row | Reference nuggets | Answer has | Result under "all vital present" |
|---|---|---|---|
| pq_10 | CDW SUV $16/day (vital), $500 deductible (okay?) | $16/day | correct if the deductible is okay; partial if vital |
| ho_09 | flat tire covered (vital), 60–90 min metro response (okay?) | covered | correct if the time is okay |
| ho_06 | timing-based refund rules (vital), flight delay is not an exception (vital) | rules only | partial: a vital nugget is missing |
| ho_02 | change > 24 h free (vital), one-way repositioning fee (vital) | first only | partial |

### 4.5 Claim-level scores

Split the **answer** (not the reference) into claims and check each one.
- **FActScore** (Min et al. 2023): share of the answer's atomic facts supported by a knowledge source
  (a precision measure).
- **RAGAS** (Es et al. 2023): *faithfulness* = supported claims / all claims, against the retrieved
  context (our groundedness, as a fraction); *answer correctness* = F1 over claims matched to the
  reference (true / false positives and negatives), blended with semantic similarity.
- **TruLens** groundedness: per-sentence support scores averaged to 0–1.
- Pros: continuous, fine-grained; claim precision catches "mostly right but one false claim".
- Cons: depends on how the answer is split; continuous scores need their own thresholds; more LLM
  calls per answer.

### 4.6 Our choice and the open decision

- **Now (Gate 3.3):** three-level labels, reported three ways side by side: **strict** (the plan §4
  pass rule), **lenient**, and **partial credit**. This is the user's methodology choice for judging
  the RAG process fairly: a probabilistic generator will often produce answers that are right but
  incomplete, and a binary score would hide that.
- **Open (D-open-1, user decision before the next answer setup `a1_haiku` / `ga_p2`):** which of
  §4.2–4.5 becomes the correctness metric going forward. Leading candidate: nuggets (§4.4), because
  the observed judge bias (§3.4) is exactly "which reference facts are key". If chosen, the
  vital/okay tags go into the labels before the next setup runs.

## 5. Randomness: why the rubric stays fixed

A probabilistic model is **not** a reason for a looser rubric. The rubric is the ruler; if the ruler
changes, you can no longer tell whether a score moved because of the model or because of the
scoring. Randomness is handled by **measuring repeatedly**:

- **Repeated runs:** run the same questions k times (with the caches bypassed) and report the mean
  and spread, or the share of questions whose verdict flips between runs.
- **pass@k** (Chen et al. 2021, code generation): probability that at least one of k samples is
  correct. Measures *capability* ("can it ever get it right?").
- **pass^k** (τ-bench, Yao et al. 2024): probability that *all* k samples are correct. Measures
  *reliability* ("does it get it right every time?"), which is what a customer-facing assistant needs.

In this project the generator and judge both run at temperature 0 and are cached, so a "partial" is
a consistent gap (the same answer every time), not noise. Measuring the flip rate costs one extra
judge pass (~0.1 cr) and is planned only if judge–human agreement is low; at κ = 0.77 it is not
needed now.

## 6. Small samples: how sure are the numbers?

A rate on 30 or 14 questions has wide uncertainty. The **Wilson score interval** is a standard 95%
interval for a proportion that behaves well near 0% and 100% (unlike the simple ± 1.96·√(p(1−p)/n)).

| Metric (human labels) | Value | 95% Wilson interval |
|---|---|---|
| Golden strict correctness | 29/30 = 0.967 | 0.83 – 0.99 |
| Golden strict, judge only (before review) | 26/30 = 0.867 | 0.70 – 0.95 |
| Held-out strict correctness | 8/14 = 0.571 | 0.33 – 0.79 |
| Held-out lenient | 12/14 = 0.857 | 0.60 – 0.96 |

Reading: the golden result clears the 90% target as a point estimate, but the interval includes
values below it; the 3 human overrides moved the point estimate from below to above the target,
which is why the human pass matters. On held-out, 14 questions cannot distinguish 60% from 75%:
treat held-out numbers as direction, and look at the failure list, not the decimals.

## 7. Gate 3.3 results in brief

| | Golden (30 answerable) | Held-out (14 answerable) |
|---|---|---|
| Judged rows (answered) | 30 | 13 (12 answerable + ho_21 OOS) |
| Correct / partial / wrong (human) | 29 / 1 / 0 | 8 / 4 / 0 (+2 abstained) |
| **Strict** / lenient / partial credit | **0.967** / 1.000 / 0.983 | **0.571** / 0.857 / 0.714 |
| Grounded (answered rows) | 30/30 | 12/13 (ho_21) |
| Judge–human agreement (correctness) | 27/30, κ 0.37 (kappa paradox, §3.3) | 13/13, κ 1.0 |
| Groundedness agreement | 30/30 | 13/13 |
| Judge cost | 31.6k prompt / 1.9k completion tokens | 14.6k / 0.8k |

Full results, run ids and the per-row list: plan 03, "Gate 3.3 results".

## 8. References (for study)

- Zheng et al. 2023, *Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena*: judge biases (position, verbosity, self-enhancement).
- Liu et al. 2023, *G-Eval*: rubric-based LLM scoring weighted by token probabilities.
- Voorhees 2003, *Overview of the TREC 2003 Question Answering Track*: vital/okay nuggets.
- Lin & Demner-Fushman 2006, *Will Pyramids Built of Nuggets Topple Over?*: weighted nuggets.
- Pradeep et al. 2024/2025, TREC 2024 RAG Track nugget evaluation (AutoNuggetizer).
- Rajpurkar et al. 2016, *SQuAD*: Exact Match + F1.
- Min et al. 2023, *FActScore*; Es et al. 2023, *RAGAS*.
- Chen et al. 2021, *Evaluating Large Language Models Trained on Code* (pass@k); Yao et al. 2024, *τ-bench* (pass^k).
- Cohen 1960 (kappa); Landis & Koch 1977 (interpretation bands); Feinstein & Cicchetti 1990 (kappa paradox); Gwet 2008 (AC1).
- Wilson 1927 (score interval).

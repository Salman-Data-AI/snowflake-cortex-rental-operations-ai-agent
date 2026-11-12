# 02 — Policy RAG Roadmap Revision (after the v0 baseline)

| | |
|---|---|
| **Date** | 2026-11-12 (updated the same day after Phase 2: results, decisions 6–8, Phase 2a) |
| **Supersedes** | `docs/plans/01_resume_assessment_and_roadmap.md` Phase 3, and Step 4 of `docs/prompts/01_policy_rag_retrieval_evaluation.md` (both marked RETIRED) |
| **Evidence** | `docs/design-knowledge/01_policy_retrieval_evaluation.md` §4.3 and §7; results in `RENTAL_OPS.EVALUATION.policy_retrieval_results` |
| **Working mode** | Unchanged: one phase at a time, DDL approved before running, results reviewed before the next phase |

## Context

The original plan assumed retrieval needed two improvement layers: doc2query at ingestion (Step 3)
and query rewrite + fusion + a reranker-score threshold at query time (Step 4). The v0 baseline on
the extended golden set (`gq_v2`, 38 questions) changed that picture:

| Finding | Evidence |
|---|---|
| **Ranking is already strong** | hit@1 = 0.967 (29 / 30 answerable); every miss/hit is all-or-nothing (hit@1 = hit@5 = MRR) |
| **The one miss is "confidently wrong"** | pq_05 (late return): correct chunk at rank 24 of 35; top score −5.11, margin 2.07, so no score rule can catch it. Only closing the vocabulary gap fixes it |
| **Scores are poorly calibrated** | Answerable (min −8.36) and out-of-scope (max −6.87) top scores overlap; best single cut-off still rejects a correct answer (pq_30) |
| **Margin is not a better rejection signal** | Margin < 1.5 rejects 7 / 8 out-of-scope but 3 / 30 answerable, worse than the raw score; near-misses naming a real entity (pq_24, "Davidstad") get a big margin |
| **Chunking causes some low confidence** | pq_30 is a correct rank-1 hit at −8.36 because the loyalty FAQ is one 491-token chunk (6.0× the median of 82) |

## Decisions

1. **Keep doc2query (Step 3) as the next phase.** One-time ingestion cost (~35 LLM calls, zero per
   query). It is the only planned change that targets the confidently-wrong miss, and it should lift
   scores on casual wording.
2. **Retire Step 4 as a planned phase; keep it as a conditional option.** It adds an LLM call and
   latency to *every* query for little ranking headroom (one miss in 30), and threshold calibration
   proved fragile. Revisit only if answer-level evaluation shows the agent answering out-of-scope
   questions or still missing casual questions.
3. **Handle abstention in the generation step, not with a retrieval threshold.** The answering LLM
   reads the chunks anyway; grounded instructions ("answer only from the provided policy text;
   otherwise say it is not covered") are the cheapest answerability check.
4. **Bring answer-level evaluation (Step 5) forward**, so abstention and groundedness are measured
   directly using the golden set's `expected_answer` column.
5. **Adopt chunking guidelines** (`docs/design-knowledge/02_chunking_guidelines.md`) for the policy
   corpus and for any larger corpus later, starting with automatic chunk-quality flags in Silver.
6. **(after Phase 2) `v1_doc2query` is the reference setup** for every later comparison: no ranking
   regressions, clearly higher confidence on answerable questions (see "Phase 2 results").
7. **(after Phase 2) Calibration is an explicit objective, and it is optimised on a held-out set,
   not on the golden set.** Ranking is good enough; the open problem is that confidence is low and
   overlapping even for correct hits (median rank-1 reranker score is negative), which will matter
   more on a larger corpus where more near-miss chunks compete. The golden set is saturated for
   ranking (29 / 30 at rank 1) and now mildly contaminated (4 golden questions have near-copies
   among the generated questions), so tuning against it would fit the exam. Hence Phase 2a.
8. **(after Phase 2) Question-rows indexing (`v1c_question_rows`) is parked, not rejected.**
   Indexing each generated question as its own search row (multi-vector / hypothetical-question
   indexing) is a legitimate calibration lever, because appended questions are diluted inside one
   chunk embedding. It was designed but not run: on the golden set its only measurable effect is
   whether pq_05 flips (one generated question) and leakage would be amplified (near-copy rows
   match golden questions directly). It also costs every caller over-fetch + de-duplication by
   chunk_id and a ~5× index. Revisit it as a calibration experiment once the held-out set exists.

## Revised sequence

| Phase | Deliverable | setup_version | Status |
|---|---|---|---|
| 0 | Claude Code setup (CLAUDE.md, snow CLI, staging script, allowlist, cost tracking) | — | **Done** |
| 1 | Evaluation framework + golden set `gq_v1` → `gq_v2` + baseline | `v0_baseline` | **Done** |
| 2 | doc2query: generated questions per chunk in Silver, carried to Gold, service rebuilt, eval run vs v0 | `v1_doc2query` | **Done** (reference setup) |
| 2a | Held-out evaluation set for calibration: questions not written while looking at the pipeline (primary source: real customer phrasing in the support tickets), labelled from evidence spans; calibration metrics (separation, overlap, AUC of the rank-1 score) measured on it for v1 | — (new `dataset_version`) | **Next** |
| 2b | Chunk-quality hardening: structure-aware split (FAQ → one chunk per question), size target, quality flags in Silver; labels re-derived from evidence spans; regenerate doc2query for changed chunks | `v1b_chunking` | Planned (after 2, see note) |
| 3 | Grounded answer generation (agent or `AI_COMPLETE` over retrieved chunks) with explicit "not covered" abstention + answer-level evaluation (correctness vs `expected_answer`, groundedness, abstention on the 8 out-of-scope questions) | `a1_grounded_answer` | Planned (Step 5 brought forward) |
| 4 | *Conditional:* query rewrite + fusion (old Step 4), only if Phase 3 shows out-of-scope answers or casual misses | `v2_query_rewrite` | **Conditional** (old Step 4 retired) |
| Later | Semantic View + Cortex Analyst over the Gold star schema; Cortex Agent combining Analyst + Search | — | Separate planning |

**Note on 2a:** calibration levers (2b chunking, parked question rows, contextual headers) are
compared on the held-out set; the golden set stays the regression check (no ranking losses) and is
reported with and without the 4 leak-flagged questions.

**Note on 2 vs 2b order:** one change per run keeps results attributable. Doing doc2query first follows
the agreed priority (it targets the real miss). Re-chunking afterwards changes chunk ids and some chunk
text, so doc2query is regenerated for the changed chunks (a few LLM calls), and golden labels are
re-derived from `expected_evidence` with the existing validation query; no hand relabelling.

## Phase 2 results (`v1_doc2query` vs `v0_baseline`, gq_v2)

| | v0 | v1 |
|---|---|---|
| hit@1 / hit@5 / MRR (30 answerable) | 0.967 / 0.967 / 0.967 | 0.967 / 0.967 / 0.967 (no question flipped) |
| pq_05 rank of expected chunk (depth 35) | 24 | 17 (rank 1 now `rental_agreement_terms_02`: its generated question says "running late") |
| Rank-1 score, answerable hits: min / median / max | −8.36 / −3.94 / 2.70 | −8.09 / **−1.25** / 2.88 |
| Rank-1 score, out-of-scope: min / median / max | −10.92 / −9.26 / −6.87 | −10.99 / −9.64 / −6.62 |
| Median gap answerable − out-of-scope | 5.3 | 8.4 |
| Score overlap (min answerable < max OOS) | yes | yes (still no clean cut-off) |

- Median score change: answerable +1.57 (non-leaked), out-of-scope +0.22; doc2query lifts
  confidence on real questions without lifting near-misses.
- Leakage: 4 golden questions have a generated near-copy (cosine ≥ 0.90): pq_19 (0.996),
  pq_10 (0.97), pq_11 (0.956) on their expected chunk, pq_06 (0.915) on a wrong chunk. All four
  were already rank 1 in v0, so hit metrics are not inflated; their score gain (+2.09 median) is
  only slightly above the rest.
- Generation: 35 chunks × 4 questions, `claude-sonnet-4-5`, temperature 0, prompt `d2q_p1`
  (generic; golden examples deliberately not named). Incremental: reruns only regenerate
  new/changed chunks. One chunk (loyalty FAQ) is 550 tokens with questions (> 512; fixed by 2b).
- Objects: `SILVER.policy_chunk_generated_questions`, `GOLD.policy_document_chunks` (+ questions,
  `search_text`; suspended), `GOLD.policy_search` (indexes `search_text`); runs in
  `evaluation/07_run_v1_doc2query.sql`.

## What each phase must report

- **Phase 2:** v1 vs v0 deltas overall and per style; questions that flipped; pq_05 rank; top-score
  distribution shift (answerable vs out-of-scope); leakage check (generated questions vs golden
  questions); one-time LLM cost.
- **Phase 2a:** held-out set size and composition (source, style, answerable vs out-of-scope),
  label validation, v1 retrieval metrics and calibration metrics on it, and overlap check against
  the golden set and the generated questions.
- **Phase 2b:** chunk count/size distribution before vs after; flagged chunks; v1b vs v1 metrics; pq_30 score.
- **Phase 3:** answer correctness, groundedness, abstention rate on out-of-scope, false abstention on
  answerable; per-query LLM cost and latency.
- **Every phase:** Snowflake credits (estimate + actual) and Claude cost/tokens per `CLAUDE.md` "Cost tracking".

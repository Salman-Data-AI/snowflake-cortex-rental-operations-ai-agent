# Chunking Guidelines for Policy and Document RAG

How to split documents into chunks that retrieve well, and how to make the ingestion flow catch
bad chunks **automatically**, so a larger corpus does not depend on manual inspection.

| | |
|---|---|
| **Applies to** | `RENTAL_OPS.SILVER.policy_document_chunks` today; any future document corpus |
| **Related** | `01_policy_retrieval_evaluation.md` (how chunk quality shows up in metrics), `docs/plans/02_policy_rag_roadmap_revision.md` (Phase 2b) |
| **Status** | G1 (FAQ split), G3, G4 (3 flags) and G6 applied in Phase 2b (`c2_structure`, 2026-11-12); G2 recursive fallback, G5 and the other flags not needed at this corpus size |
| **Last updated** | 2026-11-13 |

## Implementation map

| What | Object | File |
|---|---|---|
| Load the 6 markdown documents (1 row each) | `BRONZE.bronze_policy_documents` | `src/bronze-layer-code/unstructured-data/01_load_policy_documents.sql` |
| Split (`SPLIT_TEXT_MARKDOWN_HEADER`, FAQ lines promoted to `##`), `title \| section` prefix, token count, quality flags, `chunking_version` | `SILVER.policy_document_chunks` | `src/silver-layer-code/unstructured-data/01_policy_document_chunks.sql` |
| doc2query (G3), cached by chunk-text hash, regenerated only for changed chunks | `SILVER.policy_chunk_generated_questions` | `src/silver-layer-code/unstructured-data/02_policy_chunk_generated_questions.sql` |
| Chunk + questions → `search_text`; flags carried as `is_quality_flagged` | `GOLD.policy_document_chunks` (DT) | `src/gold-layer-code/unstructured-data/01_policy_document_chunks.sql` |
| Index (keyword + vector, user-provided embeddings) | `GOLD.policy_search` | `src/gold-layer-code/unstructured-data/02_policy_search_service.sql` |
| Re-derive golden chunk ids from evidence spans (G6) | last validation query | `evaluation/02_policy_golden_questions.sql` (held-out: `09_…`) |
| v1b eval run | — | `evaluation/08_run_v1b_chunking.sql` |

---

## 1. Why chunking matters

Retrieval never returns a document, only chunks. A chunk is the unit that gets matched, scored and
handed to the LLM, so its boundaries decide what can be found:

- **Too big / multi-topic:** the one relevant sentence is diluted by unrelated text, and scores drop.
  *Our example:* the loyalty FAQ is a single 491-token chunk (6.0× the median of 82). "Can I give my
  points to my partner?" still ranks it first, but at −8.36, inside the out-of-scope score range.
  The same chunk scores +2.7 for "How many points per day?", which matches its main topic.
- **Too small:** the chunk loses the context needed to answer ("this applies to Sports and
  Convertible only" ends up in a neighbouring chunk).
- **Wrong boundaries:** a rule split across two chunks means neither chunk fully answers.

Good chunking gives each chunk **one self-contained unit of meaning**: one rule, one FAQ answer,
one procedure step group, with enough context to stand alone.

## 2. Current approach (baseline)

| Aspect | Today |
|---|---|
| Splitter | `SNOWFLAKE.CORTEX.SPLIT_TEXT_MARKDOWN_HEADER` on `#` / `##` |
| Size | max 2000 chars (~512 tokens), 200-char overlap when a section is split |
| Context | `chunk_text_with_context` = `title | section` + text |
| Filters | drop metadata-only Overview chunks |
| Result | 35 chunks, median 82 tokens, max 491 (the FAQ) |

*This was `c1_header`. Since Phase 2b (`c2_structure`): FAQ question lines become sections first →
42 chunks, median 81, max 183 tokens, no flagged chunks (§6).*

The baseline worked because the documents are short and well-headed. It fails on structure without `##`
headers (the FAQ's bold questions), and it has no check that would flag an outlier.

## 3. Guidelines

### G1. Split on the document's real structure, not only on headers
Detect the natural units of each document type and split on them first:

| Structure | Unit | Detection |
|---|---|---|
| Headed sections | one section | `#`, `##`, `###` |
| FAQ | one question + its answer | bold or `Q:` question lines, lines ending with `?` |
| Numbered clauses / rules | one clause | `1.`, `1.1`, `(a)` patterns |
| Tables | one table (or row groups with the header row repeated) | markdown table syntax |
| Procedures | one step group | ordered lists |

For PDFs, Word files and scans, **parse to markdown first** (e.g. `AI_PARSE_DOCUMENT` in layout mode)
so headings and tables survive into the splitter. Keep the parsed markdown in Bronze or Silver so
re-chunking never needs re-parsing.

### G2. Use a target size and a recursive fallback
- **Target ~150–300 tokens** for policy/FAQ text, where each rule is an independent fact. Use larger
  targets (~400–800) for narrative documents where reasoning spans paragraphs.
- **Recursive fallback:** if a structural unit exceeds the maximum, split by paragraph, then by
  sentence, never mid-sentence. Overlap (~10–15%) only applies to these forced splits.
- **Merge tiny units** (< ~30 tokens) with their neighbour in the same section, so chunks are never
  just a heading or a one-word answer.

### G3. Make every chunk self-describing
- Prefix document title and section path (already done: `title | section`).
- At scale, add a one-sentence generated "where this sits" context per chunk (contextual retrieval)
  and/or generated questions (doc2query, Phase 2). Both are **one-time ingestion costs** and belong
  in Silver, so Gold refreshes and queries stay free of AI cost.
- Keep the **raw chunk text unchanged** for display and citation; put enrichments in separate columns.

### G4. Automatic chunk-quality flags in Silver (the scalable replacement for manual review)
Compute flags per chunk; route flagged chunks to re-splitting or a review table, and promote only
clean chunks to Gold.

| Flag | Rule (starting point) | Catches |
|---|---|---|
| `is_oversized` | tokens > 3× corpus (or document-type) median | FAQ-style and multi-topic chunks (would have flagged the loyalty FAQ) |
| `is_multi_topic` | ≥ 3 question lines, ≥ 3 bold labels or ≥ 3 numbered rules in one chunk | Structure the splitter missed |
| `is_undersized` | tokens < ~30 | Heading-only or orphan fragments |
| `is_metadata_only` | only header/metadata lines | Overview blocks (already filtered) |
| `is_near_duplicate` | cosine similarity > ~0.95 to another chunk | Boilerplate repeated across documents |
| `is_unanswerable_shape` | no sentence-ending punctuation / mostly table separators | Broken parsing output |

Thresholds are starting points; tune them per document type once you see the distribution.

### G5. Index small, return big (parent–child) when context matters
Search over small units (one rule / one Q&A) but return the parent section to the LLM. Precise
matching, enough context to answer. In Cortex Search: index the child text, and carry `parent_id`
and `parent_text` as extra returned columns. Use it when answers regularly need surrounding
context; skip it while chunks are already section-sized.

### G6. Keep chunk ids and labels stable across re-chunking
- Derive chunk ids deterministically (`<document>_<unit index>`), and version the chunking
  (`chunking_version` column) so runs can be compared.
- Keep golden labels chunking-independent: document + section + **verbatim evidence span**, and
  re-derive chunk ids after any change (the validation query in `evaluation/02_…`).

### G7. Let evaluation and production logs pick what to fix
At scale you review **outliers**, not everything:

| Signal | Points to |
|---|---|
| Golden questions whose correct chunk ranks low or has a low top score | The chunk (dilution) or the wording gap |
| Production queries with low top score, or where the agent abstained | Missing content, or bad chunks for that topic |
| Chunks never retrieved by any golden or production query | Unreachable chunks (bad boundaries or noise) |
| Per-document-type metrics (FAQ vs policy vs guide) | Which splitter rule needs work |

Grow the golden set partly with **LLM-drafted questions per document, spot-checked by a human**:
scalable coverage without letting the exam be generated the same way as doc2query (leakage).

## 4. How this maps to the medallion flow

```
Bronze   raw files + parsed markdown (AI_PARSE_DOCUMENT for PDFs/DOCX)        ← parse once
  │
Silver   structure-aware split (G1) → size target / recursive fallback (G2)
         → context prefix + doc2query / contextual summary (G3, AI calls here only)
         → quality flags (G4) → chunking_version, deterministic ids (G6)
  │        flagged chunks → re-split rule or review table
Gold     clean chunks only (dynamic table, no AI) → Cortex Search
  │
Eval     golden set with evidence spans (G6) + outlier signals (G7)
```

## 5. Trade-offs

| Choice | Gain | Cost |
|---|---|---|
| Smaller chunks | Sharper matches, higher scores, less noise to the LLM | Less context per chunk; more chunks to index; answers spanning units need parent–child |
| Structure-aware splitting | Natural boundaries, fewer multi-topic chunks | Per-document-type rules to maintain |
| Generated context / doc2query | Closes vocabulary gaps, raises confidence | One-time LLM cost per chunk; must check leakage against the golden set |
| Quality flags + review table | Scales without manual inspection | Thresholds need tuning; some false flags |
| Parent–child | Precision + context | More complex index and returned columns |

## 6. Applying this to the current corpus (Phase 2b) — done 2026-11-12

Result: 42 chunks (8 FAQ chunks, one per Q and A), max 183 tokens, 0 flagged; golden hit@5
0.967 → 1.000, pq_30 rank-1 score −8.09 → −4.37, no regressions. Full numbers:
`01_policy_retrieval_evaluation.md` §7 and plan 02 "Phase 2b results". Steps as planned:


1. Split the loyalty FAQ on bold question lines (one chunk per Q&A, ~8 chunks).
2. Add `is_oversized`, `is_multi_topic`, `is_undersized` flags to the Silver chunk table and a
   validation query listing flagged chunks (expect none after step 1).
3. Add `chunking_version`; rebuild Gold and the search service; re-derive golden chunk ids from
   evidence spans; regenerate doc2query for changed chunks.
4. Run the eval as `v1b_chunking`; compare with v1. Watch pq_16, pq_17, pq_30 (FAQ questions) and
   the top-score overlap with out-of-scope questions.

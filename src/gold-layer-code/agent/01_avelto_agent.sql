-- =============================================================
-- Gold Layer (serving) | Cortex Agent over structured + unstructured data
-- Purpose : one natural-language entry point that routes each question to
--           Cortex Analyst (semantic view, numbers) and/or Cortex Search
--           (policy text), and combines both when a question needs both.
-- Prereq  : structured-data/02_avelto_semantic_view.sql   (GOLD.avelto_semantic_view)
--           unstructured-data/02_policy_search_service.sql (GOLD.policy_search)
-- Rerun   : CREATE OR REPLACE AGENT (metadata only; no data, no warehouse).
-- Design notes:
--   * Tools: analyst_reservations (cortex_analyst_text_to_sql over the
--     semantic view) and search_policies (cortex_search over policy_search).
--   * policy_search indexes ONLY the 42 policy document chunks. Reviews and
--     support tickets are NOT indexed by any search service yet, so the tool
--     description says so; the agent must not claim customer-feedback facts
--     it cannot retrieve. (Open item: separate feedback search service.)
--   * Orchestration model claude-sonnet-4-5: same family as the Phase 3
--     generator (GOLD.answer_policy_question).
--   * max_results 5: Phase 3 principle "pass top 3-5 chunks".
--   * Analyst SQL runs on COMPUTE_WH (X-Small); each data question = one
--     warehouse burst. Budget caps one run at 60 s / 16k tokens.
--   * Known semantic-view limits are stated in the response instructions
--     (no time dimension; Branch/Country/Region = pickup branch).
--   * No ampersand anywhere in this file: it breaks `snow sql -f`.
-- =============================================================

CREATE OR REPLACE AGENT RENTAL_OPS.GOLD.avelto_agent
  COMMENT = 'Avelto rental-operations assistant: reservations/revenue/branch numbers via Cortex Analyst, policy text via Cortex Search.'
  PROFILE = '{"display_name": "Avelto Rental Ops Agent"}'
  FROM SPECIFICATION
$$
models:
  orchestration: claude-sonnet-4-5

orchestration:
  budget:
    seconds: 60
    tokens: 16000

instructions:
  orchestration: >
    Choose tools by the kind of information the question needs.
    Use analyst_reservations for numeric or structured questions: counts,
    revenue, averages, rankings, comparisons and breakdowns of reservations
    by branch, country, region, car category or currency.
    Use search_policies for questions about what documents describe: rules,
    fees, procedures, requirements and what a policy says.
    When a question needs both kinds of information (for example a number
    plus the policy that explains or applies to it), call both tools and
    combine the results into one answer.
    Do not compute business numbers yourself from search text, and do not
    answer policy questions from the semantic view.
  response: >
    Answer concisely. For numbers, state the metric and grouping used and
    that revenue is in USD. Branch, country and region always mean the
    pickup branch. The data has no date dimension yet, so questions about a
    specific period cannot be filtered by date: say so instead of guessing.
    For policy answers, cite the document title and section. If the tools do
    not contain the information (including customer reviews and support
    tickets, which are not searchable yet), say that you do not know rather
    than inventing an answer.
  sample_questions:
    - question: "What was total revenue in USD by country, ranked highest to lowest?"
    - question: "What happens if I cancel less than 24 hours before pickup?"
    - question: "Which branch has the most one-way rentals, and what does the policy say about one-way fees?"

tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: analyst_reservations
      description: >
        Structured reservation data for Avelto (2,000 rentals). Metrics:
        revenue in USD, reservation count, average rental days, one-way
        rentals. Dimensions: pickup branch, country, region, car category,
        payment currency. Use for any question that needs a number, ranking
        or breakdown. No date dimension.
  - tool_spec:
      type: cortex_search
      name: search_policies
      description: >
        Searches Avelto policy documents (rental terms, cancellation, fees,
        insurance, deposits, fuel, damage, one-way rules and similar), split
        into sections. Use for questions about what a policy or document
        says. Does NOT contain customer reviews or support tickets.

tool_resources:
  analyst_reservations:
    semantic_view: RENTAL_OPS.GOLD.AVELTO_SEMANTIC_VIEW
    execution_environment:
      type: warehouse
      warehouse: COMPUTE_WH
      query_timeout: 60
  search_policies:
    name: RENTAL_OPS.GOLD.POLICY_SEARCH
    max_results: 5
    id_column: CHUNK_ID
    title_column: DOCUMENT_TITLE
$$;


-- -------------------------------------------------------------
-- Validation (metadata only, no warehouse)
-- -------------------------------------------------------------
DESCRIBE AGENT RENTAL_OPS.GOLD.avelto_agent;
-- Expected: one row; agent_spec shows 2 tools (analyst_reservations,
-- search_policies), orchestration model claude-sonnet-4-5.
--
-- Smoke test (separate step, costs AI tokens + one warehouse burst per data
-- question): POST /api/v2/databases/RENTAL_OPS/schemas/GOLD/agents/AVELTO_AGENT:run
-- with the three sample questions; expect routing analyst / search / both.

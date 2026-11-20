-- =============================================================
-- Manual validation | TruLens / TruApp observability of GOLD.answer_policy_question (read-only)
-- Prereq: observability/trulens/run_eval.py has registered the app (EXTERNAL AGENT
--         RENTAL_OPS.EVALUATION.POLICY_RAG) and run at least once (plan 05, Gate T2).
-- Plan  : docs/plans/05_trulens_observability.md | Design: docs/design-knowledge/07_ai_observability.md
-- Rerunnable: yes, SELECT / SHOW only. Nothing is created.
-- Design notes:
--   - Traces and metric results of an external agent land in SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS;
--     read them via the GET_AI_OBSERVABILITY_EVENTS UDTF (object type 'EXTERNAL AGENT').
--   - Span names / attribute keys are discovered from real rows first (§2), as for the agent (O-D3);
--     §3 is written with the discovered keys.
-- =============================================================

-- §1 (metadata, no warehouse): the registered app and its versions
SHOW EXTERNAL AGENTS IN SCHEMA RENTAL_OPS.EVALUATION;

-- §2a Discovery: records per run / record type / span type / name
-- Expect for run t2_smoke_20261120: 3 record roots (one per question), RETRIEVAL + GENERATION spans,
-- and eval spans for 4 metrics.
SELECT record_attributes:"snow.ai.observability.run.name"::STRING           AS run_name,
       record_type,
       record_attributes:"ai.observability.span_type"::STRING                AS span_type,
       record:name::STRING                                                    AS record_name,
       COUNT(*)                                                               AS n,
       MIN(timestamp)                                                         AS first_ts,
       MAX(timestamp)                                                         AS last_ts
FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
        'RENTAL_OPS', 'EVALUATION', 'POLICY_RAG', 'EXTERNAL AGENT'))
GROUP BY ALL
ORDER BY run_name, record_type, span_type, record_name;

-- §2b Discovery: every attribute key with one example value (cut to 120 chars)
SELECT f.key,
       COUNT(*)                                     AS n,
       LEFT(ANY_VALUE(f.value)::STRING, 120)        AS example_value
FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
        'RENTAL_OPS', 'EVALUATION', 'POLICY_RAG', 'EXTERNAL AGENT')) e,
     LATERAL FLATTEN(INPUT => e.record_attributes) f
GROUP BY f.key
ORDER BY f.key;

-- §3 One row per record (question) of a run: decision, cache, #contexts and the 4 metric scores.
-- Keys discovered in §2b (plan 05, Gate T2): record spans carry ai.observability.record_id;
-- eval_root spans (one per record x metric) carry eval.target_record_id, eval.metric_name,
-- eval_root.score; child 'eval' spans (one per judge call) carry eval.score + eval.explanation.
-- Expect for t2_smoke_20261120: 3 rows, every metric column non-NULL.
WITH ev AS (
    SELECT * FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
        'RENTAL_OPS', 'EVALUATION', 'POLICY_RAG', 'EXTERNAL AGENT'))
    WHERE record_attributes:"snow.ai.observability.run.name"::STRING = 't2_smoke_20261120'
),
rec AS (
    SELECT record_attributes:"ai.observability.record_id"::STRING                      AS record_id,
           MAX(record_attributes:"ai.observability.record_root.input"::STRING)         AS question,
           MAX(record_attributes:"rental_ops.policy_rag.decision"::STRING)             AS decision,
           MAX(record_attributes:"rental_ops.policy_rag.cached"::BOOLEAN)              AS cached,
           MAX(record_attributes:"ai.observability.retrieval.num_contexts"::INT)       AS n_contexts,
           MAX(LEFT(record_attributes:"ai.observability.record_root.output"::STRING, 80)) AS output_cut
    FROM ev
    WHERE record_attributes:"ai.observability.span_type"::STRING IN ('record_root', 'generation', 'retrieval')
    GROUP BY 1
),
scores AS (
    SELECT record_attributes:"ai.observability.eval.target_record_id"::STRING AS record_id,
           record_attributes:"ai.observability.eval.metric_name"::STRING      AS metric,
           record_attributes:"ai.observability.eval_root.score"::FLOAT        AS score,
           record_attributes:"ai.observability.eval_root.n_calls"::INT        AS judge_calls
    FROM ev
    WHERE record_attributes:"ai.observability.span_type"::STRING = 'eval_root'
)
SELECT q.question_id, r.decision, r.cached, r.n_contexts,
       MAX(IFF(s.metric = 'context_relevance', s.score, NULL)) AS context_relevance,
       MAX(IFF(s.metric = 'groundedness',      s.score, NULL)) AS groundedness,
       MAX(IFF(s.metric = 'answer_relevance',  s.score, NULL)) AS answer_relevance,
       MAX(IFF(s.metric = 'correctness',       s.score, NULL)) AS correctness,
       SUM(s.judge_calls)                                      AS judge_calls,
       r.output_cut
FROM rec r
LEFT JOIN scores s ON s.record_id = r.record_id
LEFT JOIN RENTAL_OPS.EVALUATION.policy_eval_questions q ON q.question = r.question
GROUP BY q.question_id, r.decision, r.cached, r.n_contexts, r.output_cut
ORDER BY q.question_id;

-- §4 Judge explanations per record x metric (for comparing with the j1 verdicts)
SELECT e.record_attributes:"ai.observability.eval.target_record_id"::STRING AS record_id,
       e.record_attributes:"ai.observability.eval.metric_name"::STRING      AS metric,
       e.record_attributes:"ai.observability.eval.score"::FLOAT             AS score,
       LEFT(e.record_attributes:"ai.observability.eval.explanation"::STRING, 300) AS explanation
FROM TABLE(SNOWFLAKE.LOCAL.GET_AI_OBSERVABILITY_EVENTS(
        'RENTAL_OPS', 'EVALUATION', 'POLICY_RAG', 'EXTERNAL AGENT')) e
WHERE e.record_attributes:"snow.ai.observability.run.name"::STRING = 't2_smoke_20261120'
  AND e.record_attributes:"ai.observability.span_type"::STRING = 'eval'
ORDER BY record_id, metric, score;

"""
TruLens (OTEL) instrumented wrapper around RENTAL_OPS.GOLD.answer_policy_question.

Plan: docs/plans/05_trulens_observability.md  |  Design: docs/design-knowledge/07_ai_observability.md

Thin wrapper, no RAG logic of its own:
  answer(query)                       RECORD_ROOT  (via TruApp main_method) input = question, output = answer text
    ├─ call_answer_procedure(query)   GENERATION   one CALL of the deployed procedure (retrieval +
    │                                              AI_COMPLETE inside; answer-cache hit = 0 tokens)
    └─ retrieve(query, chunk_ids)     RETRIEVAL    text of the chunks the procedure sent to the LLM,
                                                   read from GOLD.policy_document_chunks

Span order note: the procedure retrieves and generates in one call, so the RETRIEVAL span is emitted
after the GENERATION span. It carries exactly the excerpts the LLM saw (chunk_text, ranked), which is
what the RAG-triad metrics (context relevance, groundedness) need.

Output text for abstentions: "[not_covered] <answer or uncovered_parts>", so a judge can see the
abstention, and records can be split by decision later.

Tested with: Python 3.12, trulens 2.16.0, snowflake-snowpark-python 1.58.0 (requirements.txt).
"""

from __future__ import annotations

import json
from typing import Any

from snowflake.snowpark import Session
from trulens.core.otel.instrument import instrument
from trulens.otel.semconv.trace import SpanAttributes

PROCEDURE = "RENTAL_OPS.GOLD.answer_policy_question"
CHUNKS_TABLE = "RENTAL_OPS.GOLD.policy_document_chunks"

# Same settings as the SQL harness setup a1_grounded_answer (evaluation/14), so cached answers are reused.
DEFAULT_TOP_K = 5
DEFAULT_MODEL = "claude-sonnet-4-5"
DEFAULT_OUTPUT_MODE = "plain"

ATTR_PREFIX = "rental_ops.policy_rag"  # custom span attributes, for joining back to policy_answer_results


def create_session(connection_name: str = "rental-dev") -> Session:
    """Snowpark session from the local Snowflake CLI connection (key-pair auth, no secrets in the repo)."""
    session = Session.builder.config("connection_name", connection_name).create()
    session.use_database("RENTAL_OPS")
    session.use_schema("EVALUATION")  # TruLens registers the EXTERNAL AGENT in the current schema
    return session


def _answer_text(result: dict[str, Any]) -> str:
    if result.get("call_status") != "ok":
        return f"[call_failed] {result.get('call_status')}"
    if result.get("decision") == "answered":
        return result.get("answer") or ""
    return f"[not_covered] {result.get('answer') or result.get('uncovered_parts') or ''}".strip()


def _generation_attributes(ret, exception, *args, **kwargs) -> dict[str, Any]:
    if not isinstance(ret, dict):
        return {}
    return {
        f"{ATTR_PREFIX}.decision": ret.get("decision") or "",
        f"{ATTR_PREFIX}.call_status": ret.get("call_status") or "",
        f"{ATTR_PREFIX}.cached": bool(ret.get("cached")),
        f"{ATTR_PREFIX}.model": ret.get("model") or "",
        f"{ATTR_PREFIX}.prompt_version": ret.get("prompt_version") or "",
        f"{ATTR_PREFIX}.input_sha": ret.get("input_sha") or "",
        f"{ATTR_PREFIX}.cited_chunk_ids": json.dumps(ret.get("cited_chunk_ids") or []),
        f"{ATTR_PREFIX}.prompt_tokens": int(ret.get("prompt_tokens") or 0),
        f"{ATTR_PREFIX}.completion_tokens": int(ret.get("completion_tokens") or 0),
        f"{ATTR_PREFIX}.llm_latency_ms": int(ret.get("llm_latency_ms") or 0),
    }


class PolicyRAG:
    def __init__(
        self,
        session: Session,
        top_k: int = DEFAULT_TOP_K,
        model: str = DEFAULT_MODEL,
        output_mode: str = DEFAULT_OUTPUT_MODE,
    ) -> None:
        self.session = session
        self.top_k = top_k
        self.model = model
        self.output_mode = output_mode
        self.last_result: dict[str, Any] | None = None  # full procedure result of the last answer()

    @instrument(
        name="call_answer_procedure",
        span_type=SpanAttributes.SpanType.GENERATION,
        attributes=_generation_attributes,
    )
    def call_answer_procedure(self, query: str) -> dict[str, Any]:
        row = self.session.sql(
            f"CALL {PROCEDURE}(?, ?, ?, ?, TRUE)",
            params=[query, self.top_k, self.model, self.output_mode],
        ).collect()[0]
        return json.loads(row[0])

    @instrument(
        name="retrieve",
        span_type=SpanAttributes.SpanType.RETRIEVAL,
        attributes=lambda ret, exception, *args, **kwargs: {
            SpanAttributes.RETRIEVAL.QUERY_TEXT: kwargs.get("query", ""),
            SpanAttributes.RETRIEVAL.RETRIEVED_CONTEXTS: ret or [],
            SpanAttributes.RETRIEVAL.NUM_CONTEXTS: len(ret or []),
        },
    )
    def retrieve(self, query: str, chunk_ids: list[str]) -> list[str]:
        if not chunk_ids:
            return []
        rows = self.session.sql(
            f"SELECT chunk_id, chunk_text FROM {CHUNKS_TABLE} WHERE ARRAY_CONTAINS(chunk_id::VARIANT, PARSE_JSON(?))",
            params=[json.dumps(chunk_ids)],
        ).collect()
        text_by_id = {r["CHUNK_ID"]: r["CHUNK_TEXT"] for r in rows}
        return [text_by_id[c] for c in chunk_ids if c in text_by_id]  # keep the procedure's rank order

    # Not decorated as RECORD_ROOT: TruLens refuses an explicit record_root span type; TruApp makes
    # main_method=answer the record root and sets RECORD_ROOT.INPUT / OUTPUT from its argument / return.
    def answer(self, query: str) -> str:
        result = self.call_answer_procedure(query)
        chunk_ids = [r["chunk_id"] for r in (result.get("retrieved") or [])]
        self.retrieve(query, chunk_ids)
        self.last_result = result
        return _answer_text(result)

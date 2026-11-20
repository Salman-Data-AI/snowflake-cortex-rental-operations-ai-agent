"""
Run PolicyRAG over policy eval questions, either as a plain dry run (T1) or as a TruLens run (T2/T3).

Plan: docs/plans/05_trulens_observability.md

Usage (from the repo root):
  # T1: no TruLens objects, no export. Prints answer, decision, cached, #contexts per question.
  .venv-trulens/bin/python observability/trulens/run_eval.py --dry-run --question-ids pq_01

  # T2: register TruApp (CREATE EXTERNAL AGENT in RENTAL_OPS.EVALUATION), run, compute metrics.
  .venv-trulens/bin/python observability/trulens/run_eval.py --question-ids pq_01,pq_02,pq_23 \
      --run-name t2_smoke_20261120

Dataset: RENTAL_OPS.EVALUATION.policy_eval_questions (golden + held-out), filtered here and passed
to run.start() as a DataFrame (source_type DATAFRAME), so no dataset table is created.
Judge: openai-gpt-5.4 (= the SQL harness judge j1), set explicitly via RunConfig.llm_judge_name.
"""

from __future__ import annotations

import argparse
import sys
import time

from policy_rag_app import PolicyRAG, create_session

APP_NAME = "policy_rag"
APP_VERSION = "a1_grounded_answer"  # = SQL answer setup wrapped (evaluation/14)
JUDGE = "openai-gpt-5.4"
METRICS = ["context_relevance", "groundedness", "answer_relevance", "correctness"]
DATASET_VIEW = "RENTAL_OPS.EVALUATION.policy_eval_questions"
TERMINAL_INVOCATION = {"INVOCATION_COMPLETED", "INVOCATION_PARTIALLY_COMPLETED", "FAILED"}


def load_questions(session, question_set: str | None, question_ids: list[str] | None, limit: int | None):
    sql = f"SELECT question_set, question_id, question, is_answerable, expected_answer FROM {DATASET_VIEW} WHERE TRUE"
    params: list = []
    if question_set:
        sql += " AND question_set = ?"
        params.append(question_set)
    if question_ids:
        sql += f" AND question_id IN ({', '.join('?' for _ in question_ids)})"
        params.extend(question_ids)
    sql += " ORDER BY question_set, question_id"
    if limit:
        sql += f" LIMIT {int(limit)}"
    df = session.sql(sql, params=params).to_pandas()
    df["EXPECTED_ANSWER"] = df["EXPECTED_ANSWER"].fillna("")  # OOS rows have no expected answer
    return df


def dry_run(app: PolicyRAG, df) -> None:
    for _, q in df.iterrows():
        out = app.answer(q["QUESTION"])
        r = app.last_result or {}
        print(
            f"{q['QUESTION_ID']:<8} answerable={q['IS_ANSWERABLE']!s:<5} decision={r.get('decision')!s:<12} "
            f"status={r.get('call_status')} cached={r.get('cached')} "
            f"tokens={r.get('prompt_tokens')}/{r.get('completion_tokens')} contexts={len(r.get('retrieved') or [])}"
        )
        print(f"         -> {out[:160]}")


def trulens_run(session, app: PolicyRAG, df, run_name: str, wait_s: int) -> None:
    from trulens.apps.app import TruApp
    from trulens.connectors.snowflake import SnowflakeConnector
    from trulens.core.run import RunConfig

    connector = SnowflakeConnector(snowpark_session=session)
    tru_app = TruApp(
        app,
        app_name=APP_NAME,
        app_version=APP_VERSION,
        connector=connector,
        main_method=app.answer,
    )
    run = tru_app.add_run(
        run_config=RunConfig(
            run_name=run_name,
            dataset_name=f"policy_eval_questions[{','.join(df['QUESTION_ID'])}]",
            source_type="DATAFRAME",
            dataset_spec={
                "RECORD_ROOT.INPUT": "QUESTION",
                "RECORD_ROOT.GROUND_TRUTH_OUTPUT": "EXPECTED_ANSWER",
            },
            llm_judge_name=JUDGE,
            description=f"{APP_VERSION} wrapped in TruLens; {len(df)} questions",
            label="plan05",
            invocation_max_workers=1,  # sequential: same order and load as the SQL harness
        )
    )
    print(run.start(input_df=df))

    # start() returns before server-side ingestion finishes; compute_metrics() before that computes nothing.
    deadline = time.time() + wait_s
    status = str(run.get_status())
    while not any(s in status for s in TERMINAL_INVOCATION) and time.time() < deadline:
        time.sleep(15)
        status = str(run.get_status())
        print(f"status: {status}")
    if "INVOCATION_COMPLETED" not in status:
        sys.exit(f"Stopping before metrics: run status {status}")

    print(run.compute_metrics(METRICS))
    print("Metrics are computed server-side; check status with run.get_status() or the Snowsight Evaluations page.")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--question-set", choices=["golden", "holdout"])
    p.add_argument("--question-ids", help="comma-separated, e.g. pq_01,pq_02")
    p.add_argument("--limit", type=int)
    p.add_argument("--dry-run", action="store_true", help="no TruLens registration / export (T1)")
    p.add_argument("--run-name")
    p.add_argument("--wait-s", type=int, default=600, help="max wait for ingestion before metrics")
    a = p.parse_args()
    if not a.dry_run and not a.run_name:
        p.error("--run-name is required unless --dry-run")
    if not (a.question_set or a.question_ids or a.limit):
        p.error("refusing to run on every question: pass --question-set, --question-ids or --limit")

    session = create_session()
    try:
        df = load_questions(session, a.question_set, a.question_ids.split(",") if a.question_ids else None, a.limit)
        print(f"{len(df)} question(s): {', '.join(df['QUESTION_ID'])}")
        app = PolicyRAG(session)
        if a.dry_run:
            dry_run(app, df)
        else:
            trulens_run(session, app, df, a.run_name, a.wait_s)
    finally:
        session.close()


if __name__ == "__main__":
    main()

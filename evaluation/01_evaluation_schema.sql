-- =============================================================
-- Evaluation | Step 01: Schema for retrieval evaluation objects
-- Holds the golden dataset, per-run results, summary view and eval procedure
-- for the policy RAG pipeline (RENTAL_OPS.GOLD.policy_search).
-- Kept separate from BRONZE/SILVER/GOLD so eval objects never mix with pipeline objects.
-- Rerunnable (IF NOT EXISTS).
-- =============================================================

CREATE SCHEMA IF NOT EXISTS RENTAL_OPS.EVALUATION
    COMMENT = 'Retrieval evaluation for the policy RAG pipeline (golden set, runs, metrics)';

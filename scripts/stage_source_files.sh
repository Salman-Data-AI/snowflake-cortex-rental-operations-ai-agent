#!/usr/bin/env bash
# =============================================================
# Bronze Layer | Upload source files from local data/ to @RENTAL_OPS.BRONZE.LANDING
# CLI alternative to the `COPY FILES ... FROM 'snow://workspace/...'` statements
# in src/bronze-layer-code/**, which only work inside a Snowsight Workspace.
# Files land at the same stage paths those scripts expect (e.g. FleetOps/cars.csv),
# uncompressed, overwriting existing copies (same effect as rerunning COPY FILES).
# data/FleetOps/cars_fleet_expansion.csv is intentionally excluded (note, not data).
#
# Usage: scripts/stage_source_files.sh [structured|semi-structured|policy|all]   (default: all)
# After uploading, run the matching load script(s) with: snow sql -c rental-dev -f <file>
# (skip their COPY FILES statement, or run only the DDL + COPY INTO part).
# =============================================================
set -euo pipefail

CONNECTION="${SNOW_CONNECTION:-rental-dev}"
STAGE="@RENTAL_OPS.BRONZE.LANDING"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GROUP="${1:-all}"

upload() {  # upload <local file relative to data/> ; stage dir = file's dir
    local rel="$1"
    snow stage copy "$ROOT/data/$rel" "$STAGE/$(dirname "$rel")/" \
        -c "$CONNECTION" --overwrite --no-auto-compress
}

structured() {
    for f in branches cars car_categories countries currencies customers branch_category_availability; do
        upload "FleetOps/$f.csv"
    done
    upload "BookWave/reservations_export.json"
}

semi_structured() {
    upload "Unstructured/support_tickets.csv"
    upload "Unstructured/reviews.csv"
}

policy() {
    for f in cancellation_refund_policy driving_rules_by_region insurance_damage_waiver \
             loyalty_program_faq rental_agreement_terms roadside_assistance_guide; do
        upload "Unstructured/policy_documents/$f.md"
    done
}

case "$GROUP" in
    structured)      structured ;;
    semi-structured) semi_structured ;;
    policy)          policy ;;
    all)             structured; semi_structured; policy ;;
    *) echo "Unknown group '$GROUP' (use structured|semi-structured|policy|all)" >&2; exit 1 ;;
esac

# Confirm what is on the stage (expect 16 files for 'all')
snow sql -c "$CONNECTION" -q "LIST $STAGE"

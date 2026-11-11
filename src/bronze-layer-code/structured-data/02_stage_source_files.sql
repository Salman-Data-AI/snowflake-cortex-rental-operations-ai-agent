-- =============================================================
-- Bronze Layer | Step 02: Copy source files from the workspace to the landing stage
-- FleetOps/cars_fleet_expansion.csv is intentionally excluded (superseded note, not data).
-- =============================================================

COPY FILES INTO @RENTAL_OPS.BRONZE.LANDING
FROM 'snow://workspace/USER$.PUBLIC."snowflake-cortex-rental-operations-ai-agent"/versions/live/'
FILES = (
    'FleetOps/branches.csv',
    'FleetOps/cars.csv',
    'FleetOps/car_categories.csv',
    'FleetOps/countries.csv',
    'FleetOps/currencies.csv',
    'FleetOps/customers.csv',
    'FleetOps/branch_category_availability.csv',
    'BookWave/reservations_export.json'
);

-- Confirm 8 files landed
LIST @RENTAL_OPS.BRONZE.LANDING;

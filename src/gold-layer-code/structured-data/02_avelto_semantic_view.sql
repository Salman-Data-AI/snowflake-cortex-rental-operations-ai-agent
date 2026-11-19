-- =============================================================
-- Gold Layer | Semantic View over the reservations star schema
-- Purpose : business-friendly layer (metrics + dimensions + join paths)
--           for Cortex Analyst / SEMANTIC_VIEW() queries.
-- Prereq  : 01_gold_star_schema.sql (fact_reservations, dim_branches,
--           dim_cars, dim_customers, dim_countries, dim_currencies).
-- Rerun   : CREATE OR REPLACE SEMANTIC VIEW (metadata only, no data copy).
-- Design notes:
--   * Primary keys are declared here (Gold DTs have no PK constraints);
--     relationships need the referenced side to be a declared key.
--   * dim_branches is a role-playing dimension (pickup + return). Only the
--     PICKUP role is modelled (alias `branches`), so "Branch", "Country",
--     "Region" mean the pickup location (where revenue is booked; the fact's
--     currency always equals the pickup branch's currency).
--   * Country/Region come from dim_countries via a 2-hop path
--     reservations -> branches -> countries (the fact has no country_id).
--   * Deliberately NOT modelled, to keep exactly one join path per table:
--       dim_countries.currency_code -> dim_currencies (second path to currencies)
--       dim_cars.current_branch_id  -> dim_branches   (today's location, not rental-time)
--   * dim_customers is joined but exposes no dimensions (PII table).
--   * One-way rentals: row-level fact is_one_way (0/1), summed by the metric.
-- =============================================================

CREATE OR REPLACE SEMANTIC VIEW RENTAL_OPS.GOLD.avelto_semantic_view

  TABLES (
    reservations AS RENTAL_OPS.GOLD.fact_reservations
      PRIMARY KEY (id)
      WITH SYNONYMS = ('bookings', 'rentals')
      COMMENT = 'One row per BookWave rental reservation (2,000 rows).',
    branches AS RENTAL_OPS.GOLD.dim_branches
      PRIMARY KEY (id)
      WITH SYNONYMS = ('pickup branches', 'locations')
      COMMENT = 'Rental branches, used in the pickup-branch role.',
    cars AS RENTAL_OPS.GOLD.dim_cars
      PRIMARY KEY (id)
      WITH SYNONYMS = ('vehicles', 'fleet')
      COMMENT = 'Rental fleet with category and daily list rate.',
    customers AS RENTAL_OPS.GOLD.dim_customers
      PRIMARY KEY (id)
      COMMENT = 'Renting customers (PII; no dimensions exposed).',
    countries AS RENTAL_OPS.GOLD.dim_countries
      PRIMARY KEY (country_id)
      COMMENT = 'Countries Avelto operates in, with region.',
    currencies AS RENTAL_OPS.GOLD.dim_currencies
      PRIMARY KEY (currency_code)
      COMMENT = 'Payment currencies and their USD exchange rate.'
  )

  RELATIONSHIPS (
    reservation_pickup_branch AS reservations (pickup_branch_id) REFERENCES branches (id),
    reservation_car           AS reservations (car_id)           REFERENCES cars (id),
    reservation_customer      AS reservations (customer_id)      REFERENCES customers (id),
    reservation_currency      AS reservations (currency_code)    REFERENCES currencies (currency_code),
    branch_country            AS branches (country_id)           REFERENCES countries (country_id)
  )

  FACTS (
    reservations.is_one_way AS IFF(pickup_branch_id <> return_branch_id, 1, 0)
      COMMENT = '1 when the car is returned to a different branch than pickup, else 0.',
    reservations.amount_usd AS total_amount_usd
      COMMENT = 'Amount paid, converted to USD at the snapshot exchange rate.',
    reservations.rental_days AS total_days
      COMMENT = 'Rental length in days (end_date - start_date, 1-14).'
  )

  DIMENSIONS (
    countries.country AS country_name
      WITH SYNONYMS = ('country name', 'pickup country')
      COMMENT = 'Country of the pickup branch.',
    countries.region AS region
      WITH SYNONYMS = ('geography', 'continent')
      COMMENT = 'Region of the pickup branch: North America, Europe, Asia or Oceania.',
    branches.branch AS name
      WITH SYNONYMS = ('branch name', 'pickup branch', 'location')
      COMMENT = 'Name of the branch where the rental started.',
    cars.car_category AS category
      WITH SYNONYMS = ('category', 'vehicle class', 'car class')
      COMMENT = 'Car category: Economy, Compact, SUV, Luxury, Sports, Convertible.',
    currencies.currency AS currency_code
      WITH SYNONYMS = ('payment currency', 'currency code')
      COMMENT = 'ISO 4217 currency the customer paid in (always the pickup branch currency).'
  )

  METRICS (
    reservations.revenue_usd AS SUM(reservations.amount_usd)
      WITH SYNONYMS = ('revenue', 'sales', 'total revenue in USD')
      COMMENT = 'Revenue in USD. Never sum amount_local across currencies.',
    reservations.reservation_count AS COUNT(reservations.id)
      WITH SYNONYMS = ('number of reservations', 'bookings', 'rentals')
      COMMENT = 'Number of reservations.',
    reservations.avg_rental_days AS AVG(reservations.rental_days)
      WITH SYNONYMS = ('average rental length', 'average days rented')
      COMMENT = 'Average rental length in days.',
    reservations.one_way_rentals AS SUM(reservations.is_one_way)
      WITH SYNONYMS = ('one-way reservations', 'one way trips')
      COMMENT = 'Reservations whose return branch differs from the pickup branch.'
  )

  COMMENT = 'Avelto rental reservations: revenue, volume, rental length and one-way rentals by pickup geography, branch, car category and currency.';


-- -------------------------------------------------------------
-- Validation (run after creation)
-- -------------------------------------------------------------
-- 1) Metadata, no warehouse:
--    DESCRIBE SEMANTIC VIEW RENTAL_OPS.GOLD.avelto_semantic_view;
--    Expected: 6 tables, 5 relationships, 3 facts, 5 dimensions, 4 metrics.
--
-- 2) Totals must match the fact table (resumes warehouse once):
SELECT *
FROM SEMANTIC_VIEW(
  RENTAL_OPS.GOLD.avelto_semantic_view
  METRICS reservations.reservation_count, reservations.revenue_usd,
          reservations.avg_rental_days, reservations.one_way_rentals
);
--    Expected: reservation_count = 2000; revenue_usd = SUM(total_amount_usd)
--    from fact_reservations; one_way_rentals = COUNT_IF(pickup_branch_id <> return_branch_id).
--
-- 3) By dimension: the sum over regions must again equal 2000 (no fan-out, no lost rows):
--    SELECT * FROM SEMANTIC_VIEW(RENTAL_OPS.GOLD.avelto_semantic_view
--      DIMENSIONS countries.region METRICS reservations.reservation_count, reservations.revenue_usd)
--    ORDER BY revenue_usd DESC;
--    Expected: 4 rows (North America, Europe, Asia, Oceania), counts summing to 2000.

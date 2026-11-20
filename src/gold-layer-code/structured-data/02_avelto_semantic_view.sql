-- =============================================================
-- Gold Layer | Semantic View over the reservations star schema
--              + customer reviews + support tickets
-- Purpose : business-friendly layer (metrics + dimensions + join paths)
--           for Cortex Analyst / SEMANTIC_VIEW() queries.
-- Prereq  : 01_gold_star_schema.sql (fact_reservations, dim_branches,
--           dim_cars, dim_customers, dim_countries, dim_currencies);
--           semi-structured-data/01_support_tickets_enriched.sql and
--           02_reviews_enriched.sql (GOLD.support_tickets_enriched,
--           GOLD.reviews_enriched).
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
--       reviews.branch_id / car_id / customer_id      (second paths; see below)
--   * dim_customers is joined but exposes no dimensions (PII table).
--   * One-way rentals: row-level fact is_one_way (0/1), summed by the metric.
--   * Reviews and tickets (added 2026-11-20) join ONLY through
--     reservation_id -> reservations, and reach branch / country / car
--     category from there. Checked on the source files: all 1,400 reviews
--     have a reservation, and review.branch_id = reservation pickup branch,
--     review.car_id = reservation car in 1,400 / 1,400 rows, so nothing is
--     lost. 66 of 300 tickets have no reservation_id: they count in ticket
--     totals but fall into a NULL group when split by branch / country / car.
--   * Review and ticket dates are the date the review / ticket was written,
--     not the rental date. Reservations still have no date dimension.
--   * Only structured columns are exposed (rating, AI_SENTIMENT label,
--     categories, status). The review / ticket TEXT is not exposed here;
--     free-text questions need a search service (open item, doc 06 §5).
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
      COMMENT = 'Payment currencies and their USD exchange rate.',
    reviews AS RENTAL_OPS.GOLD.reviews_enriched
      PRIMARY KEY (review_id)
      WITH SYNONYMS = ('customer reviews', 'ratings', 'customer feedback')
      COMMENT = 'One row per customer review of a reservation (1,400 rows): star rating, language and AI_SENTIMENT label.',
    tickets AS RENTAL_OPS.GOLD.support_tickets_enriched
      PRIMARY KEY (ticket_id)
      WITH SYNONYMS = ('support tickets', 'support cases', 'customer service cases')
      COMMENT = 'One row per customer support ticket (300 rows). reservation_id is NULL for 66 tickets that name no reservation.'
  )

  RELATIONSHIPS (
    reservation_pickup_branch AS reservations (pickup_branch_id) REFERENCES branches (id),
    reservation_car           AS reservations (car_id)           REFERENCES cars (id),
    reservation_customer      AS reservations (customer_id)      REFERENCES customers (id),
    reservation_currency      AS reservations (currency_code)    REFERENCES currencies (currency_code),
    branch_country            AS branches (country_id)           REFERENCES countries (country_id),
    review_reservation        AS reviews (reservation_id)        REFERENCES reservations (id),
    ticket_reservation        AS tickets (reservation_id)        REFERENCES reservations (id)
  )

  FACTS (
    reservations.is_one_way AS IFF(pickup_branch_id <> return_branch_id, 1, 0)
      COMMENT = '1 when the car is returned to a different branch than pickup, else 0.',
    reservations.amount_usd AS total_amount_usd
      COMMENT = 'Amount paid, converted to USD at the snapshot exchange rate.',
    reservations.rental_days AS total_days
      COMMENT = 'Rental length in days (end_date - start_date, 1-14).',
    reviews.review_rating AS rating
      COMMENT = 'Star rating given by the customer, 1 (worst) to 5 (best).',
    reviews.is_negative AS IFF(sentiment = 'negative', 1, 0)
      COMMENT = '1 when AI_SENTIMENT labelled the review negative, else 0.',
    tickets.is_unresolved AS IFF(status <> 'Resolved', 1, 0)
      COMMENT = '1 when the ticket status is Open, In Progress or Escalated, else 0.'
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
      COMMENT = 'ISO 4217 currency the customer paid in (always the pickup branch currency).',
    reviews.review_sentiment AS sentiment
      WITH SYNONYMS = ('sentiment', 'review tone')
      COMMENT = 'AI_SENTIMENT label of the review: positive, negative, neutral, mixed or unknown.',
    reviews.star_rating AS rating
      WITH SYNONYMS = ('stars', 'rating')
      COMMENT = 'Star rating 1-5, for grouping or filtering (e.g. 1-star reviews).',
    reviews.review_language AS language
      COMMENT = 'Language the review was written in: en, de, es or fr.',
    reviews.review_date AS review_date
      COMMENT = 'Date the review was written (2023-08 to 2025-09). Not the rental date.',
    tickets.ticket_category AS category
      WITH SYNONYMS = ('ticket type', 'support category', 'reason for contact')
      COMMENT = 'Ticket category assigned in the support system (Billing Question, Vehicle Issue, Damage Claim, Refund Request, ...). Default ticket category.',
    tickets.ai_ticket_category AS ai_category
      COMMENT = 'Ticket category assigned by AI_CLASSIFY from the ticket text (same 8 labels). Use only when asked for the AI classification.',
    tickets.ticket_channel AS channel
      WITH SYNONYMS = ('contact channel', 'channel')
      COMMENT = 'How the customer contacted support: Email, Phone or Chat.',
    tickets.ticket_status AS status
      WITH SYNONYMS = ('status')
      COMMENT = 'Ticket status: Open, In Progress, Escalated or Resolved.',
    tickets.ticket_created_date AS created_date
      COMMENT = 'Date the ticket was opened (2023-08 to 2025-09). Not the rental date.'
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
      COMMENT = 'Reservations whose return branch differs from the pickup branch.',
    reviews.review_count AS COUNT(reviews.review_id)
      WITH SYNONYMS = ('number of reviews')
      COMMENT = 'Number of customer reviews.',
    reviews.avg_rating AS AVG(reviews.review_rating)
      WITH SYNONYMS = ('average rating', 'average stars', 'customer rating')
      COMMENT = 'Average star rating (1-5).',
    reviews.negative_reviews AS SUM(reviews.is_negative)
      WITH SYNONYMS = ('number of negative reviews', 'complaints in reviews')
      COMMENT = 'Reviews labelled negative by AI_SENTIMENT.',
    reviews.negative_review_share AS SUM(reviews.is_negative) / COUNT(reviews.review_id)
      WITH SYNONYMS = ('share of negative reviews', 'negative review rate')
      COMMENT = 'Negative reviews divided by all reviews (0-1).',
    tickets.ticket_count AS COUNT(tickets.ticket_id)
      WITH SYNONYMS = ('number of tickets', 'number of support tickets')
      COMMENT = 'Number of support tickets.',
    tickets.unresolved_tickets AS SUM(tickets.is_unresolved)
      WITH SYNONYMS = ('open tickets', 'unresolved support tickets', 'backlog')
      COMMENT = 'Tickets not yet Resolved (Open, In Progress or Escalated).'
  )

  COMMENT = 'Avelto rental operations: reservation revenue, volume, rental length and one-way rentals; customer review ratings and sentiment; support ticket volume, category and status. Grouped by pickup geography, branch, car category and currency.';


-- -------------------------------------------------------------
-- Validation (run after creation)
-- -------------------------------------------------------------
-- 1) Metadata, no warehouse:
--    DESCRIBE SEMANTIC VIEW RENTAL_OPS.GOLD.avelto_semantic_view;
--    Expected: 8 tables, 7 relationships, 6 facts, 14 dimensions, 10 metrics.
--
-- 2) Totals must match the source tables (resumes warehouse once):
SELECT *
FROM SEMANTIC_VIEW(
  RENTAL_OPS.GOLD.avelto_semantic_view
  METRICS reservations.reservation_count, reservations.revenue_usd,
          reservations.avg_rental_days, reservations.one_way_rentals
);
--    Expected: reservation_count = 2000; revenue_usd = 1,514,210.12;
--    avg_rental_days = 7.415; one_way_rentals = 1818 (unchanged from 2026-11-19).
SELECT *
FROM SEMANTIC_VIEW(
  RENTAL_OPS.GOLD.avelto_semantic_view
  METRICS reviews.review_count, reviews.avg_rating, reviews.negative_reviews,
          reviews.negative_review_share, tickets.ticket_count, tickets.unresolved_tickets
);
--    Expected: review_count = 1400; avg_rating = 3.689 (5164 / 1400);
--    negative_reviews = COUNT_IF(sentiment = 'negative') in GOLD.reviews_enriched;
--    ticket_count = 300; unresolved_tickets = 223 (300 - 77 Resolved).
--
-- 3) By branch (review + ticket + reservation metrics together): no fan-out.
--    SELECT * FROM SEMANTIC_VIEW(RENTAL_OPS.GOLD.avelto_semantic_view
--      DIMENSIONS branches.branch
--      METRICS reservations.reservation_count, reviews.review_count,
--              reviews.avg_rating, tickets.ticket_count)
--    ORDER BY branch;
--    Expected: 10 branches + 1 NULL row (tickets without reservation);
--    reservation_count sums to 2000, review_count to 1400, ticket_count to
--    300 (NULL row = 66 tickets, 0 reviews, 0 reservations).
--
-- 4) Ticket category split: 8 rows summing to 300
--    (Billing Question 49, Vehicle Issue 44, General Feedback 39, Account
--    Access 36, Damage Claim 36, Roadside Assistance 36, Refund Request 33,
--    Booking Change 27).
--    SELECT * FROM SEMANTIC_VIEW(RENTAL_OPS.GOLD.avelto_semantic_view
--      DIMENSIONS tickets.ticket_category METRICS tickets.ticket_count);

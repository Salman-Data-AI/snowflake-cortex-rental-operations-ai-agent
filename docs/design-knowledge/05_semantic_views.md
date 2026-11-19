# Semantic Views: a Business Layer over the Reservations Star Schema

What a Snowflake semantic view is, how `avelto_semantic_view` is built over the Gold star schema, the
modelling decisions (role-playing branches, multi-hop geography, one join path per table) and the
alternatives that were rejected. This is the first step of the "data questions" track; Cortex Analyst
and the Cortex Agent build on it later.

| | |
|---|---|
| **Applies to** | `RENTAL_OPS.GOLD.avelto_semantic_view` |
| **Implemented in** | `src/gold-layer-code/structured-data/02_avelto_semantic_view.sql` |
| **Built over** | `src/gold-layer-code/structured-data/01_gold_star_schema.sql`; column reference `docs/GOLD_LAYER_DOCUMENTATION.md` |
| **Companion docs** | `00_project_context.md` (map); `06_cortex_agent.md` (the Cortex Agent uses this view as its `analyst_reservations` tool) |
| **Status** | Created and validated 2026-11-19 (4 metrics, 5 dimensions; all totals match the fact table) |

**Last updated:** 2026-11-19 (semantic view created)

## Implementation map

| What | Object | File |
|---|---|---|
| Semantic view: 6 logical tables, 5 relationships, 3 facts, 5 dimensions, 4 metrics | `GOLD.avelto_semantic_view` | `src/gold-layer-code/structured-data/02_avelto_semantic_view.sql` |
| Underlying fact + dimensions (dynamic tables, suspended) | `GOLD.fact_reservations`, `GOLD.dim_branches`, `dim_cars`, `dim_customers`, `dim_countries`, `dim_currencies` | `src/gold-layer-code/structured-data/01_gold_star_schema.sql` |
| Validation queries (totals vs fact table, per-dimension sums) | — | end of `02_avelto_semantic_view.sql` |

---

## 1. What a semantic view is

A **semantic view** is a schema-level Snowflake object that stores *business meaning* on top of
physical tables. It holds no data. It records:

| Building block | Meaning | Example here |
|---|---|---|
| **Logical tables** | an alias for a physical table plus its primary key | `reservations` → `GOLD.fact_reservations`, PK `id` |
| **Relationships** | many-to-one join paths (foreign key → declared key) | `reservations (pickup_branch_id) REFERENCES branches (id)` |
| **Facts** | row-level values (not aggregated) | `is_one_way = IFF(pickup_branch_id <> return_branch_id, 1, 0)` |
| **Dimensions** | attributes you group or filter by | `countries.region` |
| **Metrics** | aggregates over facts, the numbers people ask for | `revenue_usd = SUM(amount_usd)` |
| **Synonyms / comments** | the words users use; read by Cortex Analyst when it writes SQL | "sales", "bookings", "vehicle class" |

It is queried with `SELECT * FROM SEMANTIC_VIEW(<view> DIMENSIONS … METRICS …)`. Snowflake works out
the joins from the relationships and aggregates the metrics at the grain of the requested dimensions.
The point is that a metric is defined **once** ("revenue is the sum of `total_amount_usd`, never of
`amount_local`"), so every query, dashboard and LLM-generated SQL gets the same answer.

Why it matters for this project: Cortex Analyst (natural-language → SQL) works far more reliably over
a semantic view than over raw tables, because the join paths, the correct revenue column and the
business vocabulary are spelled out instead of guessed.

**Alternatives considered:**
- *YAML semantic model file on a stage* (the older Cortex Analyst format). Rejected: semantic views are
  the current, first-class Snowflake object (governed with GRANTs, visible with SHOW/DESCRIBE, queryable
  from SQL, usable by Cortex Analyst and Agents); YAML files are the legacy path.
- *Plain SQL views per question.* Rejected: one view per question shape does not scale, and an LLM
  would still have to choose joins and columns itself.

---

## 2. What was modelled

### 2.1 Logical tables and relationships

```
                  customers (dim_customers)      cars (dim_cars) ── Car Category
                            ▲                         ▲
                 customer_id │                  car_id │
                            reservations (fact_reservations)
                 pickup_branch_id │          currency_code │
                            ▼                         ▼
    Branch ── branches (dim_branches)       currencies (dim_currencies) ── Currency
                            │ country_id
                            ▼
                 countries (dim_countries) ── Country, Region
```

| Relationship | From → To | Note |
|---|---|---|
| `reservation_pickup_branch` | `reservations.pickup_branch_id` → `branches.id` | pickup role only (§3.1) |
| `reservation_car` | `reservations.car_id` → `cars.id` | |
| `reservation_customer` | `reservations.customer_id` → `customers.id` | no dimensions exposed (PII) |
| `reservation_currency` | `reservations.currency_code` → `currencies.currency_code` | |
| `branch_country` | `branches.country_id` → `countries.country_id` | second hop: fact → branch → country |

Gold dynamic tables have no PRIMARY KEY constraints, so the keys are declared inside the semantic view
(`PRIMARY KEY (id)`). A relationship can only reference a declared key on the "one" side.

### 2.2 Facts, dimensions, metrics

| Kind | Name | Definition |
|---|---|---|
| Fact | `reservations.is_one_way` | `IFF(pickup_branch_id <> return_branch_id, 1, 0)` |
| Fact | `reservations.amount_usd` | `total_amount_usd` |
| Fact | `reservations.rental_days` | `total_days` |
| Dimension | Country `countries.country` | `country_name` |
| Dimension | Region `countries.region` | `region` |
| Dimension | Branch `branches.branch` | `name` |
| Dimension | Car Category `cars.car_category` | `category` |
| Dimension | Currency `currencies.currency` | `currency_code` |
| Metric | Revenue in USD `revenue_usd` | `SUM(amount_usd)` |
| Metric | Reservation Count `reservation_count` | `COUNT(id)` |
| Metric | Average Rental Days `avg_rental_days` | `AVG(rental_days)` |
| Metric | One-Way Rentals `one_way_rentals` | `SUM(is_one_way)` |

---

## 3. Decisions and alternatives (decision log)

### 3.1 Role-playing branch: model the pickup role only (2026-11-19)

`fact_reservations` references `dim_branches` twice (pickup and return). "Branch", "Country" and
"Region" in this view mean the **pickup** branch.
- **Why pickup:** revenue is booked at pickup. The fact's `currency_code` always equals the pickup
  branch's currency (Gold doc §4.1), so the currency and geography dimensions agree with each other.
- **Alternative (deferred, not rejected):** add `dim_branches` a second time under another alias
  (`return_branches`) with its own relationship from `return_branch_id`, and expose "Return Branch" /
  "Return Country". Not done because the request asked for one Branch dimension; it is a small additive
  change if return-side questions are needed.
- **Rejected:** two relationships from the fact to the *same* logical table: the view would have two
  join paths to `branches` and "Branch" would be ambiguous.

### 3.2 Country and Region come from `dim_countries` through the branch (2026-11-19)

The fact table has no `country_id`, so a direct fact → countries relationship is impossible. The path is
`reservations → branches → countries`, which semantic views support (multi-hop many-to-one).
- **Alternative:** use the denormalised `dim_branches.country_name` / `region` and skip `dim_countries`.
  Simpler (one hop), and gives identical numbers today. Rejected because the request named
  `dim_countries` as a dimension table and it is the master source for country attributes; the
  denormalised columns stay available if `dim_countries` is ever dropped from the view.

### 3.3 Exactly one join path per table (2026-11-19)

Two real foreign keys in the star schema are **deliberately left out** of the view:

| Left out | Why |
|---|---|
| `dim_countries.currency_code → dim_currencies` | would create a second path fact → … → currencies (via the branch's country). Two paths make "Currency" ambiguous. The payment currency (fact side) is the one revenue questions mean |
| `dim_cars.current_branch_id → dim_branches` | the car's location **today**, not at rental time; it would also create a second path to `branches` and silently attribute past revenue to wherever the car is parked now |

### 3.4 One-way rentals as a 0/1 fact, summed (2026-11-19)

- **Chosen:** row-level fact `is_one_way` and metric `SUM(is_one_way)`. Keeps the metric a plain
  aggregate over a named fact, and the flag is reusable (e.g. a later "one-way share" metric =
  `SUM(is_one_way) / COUNT(id)`).
- **Alternative:** `COUNT_IF(pickup_branch_id <> return_branch_id)` directly in the metric. Equivalent
  numbers; rejected only for reuse and readability.

### 3.5 Customers joined but not exposed (2026-11-19)

`dim_customers` is linked (so a later "Customer count" metric or age band can be added) but has no
dimensions: it holds PII (name, email, phone, licence number, date of birth). Exposing those to
Cortex Analyst would let natural-language queries return personal data.

### 3.6 Revenue uses `total_amount_usd` only

Summing `amount_local` across currencies is meaningless (yen + euros). The metric uses the USD column,
and its comment says so, so Cortex Analyst is steered away from `amount_local`. Caveat inherited from
Gold: exchange rates are one undated snapshot, so USD figures for past periods are approximate.

---

## 4. Validation results (2026-11-19)

Totals through the view equal direct aggregates on `fact_reservations`:

| Metric | Semantic view | Fact table directly |
|---|---|---|
| reservation_count | 2,000 | 2,000 |
| revenue_usd | 1,514,210.12 | 1,514,210.12 |
| avg_rental_days | 7.415 | 7.415 |
| one_way_rentals | 1,818 | 1,818 |

Per-dimension sums are 2,000 for region (Europe 812, North America 768, Oceania 216, Asia 204), country
(7 rows), car category (5 rows) and branch (10 rows): no fan-out, no lost rows. `DESCRIBE SEMANTIC VIEW`
shows 5 relationships, 3 facts, 5 dimensions, 4 metrics.

**Findings worth knowing before Cortex Analyst:**
- **91% of reservations are one-way** (1,818 / 2,000). The synthetic data assigns return branches almost
  at random; in real rental data one-way is a minority. Answers about one-way rentals will look odd but
  are faithful to the data.
- **Convertible has no reservations**: the 10 Convertible cars are the pilot fleet expansion
  (`is_new_fleet`), added after the booking history. A "by category" answer shows 5 categories, not 6.
- **Sports earns the most revenue** (633.8k USD from 427 rentals) though Luxury has more rentals (518).

### 4.1 First Cortex Analyst call (2026-11-19)

Question: *"What was total revenue in USD by country, ranked highest to lowest?"*, sent to the Cortex
Analyst REST API (`POST /api/v2/cortex/analyst/message`, body `semantic_view =
RENTAL_OPS.GOLD.AVELTO_SEMANTIC_VIEW`, request id `6a74faa2-dbdd-464a-a4d6-5924a2b79ebb`).

- Analyst restated the question ("… over the entire available time period") and generated
  `SELECT * FROM SEMANTIC_VIEW(… DIMENSIONS countries.country METRICS revenue_usd) ORDER BY revenue_usd DESC`.
  It picked the right dimension and the USD metric (not `amount_local`). No verified query was used.
- **Analyst only returns SQL; the caller runs it** on its own warehouse. The result matched the
  validation numbers exactly: US 426,260.00, Germany 293,730.14, Australia 181,000.00, Japan 159,760.00,
  France 156,490.14, UK 149,769.84, Canada 147,200.00 (sum 1,514,210.12).
- Second question: *"Which branches have the most one-way rentals, where the pickup and return branch
  are different?"* (request id `0a1aad6f-4a3a-4ceb-a974-01ddf87bb6ad`). Analyst used the `one_way_rentals`
  metric with `branches.branch` instead of rewriting the condition itself, so the synonyms and comments on
  the metric worked. Result: North Valerie 193 (top) down to Jordanville 162; equal to the validation query.
  The question is ambiguous (pickup or return branch?) and Analyst silently chose pickup, because that
  is the only branch role the view models (§3.1). It did not mention this in its restatement.
- Third question: *"At Jordanville Branch, which car categories are offered but have the fewest
  reservations?"* (request id `071bf979-3aeb-4ba3-9657-1a047bc6cb16`). Analyst returned
  `reservation_count` by `car_category` with `WHERE branches.branch = 'Jordanville Branch'`, ascending:
  Compact 16, Economy 40, Sports 40, SUV 41, Luxury 45. **It redefined "offered" as "has at least one
  reservation"** (and said so in its restatement), because availability
  (`GOLD.bridge_branch_category_availability`) is not in the view. A cross-check on the bridge table
  showed the answer happens to be right: Jordanville offers exactly those 5 categories, and Convertible
  (0 reservations) is not offered. At a branch where an offered category has 0 bookings, this answer
  would silently leave out the most important row. → open item in §5.
- The "entire time period" restatement reflects the missing time dimension (§5): Analyst cannot filter
  by date yet.
- **Auth used:** the `rental-dev` connection is password-based, and the snow CLI has no Analyst
  command. A stdlib-only Python helper logs in (`/session/v1/login-request`) to get a session token and
  sends it as `Authorization: Snowflake Token="…"`. The helper was a session scratch file, not in the repo.
  For anything lasting, key-pair JWT or a programmatic access token (PAT) is the supported route;
  creating either is an account change and needs approval.

---

## 5. Open items / next steps

| Item | Why it matters |
|---|---|
| **Time dimensions** (`start_date`, `booking_date`, month/year) | none are modelled yet, so "revenue last month" or "bookings by month" cannot be answered. Needed before Cortex Analyst |
| Category availability (`bridge_branch_category_availability`) | "offered but few/no bookings" questions need it (§4.1, third question). It is a branch × category grain, not a reservation grain, so it would join as its own logical table keyed on (branch_id, category_id) with an "offered" dimension; design not yet decided |
| Return-branch role (§3.1) | for "where do cars end up" questions |
| Verified queries / `AI_SQL_GENERATION` instructions | improve Cortex Analyst accuracy on known question shapes |
| Cortex Analyst evaluation | natural-language questions with expected SQL results, same discipline as the policy RAG eval (golden + held-out) |

---

## 6. Cost

Creating and describing a semantic view is metadata only (cloud services, ≈ 0 credits). Queries
through `SEMANTIC_VIEW()` run on the warehouse like any SELECT: the validation here was two warehouse
bursts (est. ≈ 0.04–0.06 cr). The underlying dynamic tables stay suspended; the view reads their last
refreshed contents.

-- =============================================================
-- Evaluation | Step 02: Golden dataset for policy retrieval
-- Prereq: evaluation/01_evaluation_schema.sql
-- Questions are written by hand from the source markdown in data/Unstructured/policy_documents/
-- (same text as RENTAL_OPS.BRONZE.bronze_policy_documents), NOT from model-generated text,
-- so the set stays independent of the doc2query step (v1).
-- Labels, from most to least chunking-dependent:
--   expected_chunk_ids      : every chunk that answers (hit = any of them). Valid for the current
--                             chunking only; ids are <document>_<chunk_index>.
--   expected_document_id +
--   expected_section_header : survive re-chunking while chunks stay header-based.
--   expected_evidence       : verbatim span(s) from the source document (each unique in the corpus).
--                             Survives any re-chunking: after one, re-derive expected_chunk_ids as the
--                             chunks whose chunk_text contains a span (see the last validation query).
--   expected_answer         : short reference answer, for answer-quality evaluation once the agent
--                             generates answers (Step 5).
-- Out-of-scope questions: is_answerable = FALSE, no document/section, empty chunk + evidence arrays.
-- Rerunnable (CREATE OR REPLACE): the script is the source of truth for the dataset.
-- =============================================================

CREATE OR REPLACE TABLE RENTAL_OPS.EVALUATION.policy_golden_questions (
    question_id             STRING        NOT NULL,   -- pq_NN
    question                STRING        NOT NULL,
    question_style          STRING        NOT NULL,   -- direct | paraphrase | casual | out_of_scope
    is_answerable           BOOLEAN       NOT NULL,
    expected_document_id    STRING,                   -- NULL for out-of-scope
    expected_section_header STRING,                   -- primary answering section; NULL for out-of-scope
    expected_chunk_ids      ARRAY         NOT NULL,   -- empty for out-of-scope
    expected_evidence       ARRAY         NOT NULL,   -- verbatim source spans; empty for out-of-scope
    expected_answer         STRING        NOT NULL,   -- reference answer
    notes                   STRING,
    dataset_version         STRING        NOT NULL,
    created_at              TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_policy_golden_questions PRIMARY KEY (question_id)
);

-- VALUES cannot hold ARRAY expressions, so arrays are passed as JSON text and parsed in the SELECT
INSERT INTO RENTAL_OPS.EVALUATION.policy_golden_questions
    (question_id, question, question_style, is_answerable, expected_document_id,
     expected_section_header, expected_chunk_ids, expected_evidence, expected_answer, notes, dataset_version)
SELECT column1, column2, column3, column4, column5, column6,
       PARSE_JSON(column7)::ARRAY, PARSE_JSON(column8)::ARRAY, column9, column10, 'gq_v1'
FROM VALUES
-- ---------- Cancellation & Refund Policy ----------
('pq_01', 'How much of my money do I get back if I cancel between 24 and 48 hours before pickup?',
 'direct', TRUE, 'cancellation_refund_policy', 'Standard Cancellations',
 '["cancellation_refund_policy_01"]',
 '["Reservations cancelled between 48 and 24 hours before pickup receive a 50% refund"]',
 'You receive a 50% refund if you cancel between 48 and 24 hours before pickup.',
 '50% refund tier'),
('pq_02', 'I booked a convertible and now I have to cancel, do I lose my deposit?',
 'casual', TRUE, 'cancellation_refund_policy', 'Category-Specific Notes',
 '["cancellation_refund_policy_02"]',
 '["This deposit is forfeited on any cancellation, regardless of timing"]',
 'Yes. Sports and Convertible bookings require a non-refundable $50 booking deposit, which is forfeited on any cancellation regardless of timing.',
 '$50 Sports/Convertible deposit'),
('pq_03', 'Will I be charged a fee if I move my booking to different dates?',
 'paraphrase', TRUE, 'cancellation_refund_policy', 'Modifications',
 '["cancellation_refund_policy_03"]',
 '["does not trigger cancellation fees, provided the change is made more than 24 hours before the original pickup time"]',
 'No. Changing dates or branch is not a cancellation and has no fee if it is made more than 24 hours before the original pickup time and the new dates are available.',
 'Policy says "modification", user says "move my booking"'),
('pq_04', 'I''m bringing the car back 3 days early on a 10-day rental, do I get any money back?',
 'casual', TRUE, 'cancellation_refund_policy', 'Early Returns',
 '["cancellation_refund_policy_04"]',
 '["eligible for a pro-rated refund of unused full days beyond the 7-day mark"]',
 'Yes, partly. Early returns normally get no refund, but rentals of 7 days or longer get a pro-rated refund of the unused full days beyond the 7-day mark.',
 'Pro-rated refund beyond day 7'),
-- ---------- Standard Rental Agreement Terms ----------
('pq_05', 'What happens if I return the car more than an hour late?',
 'casual', TRUE, 'rental_agreement_terms', '3. Rental Period and Daily Rates',
 '["rental_agreement_terms_03"]',
 '["returns more than 59 minutes past the agreed return time are billed as an additional full day"]',
 'Returns more than 59 minutes past the agreed return time are billed as an additional full day.',
 'Known failure: "an hour late" vs "59 minutes past the agreed return time"'),
('pq_06', 'What is the minimum age to rent a car, and how long do I need to have had my license?',
 'direct', TRUE, 'rental_agreement_terms', '1. Eligibility',
 '["rental_agreement_terms_01"]',
 '["Renters must be at least 21 years old and hold a valid driver''s license that has been active for a minimum of 12 months"]',
 'You must be at least 21 and have held a valid driver''s license for at least 12 months.',
 'Region chunks (US, Australia) restate 21+; Eligibility is the canonical answer'),
('pq_07', 'Is there a charge if I bring the car back with less fuel than when I picked it up?',
 'paraphrase', TRUE, 'rental_agreement_terms', '4. Fuel Policy',
 '["rental_agreement_terms_04"]',
 '["Vehicles returned with less than a full tank are charged a refueling service fee plus the cost of missing fuel at local pump price"]',
 'Yes. Cars returned with less than a full tank are charged a refueling service fee plus the missing fuel at the local pump price.',
 NULL),
('pq_08', 'Can I drive as much as I want in a sports car or is there a mileage cap?',
 'casual', TRUE, 'rental_agreement_terms', '5. Mileage',
 '["rental_agreement_terms_05"]',
 '["Luxury, Sports, and Convertible categories include 200 miles/day, with excess mileage billed at $0.45/mile"]',
 'Sports cars include 200 miles per day; extra miles are billed at $0.45 per mile.',
 NULL),
('pq_09', 'Am I allowed to use the rental car to drive for Uber?',
 'casual', TRUE, 'rental_agreement_terms', '6. Prohibited Use',
 '["rental_agreement_terms_06"]',
 '["Vehicles may not be used for: commercial ride-sharing or delivery services"]',
 'No. Commercial ride-sharing and delivery use is prohibited and voids the insurance coverage.',
 'Brand name vs policy term "commercial ride-sharing"'),
-- ---------- Insurance & Damage Waiver Policy ----------
('pq_10', 'How much does the Collision Damage Waiver cost per day for an SUV?',
 'direct', TRUE, 'insurance_damage_waiver', '2. Collision Damage Waiver (CDW)',
 '["insurance_damage_waiver_02"]',
 '["SUV $16/day"]',
 'CDW for an SUV costs $16 per day, with a $500 deductible.',
 NULL),
('pq_11', 'Someone stole my rental car, what do I need to do?',
 'casual', TRUE, 'insurance_damage_waiver', '5. Theft',
 '["insurance_damage_waiver_05"]',
 '["the customer must file a police report within 24 hours and provide the report reference number to Avelto Rentals"]',
 'File a police report within 24 hours and give the report reference number to Avelto Rentals.',
 NULL),
('pq_12', 'How soon after an accident do I have to let you know about damage to the car?',
 'paraphrase', TRUE, 'insurance_damage_waiver', '3. Filing a Damage Claim',
 '["insurance_damage_waiver_03"]',
 '["the customer must report it to Avelto Rentals within 24 hours"]',
 'Within 24 hours, at the return branch or through Support.',
 NULL),
-- ---------- Driving Rules by Region ----------
('pq_13', 'Are winter tires required when renting in Canada?',
 'direct', TRUE, 'driving_rules_by_region', 'Canada (branch: West Kristinaside)',
 '["driving_rules_by_region_02"]',
 '["Winter tires are mandatory on all vehicles from December 1 through March 31"]',
 'Yes, from December 1 through March 31; they are fitted automatically at no extra cost.',
 NULL),
('pq_14', 'Can I rent a car in Japan with just my American license?',
 'casual', TRUE, 'driving_rules_by_region', 'Japan (branch: Juarezview)',
 '["driving_rules_by_region_06"]',
 '["An International Driving Permit (1949 Geneva Convention format) is required for all non-Japanese-licensed renters"]',
 'No. Non-Japanese-licensed renters also need an International Driving Permit in the 1949 Geneva Convention format.',
 NULL),
('pq_15', 'What extra fee do I pay for tolls I didn''t pay during a US rental?',
 'paraphrase', TRUE, 'driving_rules_by_region', 'United States (branches: South Eric, Jordanville, Suttonburgh)',
 '["driving_rules_by_region_01"]',
 '["unpaid tolls are billed to the card on file plus a $15 administrative fee per toll event"]',
 'Unpaid tolls are billed to your card on file plus a $15 administrative fee per toll event.',
 NULL),
-- ---------- Loyalty Program FAQ (single chunk) ----------
('pq_16', 'How many Avelto Miles points do I earn for each day I rent?',
 'direct', TRUE, 'loyalty_program_faq', 'Overview',
 '["loyalty_program_faq_00"]',
 '["Members earn 10 points per day rented, regardless of category"]',
 '10 points per day rented, in any category (plus 500 bonus points per completed one-way rental).',
 'Whole FAQ is one chunk'),
('pq_17', 'Do my reward points ever run out?',
 'casual', TRUE, 'loyalty_program_faq', 'Overview',
 '["loyalty_program_faq_00"]',
 '["Points expire after 24 months of account inactivity (no rentals or point redemptions)"]',
 'Yes, points expire after 24 months with no rentals or point redemptions.',
 '"reward points" vs "Avelto Miles"'),
-- ---------- Roadside Assistance Guide ----------
('pq_18', 'My car won''t start and I''m stuck on the side of the road, who do I call?',
 'casual', TRUE, 'roadside_assistance_guide', 'When to Contact Roadside Assistance',
 '["roadside_assistance_guide_01", "roadside_assistance_guide_02"]',
 '["Contact Roadside Assistance for: flat tires, dead batteries, lockouts, mechanical breakdowns", "Contact Support via phone, chat, or email with your reservation number and current location"]',
 'Contact Roadside Assistance via Support (phone, chat or email; phone 24/7) with your reservation number and location. It is free unless caused by misuse.',
 'When-to-contact and What-to-do both answer'),
('pq_19', 'How long does it take for roadside assistance to arrive?',
 'direct', TRUE, 'roadside_assistance_guide', 'Response Times',
 '["roadside_assistance_guide_03"]',
 '["Standard response time is 60–90 minutes in metro areas covered by our 10 branches, and up to 3 hours in more remote pickup/return locations"]',
 '60-90 minutes in metro areas and up to 3 hours in remote locations; Platinum members get priority dispatch.',
 NULL),
('pq_20', 'If my car can''t be fixed where it broke down, will I get another vehicle?',
 'paraphrase', TRUE, 'roadside_assistance_guide', 'Replacement Vehicles',
 '["roadside_assistance_guide_04"]',
 '["Avelto Rentals will arrange a replacement vehicle in the same category where available"]',
 'Yes, a replacement in the same category where available, otherwise the next closest category with a partial refund of the rate difference.',
 NULL),
('pq_21', 'Is towing included if the car breaks down?',
 'direct', TRUE, 'roadside_assistance_guide', 'Towing',
 '["roadside_assistance_guide_05", "insurance_damage_waiver_04"]',
 '["Towing to the nearest Avelto branch or approved partner garage is included", "including towing to the nearest Avelto branch or partner garage"]',
 'Yes, towing to the nearest Avelto branch or approved partner garage is included; towing elsewhere is billed at cost.',
 'Insurance section 4 also states towing is covered'),
-- ---------- Out of scope (no answer in the corpus) ----------
('pq_22', 'Can I bring my dog in the rental car?',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]',
 'Not covered by the policy documents.', 'Pets not covered; may pull Return Condition (cleaning fee)'),
('pq_23', 'Do you offer child car seats?',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]',
 'Not covered by the policy documents.', 'Equipment add-ons not covered'),
('pq_24', 'What are the opening hours of the Davidstad branch?',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]',
 'Not covered by the policy documents.', 'Branch is named in the corpus (France chunk), hours are not'),
('pq_25', 'Do you have electric cars and where can I charge them?',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]',
 'Not covered by the policy documents.', 'EVs not covered; may pull France ZFE / emissions-class text');

-- Validate: expect 25 rows (21 answerable, 4 out-of-scope); answerable rows need chunk ids AND evidence
SELECT question_style,
       COUNT(*)                                                         AS questions,
       COUNT_IF(is_answerable)                                          AS answerable,
       COUNT_IF(is_answerable AND (ARRAY_SIZE(expected_chunk_ids) = 0
                                OR ARRAY_SIZE(expected_evidence) = 0)) AS answerable_missing_label
FROM RENTAL_OPS.EVALUATION.policy_golden_questions
GROUP BY question_style
ORDER BY question_style;

-- Validate: chunk ids derived from evidence spans = hand-labelled chunk ids (expect 0 rows).
-- After any re-chunking, the derived_chunk_ids column of this query is the new label.
WITH spans AS (   -- flatten first: a LATERAL cannot sit on the left side of a join
    SELECT q.question_id, e.value::STRING AS span
    FROM RENTAL_OPS.EVALUATION.policy_golden_questions q,
         LATERAL FLATTEN(INPUT => q.expected_evidence) e
),
derived AS (
    SELECT s.question_id,
           ARRAY_AGG(DISTINCT c.chunk_id) WITHIN GROUP (ORDER BY c.chunk_id) AS derived_chunk_ids
    FROM spans s
    LEFT JOIN RENTAL_OPS.GOLD.policy_document_chunks c
           ON CONTAINS(c.chunk_text, s.span)
    GROUP BY s.question_id
)
SELECT q.question_id, q.expected_chunk_ids, d.derived_chunk_ids
FROM RENTAL_OPS.EVALUATION.policy_golden_questions q
JOIN derived d USING (question_id)
WHERE NOT (ARRAY_SORT(q.expected_chunk_ids) = d.derived_chunk_ids);

-- =============================================================
-- Evaluation | Step 09: Held-out set for calibration (Phase 2a, ho_tickets_v1)
--                       + view policy_eval_questions (golden + held-out, used by the eval procedure)
-- Prereq: evaluation/01_ ... 02_
-- Purpose: check on queries NOT written while looking at the pipeline whether the rank-1 score
--   separates answerable from out-of-scope queries the way it does on the golden set (v1b:
--   min answerable hit -5.83 > max out-of-scope -6.54). Calibration choices are judged here;
--   the golden set stays the regression check.
-- Source (no hand-written questions): one verbatim instance of every support-ticket template
--   (data/Unstructured/support_tickets.csv: 300 tickets = 15 templates) and of the review templates
--   that a policy lookup could plausibly serve (data/Unstructured/reviews.csv: 32 templates; purely
--   positive ones skipped). Only edit: names, e-mail addresses and phone numbers removed
--   (reservation numbers kept). Non-English reviews are kept as written (de, fr).
-- Labels follow the golden-set rules (evidence spans verbatim from the policy documents, each
--   unique in the corpus; expected_chunk_ids re-derivable from them, see the last validation).
--   answerable   = some policy text states a rule that addresses the customer's specific situation.
--   out-of-scope = no such rule (account access, duplicate / unknown charges, feedback on service,
--                  cleanliness at pickup); several are near-misses on refunds, billing or pickup.
--   Tickets are requests, not questions; they are used as the query unchanged, as an agent would
--   receive them.
-- question_style: ticket | review for answerable, out_of_scope otherwise (keeps the summary view's
--   per-style rows comparable with the golden set). question_ids use the prefix ho_.
-- Rerunnable (CREATE OR REPLACE). dataset_version = ho_tickets_v1 (22 queries: 14 answerable, 8 OOS).
-- =============================================================

CREATE OR REPLACE TABLE RENTAL_OPS.EVALUATION.policy_holdout_questions (
    question_id             STRING        NOT NULL,   -- ho_NN
    question                STRING        NOT NULL,   -- verbatim source text, PII removed
    question_style          STRING        NOT NULL,   -- ticket | review | out_of_scope
    is_answerable           BOOLEAN       NOT NULL,
    expected_document_id    STRING,
    expected_section_header STRING,                   -- primary answering section
    expected_chunk_ids      ARRAY         NOT NULL,   -- valid for chunking_version c2_structure
    expected_evidence       ARRAY         NOT NULL,   -- verbatim policy spans
    expected_answer         STRING        NOT NULL,
    source_type             STRING        NOT NULL,   -- support_ticket | review
    source_id               STRING        NOT NULL,   -- ticket_id / review_id of the instance used
    source_category         STRING,                   -- ticket category (tickets only)
    language                STRING        NOT NULL,
    notes                   STRING,
    dataset_version         STRING        NOT NULL,
    created_at              TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_policy_holdout_questions PRIMARY KEY (question_id)
);

INSERT INTO RENTAL_OPS.EVALUATION.policy_holdout_questions
    (question_id, question, question_style, is_answerable, expected_document_id, expected_section_header,
     expected_chunk_ids, expected_evidence, expected_answer, source_type, source_id, source_category,
     language, notes, dataset_version)
SELECT column1, column2, column3, column4, column5, column6,
       PARSE_JSON(column7), PARSE_JSON(column8), column9, column10, column11, column12,
       column13, column14, 'ho_tickets_v1'
FROM VALUES
-- ---------- Support tickets: answerable ----------
('ho_01', 'My driver''s license on file is expired, I uploaded a new one - can someone confirm it''s been updated?',
 'ticket', TRUE, 'rental_agreement_terms', '1. Eligibility',
 '["rental_agreement_terms_01"]',
 '["A valid driver''s license number and date of birth must be on file before pickup"]',
 'A valid license must be on file before pickup (and active for at least 12 months); Support confirms the update.',
 'support_ticket', '13', 'Account Access', 'en', 'Action is operational; the policy gives the rule behind it'),
('ho_02', 'Can I change the return branch for reservation #248? Let me know what''s possible, thanks.',
 'ticket', TRUE, 'cancellation_refund_policy', 'Modifications',
 '["cancellation_refund_policy_03", "rental_agreement_terms_02"]',
 '["Changing pickup/return dates or branch does not count as a cancellation", "a vehicle may be picked up at one branch and returned to a different branch"]',
 'Yes: a branch change made more than 24 hours before pickup is free of cancellation fees; a different return branch is a one-way rental with a repositioning fee.',
 'support_ticket', '20', 'Booking Change', 'en', NULL),
('ho_03', 'I need to extend reservation #1254 by two days. Please confirm availability.',
 'ticket', TRUE, 'cancellation_refund_policy', 'Modifications',
 '["cancellation_refund_policy_03"]',
 '["provided the change is made more than 24 hours before the original pickup time and the new dates are confirmed as available"]',
 'Date changes are modifications, not cancellations, if made more than 24 hours before pickup and the new dates are available.',
 'support_ticket', '26', 'Booking Change', 'en', 'Policy covers changes before pickup; an extension mid-rental is implied, not explicit'),
('ho_04', 'Filing a damage report for reservation #799 - a small scratch on the rear bumper of the Nissan Altima was already there at pickup.',
 'ticket', TRUE, 'insurance_damage_waiver', '3. Filing a Damage Claim',
 '["insurance_damage_waiver_03"]',
 '["Claims for damage present at pickup but not noted on the digital inspection form should reference the original pickup inspection timestamp"]',
 'Reference the original pickup inspection timestamp; include the reservation number, a description and photos.',
 'support_ticket', '10', 'Damage Claim', 'en', NULL),
('ho_05', 'We were involved in a minor parking-lot incident during reservation #306. Please send the claim form.',
 'ticket', TRUE, 'insurance_damage_waiver', '3. Filing a Damage Claim',
 '["insurance_damage_waiver_03"]',
 '["the customer must report it to Avelto Rentals within 24 hours"]',
 'Report within 24 hours at the return branch or via Support, with reservation number, damage description and photos.',
 'support_ticket', '29', 'Damage Claim', 'en', NULL),
('ho_06', 'Requesting a refund for reservation #N/A since we had to cancel due to a flight delay.',
 'ticket', TRUE, 'cancellation_refund_policy', 'Standard Cancellations',
 '["cancellation_refund_policy_01"]',
 '["Reservations cancelled between 48 and 24 hours before pickup receive a 50% refund"]',
 'Depends on timing: full refund > 48 h before pickup, 50% between 48 and 24 h, none < 24 h or no-show; a flight delay is not an exception.',
 'support_ticket', '7', 'Refund Request', 'en', NULL),
('ho_07', 'The Mercedes C-Class we received didn''t match what we booked, requesting partial refund for reservation #1623.',
 'ticket', TRUE, 'cancellation_refund_policy', 'Refunds for Service Issues',
 '["cancellation_refund_policy_05"]',
 '["If Avelto Rentals cannot provide the reserved category at pickup and no comparable upgrade is available"]',
 'If the reserved category could not be provided and no comparable upgrade was available: full refund plus 1,000 Avelto Miles.',
 'support_ticket', '24', 'Refund Request', 'en', NULL),
('ho_08', 'The Honda Civic won''t start after our overnight stop (reservation #N/A). Need roadside support ASAP.',
 'ticket', TRUE, 'roadside_assistance_guide', 'When to Contact Roadside Assistance',
 '["roadside_assistance_guide_01"]',
 '["Contact Roadside Assistance for: flat tires, dead batteries, lockouts, mechanical breakdowns"]',
 'Covered by Roadside Assistance at no charge (dead battery / breakdown); phone is fastest overnight.',
 'support_ticket', '28', 'Roadside Assistance', 'en', NULL),
('ho_09', 'We have a flat tire with the Jeep Grand Cherokee from reservation #899, currently stopped safely. Please send help.',
 'ticket', TRUE, 'roadside_assistance_guide', 'When to Contact Roadside Assistance',
 '["roadside_assistance_guide_01"]',
 '["Contact Roadside Assistance for: flat tires, dead batteries, lockouts, mechanical breakdowns"]',
 'Flat tires are covered by Roadside Assistance; response 60-90 minutes in metro areas.',
 'support_ticket', '21', 'Roadside Assistance', 'en', 'Same evidence span as ho_08'),
('ho_10', 'The Porsche 911 I picked up under reservation #1902 has a check-engine light on. Please advise.',
 'ticket', TRUE, 'insurance_damage_waiver', '4. Roadside and Mechanical Issues',
 '["insurance_damage_waiver_04", "roadside_assistance_guide_01"]',
 '["Mechanical failures not caused by customer misuse are covered under the Roadside Assistance Guide", "Contact Roadside Assistance for: flat tires, dead batteries, lockouts, mechanical breakdowns"]',
 'Mechanical issues not caused by misuse are covered via Roadside Assistance at no cost; do not attempt repairs.',
 'support_ticket', '1', 'Vehicle Issue', 'en', 'Warning light, not yet a breakdown: weakest answerable label'),
('ho_11', 'There''s a strange rattling noise coming from the Honda Civic (reservation #1295). Can I get a replacement vehicle?',
 'ticket', TRUE, 'roadside_assistance_guide', 'Replacement Vehicles',
 '["roadside_assistance_guide_04"]',
 '["Avelto Rentals will arrange a replacement vehicle in the same category where available"]',
 'If the issue cannot be resolved roadside, a same-category replacement is arranged where available (else next closest category with partial refund).',
 'support_ticket', '22', 'Vehicle Issue', 'en', NULL),
-- ---------- Reviews: answerable ----------
('ho_12', 'Overcharged for extra days we didn''t take. Adamstad Branch needs to fix their billing process.',
 'review', TRUE, 'cancellation_refund_policy', 'Early Returns',
 '["cancellation_refund_policy_04"]',
 '["Returning a vehicle before the agreed end date does not generate a partial refund for the unused days"]',
 'Unused days after an early return are not refunded, except pro-rated days beyond 7 for rentals of 7+ days.',
 'review', '19', NULL, 'en', 'Interpreted as an early return; could also be a billing error'),
('ho_13', 'The Nissan Altima had less than a quarter tank at pickup and staff at South Eric Branch were not very helpful about it.',
 'review', TRUE, 'rental_agreement_terms', '4. Fuel Policy',
 '["rental_agreement_terms_04", "rental_agreement_terms_02"]',
 '["Vehicles are provided with a full tank and must be returned full", "Renters should confirm the fuel level matches the agreement before leaving the lot"]',
 'Vehicles should be provided full; renters should confirm the fuel level matches the agreement before leaving.',
 'review', '174', NULL, 'en', NULL),
('ho_14', 'The Nissan Altima broke down halfway through our rental period. Very frustrating experience with Jordanville Branch.',
 'review', TRUE, 'roadside_assistance_guide', 'Replacement Vehicles',
 '["roadside_assistance_guide_04", "roadside_assistance_guide_01"]',
 '["If a breakdown cannot be resolved roadside", "Contact Roadside Assistance for: flat tires, dead batteries, lockouts, mechanical breakdowns"]',
 'Breakdowns are covered by Roadside Assistance; if unresolved, a replacement vehicle is arranged.',
 'review', '48', NULL, 'en', NULL),
-- ---------- Out-of-scope (tickets) ----------
('ho_15', 'I can''t log into my Avelto account anymore. Can you help me reset access?',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]', 'Not covered by the policy documents.',
 'support_ticket', '8', 'Account Access', 'en', 'Near-miss: FAQ mentions the customer portal'),
('ho_16', 'I was charged twice for reservation #546. Please refund the duplicate charge.',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]', 'Not covered by the policy documents.',
 'support_ticket', '5', 'Billing Question', 'en', 'Near-miss: refund process exists, duplicate charges are not addressed'),
('ho_17', 'I don''t recognize a charge on my card related to reservation #103. Can someone call me back?',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]', 'Not covered by the policy documents.',
 'support_ticket', '17', 'Billing Question', 'en', 'Near-miss: several fees exist, none identified'),
('ho_18', 'Suggestion: it would help to have a mobile check-in option, would have made reservation #1108 even faster.',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]', 'Not covered by the policy documents.',
 'support_ticket', '2', 'General Feedback', 'en', 'Feedback'),
-- ---------- Out-of-scope (reviews) ----------
('ho_19', 'Leider war der Ferrari 488 bei Abholung nicht richtig gereinigt. West Kristinaside Branch sollte das verbessern.',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]', 'Not covered by the policy documents.',
 'review', '34', NULL, 'de', 'Near-miss (German): cleaning fees apply to returns, not to cleanliness at pickup'),
('ho_20', 'Rental was fine overall, though the North Valerie Branch location was hard to find and parking was tight.',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]', 'Not covered by the policy documents.',
 'review', '15', NULL, 'en', 'Feedback'),
('ho_21', 'Long wait at Davidstad Branch to pick up our Sports car, and the interior wasn''t very clean.',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]', 'Not covered by the policy documents.',
 'review', '4', NULL, 'en', 'Near-miss: pickup and cleaning wording'),
('ho_22', 'Un peu déçu par le service à West Kristinaside Branch, l''attente était longue pour récupérer la Toyota Corolla.',
 'out_of_scope', FALSE, NULL, NULL, '[]', '[]', 'Not covered by the policy documents.',
 'review', '172', NULL, 'fr', 'Feedback (French)');

-- One view over both question sets: the eval procedure and summary view read this.
-- question_set = golden | holdout; question_ids are unique across sets (pq_ / ho_).
CREATE OR REPLACE VIEW RENTAL_OPS.EVALUATION.policy_eval_questions AS
SELECT 'golden' AS question_set, question_id, question, question_style, is_answerable,
       expected_document_id, expected_section_header, expected_chunk_ids, expected_evidence,
       expected_answer, dataset_version
FROM RENTAL_OPS.EVALUATION.policy_golden_questions
UNION ALL
SELECT 'holdout', question_id, question, question_style, is_answerable,
       expected_document_id, expected_section_header, expected_chunk_ids, expected_evidence,
       expected_answer, dataset_version
FROM RENTAL_OPS.EVALUATION.policy_holdout_questions;

-- Validate 1: expect 22 rows: ticket 11, review 3, out_of_scope 8; answerable_missing_label 0
SELECT question_style,
       COUNT(*)                                                         AS questions,
       COUNT_IF(is_answerable)                                          AS answerable,
       COUNT_IF(is_answerable AND (ARRAY_SIZE(expected_chunk_ids) = 0
                                OR ARRAY_SIZE(expected_evidence) = 0)) AS answerable_missing_label
FROM RENTAL_OPS.EVALUATION.policy_holdout_questions
GROUP BY question_style
ORDER BY question_style;

-- Validate 2: every evidence span occurs in exactly one Gold chunk (expect 0 rows)
WITH spans AS (
    SELECT q.question_id, e.value::STRING AS span
    FROM RENTAL_OPS.EVALUATION.policy_holdout_questions q,
         LATERAL FLATTEN(INPUT => q.expected_evidence) e
)
SELECT s.question_id, s.span, COUNT(c.chunk_id) AS matching_chunks
FROM spans s
LEFT JOIN RENTAL_OPS.GOLD.policy_document_chunks c ON CONTAINS(c.chunk_text, s.span)
GROUP BY ALL
HAVING COUNT(c.chunk_id) <> 1;

-- Validate 3: chunk ids derived from evidence spans = labelled chunk ids (expect 0 rows)
WITH spans AS (
    SELECT q.question_id, e.value::STRING AS span
    FROM RENTAL_OPS.EVALUATION.policy_holdout_questions q,
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
FROM RENTAL_OPS.EVALUATION.policy_holdout_questions q
JOIN derived d USING (question_id)
WHERE NOT (ARRAY_SORT(q.expected_chunk_ids) = d.derived_chunk_ids);

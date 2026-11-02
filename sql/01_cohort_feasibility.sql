-- =====================================================================================
-- 01_cohort_feasibility.sql
-- Exploratory feasibility: Type 2 diabetes (T2DM) -> incident chronic kidney disease (CKD)
-- on the synthetic Synthea-derived OMOP CDM v5.4 database (schema: cdm).
--
-- NON-DESTRUCTIVE. The script contains only SELECT statements plus CREATE TEMP TABLE
-- (PostgreSQL does not allow temp tables inside a READ ONLY transaction), and runs in a
-- transaction that is rolled back at the end: no CDM table is touched, no results.cohort
-- table is created, and the only objects are session-local TEMP tables, dropped on
-- rollback. Nothing here chooses a drug comparator or fits a model.
--
-- Run (any client that sends the file statement by statement, e.g. psql):
--   psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -f sql/01_cohort_feasibility.sql
-- Each result set starts with a `section` column that labels it.
--
-- DATA CAVEAT: the data are synthetic (Synthea). Counts and timings below describe the
-- simulator's disease modules and sampling, not real-world epidemiology. Do not read any
-- association here as clinical or real-world evidence.
--
-- COHORT LOGIC AND ASSUMPTIONS
--  * T2DM concept set  = verified standard concept + all descendants (concept_ancestor).
--    Complication concepts such as "Neuropathy due to type 2 diabetes mellitus" and
--    "Prediabetes" are NOT descendants of the T2DM concept in this vocabulary and are
--    therefore excluded; section 1 lists them so the exclusion is visible.
--  * Index date        = first condition_occurrence_start_date of any T2DM-set concept.
--  * Analysis population (index_pop) = indexed patients whose index date falls inside an
--    observation_period. If several periods contain it, the earliest-starting one is used.
--    Patients with an index date outside any observation period cannot be followed and are
--    counted separately in section 2.
--  * Prior observation = index date - observation_period_start_date (days).
--  * Age at index      = (index date - birth date) / 365.25, using birth_datetime when
--    present, else year/month/day_of_birth with missing month/day taken as July / 1st.
--  * Early drug window = drug_exposure_start_date in [index, index + 90 days]. Ingredients
--    are standard RxNorm / RxNorm Extension concepts of class 'Ingredient' found through
--    concept_ancestor. Combination products count once under each ingredient. Quantity,
--    days_supply and dose are deliberately NOT used (flagged unsuitable by DQD).
--  * CKD concept set   = verified standard CKD concept + all descendants. PREVALENT CKD =
--    any CKD record on or before the index date. INCIDENT CKD = first CKD record strictly
--    after the index date, counted only among patients with no CKD on or before index
--    (the "at-risk" group). Prevalent and incident are always reported separately.
--  * Potential follow-up = observation_period_end_date - index date (days).
-- =====================================================================================

BEGIN;

-- -------------------------------------------------------------------------------------
-- 0. Verify the hard-coded anchor concepts against cdm.concept before using them.
--    Candidates were found by the name/usage queries in section 1; the script aborts if
--    their vocabulary metadata is not what was verified.
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE feas_anchor (role text, concept_id integer, expected_name text);
INSERT INTO feas_anchor VALUES
  ('T2DM', 201826,   'Type 2 diabetes mellitus'),
  ('CKD',  46271022, 'Chronic kidney disease');

DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(a.role || ' ' || a.concept_id, ', ') INTO bad
  FROM feas_anchor a
  LEFT JOIN cdm.concept c
         ON c.concept_id = a.concept_id
        AND c.concept_name = a.expected_name
        AND c.domain_id = 'Condition'
        AND c.vocabulary_id = 'SNOMED'
        AND c.standard_concept = 'S'
        AND c.invalid_reason IS NULL
  WHERE c.concept_id IS NULL;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'Anchor concept metadata check failed for: %', bad;
  END IF;
END $$;

CREATE TEMP TABLE t2dm_concepts AS
SELECT c.concept_id, c.concept_name, c.vocabulary_id, c.standard_concept, c.invalid_reason
FROM cdm.concept_ancestor ca
JOIN cdm.concept c ON c.concept_id = ca.descendant_concept_id
WHERE ca.ancestor_concept_id = (SELECT concept_id FROM feas_anchor WHERE role = 'T2DM');

CREATE TEMP TABLE ckd_concepts AS
SELECT c.concept_id, c.concept_name, c.vocabulary_id, c.standard_concept, c.invalid_reason
FROM cdm.concept_ancestor ca
JOIN cdm.concept c ON c.concept_id = ca.descendant_concept_id
WHERE ca.ancestor_concept_id = (SELECT concept_id FROM feas_anchor WHERE role = 'CKD');

CREATE TEMP TABLE cond_usage AS
SELECT condition_concept_id AS concept_id, COUNT(*) AS n_records, COUNT(DISTINCT person_id) AS n_patients
FROM cdm.condition_occurrence
GROUP BY condition_concept_id;

-- -------------------------------------------------------------------------------------
-- 1. Concept discovery
--    Candidates = exact-name matches (any standard status, to show source->standard
--    mapping) UNION every concept actually used in condition_occurrence whose name
--    matches the topic. in_concept_set shows what the descendant expansion includes.
-- -------------------------------------------------------------------------------------
SELECT '1a. T2DM candidate concepts' AS section,
       c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id, c.concept_class_id,
       c.standard_concept, c.invalid_reason,
       (c.concept_id IN (SELECT concept_id FROM t2dm_concepts)) AS in_t2dm_concept_set,
       COALESCE(u.n_records, 0) AS n_condition_records, COALESCE(u.n_patients, 0) AS n_patients
FROM cdm.concept c
LEFT JOIN cond_usage u ON u.concept_id = c.concept_id
WHERE c.domain_id = 'Condition'
  AND ( lower(c.concept_name) IN ('type 2 diabetes mellitus', 'diabetes mellitus type 2',
                                  'diabetes mellitus type ii', 'type ii diabetes mellitus')
        OR (u.concept_id IS NOT NULL AND lower(c.concept_name) LIKE '%diabet%') )
ORDER BY n_condition_records DESC, c.concept_id;

SELECT '1b. CKD candidate concepts' AS section,
       c.concept_id, c.concept_name, c.domain_id, c.vocabulary_id, c.concept_class_id,
       c.standard_concept, c.invalid_reason,
       (c.concept_id IN (SELECT concept_id FROM ckd_concepts)) AS in_ckd_concept_set,
       COALESCE(u.n_records, 0) AS n_condition_records, COALESCE(u.n_patients, 0) AS n_patients
FROM cdm.concept c
LEFT JOIN cond_usage u ON u.concept_id = c.concept_id
WHERE c.domain_id = 'Condition'
  AND ( lower(c.concept_name) LIKE 'chronic kidney disease%'
        OR lower(c.concept_name) IN ('end-stage renal disease', 'chronic renal failure syndrome')
        OR (u.concept_id IS NOT NULL AND lower(c.concept_name) ~ 'kidney|renal|nephropath') )
ORDER BY n_condition_records DESC, c.concept_id;

-- -------------------------------------------------------------------------------------
-- 2. T2DM concept set, index date and analysis population
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE t2dm_first AS
SELECT co.person_id,
       MIN(co.condition_start_date) AS index_date,
       COUNT(*)                     AS n_t2dm_records
FROM cdm.condition_occurrence co
JOIN t2dm_concepts t ON t.concept_id = co.condition_concept_id
GROUP BY co.person_id;

CREATE TEMP TABLE index_pop AS
SELECT DISTINCT ON (f.person_id)
       f.person_id,
       f.index_date,
       op.observation_period_start_date AS op_start,
       op.observation_period_end_date   AS op_end,
       (f.index_date - op.observation_period_start_date) AS prior_obs_days,
       (op.observation_period_end_date - f.index_date)   AS potential_followup_days,
       (f.index_date - COALESCE(p.birth_datetime::date,
            make_date(p.year_of_birth, COALESCE(p.month_of_birth, 7), COALESCE(p.day_of_birth, 1))))
         / 365.25 AS age_at_index
FROM t2dm_first f
JOIN cdm.observation_period op
  ON op.person_id = f.person_id
 AND f.index_date BETWEEN op.observation_period_start_date AND op.observation_period_end_date
JOIN cdm.person p ON p.person_id = f.person_id
ORDER BY f.person_id, op.observation_period_start_date, op.observation_period_end_date DESC;

SELECT '2. T2DM concept set and index date' AS section, metric, value
FROM (
  SELECT 1 AS ord, 'descendant concepts incl. the standard concept itself' AS metric,
         (SELECT COUNT(*) FROM t2dm_concepts)::numeric AS value
  UNION ALL SELECT 2, 'concept-set concepts with >=1 condition_occurrence record',
         (SELECT COUNT(*) FROM t2dm_concepts t WHERE t.concept_id IN (SELECT concept_id FROM cond_usage))
  UNION ALL SELECT 3, 'condition_occurrence records in concept set',
         (SELECT COALESCE(SUM(n_t2dm_records), 0) FROM t2dm_first)
  UNION ALL SELECT 4, 'unique patients with a T2DM record (= patients with an index date)',
         (SELECT COUNT(*) FROM t2dm_first)
  UNION ALL SELECT 5, 'patients whose index date lies inside an observation_period (analysis population)',
         (SELECT COUNT(*) FROM index_pop)
  UNION ALL SELECT 6, 'patients with an index date but no containing observation_period (excluded)',
         (SELECT COUNT(*) FROM t2dm_first) - (SELECT COUNT(*) FROM index_pop)
  UNION ALL SELECT 7, 'persons in cdm.person (denominator context)',
         (SELECT COUNT(*) FROM cdm.person)
) s
ORDER BY ord;

SELECT '2b. T2DM index date range' AS section,
       MIN(index_date) AS earliest_index_date, MAX(index_date) AS latest_index_date
FROM index_pop;

-- -------------------------------------------------------------------------------------
-- 3. Observation history and age at index (analysis population)
-- -------------------------------------------------------------------------------------
SELECT '3a. Prior observation before index' AS section,
       COUNT(*)                                          AS n_index_patients,
       COUNT(*) FILTER (WHERE prior_obs_days >= 0)       AS prior_obs_ge_0d,
       COUNT(*) FILTER (WHERE prior_obs_days >= 180)     AS prior_obs_ge_180d,
       COUNT(*) FILTER (WHERE prior_obs_days >= 365)     AS prior_obs_ge_365d,
       ROUND(100.0 * COUNT(*) FILTER (WHERE prior_obs_days >= 180) / NULLIF(COUNT(*), 0), 1) AS pct_ge_180d,
       ROUND(100.0 * COUNT(*) FILTER (WHERE prior_obs_days >= 365) / NULLIF(COUNT(*), 0), 1) AS pct_ge_365d
FROM index_pop;

SELECT '3b. Age at index' AS section,
       COUNT(*)                                                           AS n,
       ROUND(MIN(age_at_index)::numeric, 1)                               AS min_years,
       ROUND((percentile_cont(0.25) WITHIN GROUP (ORDER BY age_at_index))::numeric, 1) AS q1_years,
       ROUND((percentile_cont(0.50) WITHIN GROUP (ORDER BY age_at_index))::numeric, 1) AS median_years,
       ROUND((percentile_cont(0.75) WITHIN GROUP (ORDER BY age_at_index))::numeric, 1) AS q3_years,
       ROUND(MAX(age_at_index)::numeric, 1)                               AS max_years,
       COUNT(*) FILTER (WHERE age_at_index < 18)                          AS n_under_18,
       COUNT(*) FILTER (WHERE age_at_index >= 18)                         AS n_18_or_over
FROM index_pop;

-- -------------------------------------------------------------------------------------
-- 4. Drug exposure within 90 days after index, rolled up to standard Ingredients
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE early_exposure AS
SELECT d.drug_exposure_id, d.person_id, d.drug_concept_id
FROM cdm.drug_exposure d
JOIN index_pop i ON i.person_id = d.person_id
WHERE d.drug_exposure_start_date BETWEEN i.index_date AND i.index_date + 90;

CREATE TEMP TABLE drug_to_ingredient AS
SELECT DISTINCT e.drug_concept_id, ca.ancestor_concept_id AS ingredient_concept_id
FROM (SELECT DISTINCT drug_concept_id FROM early_exposure) e
JOIN cdm.concept_ancestor ca ON ca.descendant_concept_id = e.drug_concept_id
JOIN cdm.concept ing
  ON ing.concept_id = ca.ancestor_concept_id
 AND ing.concept_class_id = 'Ingredient'
 AND ing.standard_concept = 'S'
 AND ing.invalid_reason IS NULL
 AND ing.vocabulary_id IN ('RxNorm', 'RxNorm Extension');

SELECT '4a. Early drug exposure coverage' AS section, metric, value
FROM (
  SELECT 1 AS ord, 'analysis population (denominator)' AS metric, (SELECT COUNT(*) FROM index_pop)::numeric AS value
  UNION ALL SELECT 2, 'patients with >=1 drug_exposure in [index, index+90d]',
         (SELECT COUNT(DISTINCT person_id) FROM early_exposure)
  UNION ALL SELECT 3, 'drug_exposure records in window', (SELECT COUNT(*) FROM early_exposure)
  UNION ALL SELECT 4, 'records not mapped to any standard Ingredient (incl. drug_concept_id = 0)',
         (SELECT COUNT(*) FROM early_exposure e
           WHERE NOT EXISTS (SELECT 1 FROM drug_to_ingredient m WHERE m.drug_concept_id = e.drug_concept_id))
) s
ORDER BY ord;

SELECT '4b. Top 30 ingredients in first 90 days' AS section,
       m.ingredient_concept_id, c.concept_name,
       COUNT(DISTINCT e.person_id)        AS unique_exposed_patients,
       COUNT(DISTINCT e.drug_exposure_id) AS drug_exposure_records,
       ROUND(100.0 * COUNT(DISTINCT e.person_id) / (SELECT COUNT(*) FROM index_pop), 2) AS pct_of_indexed_t2dm
FROM early_exposure e
JOIN drug_to_ingredient m ON m.drug_concept_id = e.drug_concept_id
JOIN cdm.concept c ON c.concept_id = m.ingredient_concept_id
GROUP BY m.ingredient_concept_id, c.concept_name
ORDER BY unique_exposed_patients DESC, drug_exposure_records DESC, c.concept_name
LIMIT 30;

-- -------------------------------------------------------------------------------------
-- 5. CKD endpoint feasibility (prevalent kept separate from incident)
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE ckd_status AS
SELECT i.person_id, i.index_date, i.op_end, i.potential_followup_days,
       COALESCE(BOOL_OR(co.condition_start_date <  i.index_date), FALSE) AS ckd_before_index,
       COALESCE(BOOL_OR(co.condition_start_date =  i.index_date), FALSE) AS ckd_on_index,
       MIN(co.condition_start_date) FILTER (WHERE co.condition_start_date > i.index_date) AS first_ckd_after
FROM index_pop i
LEFT JOIN cdm.condition_occurrence co
  ON co.person_id = i.person_id
 AND co.condition_concept_id IN (SELECT concept_id FROM ckd_concepts)
GROUP BY i.person_id, i.index_date, i.op_end, i.potential_followup_days;

-- at_risk = no CKD on or before index; only these patients can have INCIDENT CKD.
SELECT '5a. CKD at/around index' AS section, metric, value
FROM (
  SELECT 1 AS ord, 'analysis population' AS metric, COUNT(*)::numeric AS value FROM ckd_status
  UNION ALL SELECT 2, 'CKD concept-set concepts (incl. standard concept itself)', (SELECT COUNT(*) FROM ckd_concepts)
  UNION ALL SELECT 3, 'PREVALENT: CKD before index', COUNT(*) FILTER (WHERE ckd_before_index) FROM ckd_status
  UNION ALL SELECT 4, 'PREVALENT: CKD on index date', COUNT(*) FILTER (WHERE ckd_on_index) FROM ckd_status
  UNION ALL SELECT 5, 'PREVALENT: CKD on or before index (either; excluded from incident analysis)',
         COUNT(*) FILTER (WHERE ckd_before_index OR ckd_on_index) FROM ckd_status
  UNION ALL SELECT 6, 'any CKD record after index (all patients, incl. prevalent)',
         COUNT(*) FILTER (WHERE first_ckd_after IS NOT NULL) FROM ckd_status
  UNION ALL SELECT 7, 'AT RISK for incident CKD (no CKD on or before index)',
         COUNT(*) FILTER (WHERE NOT ckd_before_index AND NOT ckd_on_index) FROM ckd_status
  UNION ALL SELECT 8, 'INCIDENT: at risk with first CKD after index',
         COUNT(*) FILTER (WHERE NOT ckd_before_index AND NOT ckd_on_index AND first_ckd_after IS NOT NULL) FROM ckd_status
  UNION ALL SELECT 9, 'at risk with no subsequent CKD (censored at end of observation unless died)',
         COUNT(*) FILTER (WHERE NOT ckd_before_index AND NOT ckd_on_index AND first_ckd_after IS NULL) FROM ckd_status
  UNION ALL SELECT 10, 'incident CKD dated after observation_period end (data check; expect 0)',
         COUNT(*) FILTER (WHERE NOT ckd_before_index AND NOT ckd_on_index AND first_ckd_after > op_end) FROM ckd_status
) s
ORDER BY ord;

-- Time-to-event / follow-up distributions among the at-risk group.
SELECT '5b. Days from index (at-risk group)' AS section, metric,
       COUNT(v) AS n, MIN(v) AS min_days,
       ROUND((percentile_cont(0.25) WITHIN GROUP (ORDER BY v))::numeric, 0) AS q1_days,
       ROUND((percentile_cont(0.50) WITHIN GROUP (ORDER BY v))::numeric, 0) AS median_days,
       ROUND((percentile_cont(0.75) WITHIN GROUP (ORDER BY v))::numeric, 0) AS q3_days,
       MAX(v) AS max_days
FROM (
  SELECT 'index -> incident CKD (incident cases only)' AS metric,
         (first_ckd_after - index_date) AS v
  FROM ckd_status
  WHERE NOT ckd_before_index AND NOT ckd_on_index AND first_ckd_after IS NOT NULL
  UNION ALL
  SELECT 'potential follow-up, index -> observation_period end (all at-risk)', potential_followup_days
  FROM ckd_status
  WHERE NOT ckd_before_index AND NOT ckd_on_index
  UNION ALL
  SELECT 'potential follow-up (at-risk without subsequent CKD)', potential_followup_days
  FROM ckd_status
  WHERE NOT ckd_before_index AND NOT ckd_on_index AND first_ckd_after IS NULL
  UNION ALL
  SELECT 'potential follow-up (all analysis population, incl. prevalent CKD)', potential_followup_days
  FROM ckd_status
) x
GROUP BY metric
ORDER BY metric;

-- Informational only: diabetic kidney disease is NOT a descendant of the CKD concept in this
-- vocabulary, so it is not part of the endpoint. Counted here so the choice is visible.
SELECT '5c. Info: concepts outside the CKD set, not used as endpoint' AS section,
       c.concept_id, c.concept_name,
       COUNT(DISTINCT co.person_id) AS patients_in_analysis_population
FROM cdm.concept c
JOIN cdm.condition_occurrence co ON co.condition_concept_id = c.concept_id
JOIN index_pop i ON i.person_id = co.person_id
WHERE c.domain_id = 'Condition' AND c.standard_concept = 'S' AND c.invalid_reason IS NULL
  AND lower(c.concept_name) = 'disorder of kidney due to diabetes mellitus'
  AND c.concept_id NOT IN (SELECT concept_id FROM ckd_concepts)
GROUP BY c.concept_id, c.concept_name;

-- -------------------------------------------------------------------------------------
-- 6. Mortality after index (cdm.death), analysis population
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE death_status AS
SELECT i.person_id, i.index_date, i.op_end, MIN(d.death_date) AS death_date
FROM index_pop i
LEFT JOIN cdm.death d ON d.person_id = i.person_id
GROUP BY i.person_id, i.index_date, i.op_end;

SELECT '6a. Mortality counts' AS section, metric, value
FROM (
  SELECT 1 AS ord, 'analysis population' AS metric, COUNT(*)::numeric AS value FROM death_status
  UNION ALL SELECT 2, 'patients with any death record', COUNT(death_date) FROM death_status
  UNION ALL SELECT 3, 'deaths after index date', COUNT(*) FILTER (WHERE death_date > index_date) FROM death_status
  UNION ALL SELECT 4, 'deaths on or before index date (data check; expect ~0)',
         COUNT(*) FILTER (WHERE death_date <= index_date) FROM death_status
  UNION ALL SELECT 5, 'deaths after index but after observation_period end',
         COUNT(*) FILTER (WHERE death_date > index_date AND death_date > op_end) FROM death_status
  UNION ALL SELECT 6, 'AT-RISK patients who die after index without incident CKD (competing event)',
         COUNT(*) FROM death_status d JOIN ckd_status k USING (person_id)
         WHERE NOT k.ckd_before_index AND NOT k.ckd_on_index AND k.first_ckd_after IS NULL
           AND d.death_date > d.index_date
  UNION ALL SELECT 7, 'incident CKD patients who die before their CKD date (data check; expect 0)',
         COUNT(*) FROM death_status d JOIN ckd_status k USING (person_id)
         WHERE NOT k.ckd_before_index AND NOT k.ckd_on_index AND k.first_ckd_after IS NOT NULL
           AND d.death_date < k.first_ckd_after
) s
ORDER BY ord;

SELECT '6b. Days from index to death (deaths after index)' AS section,
       COUNT(*) AS n,
       MIN(death_date - index_date) AS min_days,
       ROUND((percentile_cont(0.25) WITHIN GROUP (ORDER BY death_date - index_date))::numeric, 0) AS q1_days,
       ROUND((percentile_cont(0.50) WITHIN GROUP (ORDER BY death_date - index_date))::numeric, 0) AS median_days,
       ROUND((percentile_cont(0.75) WITHIN GROUP (ORDER BY death_date - index_date))::numeric, 0) AS q3_days,
       MAX(death_date - index_date) AS max_days
FROM death_status
WHERE death_date > index_date;

ROLLBACK;

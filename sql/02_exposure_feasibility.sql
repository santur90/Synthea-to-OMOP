-- =====================================================================================
-- 02_exposure_feasibility.sql
-- Feasibility of a metformin-exposure comparison for T2DM -> incident CKD on the synthetic
-- Synthea-derived OMOP CDM v5.4 database (schema: cdm). Follows 01_cohort_feasibility.sql.
--
-- NON-DESTRUCTIVE. Only SELECT and CREATE TEMP TABLE (PostgreSQL forbids temp tables in a
-- READ ONLY transaction), inside a transaction that is rolled back at the end. No CDM table
-- is touched, no results.cohort is created, nothing permanent is left behind.
-- No fitted models. Drug quantity, days_supply and dose are never used (DQD flagged them).
--
-- DATA CAVEAT: synthetic (Synthea) data. Differences between groups below reflect the
-- simulator's disease modules and prescribing rules, not clinical or real-world evidence.
--
-- DEFINITIONS
--  * T2DM set  : concept 201826 + descendants. Index date = first T2DM condition_start_date,
--                restricted to patients whose index date lies inside an observation_period.
--  * CKD set   : concept 46271022 + descendants (primary endpoint).
--  * Sensitivity CKD set : primary set + concept 192279 (Disorder of kidney due to diabetes
--                mellitus) + its descendants.
--  * Metformin exposure : any drug_exposure whose drug_concept_id is concept 1503297
--                (metformin ingredient) or a descendant (so metformin combination products
--                count), with drug_exposure_start_date in [index, index + 90 days].
--  * Landmark design: follow-up starts at lm_date = index + 90 days. Exposure is classified
--                from the 0-90 day window only, which avoids immortal-time bias. Excluded:
--                  - CKD on or before lm_date (prevalent at landmark),
--                  - death before lm_date,
--                  - observation_period end before lm_date.
--                The three exclusions overlap; the flow table counts each independently.
--  * Outcomes after lm_date: incident CKD = first CKD record strictly after lm_date (everyone
--                with a CKD record on or before lm_date is already excluded). Death without
--                CKD = death with no CKD record on or before the death date. Everyone else is
--                censored alive at observation_period end. Follow-up = end date - lm_date.
-- =====================================================================================

BEGIN;

-- -------------------------------------------------------------------------------------
-- 0. Verify anchor concepts against cdm.concept; abort if metadata differs.
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE anchor (role text, concept_id integer, expected_name text,
                          expected_domain text, expected_vocab text, expected_class text);
INSERT INTO anchor VALUES
  ('T2DM',      201826,   'Type 2 diabetes mellitus',                          'Condition', 'SNOMED', 'Disorder'),
  ('CKD',       46271022, 'Chronic kidney disease',                            'Condition', 'SNOMED', 'Disorder'),
  ('DKD',       192279,   'Disorder of kidney due to diabetes mellitus',       'Condition', 'SNOMED', 'Disorder'),
  ('METFORMIN', 1503297,  'metformin',                                         'Drug',      'RxNorm', 'Ingredient');

DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(a.role || ' ' || a.concept_id, ', ') INTO bad
  FROM anchor a
  LEFT JOIN cdm.concept c
         ON c.concept_id = a.concept_id AND c.concept_name = a.expected_name
        AND c.domain_id = a.expected_domain AND c.vocabulary_id = a.expected_vocab
        AND c.concept_class_id = a.expected_class
        AND c.standard_concept = 'S' AND c.invalid_reason IS NULL
  WHERE c.concept_id IS NULL;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'Anchor concept metadata check failed for: %', bad;
  END IF;
END $$;

CREATE TEMP TABLE t2dm_concepts AS
SELECT ca.descendant_concept_id AS concept_id FROM cdm.concept_ancestor ca
WHERE ca.ancestor_concept_id = (SELECT concept_id FROM anchor WHERE role = 'T2DM');

CREATE TEMP TABLE ckd_concepts AS
SELECT ca.descendant_concept_id AS concept_id FROM cdm.concept_ancestor ca
WHERE ca.ancestor_concept_id = (SELECT concept_id FROM anchor WHERE role = 'CKD');

CREATE TEMP TABLE dkd_concepts AS
SELECT ca.descendant_concept_id AS concept_id FROM cdm.concept_ancestor ca
WHERE ca.ancestor_concept_id = (SELECT concept_id FROM anchor WHERE role = 'DKD');

CREATE TEMP TABLE metformin_concepts AS
SELECT ca.descendant_concept_id AS concept_id FROM cdm.concept_ancestor ca
WHERE ca.ancestor_concept_id = (SELECT concept_id FROM anchor WHERE role = 'METFORMIN');

CREATE TEMP TABLE endpoint_set AS
SELECT 'primary'::text AS endpoint, concept_id FROM ckd_concepts
UNION
SELECT 'sensitivity', concept_id FROM ckd_concepts
UNION
SELECT 'sensitivity', concept_id FROM dkd_concepts;

CREATE TEMP TABLE cond_usage AS
SELECT condition_concept_id AS concept_id, COUNT(*) AS n_records
FROM cdm.condition_occurrence GROUP BY condition_concept_id;

-- -------------------------------------------------------------------------------------
-- Index population (same rule as 01_cohort_feasibility.sql)
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE t2dm_first AS
SELECT co.person_id, MIN(co.condition_start_date) AS index_date
FROM cdm.condition_occurrence co
JOIN t2dm_concepts t ON t.concept_id = co.condition_concept_id
GROUP BY co.person_id;

CREATE TEMP TABLE index_pop AS
SELECT DISTINCT ON (f.person_id)
       f.person_id, f.index_date, op.observation_period_end_date AS op_end,
       EXTRACT(YEAR FROM f.index_date)::int AS index_year
FROM t2dm_first f
JOIN cdm.observation_period op
  ON op.person_id = f.person_id
 AND f.index_date BETWEEN op.observation_period_start_date AND op.observation_period_end_date
ORDER BY f.person_id, op.observation_period_start_date, op.observation_period_end_date DESC;

CREATE TEMP TABLE lm_base AS
SELECT i.person_id, i.index_date, i.index_year, i.op_end,
       i.index_date + 90 AS lm_date,
       EXISTS (SELECT 1 FROM cdm.drug_exposure d
               WHERE d.person_id = i.person_id
                 AND d.drug_exposure_start_date BETWEEN i.index_date AND i.index_date + 90
                 AND d.drug_concept_id IN (SELECT concept_id FROM metformin_concepts)) AS metformin_0_90,
       (SELECT MIN(dt.death_date) FROM cdm.death dt WHERE dt.person_id = i.person_id) AS death_date
FROM index_pop i;

-- -------------------------------------------------------------------------------------
-- 1. T2DM index date by decade, and metformin exposure in days 0-90 by index decade
-- -------------------------------------------------------------------------------------
SELECT '1. Index decade x metformin 0-90d' AS section,
       COALESCE((index_year / 10 * 10)::text, 'all decades') AS index_decade,
       COUNT(*)                                          AS n_indexed,
       COUNT(*) FILTER (WHERE metformin_0_90)            AS n_metformin_0_90,
       ROUND(100.0 * COUNT(*) FILTER (WHERE metformin_0_90) / COUNT(*), 1) AS pct_metformin_0_90
FROM lm_base
GROUP BY ROLLUP (index_year / 10 * 10)
ORDER BY (index_year / 10 * 10) NULLS LAST;

-- -------------------------------------------------------------------------------------
-- Landmark cohort build (both endpoints). One row per person x endpoint.
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE endpoint_ckd AS
SELECT e.endpoint, b.person_id,
       COALESCE(BOOL_OR(co.condition_start_date <= b.lm_date), FALSE)           AS ckd_le_lm,
       MIN(co.condition_start_date) FILTER (WHERE co.condition_start_date > b.lm_date) AS first_ckd_after
FROM (SELECT DISTINCT endpoint FROM endpoint_set) e
CROSS JOIN lm_base b
LEFT JOIN cdm.condition_occurrence co
  ON co.person_id = b.person_id
 AND co.condition_concept_id IN (SELECT s.concept_id FROM endpoint_set s WHERE s.endpoint = e.endpoint)
GROUP BY e.endpoint, b.person_id;

CREATE TEMP TABLE lm_cohort AS
SELECT x.endpoint, b.person_id, b.index_date, b.index_year, b.lm_date, b.op_end, b.death_date,
       b.metformin_0_90, x.ckd_le_lm AS excl_ckd,
       COALESCE(b.death_date < b.lm_date, FALSE) AS excl_death,
       (b.op_end < b.lm_date)                    AS excl_obs_end,
       x.first_ckd_after
FROM lm_base b
JOIN endpoint_ckd x USING (person_id);

CREATE TEMP TABLE lm_elig AS
SELECT s.*,
       (s.death_date IS NOT NULL AND NOT s.event_ckd) AS death_wo_ckd,
       CASE WHEN s.event_ckd THEN s.first_ckd_after
            WHEN s.death_date IS NOT NULL THEN s.death_date
            ELSE s.op_end END AS end_date
FROM (SELECT c.*,
             (c.first_ckd_after IS NOT NULL AND (c.death_date IS NULL OR c.first_ckd_after <= c.death_date)) AS event_ckd
      FROM lm_cohort c
      WHERE NOT (c.excl_ckd OR c.excl_death OR c.excl_obs_end)) s;

CREATE TEMP TABLE cutoffs (ord int, label text, min_year int);
INSERT INTO cutoffs VALUES (1, 'all index years', 0), (2, 'index year >= 2000', 2000), (3, 'index year >= 2005', 2005);

CREATE TEMP TABLE lm_summary AS
SELECT c.ord, c.label, e.endpoint,
       CASE WHEN GROUPING(e.metformin_0_90) = 1 THEN 'all eligible'
            WHEN e.metformin_0_90 THEN 'metformin days 0-90'
            ELSE 'no metformin days 0-90' END AS grp,
       COUNT(*)                                                           AS n,
       COUNT(*) FILTER (WHERE e.event_ckd)                                AS incident_ckd_events,
       COUNT(*) FILTER (WHERE e.death_wo_ckd)                             AS deaths_without_ckd,
       COUNT(*) FILTER (WHERE NOT e.event_ckd AND NOT e.death_wo_ckd)     AS censored_alive,
       ROUND((percentile_cont(0.25) WITHIN GROUP (ORDER BY e.end_date - e.lm_date))::numeric, 0) AS fu_q1_days,
       ROUND((percentile_cont(0.50) WITHIN GROUP (ORDER BY e.end_date - e.lm_date))::numeric, 0) AS fu_median_days,
       ROUND((percentile_cont(0.75) WITHIN GROUP (ORDER BY e.end_date - e.lm_date))::numeric, 0) AS fu_q3_days
FROM cutoffs c
JOIN lm_elig e ON e.index_year >= c.min_year
GROUP BY c.ord, c.label, e.endpoint, GROUPING SETS ((e.metformin_0_90), ());

-- -------------------------------------------------------------------------------------
-- 2. Landmark design (primary CKD endpoint), all index years
-- -------------------------------------------------------------------------------------
SELECT '2a. Landmark exclusion flow (overlapping reasons)' AS section, c.endpoint,
       COUNT(*)                                                           AS n_indexed,
       COUNT(*) FILTER (WHERE c.excl_ckd)                                 AS excl_ckd_on_or_before_landmark,
       COUNT(*) FILTER (WHERE c.excl_death)                               AS excl_death_before_landmark,
       COUNT(*) FILTER (WHERE c.excl_obs_end)                             AS excl_obs_end_before_landmark,
       COUNT(*) FILTER (WHERE NOT (c.excl_ckd OR c.excl_death OR c.excl_obs_end)) AS n_eligible,
       (SELECT COUNT(*) FROM lm_elig e WHERE e.endpoint = c.endpoint AND e.end_date > e.op_end)
                                                                           AS eligible_with_end_after_obs_end_check
FROM lm_cohort c
GROUP BY c.endpoint
ORDER BY c.endpoint DESC;

SELECT '2b. Landmark outcomes, ' || label AS section, grp, n, incident_ckd_events, deaths_without_ckd,
       censored_alive, fu_q1_days, fu_median_days, fu_q3_days
FROM lm_summary
WHERE endpoint = 'primary' AND ord = 1
ORDER BY CASE grp WHEN 'metformin days 0-90' THEN 1 WHEN 'no metformin days 0-90' THEN 2 ELSE 3 END;

-- -------------------------------------------------------------------------------------
-- 3. Same, restricted to index year >= 2000 and >= 2005
-- -------------------------------------------------------------------------------------
SELECT '3. Landmark outcomes, ' || label AS section, grp, n, incident_ckd_events, deaths_without_ckd,
       censored_alive, fu_q1_days, fu_median_days, fu_q3_days
FROM lm_summary
WHERE endpoint = 'primary' AND ord IN (2, 3)
ORDER BY ord, CASE grp WHEN 'metformin days 0-90' THEN 1 WHEN 'no metformin days 0-90' THEN 2 ELSE 3 END;

-- -------------------------------------------------------------------------------------
-- 4. Drug records in days 0-90 that do not roll up to a standard Ingredient
--    drug_source_value in this ETL is a source code, so the source concept's name
--    (drug_source_concept_id) is shown as the description.
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE early_exposure AS
SELECT d.drug_exposure_id, d.person_id, d.drug_concept_id, d.drug_source_value, d.drug_source_concept_id
FROM cdm.drug_exposure d
JOIN index_pop i ON i.person_id = d.person_id
WHERE d.drug_exposure_start_date BETWEEN i.index_date AND i.index_date + 90;

CREATE TEMP TABLE drug_to_ingredient AS
SELECT DISTINCT e.drug_concept_id
FROM (SELECT DISTINCT drug_concept_id FROM early_exposure) e
JOIN cdm.concept_ancestor ca ON ca.descendant_concept_id = e.drug_concept_id
JOIN cdm.concept ing
  ON ing.concept_id = ca.ancestor_concept_id
 AND ing.concept_class_id = 'Ingredient' AND ing.standard_concept = 'S'
 AND ing.invalid_reason IS NULL AND ing.vocabulary_id IN ('RxNorm', 'RxNorm Extension');

CREATE TEMP TABLE unmapped AS
SELECT e.drug_exposure_id, e.person_id, e.drug_concept_id,
       COALESCE(dc.concept_name, '(no concept)')  AS drug_concept_name,
       e.drug_source_value,
       COALESCE(sc.concept_name, '(no source concept)') AS source_concept_name,
       lower(concat_ws(' ', dc.concept_name, sc.concept_name, e.drug_source_value)) ~
         'metformin|insulin|glipizide|glyburide|glibenclamide|glimepiride|gliclazide|pioglitazone|rosiglitazone|sitagliptin|linagliptin|saxagliptin|alogliptin|vildagliptin|empagliflozin|canagliflozin|dapagliflozin|ertugliflozin|liraglutide|semaglutide|dulaglutide|exenatide|lixisenatide|repaglinide|nateglinide|acarbose|miglitol|pramlintide|tolbutamide|chlorpropamide|tolazamide|diabet'
         AS looks_antidiabetic
FROM early_exposure e
LEFT JOIN cdm.concept dc ON dc.concept_id = e.drug_concept_id
LEFT JOIN cdm.concept sc ON sc.concept_id = e.drug_source_concept_id
WHERE e.drug_concept_id NOT IN (SELECT drug_concept_id FROM drug_to_ingredient);

SELECT '4a. Unmapped drug records in days 0-90' AS section, metric, value
FROM (
  SELECT 1 AS ord, 'unmapped drug_exposure records' AS metric, COUNT(*)::numeric AS value FROM unmapped
  UNION ALL SELECT 2, 'unique patients', COUNT(DISTINCT person_id) FROM unmapped
  UNION ALL SELECT 3, 'records with drug_concept_id = 0', COUNT(*) FILTER (WHERE drug_concept_id = 0) FROM unmapped
  UNION ALL SELECT 4, 'records flagged looks_antidiabetic', COUNT(*) FILTER (WHERE looks_antidiabetic) FROM unmapped
  UNION ALL SELECT 5, 'patients with a flagged record', COUNT(DISTINCT person_id) FILTER (WHERE looks_antidiabetic) FROM unmapped
) s
ORDER BY ord;

SELECT '4b. Top 20 unmapped drugs' AS section, drug_concept_id, drug_concept_name, drug_source_value,
       source_concept_name, COUNT(*) AS n_records, COUNT(DISTINCT person_id) AS n_patients,
       BOOL_OR(looks_antidiabetic) AS looks_antidiabetic
FROM unmapped
GROUP BY drug_concept_id, drug_concept_name, drug_source_value, source_concept_name
ORDER BY n_records DESC, drug_source_value
LIMIT 20;

SELECT '4c. All flagged (antidiabetic-looking) unmapped drugs' AS section, drug_concept_id, drug_concept_name,
       drug_source_value, source_concept_name, COUNT(*) AS n_records, COUNT(DISTINCT person_id) AS n_patients
FROM unmapped
WHERE looks_antidiabetic
GROUP BY drug_concept_id, drug_concept_name, drug_source_value, source_concept_name
ORDER BY n_records DESC;

-- -------------------------------------------------------------------------------------
-- 5. T2DM-complication patients with no record under concept 201826 (whole cdm.person).
--    Complication concepts = standard, valid Condition concepts used in the data whose name
--    mentions diabetes, excluding the T2DM set itself, prediabetes, type 1, gestational,
--    drug-induced, neonatal and insipidus. The list is printed in 5b so the rule is auditable.
-- -------------------------------------------------------------------------------------
CREATE TEMP TABLE compl_concepts AS
SELECT c.concept_id, c.concept_name
FROM cdm.concept c
JOIN cond_usage u ON u.concept_id = c.concept_id
WHERE c.domain_id = 'Condition' AND c.standard_concept = 'S' AND c.invalid_reason IS NULL
  AND lower(c.concept_name) ~ 'diabet'
  AND lower(c.concept_name) !~ 'prediabet|pre-diabet|type 1|gestational|drug induced|drug-induced|neonatal|insipidus'
  AND c.concept_id NOT IN (SELECT concept_id FROM t2dm_concepts);

CREATE TEMP TABLE compl_pat AS
SELECT co.person_id, MIN(co.condition_start_date) AS first_compl_date
FROM cdm.condition_occurrence co
WHERE co.condition_concept_id IN (SELECT concept_id FROM compl_concepts)
GROUP BY co.person_id;

CREATE TEMP TABLE orphan_pat AS
SELECT p.person_id, p.first_compl_date
FROM compl_pat p
WHERE p.person_id NOT IN (SELECT person_id FROM t2dm_first);

SELECT '5a. Complication patients vs T2DM record' AS section, metric, value
FROM (
  SELECT 1 AS ord, 'patients with >=1 complication concept' AS metric, COUNT(*)::numeric AS value FROM compl_pat
  UNION ALL SELECT 2, '  ...of whom have a T2DM (201826) record', COUNT(*) FROM compl_pat WHERE person_id IN (SELECT person_id FROM t2dm_first)
  UNION ALL SELECT 3, '  ...of whom have NO T2DM record', COUNT(*) FROM orphan_pat
  UNION ALL SELECT 4, 'no-T2DM-record patients with any CKD-set record', COUNT(*) FROM orphan_pat o
         WHERE EXISTS (SELECT 1 FROM cdm.condition_occurrence co JOIN ckd_concepts k ON k.concept_id = co.condition_concept_id WHERE co.person_id = o.person_id)
  UNION ALL SELECT 5, 'no-T2DM-record patients ever exposed to metformin', COUNT(*) FROM orphan_pat o
         WHERE EXISTS (SELECT 1 FROM cdm.drug_exposure d JOIN metformin_concepts m ON m.concept_id = d.drug_concept_id WHERE d.person_id = o.person_id)
  UNION ALL SELECT 6, 'T2DM-record patients whose first complication precedes the T2DM index date', COUNT(*)
         FROM compl_pat p JOIN t2dm_first f USING (person_id) WHERE p.first_compl_date < f.index_date
) s
ORDER BY ord;

SELECT '5b. Complication concepts' AS section, k.concept_id, k.concept_name,
       COUNT(DISTINCT co.person_id) AS n_patients,
       COUNT(DISTINCT co.person_id) FILTER (WHERE co.person_id IN (SELECT person_id FROM orphan_pat)) AS n_patients_without_t2dm_record
FROM compl_concepts k
JOIN cdm.condition_occurrence co ON co.condition_concept_id = k.concept_id
GROUP BY k.concept_id, k.concept_name
ORDER BY n_patients DESC;

-- -------------------------------------------------------------------------------------
-- 6. Sensitivity endpoint: CKD set + diabetic kidney disease (192279 + descendants).
--    Eligibility is re-applied with the broader endpoint (prior DKD/CKD at landmark excludes).
--    Event counts only.
-- -------------------------------------------------------------------------------------
SELECT '6. Sensitivity endpoint (CKD + DKD), ' || label AS section, grp, n AS n_eligible,
       incident_ckd_events AS incident_ckd_or_dkd_events
FROM lm_summary
WHERE endpoint = 'sensitivity'
ORDER BY ord, CASE grp WHEN 'metformin days 0-90' THEN 1 WHEN 'no metformin days 0-90' THEN 2 ELSE 3 END;

ROLLBACK;

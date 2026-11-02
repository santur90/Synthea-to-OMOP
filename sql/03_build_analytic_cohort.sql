-- 03_build_analytic_cohort.sql
-- Builds results.t2dm_ckd_analytic (one row per person) for a landmark
-- T2DM -> incident CKD analysis. SYNTHETIC DATA: methodology demonstration only.
--
-- Writes ONLY to schema "results" (created if missing). CDM/native are read-only.
-- Re-runnable: results tables are dropped and rebuilt.
--
-- Design
--   index date     = first condition_start_date under 201826 (+descendants), inside an
--                    observation_period (earliest-starting one if several contain it)
--   landmark       = index + 90 days
--   exclusions     = CKD (46271022+desc) start <= landmark; death <= landmark;
--                    observation_period_end_date < landmark   (applied sequentially)
--   follow-up      = landmark -> first of CKD (> landmark), death, observation end
--   event_type     = 1 CKD (CKD date <= death date), 2 death before CKD, 0 censored
--   metformin_early= any drug_exposure of ingredient 1503297 (via concept_ancestor)
--                    with start date in [index, index+90]. Exploratory covariate only.
--                    drug quantity / dose are NOT used.
--   covariates     = condition_occurrence with start date STRICTLY BEFORE landmark.
--                    Obesity = 433736 + 4060985 + 4256640 and descendants (the BMI-30+
--                    concepts are not descendants of 433736 in this vocabulary).
--   complication-only patients (no 201826 record) are never in the cohort.

CREATE SCHEMA IF NOT EXISTS results;

-- ---------------------------------------------------------------------------
-- 0. Verify anchor concepts (abort if metadata differs from expectation)
-- ---------------------------------------------------------------------------
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
  FROM (VALUES
    (201826::int,  'Type 2 diabetes mellitus',              'Condition',  'SNOMED'),
    (46271022,     'Chronic kidney disease',                'Condition',  'SNOMED'),
    (192279,       'Disorder of kidney due to diabetes mellitus','Condition','SNOMED'),
    (1503297,      'metformin',                             'Drug',       'RxNorm'),
    (316866,       'Hypertensive disorder',                 'Condition',  'SNOMED'),
    (432867,       'Hyperlipidemia',                        'Condition',  'SNOMED'),
    (433736,       'Obesity',                               'Condition',  'SNOMED'),
    (4060985,      'Body mass index 30+ - obesity',         'Condition',  'SNOMED'),
    (4256640,      'Body mass index 40+ - severely obese',  'Condition',  'SNOMED'),
    (316139,       'Heart failure',                         'Condition',  'SNOMED'),
    (8507,         'MALE',                                  'Gender',     'Gender'),
    (8532,         'FEMALE',                                'Gender',     'Gender')
  ) v(id, nm, dom, voc)
  LEFT JOIN cdm.concept c
         ON c.concept_id = v.id AND c.concept_name = v.nm AND c.domain_id = v.dom
        AND c.vocabulary_id = v.voc AND c.standard_concept = 'S' AND c.invalid_reason IS NULL
  WHERE c.concept_id IS NULL;
  IF bad > 0 THEN
    RAISE EXCEPTION 'Anchor concept verification failed for % concept(s)', bad;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1. Concept sets
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_t2dm, tmp_ckd, tmp_dkd, tmp_met, tmp_htn, tmp_hld, tmp_obs, tmp_hf;
CREATE TEMP TABLE tmp_t2dm AS SELECT descendant_concept_id AS concept_id FROM cdm.concept_ancestor WHERE ancestor_concept_id = 201826;
CREATE TEMP TABLE tmp_ckd  AS SELECT descendant_concept_id AS concept_id FROM cdm.concept_ancestor WHERE ancestor_concept_id = 46271022;
CREATE TEMP TABLE tmp_dkd  AS SELECT descendant_concept_id AS concept_id FROM cdm.concept_ancestor WHERE ancestor_concept_id = 192279;
CREATE TEMP TABLE tmp_met  AS SELECT descendant_concept_id AS concept_id FROM cdm.concept_ancestor WHERE ancestor_concept_id = 1503297;
CREATE TEMP TABLE tmp_htn  AS SELECT descendant_concept_id AS concept_id FROM cdm.concept_ancestor WHERE ancestor_concept_id = 316866;
CREATE TEMP TABLE tmp_hld  AS SELECT descendant_concept_id AS concept_id FROM cdm.concept_ancestor WHERE ancestor_concept_id = 432867;
CREATE TEMP TABLE tmp_obs  AS SELECT DISTINCT descendant_concept_id AS concept_id FROM cdm.concept_ancestor WHERE ancestor_concept_id IN (433736, 4060985, 4256640);
CREATE TEMP TABLE tmp_hf   AS SELECT descendant_concept_id AS concept_id FROM cdm.concept_ancestor WHERE ancestor_concept_id = 316139;

-- ---------------------------------------------------------------------------
-- 2. Index, landmark, exclusion flags
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_first_t2dm, tmp_base;
CREATE TEMP TABLE tmp_first_t2dm AS
SELECT co.person_id, MIN(co.condition_start_date) AS index_date
FROM cdm.condition_occurrence co
JOIN tmp_t2dm t ON t.concept_id = co.condition_concept_id
GROUP BY co.person_id;

CREATE TEMP TABLE tmp_base AS
SELECT f.person_id,
       f.index_date,
       (f.index_date + 90) AS landmark_date,
       op.observation_period_end_date AS obs_end_date,
       d.death_date,
       (SELECT MIN(c.condition_start_date) FROM cdm.condition_occurrence c
         JOIN tmp_ckd k ON k.concept_id = c.condition_concept_id
        WHERE c.person_id = f.person_id AND c.condition_start_date <= f.index_date + 90) AS ckd_on_or_before_lm,
       (SELECT MIN(c.condition_start_date) FROM cdm.condition_occurrence c
         JOIN tmp_ckd k ON k.concept_id = c.condition_concept_id
        WHERE c.person_id = f.person_id AND c.condition_start_date > f.index_date + 90) AS first_ckd_after,
       (SELECT MIN(c.condition_start_date) FROM cdm.condition_occurrence c
         JOIN tmp_dkd k ON k.concept_id = c.condition_concept_id
        WHERE c.person_id = f.person_id AND c.condition_start_date <= f.index_date + 90) AS dkd_on_or_before_lm,
       (SELECT MIN(c.condition_start_date) FROM cdm.condition_occurrence c
         JOIN tmp_dkd k ON k.concept_id = c.condition_concept_id
        WHERE c.person_id = f.person_id AND c.condition_start_date > f.index_date + 90) AS first_dkd_after
FROM tmp_first_t2dm f
JOIN LATERAL (
    SELECT observation_period_end_date
    FROM cdm.observation_period o
    WHERE o.person_id = f.person_id
      AND f.index_date BETWEEN o.observation_period_start_date AND o.observation_period_end_date
    ORDER BY o.observation_period_start_date
    LIMIT 1) op ON TRUE
LEFT JOIN (SELECT person_id, MIN(death_date) AS death_date FROM cdm.death GROUP BY person_id) d
       ON d.person_id = f.person_id;

-- ---------------------------------------------------------------------------
-- 3. Attrition (sequential exclusions)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS results.t2dm_ckd_attrition;
CREATE TABLE results.t2dm_ckd_attrition (
    step_order int, step_label text, n_remaining int, n_excluded int);

INSERT INTO results.t2dm_ckd_attrition
WITH s AS (
  SELECT
    (SELECT count(*) FROM tmp_first_t2dm)                                                         AS n0,
    (SELECT count(*) FROM tmp_base)                                                               AS n1,
    (SELECT count(*) FROM tmp_base WHERE ckd_on_or_before_lm IS NULL)                             AS n2,
    (SELECT count(*) FROM tmp_base WHERE ckd_on_or_before_lm IS NULL
        AND (death_date IS NULL OR death_date > landmark_date))                                   AS n3,
    (SELECT count(*) FROM tmp_base WHERE ckd_on_or_before_lm IS NULL
        AND (death_date IS NULL OR death_date > landmark_date)
        AND obs_end_date >= landmark_date)                                                        AS n4)
SELECT 1, 'Persons with a T2DM (201826+desc) condition record', n0, 0 FROM s
UNION ALL SELECT 2, 'Index date inside an observation period', n1, n0 - n1 FROM s
UNION ALL SELECT 3, 'Excluded: CKD on/before landmark (index+90d)', n2, n1 - n2 FROM s
UNION ALL SELECT 4, 'Excluded: death on/before landmark', n3, n2 - n3 FROM s
UNION ALL SELECT 5, 'Excluded: observation period ends before landmark (final cohort)', n4, n3 - n4 FROM s;

-- ---------------------------------------------------------------------------
-- 4. Analytic table
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS results.t2dm_ckd_analytic;
CREATE TABLE results.t2dm_ckd_analytic AS
WITH elig AS (
  SELECT * FROM tmp_base
  WHERE ckd_on_or_before_lm IS NULL
    AND (death_date IS NULL OR death_date > landmark_date)
    AND obs_end_date >= landmark_date
), ev AS (
  SELECT e.*,
    CASE
      WHEN e.first_ckd_after IS NOT NULL AND e.first_ckd_after <= e.obs_end_date
           AND (e.death_date IS NULL OR e.first_ckd_after <= e.death_date) THEN 1
      WHEN e.death_date IS NOT NULL AND e.death_date <= e.obs_end_date THEN 2
      ELSE 0 END AS event_type
  FROM elig e
)
SELECT
  ev.person_id,
  ev.index_date,
  ev.landmark_date,
  CASE ev.event_type WHEN 1 THEN ev.first_ckd_after
                     WHEN 2 THEN ev.death_date
                     ELSE ev.obs_end_date END                      AS followup_end_date,
  CASE ev.event_type WHEN 1 THEN ev.first_ckd_after
                     WHEN 2 THEN ev.death_date END                 AS event_date,
  (CASE ev.event_type WHEN 1 THEN ev.first_ckd_after
                      WHEN 2 THEN ev.death_date
                      ELSE ev.obs_end_date END - ev.landmark_date) AS time_days,
  ev.event_type,
  EXISTS (SELECT 1 FROM cdm.drug_exposure de JOIN tmp_met m ON m.concept_id = de.drug_concept_id
           WHERE de.person_id = ev.person_id
             AND de.drug_exposure_start_date BETWEEN ev.index_date AND ev.index_date + 90)::int AS metformin_early,
  ROUND(((ev.index_date - COALESCE(p.birth_datetime::date,
          make_date(p.year_of_birth, COALESCE(p.month_of_birth, 7), COALESCE(p.day_of_birth, 1)))) / 365.25)::numeric, 2) AS age_at_index,
  CASE p.gender_concept_id WHEN 8532 THEN 'F' WHEN 8507 THEN 'M' END AS sex,
  (p.gender_concept_id = 8532)::int                                   AS sex_female,
  EXTRACT(year FROM ev.index_date)::int                               AS index_year,
  EXISTS (SELECT 1 FROM cdm.condition_occurrence c JOIN tmp_htn x ON x.concept_id = c.condition_concept_id
           WHERE c.person_id = ev.person_id AND c.condition_start_date < ev.landmark_date)::int AS hypertension,
  EXISTS (SELECT 1 FROM cdm.condition_occurrence c JOIN tmp_hld x ON x.concept_id = c.condition_concept_id
           WHERE c.person_id = ev.person_id AND c.condition_start_date < ev.landmark_date)::int AS hyperlipidemia,
  EXISTS (SELECT 1 FROM cdm.condition_occurrence c JOIN tmp_obs x ON x.concept_id = c.condition_concept_id
           WHERE c.person_id = ev.person_id AND c.condition_start_date < ev.landmark_date)::int AS obesity,
  EXISTS (SELECT 1 FROM cdm.condition_occurrence c JOIN tmp_hf x ON x.concept_id = c.condition_concept_id
           WHERE c.person_id = ev.person_id AND c.condition_start_date < ev.landmark_date)::int AS heart_failure
FROM ev
JOIN cdm.person p ON p.person_id = ev.person_id;

ALTER TABLE results.t2dm_ckd_analytic ADD PRIMARY KEY (person_id);

-- ---------------------------------------------------------------------------
-- 5. Assertions (raise on failure)
-- ---------------------------------------------------------------------------
DO $$
DECLARE n_rows int; n_ids int; n_neg int; n_final int; n_bad_type int; n_null int;
BEGIN
  SELECT count(*), count(DISTINCT person_id) INTO n_rows, n_ids FROM results.t2dm_ckd_analytic;
  IF n_rows <> n_ids THEN RAISE EXCEPTION 'person_id not unique (% rows, % ids)', n_rows, n_ids; END IF;
  SELECT count(*) INTO n_neg FROM results.t2dm_ckd_analytic WHERE time_days < 0;
  IF n_neg > 0 THEN RAISE EXCEPTION '% rows with negative follow-up', n_neg; END IF;
  SELECT n_remaining INTO n_final FROM results.t2dm_ckd_attrition WHERE step_order = 5;
  IF n_final <> n_rows THEN RAISE EXCEPTION 'attrition final N (%) <> table rows (%)', n_final, n_rows; END IF;
  SELECT count(*) INTO n_bad_type FROM results.t2dm_ckd_analytic WHERE event_type NOT IN (0,1,2);
  IF n_bad_type > 0 THEN RAISE EXCEPTION 'invalid event_type values'; END IF;
  SELECT count(*) INTO n_null FROM results.t2dm_ckd_analytic
   WHERE age_at_index IS NULL OR sex IS NULL OR followup_end_date IS NULL OR time_days IS NULL
      OR (event_type > 0 AND event_date IS NULL);
  IF n_null > 0 THEN RAISE EXCEPTION '% rows with unexpected NULLs', n_null; END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 6. Sensitivity: CKD OR diabetic kidney disease (192279+desc). Event counts only;
--    does NOT replace the primary endpoint. Same primary cohort, additionally
--    excluding people with a DKD record on/before landmark.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS results.t2dm_ckd_sensitivity;
CREATE TABLE results.t2dm_ckd_sensitivity AS
WITH c AS (
  SELECT a.person_id, a.metformin_early, a.event_type AS primary_event_type,
         b.death_date, b.obs_end_date, b.first_ckd_after,
         LEAST(b.first_ckd_after, b.first_dkd_after) AS first_comb_after
  FROM results.t2dm_ckd_analytic a
  JOIN tmp_base b USING (person_id)
  WHERE b.dkd_on_or_before_lm IS NULL
)
SELECT
  count(*)                                                                           AS n_at_risk,
  (SELECT count(*) FROM results.t2dm_ckd_analytic) - count(*)                        AS n_excluded_dkd_on_or_before_landmark,
  count(*) FILTER (WHERE primary_event_type = 1)                                     AS primary_ckd_events_same_cohort,
  count(*) FILTER (WHERE first_comb_after <= obs_end_date
                     AND (death_date IS NULL OR first_comb_after <= death_date))     AS ckd_or_dkd_events,
  count(*) FILTER (WHERE metformin_early = 1 AND first_comb_after <= obs_end_date
                     AND (death_date IS NULL OR first_comb_after <= death_date))     AS ckd_or_dkd_events_metformin
FROM c;

-- ---------------------------------------------------------------------------
-- Result sections
-- ---------------------------------------------------------------------------
SELECT '1_attrition' AS section, * FROM results.t2dm_ckd_attrition ORDER BY step_order;
SELECT '2_event_by_metformin' AS section, metformin_early, event_type, count(*) AS n,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY time_days) AS median_time_days
FROM results.t2dm_ckd_analytic GROUP BY 2,3 ORDER BY 2,3;
SELECT '3_sensitivity_ckd_plus_dkd' AS section, * FROM results.t2dm_ckd_sensitivity;

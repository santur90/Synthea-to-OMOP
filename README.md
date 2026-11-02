# Synthea-to-OMOP

End-to-end OMOP CDM 5.4 pipeline and time-to-event analysis on synthetic EHR data.

**Time-to-event analysis of incident CKD in a synthetic OMOP T2DM cohort.**

> **All data are synthetic (Synthea). Every result here is a methodology demonstration, not clinical evidence.**
> This is a descriptive time-to-event analysis, not a prediction model.

## Purpose and architecture
An end-to-end, reproducible pipeline:

```
Synthea (CSV) → OMOP CDM v5.4 (PostgreSQL) → DataQualityDashboard → landmark T2DM cohort → Cox / Aalen-Johansen
```

| Stage | Code | Output |
|---|---|---|
| Generate Synthea (10,000 pop., seed 42, Massachusetts, CSV only) | `scripts/generate_synthea.sh` | `data/synthea/` |
| Load OMOP vocabularies | `R/01_load_vocab.R` | `cdm` schema |
| ETL (ETLSyntheaBuilder) | `R/02_etl.R`, `python/align_synthea_csv.py` | `cdm`, `native` schemas |
| Data quality | `R/03_dqd.R`, `R/04_dqd_review.R` | `output/dqd/` |
| Feasibility exploration | `sql/01_*.sql`, `sql/02_*.sql` | read-only |
| Analytic cohort | `sql/03_build_analytic_cohort.sql` | `results.t2dm_ckd_*` |
| Survival analysis | `python/analysis/survival.py` | `output/tables`, `output/figures` |

## Setup
1. `cp .env.example .env` and set `DB_USER` and `DB_PASSWORD` (plus optional `DB_HOST`, `DB_PORT`, `DB_NAME`). Credentials are read from environment variables only; never commit `.env`.
2. Requirements: Java (Synthea), R (DatabaseConnector, ETLSyntheaBuilder, DataQualityDashboard), Python 3 (`pip install -r python/requirements.txt`), PostgreSQL. `psql` is **not** required.
3. Download vocabularies from [Athena](https://athena.ohdsi.org) into `vocab/`.

## Usage
| Target | Description |
|---|---|
| `make synthea` | Generate Synthea CSVs and `RUN_INFO.txt` |
| `make vocab` | Load OMOP vocabulary |
| `make etl` | Synthea → OMOP CDM (drops and recreates the `native` schema; never the `cdm` schema) |
| `make dqd` | Run DataQualityDashboard |
| `make cohort` | Build `results.t2dm_ckd_analytic` via `python/run_sql.py` |
| `make survival` | Cox, Kaplan-Meier, Aalen-Johansen, forest plot; log in `output/logs/survival.log` |
| `make analysis` | `cohort` then `survival` |
| `make test` | pytest suite (DB tests skip if no database) |
| `make all` | Everything |

## Results (synthetic data)

### OMOP CDM 5.4 core row counts
| Table | Rows |
|---|---|
| person | 11,468 |
| observation_period | 11,468 |
| condition_occurrence | 192,944 |
| drug_exposure | 752,163 |
| measurement | 5,762,946 |
| visit_occurrence | 602,551 |
| death | 1,375 |

### Data quality (DQD 2.9.1, `cdm` schema, COST excluded)
**1,464 of 1,484 evaluable pass/fail checks passed (98.65%)**; 20 failed. A further 33 checks errored and 836 were not applicable, so they are not counted in the pass rate (2,320 checks total). See `output/dqd/`.

Reviewed limitations (`output/dqd/dqd_review_summary.csv`; no root cause is assumed):
- **COST** was not loaded (insertion was prohibitively slow locally) and is excluded from the scan. COST-related results are not evidence about the core CDM.
- The `results.cohort` / `cohort_definition` tables were absent at scan time: 2 failures and 46 errored checks are `expected_missing_optional_table`.
- 18 failures remain `requires_review` (concept completeness, plausibility of some drug and payer fields). `drug_exposure.quantity` and dose were flagged as unsuitable and are **never used** in the analysis.

### Landmark cohort (`sql/03_build_analytic_cohort.sql`)
- Index: first T2DM condition (concept 201826 + descendants) inside an observation period. Landmark = index + 90 days.
- Exclusions: CKD (46271022 + descendants), death, or end of observation on/before (death/CKD) or before (observation) the landmark.
- Follow-up from landmark to first CKD, death, or observation end. Event 1 = incident CKD; event 2 = death before CKD (competing); 0 = censored.
- Covariates before the landmark: age, sex, index year, hypertension, hyperlipidemia, obesity (heart failure kept only in descriptives: 6/796 patients).

| Step | Remaining |
|---|---|
| T2DM record, index in an observation period | 843 |
| Excluded: CKD on/before landmark (22) | 821 |
| Excluded: death on/before landmark (1) | 820 |
| Excluded: observation ends before landmark (24) | **796** |

Final cohort: **256 CKD events, 110 competing deaths, 430 censored.** Sensitivity endpoint (CKD or diabetic kidney disease 192279): 264 events in 791 patients; it does not replace the primary endpoint.

### Primary cause-specific Cox model (incident CKD, N = 796, 256 events, ridge penalizer 0.01)
| Covariate | HR | 95% CI | p |
|---|---|---|---|
| Early metformin (**exploratory**) | 1.12 | 0.62-2.03 | 0.72 |
| Age (per year) | 1.00 | 0.99-1.01 | 0.98 |
| Female | 0.88 | 0.69-1.13 | 0.32 |
| Index year (per 10 y) | 1.19 | 1.08-1.31 | 0.0007 |
| Hypertension | 0.98 | 0.75-1.27 | 0.86 |
| Hyperlipidemia | 0.97 | 0.64-1.46 | 0.88 |
| Obesity | 0.81 | 0.62-1.06 | 0.13 |

Schoenfeld proportional-hazards test (rank time): only hypertension was flagged (p = 0.030); all others p > 0.18. The model was not altered in response. A sensitivity model including heart failure (HR 0.21, CI 0.001-33.4, uninformative) is saved separately. A secondary cause-specific model for death is also saved and not interpreted. Forest plot: `output/figures/cox_primary_ckd_forest.png`.

### Competing-risk cumulative incidence, overall (Aalen-Johansen)
| Years | CKD | Death before CKD |
|---|---|---|
| 1 | 0.019 | 0.010 |
| 5 | 0.101 | 0.027 |
| 10 | 0.188 | 0.063 |
| 20 | 0.337 | 0.139 |

Per-group values are in `output/tables/aj_cumulative_incidence_by_year.csv` and must not be read causally.

### Metformin: exploratory and non-causal
Early metformin (ingredient 1503297, days 0-90 from index) occurred in 93 patients with 12 CKD events. Its estimate is imprecise and is strongly tied to the index calendar era. It is reported only as an exploratory covariate, **not as a treatment effect**.

## Limitations
- **Synthetic data**: associations reflect the Synthea generator, not real patients.
- **Calendar-time confounding**: index years span 1947-2026, and metformin use rises sharply by era; index year is also associated with CKD hazard.
- **Sparse exposed events**: only 12 CKD events among 93 exposed patients (6 patients with heart failure).
- **Incomplete COST ETL**: COST is not loaded or assessed.
- **Phenotype representation**: Synthea's condition coding (e.g. diabetic kidney disease and complication concepts, BMI-based obesity concepts) may not mirror real-world phenotypes; 794 complication-only patients without a 201826 record are excluded from the primary cohort.
- **Aalen-Johansen ties**: lifelines randomly jitters tied event times (fixed seed 42), so cumulative-incidence values are reproducible but approximate; late-time estimates in small groups are unstable.

## Layout
`config/` settings · `R/` load/ETL/DQD · `sql/` feasibility and cohort SQL · `python/run_sql.py` SQL runner · `python/analysis/` analysis · `scripts/` helpers · `tests/` pytest

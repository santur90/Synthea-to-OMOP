-include .env
export

PYTHON ?= python
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: all synthea vocab etl dqd cohort survival analysis test

all: synthea vocab etl dqd cohort survival

synthea:
	bash scripts/generate_synthea.sh

vocab:
	Rscript R/01_load_vocab.R

etl:
	Rscript R/02_etl.R

dqd:
	Rscript R/03_dqd.R

# Builds results.t2dm_ckd_analytic (needs DB_USER / DB_PASSWORD; no psql required)
cohort:
	$(PYTHON) python/run_sql.py sql/03_build_analytic_cohort.sql

survival:
	mkdir -p output/logs
	$(PYTHON) python/analysis/survival.py 2>&1 | tee output/logs/survival.log

# Cohort build followed by the survival analysis (phenotyping is not implemented yet)
analysis: cohort survival

test:
	$(PYTHON) -m pytest tests -v

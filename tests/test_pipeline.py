"""Tests for the SQL runner, analytic dataset integrity and required outputs.

Database tests are skipped when DB credentials are unavailable or the database
is unreachable; they never write to the database.
"""
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

REQUIRED_TABLES = [
    "attrition", "baseline_characteristics", "event_summary", "sensitivity_ckd_plus_dkd_counts",
    "metformin_exploratory_note", "cox_primary_ckd_adjusted_hr", "cox_primary_ckd_ph_test",
    "cox_sensitivity_ckd_with_heart_failure_adjusted_hr", "cox_secondary_death_adjusted_hr",
    "aj_cumulative_incidence_by_year",
]
REQUIRED_FIGURES = [
    "km_ckd_free_overall", "km_ckd_free_by_metformin", "aj_cumulative_incidence_ckd",
    "aj_cumulative_incidence_death", "cox_primary_ckd_forest",
]


def test_sql_runner_fails_without_credentials():
    env = {k: v for k, v in os.environ.items() if k not in ("DB_USER", "DB_PASSWORD")}
    r = subprocess.run(
        [sys.executable, str(ROOT / "python" / "run_sql.py"), str(ROOT / "sql" / "03_build_analytic_cohort.sql")],
        env=env, capture_output=True, text=True, timeout=60)
    assert r.returncode != 0
    assert "DB_USER" in r.stderr and "DB_PASSWORD" in r.stderr


def test_split_statements_keeps_dollar_blocks():
    from run_sql import split_statements
    sql = "-- c\nSELECT 1;\nDO $$\nBEGIN\n  PERFORM 1;\nEND $$;\nSELECT 2;"
    assert len(split_statements(sql)) == 3


@pytest.fixture(scope="module")
def analytic():
    pd = pytest.importorskip("pandas")
    if not (os.environ.get("DB_USER") and os.environ.get("DB_PASSWORD")):
        pytest.skip("DB credentials not set")
    from run_sql import connect
    try:
        conn = connect()
    except Exception as exc:  # unreachable DB or missing driver
        pytest.skip(f"database unavailable: {type(exc).__name__}")
    try:
        cur = conn.cursor()
        cur.execute("SELECT * FROM results.t2dm_ckd_analytic")
        return pd.DataFrame(cur.fetchall(), columns=[d[0] for d in cur.description])
    except Exception as exc:
        pytest.skip(f"results.t2dm_ckd_analytic unavailable: {type(exc).__name__}")
    finally:
        conn.close()


def test_one_row_per_person(analytic):
    assert len(analytic) > 0
    assert analytic["person_id"].is_unique


def test_event_type_values(analytic):
    assert set(analytic["event_type"].unique()) <= {0, 1, 2}


def test_time_days_nonnegative(analytic):
    assert (analytic["time_days"] >= 0).all()


def test_followup_consistent(analytic):
    delta = (analytic["followup_end_date"] - analytic["landmark_date"]).apply(lambda d: d.days)
    assert (analytic["time_days"] == delta).all()
    events = analytic[analytic["event_type"] > 0]
    assert events["event_date"].notna().all()
    assert (events["event_date"] == events["followup_end_date"]).all()


@pytest.mark.parametrize("name", REQUIRED_TABLES)
def test_required_tables_exist(name):
    assert (ROOT / "output" / "tables" / f"{name}.csv").is_file()


@pytest.mark.parametrize("name", REQUIRED_FIGURES)
def test_required_figures_exist(name):
    assert (ROOT / "output" / "figures" / f"{name}.png").is_file()

"""Survival analysis of results.t2dm_ckd_analytic.

SYNTHETIC-DATA METHODOLOGY DEMONSTRATION - NOT CLINICAL EVIDENCE.
Metformin is an exploratory covariate only; no causal treatment effect is claimed.
DB credentials come from environment variables (DB_USER, DB_PASSWORD, DB_HOST, DB_PORT, DB_NAME).
"""
import os
import sys
import warnings
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from lifelines import AalenJohansenFitter, CoxPHFitter, KaplanMeierFitter
from lifelines.statistics import logrank_test, proportional_hazard_test
from sqlalchemy import create_engine
from sqlalchemy.engine import URL

LABEL = "SYNTHETIC-DATA METHODOLOGY DEMONSTRATION - NOT CLINICAL EVIDENCE"
ROOT = Path(__file__).resolve().parents[2]
TABLE_DIR = ROOT / "output" / "tables"
FIG_DIR = ROOT / "output" / "figures"
RESULTS_SCHEMA = "results"
DAYS_PER_YEAR = 365.25
# Heart failure (6/796 patients) is excluded from the primary model; kept in a labelled sensitivity model.
COVARIATES = ["metformin_early", "age_at_index", "sex_female", "index_decade",
              "hypertension", "hyperlipidemia", "obesity"]
COVARIATES_SENS = COVARIATES + ["heart_failure"]
BINARY = ["metformin_early", "sex_female", "hypertension", "hyperlipidemia", "obesity", "heart_failure"]
PENALIZER = 0.01


def get_engine():
    missing = [k for k in ("DB_USER", "DB_PASSWORD") if not os.environ.get(k)]
    if missing:
        sys.exit(f"Missing required environment variable(s): {', '.join(missing)}")
    url = URL.create(
        "postgresql+psycopg2",
        username=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        host=os.environ.get("DB_HOST", "localhost"),
        port=int(os.environ.get("DB_PORT", "5432")),
        database=os.environ.get("DB_NAME", "omop"),
    )
    return create_engine(url)


def save_table(df, name):
    """Write CSV with a leading '#' label line (read with comment='#')."""
    TABLE_DIR.mkdir(parents=True, exist_ok=True)
    with open(TABLE_DIR / f"{name}.csv", "w") as fh:
        fh.write(f"# {LABEL}\n")
        df.to_csv(fh, index=False)
    print(f"\n[{name}]  ({LABEL})\n{df.to_string(index=False)}")


def save_fig(fig, name):
    FIG_DIR.mkdir(parents=True, exist_ok=True)
    fig.text(0.5, 0.01, LABEL, ha="center", fontsize=8, color="firebrick")
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    fig.savefig(FIG_DIR / f"{name}.png", dpi=150)
    plt.close(fig)


def load(engine):
    df = pd.read_sql(f"SELECT * FROM {RESULTS_SCHEMA}.t2dm_ckd_analytic", engine)
    attr = pd.read_sql(f"SELECT * FROM {RESULTS_SCHEMA}.t2dm_ckd_attrition ORDER BY step_order", engine)
    sens = pd.read_sql(f"SELECT * FROM {RESULTS_SCHEMA}.t2dm_ckd_sensitivity", engine)
    assert df["person_id"].is_unique and (df["time_days"] >= 0).all()
    df["age_at_index"] = df["age_at_index"].astype(float)
    df["time_years"] = df["time_days"] / DAYS_PER_YEAR
    df["index_decade"] = (df["index_year"] - 2000) / 10.0  # HR is per 10 calendar years
    df["ckd_event"] = (df["event_type"] == 1).astype(int)
    df["death_event"] = (df["event_type"] == 2).astype(int)
    df["metformin_label"] = np.where(df["metformin_early"] == 1, "Early metformin", "No early metformin")
    return df, attr, sens


def groups(df):
    return [("Overall", df)] + list(df.groupby("metformin_label"))


def descriptive_tables(df, attr, sens):
    save_table(attr, "attrition")
    save_table(sens, "sensitivity_ckd_plus_dkd_counts")

    rows = []
    for label, g in groups(df):
        r = {"group": label, "N": len(g),
             "age_median": g["age_at_index"].median(),
             "age_q1": g["age_at_index"].quantile(.25), "age_q3": g["age_at_index"].quantile(.75),
             "index_year_median": g["index_year"].median()}
        for c in ["sex_female"] + BINARY[2:]:
            r[f"{c}_n"] = int(g[c].sum())
            r[f"{c}_pct"] = round(100 * g[c].mean(), 1)
        rows.append(r)
    save_table(pd.DataFrame(rows).round(2), "baseline_characteristics")

    ev = []
    for label, g in groups(df):
        py = g["time_days"].sum() / DAYS_PER_YEAR
        ev.append({"group": label, "N": len(g), "ckd_events": int(g["ckd_event"].sum()),
                   "death_before_ckd": int(g["death_event"].sum()),
                   "censored": int((g["event_type"] == 0).sum()),
                   "median_followup_years": round(g["time_years"].median(), 2),
                   "person_years": round(py, 1),
                   "ckd_rate_per_1000py": round(1000 * g["ckd_event"].sum() / py, 2)})
    ev = pd.DataFrame(ev)
    save_table(ev, "event_summary")
    return ev


def report_warnings(caught, context):
    """Print (rather than hide) numerical/convergence warnings."""
    msgs = sorted({f"{w.category.__name__}: {str(w.message).strip()[:300]}" for w in caught})
    print(f"\n[warnings: {context}] " + (f"{len(msgs)} distinct" if msgs else "none"))
    for m in msgs:
        print(f"  - {m}")


def fit_cox(df, event_col, name, covariates=COVARIATES):
    d = df[["time_years", event_col] + covariates].copy()
    # Small ridge penalty only to stabilise sparse binaries (e.g. heart failure); reported in output.
    cph = CoxPHFitter(penalizer=PENALIZER)
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        cph.fit(d, duration_col="time_years", event_col=event_col)
    report_warnings(caught, f"cox_{name} fit")
    s = cph.summary
    hr = pd.DataFrame({
        "covariate": s.index,
        "HR": s["exp(coef)"].values,
        "CI95_lower": s["exp(coef) lower 95%"].values,
        "CI95_upper": s["exp(coef) upper 95%"].values,
        "p": s["p"].values,
        "unit": ["exposed vs not" if c in BINARY else ("per year" if c == "age_at_index" else "per 10 calendar years")
                 for c in s.index],
    }).round(4)
    hr["n_events_model"] = int(d[event_col].sum())
    hr["penalizer"] = PENALIZER
    save_table(hr, f"cox_{name}_adjusted_hr")

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        ph = proportional_hazard_test(cph, d, time_transform="rank")
    report_warnings(caught, f"cox_{name} PH test")
    pht = ph.summary.reset_index().rename(columns={"index": "covariate"}).round(4)
    pht["flag_p_lt_0.05"] = pht["p"] < 0.05
    pht["note"] = "Schoenfeld-residual test (rank time); small p suggests PH violation"
    save_table(pht, f"cox_{name}_ph_test")


def plot_km(df):
    fig, ax = plt.subplots(figsize=(7, 5))
    parts = []
    for label, g in df.groupby("metformin_label"):
        KaplanMeierFitter().fit(
            g["time_years"], g["ckd_event"],
            label=f"{label} (n={len(g)}, CKD={g['ckd_event'].sum()})").plot_survival_function(ax=ax)
        parts.append(g)
    a, b = parts
    p = logrank_test(a["time_years"], b["time_years"], a["ckd_event"], b["ckd_event"]).p_value
    ax.set_title(f"Kaplan-Meier: CKD-free survival from landmark (deaths censored)\n"
                 f"exploratory log-rank p={p:.3f}")
    ax.set_xlabel("Years since landmark (index + 90 d)")
    ax.set_ylabel("Probability free of CKD")
    save_fig(fig, "km_ckd_free_by_metformin")

    fig, ax = plt.subplots(figsize=(7, 5))
    KaplanMeierFitter().fit(df["time_years"], df["ckd_event"],
                            label=f"All (n={len(df)})").plot_survival_function(ax=ax)
    ax.set_title("Kaplan-Meier: CKD-free survival from landmark (deaths censored)")
    ax.set_xlabel("Years since landmark (index + 90 d)")
    ax.set_ylabel("Probability free of CKD")
    save_fig(fig, "km_ckd_free_overall")


def fit_aj(g, event, label):
    # lifelines' AJ jitters tied times; fixed seed keeps it reproducible
    return AalenJohansenFitter(seed=42, calculate_variance=True).fit(
        g["time_years"], g["event_type"], event_of_interest=event, label=label)


def plot_aj(df):
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        for event, tag, title, other in [(1, "ckd", "CKD", "death"), (2, "death", "death before CKD", "CKD")]:
            fig, ax = plt.subplots(figsize=(7, 5))
            for label, g in groups(df):
                fit_aj(g, event, f"{label} (n={len(g)})").plot(ax=ax)
            ax.set_title(f"Aalen-Johansen cumulative incidence of {title}\n(competing risk: {other})")
            ax.set_xlabel("Years since landmark (index + 90 d)")
            ax.set_ylabel("Cumulative incidence")
            save_fig(fig, f"aj_cumulative_incidence_{tag}")

        rows = []
        for label, g in groups(df):
            ci = fit_aj(g, 1, label).cumulative_density_.iloc[:, 0]
            cd = fit_aj(g, 2, label).cumulative_density_.iloc[:, 0]
            for yr in (1, 5, 10, 20):
                i1, i2 = ci.index[ci.index <= yr], cd.index[cd.index <= yr]
                rows.append({"group": label, "years": yr,
                             "ckd_cumulative_incidence": round(float(ci.loc[i1[-1]]), 4) if len(i1) else np.nan,
                             "death_cumulative_incidence": round(float(cd.loc[i2[-1]]), 4) if len(i2) else np.nan})
        save_table(pd.DataFrame(rows), "aj_cumulative_incidence_by_year")
    report_warnings(caught, "Aalen-Johansen")


FOREST_LABELS = {
    "metformin_early": "Early metformin (exploratory, non-causal)",
    "age_at_index": "Age at index (per year)",
    "sex_female": "Female sex",
    "index_decade": "Index year (per 10 calendar years)",
    "hypertension": "Hypertension",
    "hyperlipidemia": "Hyperlipidemia",
    "obesity": "Obesity",
}


def plot_forest(csv_path=None):
    """Forest plot from the saved primary-model table; does not refit anything."""
    csv_path = csv_path or TABLE_DIR / "cox_primary_ckd_adjusted_hr.csv"
    hr = pd.read_csv(csv_path, comment="#").iloc[::-1].reset_index(drop=True)
    y = np.arange(len(hr))
    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.errorbar(hr["HR"], y, xerr=[hr["HR"] - hr["CI95_lower"], hr["CI95_upper"] - hr["HR"]],
                fmt="s", color="black", ecolor="gray", capsize=3)
    ax.axvline(1, color="firebrick", linestyle="--", linewidth=1)
    ax.set_xscale("log")
    ax.set_yticks(y)
    ax.set_yticklabels([FOREST_LABELS.get(c, c) for c in hr["covariate"]])
    for yi, row in hr.iterrows():
        ax.annotate(f"{row['HR']:.2f} ({row['CI95_lower']:.2f}-{row['CI95_upper']:.2f})",
                    (row["CI95_upper"], yi), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=7)
    ax.set_xlabel("Adjusted hazard ratio (log scale), 95% CI")
    n_ev = int(hr["n_events_model"].iloc[0])
    ax.set_title(f"Primary cause-specific Cox: incident CKD ({n_ev} events)\n"
                 "metformin estimate is exploratory (few exposed events)", fontsize=10)
    ax.margins(x=0.35)
    save_fig(fig, "cox_primary_ckd_forest")


def main():
    if "--forest-only" in sys.argv:
        plot_forest()
        print(f"Saved {FIG_DIR / 'cox_primary_ckd_forest.png'}")
        return
    df, attr, sens = load(get_engine())
    print(LABEL)
    ev = descriptive_tables(df, attr, sens)

    exp = ev[ev["group"] == "Early metformin"].iloc[0]
    tot = ev[ev["group"] == "Overall"].iloc[0]
    print(f"\nEXPLORATORY metformin analysis: {int(exp['N'])} exposed patients, "
          f"{int(exp['ckd_events'])} exposed CKD events (of {int(tot['ckd_events'])} total). "
          "Estimates are imprecise and confounded by index era; NOT a treatment effect.")
    save_table(pd.DataFrame([{
        "exposed_n": int(exp["N"]), "exposed_ckd_events": int(exp["ckd_events"]),
        "total_ckd_events": int(tot["ckd_events"]),
        "interpretation": "exploratory covariate only; not a causal treatment effect"}]),
        "metformin_exploratory_note")

    fit_cox(df, "ckd_event", "primary_ckd")        # primary cause-specific model
    fit_cox(df, "ckd_event", "sensitivity_ckd_with_heart_failure", COVARIATES_SENS)  # sensitivity only
    fit_cox(df, "death_event", "secondary_death")  # complementary cause-specific model
    plot_forest()
    plot_km(df)
    plot_aj(df)
    print(f"\nTables: {TABLE_DIR}\nFigures: {FIG_DIR}")


if __name__ == "__main__":
    main()

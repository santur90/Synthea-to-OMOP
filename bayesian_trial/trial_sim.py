"""Biomarker-stratified two-arm trial simulation with a fast Bayesian (normal-normal) analysis."""
import numpy as np
import pandas as pd
from scipy.stats import norm

PRIOR_SD = 1.0
HR_TARGET = 0.80
SUCCESS_P, FUTILITY_P = 0.95, 0.20   # simulation decision rules, not regulatory standards


def logrank_loghr(time, event, arm):
    """Peto log-HR estimate and SE: (O-E)/V, 1/sqrt(V). arm: 1 = treatment."""
    O = E = V = 0.0
    for t in np.unique(time[event == 1]):
        at = time >= t
        n, n1 = at.sum(), (at & (arm == 1)).sum()
        d = ((time == t) & (event == 1)).sum()
        d1 = ((time == t) & (event == 1) & (arm == 1)).sum()
        O += d1
        E += d * n1 / n
        if n > 1:
            V += d * (n1 / n) * (1 - n1 / n) * (n - d) / (n - 1)
    if V <= 0:
        return np.nan, np.nan
    return (O - E) / V, 1 / np.sqrt(V)


def one_trial(rng, n=400, prev=0.30, hr_pos=0.75, hr_neg=1.0, median_ctrl=18,
              accrual=18, followup=12, dropout_yr=0.07):
    lam0 = np.log(2) / median_ctrl
    pos = rng.random(n) < prev
    arm = rng.integers(0, 2, n)
    hr = np.where(pos, hr_pos, hr_neg)
    T = rng.exponential(1 / (lam0 * np.where(arm == 1, hr, 1.0)))
    entry = rng.uniform(0, accrual, n)
    drop = rng.exponential(1 / (-np.log(1 - dropout_yr) / 12), n)
    cutoff = accrual + followup
    obs = np.minimum.reduce([T, drop, cutoff - entry])
    ev = (T <= np.minimum(drop, cutoff - entry)).astype(int)
    out = {}
    for name, mask in [("pos", pos), ("neg", ~pos), ("all", np.ones(n, bool))]:
        est, se = logrank_loghr(obs[mask], ev[mask], arm[mask])
        out[name] = (est, se, int(ev[mask].sum()))
    return out

def one_enriched_trial(
    rng,
    n=400,
    hr=0.65,
    median_ctrl=18,
    accrual=18,
    followup=12,
    dropout_yr=0.07,
):
    """Biomarker-positive enrichment trial."""

    lam0 = np.log(2) / median_ctrl

    arm = rng.integers(0, 2, n)

    T = rng.exponential(
        1 / (lam0 * np.where(arm == 1, hr, 1.0))
    )

    entry = rng.uniform(0, accrual, n)

    drop = rng.exponential(
        1 / (-np.log(1 - dropout_yr) / 12),
        n,
    )

    cutoff = accrual + followup

    obs = np.minimum.reduce(
        [T, drop, cutoff - entry]
    )

    event = (
        T <= np.minimum(drop, cutoff - entry)
    ).astype(int)

    est, se = logrank_loghr(
        obs,
        event,
        arm,
    )

    return est, se, int(event.sum())

def run_enrichment_grid(
    n_sim=500,
    seed=123,
):
    rng = np.random.default_rng(seed)

    rows = []

    for n in [200, 400, 600, 800, 1200]:
        for true_hr in [0.65, 0.75, 0.85, 1.00]:

            success = 0
            futility = 0
            events = []
            posterior_hr = []

            for _ in range(n_sim):

                est, se, d = one_enriched_trial(
                    rng,
                    n=n,
                    hr=true_hr,
                )

                if np.isnan(est):
                    continue

                mu, sd = posterior(est, se)

                p = norm.cdf(
                    (np.log(HR_TARGET) - mu) / sd
                )

                success += p >= SUCCESS_P
                futility += p <= FUTILITY_P

                events.append(d)
                posterior_hr.append(np.exp(mu))

            rows.append(
                dict(
                    sample_size=n,
                    true_hr=true_hr,
                    n_sim=n_sim,
                    success_probability=success / n_sim,
                    futility_probability=futility / n_sim,
                    mean_events=np.mean(events),
                    mean_posterior_hr=np.mean(posterior_hr),
                )
            )

    return pd.DataFrame(rows).round(3)


def posterior(est, se):
    prec = 1 / PRIOR_SD**2 + 1 / se**2
    return (est / se**2) / prec, np.sqrt(1 / prec)


def run_scenarios(n_sim=500, seed=7, **kw):
    rng = np.random.default_rng(seed)
    rows = []
    for hr_pos in (0.65, 0.75, 0.85, 1.0):
        for hr_neg in (0.90, 1.0):
            res = {"pos": [0, 0, [], []], "all": [0, 0, [], []]}
            for _ in range(n_sim):
                trial = one_trial(rng, hr_pos=hr_pos, hr_neg=hr_neg, **kw)
                for key, acc in res.items():
                    est, se, d = trial[key]
                    if np.isnan(est):
                        continue
                    mu, sd = posterior(est, se)
                    p = norm.cdf((np.log(HR_TARGET) - mu) / sd)   # P(HR < 0.80 | data)
                    acc[0] += p >= SUCCESS_P
                    acc[1] += p <= FUTILITY_P
                    acc[2].append(d); acc[3].append(mu)
            rows.append(dict(hr_pos=hr_pos, hr_neg=hr_neg, n_sim=n_sim,
                             success_biomarker_pos=res["pos"][0] / n_sim,
                             futility_biomarker_pos=res["pos"][1] / n_sim,
                             success_all_comers=res["all"][0] / n_sim,
                             events_pos_mean=np.mean(res["pos"][2]),
                             post_HR_pos=np.exp(np.mean(res["pos"][3]))))
    return pd.DataFrame(rows).round(3)


if __name__ == "__main__":
    all_results = []

    for n in [400, 600, 800, 1200]:
        print(f"\nRunning sample size N={n} ...")

        df = run_scenarios(
            n_sim=500,
            n=n,
            prev=0.30
        )

        df["sample_size"] = n
        all_results.append(df)

    out = pd.concat(all_results, ignore_index=True)

    print("\nFINAL RESULTS")
    print(out.to_string(index=False))

    out.to_csv(
        "trial_operating_characteristics_by_sample_size.csv",
        index=False
    )

    print(
        "\nSaved trial_operating_characteristics_by_sample_size.csv"
    )

def refine_enrichment_threshold(
    n_sim=2000,
    seed=2026,
):
    rng = np.random.default_rng(seed)

    rows = []

    for n in [1000, 1100, 1200, 1300, 1400, 1600]:

        success = 0
        futility = 0
        events = []

        for _ in range(n_sim):

            est, se, d = one_enriched_trial(
                rng,
                n=n,
                hr=0.65,
            )

            if np.isnan(est):
                continue

            mu, sd = posterior(est, se)

            p_success = norm.cdf(
                (np.log(HR_TARGET) - mu) / sd
            )

            success += p_success >= SUCCESS_P
            futility += p_success <= FUTILITY_P

            events.append(d)

        p = success / n_sim

        mcse = np.sqrt(
            p * (1 - p) / n_sim
        )

        rows.append(
            dict(
                sample_size=n,
                true_hr=0.65,
                n_sim=n_sim,
                success_probability=p,
                success_mcse=mcse,
                success_mc95_low=max(0, p - 1.96 * mcse),
                success_mc95_high=min(1, p + 1.96 * mcse),
                futility_probability=futility / n_sim,
                mean_events=np.mean(events),
            )
        )

    return pd.DataFrame(rows).round(4)


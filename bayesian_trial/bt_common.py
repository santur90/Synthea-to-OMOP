"""Piecewise-exponential Bayesian survival with a time-updated biomarker (PyMC)."""
import numpy as np
import pandas as pd
import pymc as pm
import pytensor.tensor as pt

BREAKS = np.array([0, 3, 6, 12, 18, 24, 36.0])  # months; last break must be >= max follow-up
TRUE = dict(b_arm=np.log(0.75), b_bm=0.30, b_int=-0.25)


def simulate_cohort(n=600, seed=1, breaks=BREAKS):
    """Synthetic patients whose hazard depends on a biomarker that drifts over time.
    Returns (pts, bm) in the same format the real-data loader must produce."""
    rng = np.random.default_rng(seed)
    base = np.array([0.05, 0.04, 0.035, 0.03, 0.03, 0.035])
    arm = rng.integers(0, 2, n)
    bm0 = rng.normal(0, 1, n)
    slope = rng.normal(0.15, 0.2, n)
    cens = np.minimum(breaks[-1], rng.exponential(60, n))
    pts, bm_rows = [], []
    for i in range(n):
        t_event, ev = cens[i], 0
        for j in range(len(breaks) - 1):
            s, e = breaks[j], breaks[j + 1]
            if s >= cens[i]:
                break
            z = bm0[i] + slope[i] * s / 6
            lam = base[j] * np.exp(TRUE["b_arm"] * arm[i] + TRUE["b_bm"] * z
                                   + TRUE["b_int"] * arm[i] * z)
            w = rng.exponential(1 / lam)
            if s + w < min(e, cens[i]):
                t_event, ev = s + w, 1
                break
        pts.append(dict(id=i, arm=arm[i], time=t_event, event=ev))
        for s in breaks[:-1]:
            if s < t_event:
                bm_rows.append(dict(id=i, t=s, value=bm0[i] + slope[i] * s / 6 + rng.normal(0, 0.05)))
    return pd.DataFrame(pts), pd.DataFrame(bm_rows)


def expand(pts, bm, breaks=BREAKS):
    """One row per patient per interval at risk. Biomarker = last value on/before interval start (LOCF).
    Every patient needs a biomarker value at t=0."""
    rows = []
    for j in range(len(breaks) - 1):
        s, e = breaks[j], breaks[j + 1]
        at = pts[pts.time > s].copy()
        at["interval"], at["start"] = j, float(s)
        at["exposure"] = np.minimum(at.time, e) - s
        at["d"] = ((at.event == 1) & (at.time <= e)).astype(int)
        rows.append(at)
    pp = pd.concat(rows, ignore_index=True).sort_values("start")
    b = bm.sort_values("t").rename(columns={"t": "bm_t"})
    pp = pd.merge_asof(pp, b, left_on="start", right_on="bm_t", by="id", direction="backward")
    assert pp["value"].notna().all(), "every patient needs a biomarker value at t=0"
    pp["bm_z"] = (pp["value"] - pp["value"].mean()) / pp["value"].std()
    return pp.reset_index(drop=True)


def build_model(pp, n_int):
    j, arm, bmz = pp.interval.values, pp.arm.values, pp.bm_z.values
    with pm.Model() as m:
        a0 = pm.Normal("a0", np.log(0.03), 2.0)                  # log-hazard, interval 0 (per month)
        sd_rw = pm.HalfNormal("sd_rw", 0.5)
        steps = pm.Normal("steps", 0, 1, shape=n_int - 1)
        alpha = pm.Deterministic("alpha", a0 + pt.concatenate([pt.zeros(1), pt.cumsum(steps) * sd_rw]))
        b_arm = pm.Normal("b_arm", 0, 1)                          # treatment log-HR
        b_bm = pm.Normal("b_bm", 0, 1)                            # log-HR per 1 SD biomarker
        b_int = pm.Normal("b_int", 0, 0.5)                        # treatment x biomarker
        eta = alpha[j] + b_arm * arm + b_bm * bmz + b_int * arm * bmz
        pm.Poisson("d", mu=pt.exp(eta) * pp.exposure.values, observed=pp.d.values)
    return m

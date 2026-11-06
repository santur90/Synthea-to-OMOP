import numpy as np, arviz as az, pymc as pm
from bt_common import *

pts, bm = simulate_cohort(n=600, seed=1)
print("patients", len(pts), "events", pts.event.sum())
pp = expand(pts, bm)
m = build_model(pp, len(BREAKS) - 1)
with m:
    prior = pm.sample_prior_predictive(random_seed=1)          # 先验预测检查
    idata = pm.sample(draws=1000, tune=1000, chains=4, target_accept=0.95, random_seed=42)
    ppc = pm.sample_posterior_predictive(idata, random_seed=1)
print(az.summary(idata, var_names=["a0", "sd_rw", "b_arm", "b_bm", "b_int"]).round(3))
print("divergences:", int(idata.sample_stats["diverging"].sum()))
print("true values:", {k: round(v, 3) for k, v in TRUE.items()})
post = idata.posterior
print("HR treatment, median:", float(np.exp(post["b_arm"]).median()),
      "| P(HR<1):", float((post["b_arm"] < 0).mean()))
sim = ppc.posterior_predictive["d"].values.sum(-1).ravel()
print("events observed", pp.d.sum(), "| posterior predictive 90% interval", np.percentile(sim, [5, 95]))
az.plot_trace(idata, var_names=["b_arm", "b_bm", "b_int"]); 
import matplotlib.pyplot as plt; plt.savefig("trace.png", dpi=120)

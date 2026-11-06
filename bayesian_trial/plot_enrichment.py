import pandas as pd
import matplotlib.pyplot as plt

allc = pd.read_csv(
    "trial_operating_characteristics_by_sample_size.csv"
)

enr = pd.read_csv(
    "enrichment_trial_operating_characteristics.csv"
)

fig, ax = plt.subplots(figsize=(8, 5))

# All-comer design:
# HR-negative = 1.0, true HR+ = 0.65
x = allc[
    (allc["hr_neg"] == 1.0) &
    (allc["hr_pos"] == 0.65)
].sort_values("sample_size")

ax.plot(
    x["sample_size"],
    x["success_biomarker_pos"],
    "o-",
    label="All-comer, 30% biomarker-positive",
)

# Enrichment design
y = enr[
    enr["true_hr"] == 0.65
].sort_values("sample_size")

ax.plot(
    y["sample_size"],
    y["success_probability"],
    "s-",
    label="Biomarker-positive enrichment",
)

ax.axhline(
    0.80,
    color="gray",
    linestyle="--",
    linewidth=1,
    label="80% operating success rate",
)

ax.set_xlabel("Randomized sample size")
ax.set_ylabel(
    "Probability trial meets Bayesian success rule"
)

ax.set_ylim(0, 1)

ax.set_title(
    "All-comer vs biomarker-enrichment trial design\n"
    "True HR+ = 0.65"
)

ax.legend()

fig.tight_layout()

fig.savefig(
    "all_comer_vs_enrichment.png",
    dpi=150,
)

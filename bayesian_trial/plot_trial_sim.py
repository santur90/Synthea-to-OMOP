import pandas as pd
import matplotlib.pyplot as plt

df = pd.read_csv(
    "trial_operating_characteristics_by_sample_size.csv"
)

fig, ax = plt.subplots(figsize=(8, 5))

sub = df[df["hr_neg"] == 1.0]

for hr, g in sub.groupby("hr_pos"):
    g = g.sort_values("sample_size")
    ax.plot(
        g["sample_size"],
        g["success_biomarker_pos"],
        marker="o",
        label=f"True HR+ = {hr:.2f}",
    )

ax.axhline(
    0.80,
    linestyle="--",
    color="gray",
    linewidth=1,
    label="80% success probability"
)

ax.set_xlabel("Total randomized sample size")
ax.set_ylabel("Probability of Bayesian trial success")
ax.set_ylim(0, 1)
ax.set_title(
    "Biomarker-positive trial operating characteristics"
)
ax.legend()

fig.tight_layout()
fig.savefig(
    "trial_success_by_sample_size.png",
    dpi=150
)

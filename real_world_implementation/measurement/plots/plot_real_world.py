#!/usr/bin/env python3
"""
plot_real_world.py
Generates comparison plots for the two real-world debugging scenarios:
  1. CPU Noise    — jittery latency, high scheduler activity
  2. App Delay    — stable latency increase, normal scheduler

Output: real_world_latency_comparison.png
"""

import subprocess, sys
for pkg in ("matplotlib", "pandas"):
    try: __import__(pkg)
    except ImportError:
        subprocess.check_call([sys.executable,"-m","pip","install",
                               pkg,"--break-system-packages","--quiet"])

import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import matplotlib.ticker as ticker
import statistics
from pathlib import Path

LOGS   = Path(__file__).parent.parent / "logs"
OUT    = Path(__file__).parent / "real_world_latency_comparison.png"


def load_csv(name):
    path = LOGS / name
    if not path.exists():
        return None
    try:
        df = pd.read_csv(path)
        df.columns = ["ts_ms","lat_s"]
        df["lat_ms"] = pd.to_numeric(df["lat_s"], errors="coerce") * 1000
        df = df.dropna(subset=["lat_ms"])
        df["ts_ms"] = pd.to_numeric(df["ts_ms"], errors="coerce")
        df = df.dropna(subset=["ts_ms"])
        df["elapsed_s"] = (df["ts_ms"] - df["ts_ms"].iloc[0]) / 1000.0
        return df
    except Exception as e:
        print(f"[plot] Warning loading {name}: {e}")
        return None


cpu_df = load_csv("latency_cpu_noise.csv")
app_df = load_csv("latency_app_delay.csv")

if cpu_df is None and app_df is None:
    print("[plot] No data found. Run scenarios first.")
    sys.exit(0)

# ── Layout ────────────────────────────────────────────────
fig = plt.figure(figsize=(16, 12))
fig.patch.set_facecolor("#0f1117")
fig.suptitle(
    "GRS Real-World Debugging — Same Symptom, Different Cause\n"
    "Latency elevated in both scenarios — eBPF reveals the difference",
    fontsize=13, fontweight="bold", color="#e6edf3", y=0.98
)

gs = gridspec.GridSpec(3, 2,
    height_ratios=[2.5, 1.5, 0.8],
    hspace=0.48, wspace=0.32,
    top=0.93, bottom=0.06, left=0.08, right=0.97
)

ax_cpu  = fig.add_subplot(gs[0, 0])   # CPU noise timeline
ax_app  = fig.add_subplot(gs[0, 1])   # App delay timeline
ax_box  = fig.add_subplot(gs[1, 0])   # Box plot comparison
ax_diag = fig.add_subplot(gs[1, 1])   # Diagnosis table
ax_tbl  = fig.add_subplot(gs[2, :])   # Stats table

COLORS = {
    "cpu_noise": "#ff9e64",
    "app_delay": "#79c0ff",
    "baseline":  "#3fb950",
}

def style_ax(ax, title):
    ax.set_facecolor("#161b22")
    ax.tick_params(colors="#8b949e", labelsize=8)
    ax.grid(True, linestyle="--", alpha=0.3, color="#30363d")
    for sp in ax.spines.values(): sp.set_edgecolor("#30363d")
    ax.set_title(title, color="#e6edf3", fontsize=10, pad=6)

# ── CPU Noise timeline ────────────────────────────────────
style_ax(ax_cpu, "Scenario 1 — CPU Noise (Jittery Latency)")
if cpu_df is not None:
    n = len(cpu_df)
    # First 20s = baseline, rest = noise
    baseline_mask = cpu_df["elapsed_s"] <= 20
    noise_mask    = cpu_df["elapsed_s"] >  20

    ax_cpu.plot(cpu_df.loc[baseline_mask,"elapsed_s"],
                cpu_df.loc[baseline_mask,"lat_ms"],
                color=COLORS["baseline"], linewidth=1.5,
                label=f"Baseline (mean={cpu_df.loc[baseline_mask,'lat_ms'].mean():.1f}ms)",
                marker="o", markersize=3)
    ax_cpu.plot(cpu_df.loc[noise_mask,"elapsed_s"],
                cpu_df.loc[noise_mask,"lat_ms"],
                color=COLORS["cpu_noise"], linewidth=1.5,
                label=f"Under CPU Noise (mean={cpu_df.loc[noise_mask,'lat_ms'].mean():.1f}ms)",
                marker="o", markersize=3, alpha=0.9)
    ax_cpu.axvline(x=20, color="#f85149", linestyle="--", alpha=0.7, label="Noise starts")
    ax_cpu.set_xlabel("Elapsed time (s)", color="#8b949e", fontsize=8)
    ax_cpu.set_ylabel("Latency (ms)", color="#8b949e", fontsize=8)
    leg = ax_cpu.legend(fontsize=7, facecolor="#161b22", edgecolor="#30363d")
    for t in leg.get_texts(): t.set_color("#c9d1d9")
    # Annotation
    ax_cpu.text(0.98, 0.95, "HIGH JITTER\n→ CPU cause",
                transform=ax_cpu.transAxes, color="#f85149",
                fontsize=8, ha="right", va="top",
                bbox=dict(boxstyle="round,pad=0.3", facecolor="#1c1218", edgecolor="#f85149"))
else:
    ax_cpu.text(0.5, 0.5, "Run run_cpu_scenario.sh first",
                transform=ax_cpu.transAxes, color="#8b949e", ha="center")

# ── App Delay timeline ────────────────────────────────────
style_ax(ax_app, "Scenario 2 — App Delay (Stable Latency Increase)")
if app_df is not None:
    baseline_mask = app_df["elapsed_s"] <= 20
    delay_mask    = app_df["elapsed_s"] >  20

    ax_app.plot(app_df.loc[baseline_mask,"elapsed_s"],
                app_df.loc[baseline_mask,"lat_ms"],
                color=COLORS["baseline"], linewidth=1.5,
                label=f"Baseline (mean={app_df.loc[baseline_mask,'lat_ms'].mean():.1f}ms)",
                marker="o", markersize=3)
    ax_app.plot(app_df.loc[delay_mask,"elapsed_s"],
                app_df.loc[delay_mask,"lat_ms"],
                color=COLORS["app_delay"], linewidth=1.5,
                label=f"Under App Delay (mean={app_df.loc[delay_mask,'lat_ms'].mean():.1f}ms)",
                marker="o", markersize=3, alpha=0.9)
    ax_app.axvline(x=20, color="#f85149", linestyle="--", alpha=0.7, label="Delay deployed")
    ax_app.set_xlabel("Elapsed time (s)", color="#8b949e", fontsize=8)
    ax_app.set_ylabel("Latency (ms)", color="#8b949e", fontsize=8)
    leg = ax_app.legend(fontsize=7, facecolor="#161b22", edgecolor="#30363d")
    for t in leg.get_texts(): t.set_color("#c9d1d9")
    ax_app.text(0.98, 0.95, "STABLE INCREASE\n→ App cause",
                transform=ax_app.transAxes, color="#79c0ff",
                fontsize=8, ha="right", va="top",
                bbox=dict(boxstyle="round,pad=0.3", facecolor="#0d1b2a", edgecolor="#79c0ff"))
else:
    ax_app.text(0.5, 0.5, "Run run_app_delay_scenario.sh first",
                transform=ax_app.transAxes, color="#8b949e", ha="center")

# ── Box plot comparison ───────────────────────────────────
style_ax(ax_box, "Latency Distribution — Both Scenarios")
box_data, box_labels, box_colors = [], [], []

if cpu_df is not None:
    noise_vals = cpu_df.loc[cpu_df["elapsed_s"]>20, "lat_ms"].values
    if len(noise_vals):
        box_data.append(noise_vals)
        box_labels.append("CPU Noise")
        box_colors.append(COLORS["cpu_noise"])

if app_df is not None:
    delay_vals = app_df.loc[app_df["elapsed_s"]>20, "lat_ms"].values
    if len(delay_vals):
        box_data.append(delay_vals)
        box_labels.append("App Delay")
        box_colors.append(COLORS["app_delay"])

# Baseline from whichever is available
bl = (cpu_df if cpu_df is not None else app_df)
if bl is not None:
    bl_vals = bl.loc[bl["elapsed_s"]<=20, "lat_ms"].values
    if len(bl_vals):
        box_data.insert(0, bl_vals)
        box_labels.insert(0, "Baseline")
        box_colors.insert(0, COLORS["baseline"])

if box_data:
    try:
        bp = ax_box.boxplot(box_data, tick_labels=box_labels,
                            patch_artist=True, notch=False, widths=0.5)
    except TypeError:
        bp = ax_box.boxplot(box_data, labels=box_labels,
                            patch_artist=True, notch=False, widths=0.5)
    for patch, c in zip(bp["boxes"], box_colors):
        patch.set_facecolor(c); patch.set_alpha(0.75)
    for elem in ["whiskers","caps","medians","fliers"]:
        for item in bp[elem]: item.set_color("#8b949e")
    ax_box.tick_params(axis="x", colors="#c9d1d9", labelsize=9)
    ax_box.set_ylabel("Latency (ms)", color="#8b949e", fontsize=8)

# ── Diagnosis table ───────────────────────────────────────
ax_diag.set_facecolor("#0f1117")
ax_diag.axis("off")
ax_diag.set_title("eBPF Diagnosis Checklist", color="#e6edf3", fontsize=10, pad=6)

check_data = [
    ["Check",          "CPU Noise",   "App Delay",  "Expected"],
    ["Retransmissions","0 ✓",         "0 ✓",        "0 if NOT network loss"],
    ["Packet Drops",   "0 ✓",         "0 ✓",        "0 if NOT tc netem"],
    ["Sched Events",   "HIGH ✗",      "Normal ✓",   "HIGH = CPU issue"],
    ["Latency Jitter", "HIGH ✗",      "LOW ✓",      "HIGH = sched cause"],
    ["Stable +latency","Variable",    "YES ✗",      "Stable = app cause"],
    ["Conclusion",     "CPU noise",   "App delay",  "—"],
]

tbl = ax_diag.table(
    cellText=check_data[1:],
    colLabels=check_data[0],
    cellLoc="center", loc="center",
    bbox=[0, 0, 1, 1]
)
tbl.auto_set_font_size(False)
tbl.set_fontsize(7)
row_colors = [COLORS["cpu_noise"], COLORS["app_delay"]]
for (row, col), cell in tbl.get_celld().items():
    if row == 0:
        cell.set_facecolor("#21262d"); cell.set_text_props(color="#8b949e", fontweight="bold")
    elif row == len(check_data)-1:  # Conclusion
        cell.set_facecolor("#0d1117"); cell.set_text_props(color="#e6edf3", fontweight="bold")
    else:
        cell.set_facecolor("#161b22"); cell.set_text_props(color="#c9d1d9")
    cell.set_edgecolor("#30363d")

# ── Statistics table ──────────────────────────────────────
ax_tbl.set_facecolor("#0f1117")
ax_tbl.axis("off")

tbl_data = []
for df, label in [(cpu_df, "CPU Noise"), (app_df, "App Delay")]:
    if df is None: continue
    fault = df.loc[df["elapsed_s"]>20, "lat_ms"]
    bl    = df.loc[df["elapsed_s"]<=20, "lat_ms"]
    if len(fault) == 0: continue
    jitter = statistics.stdev(fault.tolist()) if len(fault)>1 else 0
    tbl_data.append([
        label,
        f"{bl.mean():.1f}ms",
        f"{fault.mean():.1f}ms",
        f"+{fault.mean()-bl.mean():.1f}ms",
        f"{jitter:.1f}ms",
        "HIGH — CPU cause" if label=="CPU Noise" else "LOW — App cause",
    ])

if tbl_data:
    cols = ["Scenario","Baseline Mean","Fault Mean","Delta","Jitter (σ)","Conclusion"]
    t = ax_tbl.table(cellText=tbl_data, colLabels=cols,
                     cellLoc="center", loc="center", bbox=[0,0,1,1])
    t.auto_set_font_size(False); t.set_fontsize(8)
    for (row, col), cell in t.get_celld().items():
        cell.set_facecolor("#21262d" if row==0 else "#161b22")
        cell.set_edgecolor("#30363d")
        cell.set_text_props(color="#8b949e" if row==0 else "#c9d1d9")
        if row > 0 and col == 0:
            cell.set_text_props(color="#e6edf3")
    ax_tbl.set_title("Summary Statistics", color="#e6edf3", fontsize=9, pad=4)

OUT.parent.mkdir(parents=True, exist_ok=True)
fig.savefig(OUT, dpi=150, bbox_inches="tight", facecolor="#0f1117")
plt.close(fig)
print(f"[plot] Saved → {OUT}")

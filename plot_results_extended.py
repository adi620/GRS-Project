#!/usr/bin/env python3
"""
plot_results_extended.py — GRS Extended Latency Chart
All 7 experiments: Baseline, Delay, Loss, Bandwidth, Reordering, CPU Stress, Chaos
Saves: results/latency_comparison_extended.png
"""

import subprocess, sys, os

for pkg in ("matplotlib", "pandas"):
    try:
        __import__(pkg)
    except ImportError:
        subprocess.check_call([sys.executable, "-m", "pip", "install",
                               pkg, "--break-system-packages", "--quiet"])

import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from pathlib import Path

RESULTS_DIR = Path(__file__).parent / "results"
OUT = RESULTS_DIR / "latency_comparison_extended.png"


def safe_out_path(path):
    if path.exists():
        try:
            path.unlink()
        except PermissionError:
            alt = path.with_name(path.stem + "_new.png")
            print(f"[plot] WARNING: Cannot overwrite {path.name}. Saving to {alt.name}")
            return alt
    return path


def load(name):
    path = RESULTS_DIR / name
    if not path.exists():
        return None
    try:
        df = pd.read_csv(path, usecols=[0, 1], on_bad_lines="skip")
    except TypeError:
        df = pd.read_csv(path, usecols=[0, 1], error_bad_lines=False)
    df.columns = ["ts_ms", "lat_s"]
    df = df[df["lat_s"] != "timeout"].copy()
    df["lat_s"] = pd.to_numeric(df["lat_s"], errors="coerce")
    df = df.dropna(subset=["lat_s"])
    if df.empty:
        return None
    df["ts_ms"] = pd.to_numeric(df["ts_ms"], errors="coerce")
    df = df.dropna(subset=["ts_ms"])
    df["elapsed_s"] = (df["ts_ms"] - df["ts_ms"].iloc[0]) / 1000.0
    df["lat_ms"] = df["lat_s"] * 1000
    return df


# ── Load all datasets ──────────────────────────────────────────
DATASETS = [
    ("baseline.csv",        "Baseline",      "#3fb950"),
    ("delay.csv",           "200ms Delay",   "#d29922"),
    ("loss.csv",            "20% Loss",      "#f85149"),
    ("bandwidth.csv",       "1mbit BW",      "#a371f7"),
    ("reordering.csv",      "Reorder 25%",   "#79c0ff"),
    ("cpu_stress.csv",      "CPU Stress",    "#ff9e64"),
    ("chaos_combined.csv",  "Chaos (Loss+CPU)", "#ff6ec7"),
]

loaded  = [(load(f), lbl, c) for f, lbl, c in DATASETS]
present = [(df, lbl, c) for df, lbl, c in loaded if df is not None]

if not present:
    print("[plot] No CSV data found in results/. Run the pipeline first.")
    sys.exit(0)

# ── Layout: 3 panels using gridspec with explicit spacing ──────
# NOTE: We use gridspec with explicit top/bottom/left/right margins
# instead of tight_layout() to avoid the UserWarning about incompatible Axes.
fig = plt.figure(figsize=(15, 11))
fig.patch.set_facecolor("#0f1117")
fig.suptitle(
    "GRS Extended — Kubernetes eBPF Networking\n"
    "Latency Comparison: All Fault Types",
    fontsize=13, fontweight="bold", color="#e6edf3", y=0.98
)

gs = fig.add_gridspec(
    3, 1,
    height_ratios=[2.8, 1.2, 0.8],
    hspace=0.45,
    top=0.93, bottom=0.06, left=0.08, right=0.97
)
ax1 = fig.add_subplot(gs[0])  # timeline
ax2 = fig.add_subplot(gs[1])  # box plot
ax3 = fig.add_subplot(gs[2])  # stats table

for ax in (ax1, ax2):
    ax.set_facecolor("#161b22")
    ax.tick_params(colors="#8b949e", labelsize=9)
    ax.grid(True, linestyle="--", alpha=0.3, color="#30363d")
    for spine in ax.spines.values():
        spine.set_edgecolor("#30363d")

# ── Timeline ───────────────────────────────────────────────────
for df, lbl, c in present:
    ax1.plot(df["elapsed_s"], df["lat_ms"],
             label=f"{lbl}  (mean={df['lat_ms'].mean():.1f}ms)",
             color=c, linewidth=1.4, marker="o", markersize=2.5, alpha=0.9)

ax1.set_yscale("log")
ax1.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:.0f}ms"))
ax1.set_xlabel("Elapsed time (s)", color="#8b949e", fontsize=9)
ax1.set_ylabel("Latency (ms) — log scale", color="#8b949e", fontsize=9)
ax1.set_title("Latency over time — all fault types", color="#e6edf3", fontsize=11)

handles, lbls = ax1.get_legend_handles_labels()
if handles:
    legend = ax1.legend(fontsize=8, facecolor="#161b22", edgecolor="#30363d",
                        ncol=2, loc="upper left")
    for text in legend.get_texts():
        text.set_color("#c9d1d9")

# ── Box plot ───────────────────────────────────────────────────
box_data   = [df["lat_ms"].values for df, _, _ in present]
box_labels = [lbl for _, lbl, _ in present]
box_colors = [c   for _, _, c   in present]

try:
    bp = ax2.boxplot(box_data, tick_labels=box_labels,
                     patch_artist=True, notch=False, widths=0.5)
except TypeError:
    bp = ax2.boxplot(box_data, labels=box_labels,
                     patch_artist=True, notch=False, widths=0.5)

for patch, c in zip(bp["boxes"], box_colors):
    patch.set_facecolor(c)
    patch.set_alpha(0.72)
for elem in ["whiskers", "caps", "medians", "fliers"]:
    for item in bp[elem]:
        item.set_color("#8b949e")

ax2.set_facecolor("#161b22")
ax2.tick_params(colors="#8b949e", labelsize=8)
ax2.grid(True, linestyle="--", alpha=0.3, color="#30363d")
for spine in ax2.spines.values():
    spine.set_edgecolor("#30363d")
ax2.tick_params(axis="x", colors="#c9d1d9", labelsize=7.5)
ax2.set_ylabel("Latency (ms)", color="#8b949e", fontsize=9)
ax2.set_title("Distribution per fault type", color="#e6edf3", fontsize=11)

# ── Stats table ────────────────────────────────────────────────
ax3.set_facecolor("#0f1117")
ax3.axis("off")
for spine in ax3.spines.values():
    spine.set_visible(False)

col_labels = ["Experiment", "Mean", "Median", "p95", "Max", "n"]
table_data = []
for df, lbl, _ in present:
    lat = df["lat_ms"]
    table_data.append([
        lbl,
        f"{lat.mean():.1f}ms",
        f"{lat.median():.1f}ms",
        f"{lat.quantile(0.95):.1f}ms",
        f"{lat.max():.1f}ms",
        str(len(lat)),
    ])

tbl = ax3.table(
    cellText=table_data,
    colLabels=col_labels,
    cellLoc="center",
    loc="center",
    bbox=[0, 0, 1, 1]
)
tbl.auto_set_font_size(False)
tbl.set_fontsize(8)
for (row, col), cell in tbl.get_celld().items():
    cell.set_facecolor("#161b22" if row > 0 else "#21262d")
    cell.set_edgecolor("#30363d")
    cell.set_text_props(color="#8b949e" if row == 0 else "#c9d1d9")
    if row > 0 and col == 0:
        cell.set_text_props(color="#e6edf3")

ax3.set_title("Statistics Summary", color="#e6edf3", fontsize=10,
              pad=4)

# ── Save ───────────────────────────────────────────────────────
RESULTS_DIR.mkdir(exist_ok=True)
out_path = safe_out_path(OUT)
try:
    fig.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="#0f1117")
    print(f"[plot] Extended plot saved → {out_path}")
except PermissionError as e:
    print(f"[plot] ERROR: {e}")
    print("[plot] TIP: sudo chown $USER results/latency_comparison_extended.png")
finally:
    plt.close(fig)

if not os.environ.get("DISPLAY", ""):
    print("[plot] Headless VM detected.")
    print("[plot] View options:")
    print("[plot]   1. Copy results/ folder to Windows and open the PNG directly")
    print("[plot]   2. Run: python3 -m http.server 8080 --directory results/")
    print("[plot]      Then on Windows: http://<VM_IP>:8080/latency_comparison_extended.png")
    print("[plot]   3. Open: results/report_extended.html (has inline charts, no PNG needed)")

# ── Statistics ─────────────────────────────────────────────────
print("\n── Extended Statistics ──────────────────────────────────────")
for df, lbl, _ in present:
    lat = df["lat_ms"]
    print(f"  {lbl:20s}  mean={lat.mean():8.2f}ms  "
          f"median={lat.median():8.2f}ms  "
          f"p95={lat.quantile(0.95):8.1f}ms  "
          f"max={lat.max():8.1f}ms  n={len(lat)}")

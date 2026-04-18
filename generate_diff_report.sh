#!/bin/bash
# generate_diff_report.sh
# Compares current experiment run against a stored reference baseline.
# On first run, saves current results as the reference.
# On subsequent runs, highlights regressions and improvements.
#
# Regression thresholds (configurable):
#   THRESH_MEAN_PCT=10    — flag if mean latency increased >10%
#   THRESH_MAX_PCT=20     — flag if max latency increased >20%
#   THRESH_RETRANS_ABS=5  — flag if retransmissions increased by >5
#
# Output: results/diff_report.html
# Usage:  bash generate_diff_report.sh [--save-as-reference]

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${SCRIPT_DIR}/results"
REF_JSON="${RESULTS}/baseline_reference.json"
DIFF_REPORT="${RESULTS}/diff_report.html"

THRESH_MEAN_PCT="${THRESH_MEAN_PCT:-10}"
THRESH_MAX_PCT="${THRESH_MAX_PCT:-20}"
THRESH_RETRANS_ABS="${THRESH_RETRANS_ABS:-5}"

SAVE_REF=0
[ "${1:-}" = "--save-as-reference" ] && SAVE_REF=1

echo "[diff_report] Generating regression diff report..."

# ── Helper: compute stats from csv ───────────────────────────
get_stat() {
    local file="${RESULTS}/$1" field="$2"
    [ -f "$file" ] || { echo "0"; return; }
    tail -n +2 "$file" | grep -v timeout | awk -F',' -v f="$field" '
    BEGIN{n=0;s=0;m=0}
    {n++;s+=$2;if($2>m)m=$2}
    END{
        if(f=="mean") printf "%.4f",s/(n>0?n:1)
        if(f=="max")  printf "%.4f",m
        if(f=="n")    printf "%d",n
    }'
}

# ── Collect current run stats ─────────────────────────────────
declare -A CUR_MEAN CUR_MAX CUR_N
for exp in baseline delay loss bandwidth reordering cpu_stress chaos_combined; do
    CUR_MEAN[$exp]=$(get_stat "${exp}.csv" mean)
    CUR_MAX[$exp]=$(get_stat "${exp}.csv" max)
    CUR_N[$exp]=$(get_stat "${exp}.csv" n)
done

CUR_RETRANS=$(grep -c "RETRANSMIT" "${RESULTS}/retransmissions.log" 2>/dev/null || echo 0)
CUR_DROPS=$(grep -v "^TIME\|^Tracing\|^$\|\[eBPF\]\|^===" \
    "${RESULTS}/packet_drops.log" 2>/dev/null | grep -c "[0-9]" || echo 0)
RUN_DATE=$(date "+%d %B %Y, %H:%M:%S")

# ── Save as reference if requested or if no reference exists ─
if [ "$SAVE_REF" -eq 1 ] || [ ! -f "$REF_JSON" ]; then
    echo "[diff_report] Saving current run as reference → ${REF_JSON}"
    cat > "$REF_JSON" << JSONEOF
{
  "saved_at": "${RUN_DATE}",
  "baseline_mean":  ${CUR_MEAN[baseline]:-0},
  "delay_mean":     ${CUR_MEAN[delay]:-0},
  "loss_mean":      ${CUR_MEAN[loss]:-0},
  "bandwidth_mean": ${CUR_MEAN[bandwidth]:-0},
  "reordering_mean":${CUR_MEAN[reordering]:-0},
  "cpu_stress_mean":${CUR_MEAN[cpu_stress]:-0},
  "chaos_mean":     ${CUR_MEAN[chaos_combined]:-0},
  "baseline_max":   ${CUR_MAX[baseline]:-0},
  "delay_max":      ${CUR_MAX[delay]:-0},
  "loss_max":       ${CUR_MAX[loss]:-0},
  "bandwidth_max":  ${CUR_MAX[bandwidth]:-0},
  "reordering_max": ${CUR_MAX[reordering]:-0},
  "cpu_stress_max": ${CUR_MAX[cpu_stress]:-0},
  "chaos_max":      ${CUR_MAX[chaos_combined]:-0},
  "retransmissions":${CUR_RETRANS},
  "packet_drops":   ${CUR_DROPS}
}
JSONEOF
    echo "[diff_report] ✓ Reference saved. Run again without --save-as-reference to diff."
fi

# ── Load reference ────────────────────────────────────────────
REF_BASELINE_MEAN=$(python3 -c "import json,sys; d=json.load(open('${REF_JSON}')); print(d.get('baseline_mean',0))" 2>/dev/null || echo 0)
REF_LOSS_MEAN=$(python3 -c "import json,sys; d=json.load(open('${REF_JSON}')); print(d.get('loss_mean',0))" 2>/dev/null || echo 0)
REF_LOSS_MAX=$(python3 -c "import json,sys; d=json.load(open('${REF_JSON}')); print(d.get('loss_max',0))" 2>/dev/null || echo 0)
REF_RETRANS=$(python3 -c "import json,sys; d=json.load(open('${REF_JSON}')); print(d.get('retransmissions',0))" 2>/dev/null || echo 0)
REF_SAVED=$(python3 -c "import json,sys; d=json.load(open('${REF_JSON}')); print(d.get('saved_at','unknown'))" 2>/dev/null || echo "unknown")

# ── Compute diffs using python3 for float arithmetic ─────────
build_diff_rows() {
python3 << PYEOF
import json, os

try:
    ref = json.load(open("${REF_JSON}"))
except:
    ref = {}

thresh_mean = ${THRESH_MEAN_PCT}
thresh_max  = ${THRESH_MAX_PCT}

experiments = [
    ("baseline",       ${CUR_MEAN[baseline]:-0},   ${CUR_MAX[baseline]:-0},   ${CUR_N[baseline]:-0}),
    ("delay",          ${CUR_MEAN[delay]:-0},       ${CUR_MAX[delay]:-0},      ${CUR_N[delay]:-0}),
    ("loss",           ${CUR_MEAN[loss]:-0},        ${CUR_MAX[loss]:-0},       ${CUR_N[loss]:-0}),
    ("bandwidth",      ${CUR_MEAN[bandwidth]:-0},   ${CUR_MAX[bandwidth]:-0},  ${CUR_N[bandwidth]:-0}),
    ("reordering",     ${CUR_MEAN[reordering]:-0},  ${CUR_MAX[reordering]:-0}, ${CUR_N[reordering]:-0}),
    ("cpu_stress",     ${CUR_MEAN[cpu_stress]:-0},  ${CUR_MAX[cpu_stress]:-0}, ${CUR_N[cpu_stress]:-0}),
    ("chaos_combined", ${CUR_MEAN[chaos_combined]:-0}, ${CUR_MAX[chaos_combined]:-0}, ${CUR_N[chaos_combined]:-0}),
]

rows = ""
for name, cur_mean, cur_max, n in experiments:
    ref_mean = ref.get(f"{name}_mean", 0)
    ref_max  = ref.get(f"{name}_max",  0)
    mean_ms = cur_mean * 1000
    max_ms  = cur_max  * 1000
    ref_mean_ms = ref_mean * 1000
    ref_max_ms  = ref_max  * 1000

    if ref_mean > 0:
        mean_pct = (cur_mean - ref_mean) / ref_mean * 100
        max_pct  = (cur_max  - ref_max)  / max(ref_max, 0.0001) * 100
    else:
        mean_pct = 0; max_pct = 0

    mean_flag = "ok"
    if   mean_pct >  thresh_mean: mean_flag = "regression"
    elif mean_pct < -thresh_mean: mean_flag = "improvement"

    max_flag = "ok"
    if   max_pct  >  thresh_max:  max_flag  = "regression"
    elif max_pct  < -thresh_max:  max_flag  = "improvement"

    mean_css = {"ok":"","regression":"color:#f85149;font-weight:600","improvement":"color:#3fb950;font-weight:600"}
    max_css  = mean_css

    mean_arrow = {"ok":"→","regression":"▲","improvement":"▼"}
    delta_str = f'{mean_pct:+.1f}%' if ref_mean > 0 else "—"
    rows += f"""<tr>
  <td style="color:#e6edf3;font-weight:500">{name}</td>
  <td style="font-family:monospace">{mean_ms:.1f}ms</td>
  <td style="font-family:monospace;color:#8b949e">{ref_mean_ms:.1f}ms</td>
  <td style="{mean_css[mean_flag]};font-family:monospace">{mean_arrow[mean_flag]} {delta_str}</td>
  <td style="font-family:monospace">{max_ms:.1f}ms</td>
  <td style="font-family:monospace;color:#8b949e">{ref_max_ms:.1f}ms</td>
  <td style="font-family:monospace">{n}</td>
</tr>"""

print(rows)
PYEOF
}

DIFF_ROWS=$(build_diff_rows)

# ── Retransmission diff ───────────────────────────────────────
RETRANS_DELTA=$(( CUR_RETRANS - REF_RETRANS ))
RETRANS_CSS="color:#e6edf3"
RETRANS_NOTE="within normal range"
if [ "$RETRANS_DELTA" -gt "$THRESH_RETRANS_ABS" ] 2>/dev/null; then
    RETRANS_CSS="color:#f85149;font-weight:600"
    RETRANS_NOTE="REGRESSION: +${RETRANS_DELTA} vs reference"
elif [ "$RETRANS_DELTA" -lt "-${THRESH_RETRANS_ABS}" ] 2>/dev/null; then
    RETRANS_CSS="color:#3fb950;font-weight:600"
    RETRANS_NOTE="IMPROVEMENT: ${RETRANS_DELTA} vs reference"
fi

# ── Generate HTML diff report ─────────────────────────────────
cat > "$DIFF_REPORT" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>GRS — Regression Diff Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#0f1117;color:#c9d1d9;padding:24px}
.page{max-width:960px;margin:0 auto}
.header{background:linear-gradient(135deg,#161b22,#1c2333);border:1px solid #30363d;border-radius:12px;padding:28px 36px;margin-bottom:24px}
h1{color:#e6edf3;font-size:22px;margin-bottom:6px}
.sub{color:#8b949e;font-size:12px}
.section{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:22px 26px;margin-bottom:18px}
.stitle{color:#e6edf3;font-size:14px;font-weight:600;margin-bottom:14px;padding-bottom:8px;border-bottom:1px solid #21262d}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:#21262d;color:#8b949e;font-size:11px;text-transform:uppercase;letter-spacing:.4px;padding:8px 12px;text-align:left}
td{padding:8px 12px;border-bottom:1px solid #21262d;color:#c9d1d9}
tr:last-child td{border-bottom:none}
tr:hover td{background:#1c2333}
.legend{display:flex;gap:20px;font-size:11px;margin-top:12px}
.leg{display:flex;align-items:center;gap:6px}
.dot{width:10px;height:10px;border-radius:50%;display:inline-block}
.footer{text-align:center;color:#484f58;font-size:11px;margin-top:24px;padding-top:14px;border-top:1px solid #21262d}
</style>
</head>
<body>
<div class="page">
<div class="header">
  <h1>GRS — Regression Diff Report</h1>
  <div class="sub">Current run vs reference &nbsp;|&nbsp; Generated: ${RUN_DATE}</div>
  <div class="sub" style="margin-top:6px">Reference saved: ${REF_SAVED} &nbsp;|&nbsp; Thresholds: mean &gt;${THRESH_MEAN_PCT}% = regression &nbsp;|&nbsp; Retransmissions delta &gt;${THRESH_RETRANS_ABS}</div>
</div>

<div class="section">
  <div class="stitle">Latency Comparison — Current vs Reference</div>
  <table>
    <thead><tr>
      <th>Experiment</th>
      <th>Current Mean</th>
      <th>Ref Mean</th>
      <th>Mean Δ</th>
      <th>Current Max</th>
      <th>Ref Max</th>
      <th>Samples</th>
    </tr></thead>
    <tbody>
${DIFF_ROWS}
    </tbody>
  </table>
  <div class="legend">
    <div class="leg"><div class="dot" style="background:#3fb950"></div><span style="color:#3fb950">▼ Improvement (faster than reference)</span></div>
    <div class="leg"><div class="dot" style="background:#f85149"></div><span style="color:#f85149">▲ Regression (slower than reference)</span></div>
    <div class="leg"><div class="dot" style="background:#8b949e"></div><span style="color:#8b949e">→ Within threshold (±${THRESH_MEAN_PCT}%)</span></div>
  </div>
</div>

<div class="section">
  <div class="stitle">eBPF Event Comparison</div>
  <table>
    <thead><tr><th>Metric</th><th>Current</th><th>Reference</th><th>Delta</th><th>Status</th></tr></thead>
    <tbody>
      <tr>
        <td style="color:#e6edf3">TCP Retransmissions</td>
        <td style="font-family:monospace">${CUR_RETRANS}</td>
        <td style="font-family:monospace;color:#8b949e">${REF_RETRANS}</td>
        <td style="font-family:monospace;${RETRANS_CSS}">${RETRANS_DELTA:+}${RETRANS_DELTA}</td>
        <td style="${RETRANS_CSS}">${RETRANS_NOTE}</td>
      </tr>
      <tr>
        <td style="color:#e6edf3">Packet Drops (kfree_skb)</td>
        <td style="font-family:monospace">${CUR_DROPS}</td>
        <td style="font-family:monospace;color:#8b949e">${CUR_DROPS}</td>
        <td style="font-family:monospace">—</td>
        <td style="color:#8b949e">reference value reflects same run</td>
      </tr>
    </tbody>
  </table>
</div>

<div class="section">
  <div class="stitle">How to Use This Report</div>
  <p style="font-size:12px;color:#8b949e;line-height:1.8">
    <strong style="color:#e6edf3">Save a new reference:</strong>
    <code style="background:#21262d;padding:2px 6px;border-radius:4px;color:#58a6ff">bash generate_diff_report.sh --save-as-reference</code><br>
    <strong style="color:#e6edf3">Compare against reference:</strong>
    <code style="background:#21262d;padding:2px 6px;border-radius:4px;color:#58a6ff">bash generate_diff_report.sh</code><br><br>
    The reference is stored in <code style="color:#58a6ff">results/baseline_reference.json</code>.
    Re-run the full pipeline then call this script to detect regressions.
    A <span style="color:#f85149">▲ regression</span> means this run is slower than the stored reference by more than the threshold.
  </p>
</div>

<div class="footer">GRS Diff Report &nbsp;|&nbsp; ${RUN_DATE}</div>
</div>
</body>
</html>
HTMLEOF

echo "[diff_report] ✓ Diff report saved → ${DIFF_REPORT}"
echo "[diff_report]   Reference file:    ${REF_JSON}"

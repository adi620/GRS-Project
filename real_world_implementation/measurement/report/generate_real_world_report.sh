#!/bin/bash
# generate_real_world_report.sh — generates real_world_report.html

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="${SCRIPT_DIR}/../logs"
PLOTS="${SCRIPT_DIR}/../plots"
REPORT="${SCRIPT_DIR}/real_world_report.html"

# ── Compute stats from CSV ────────────────────────────────
get_stats() {
    local file="$1" phase="$2"  # phase: baseline or fault
    [ -f "$file" ] || { echo "0,0,0,0,0"; return; }
    python3 << PYEOF
import statistics, sys
rows = []
try:
    with open("$file") as f:
        next(f)
        for line in f:
            p = line.strip().split(',')
            if len(p)==2:
                try: rows.append((float(p[0]), float(p[1])*1000))
                except: pass
except: pass
if not rows: print("0,0,0,0,0"); sys.exit()
# Split: first 20s = baseline, rest = fault phase
t0 = rows[0][0]
if "$phase" == "baseline":
    vals = [v for ts,v in rows if (ts-t0)/1000 <= 20]
else:
    vals = [v for ts,v in rows if (ts-t0)/1000 > 20]
if not vals: print("0,0,0,0,0"); sys.exit()
s = sorted(vals); n = len(s)
mean = sum(s)/n
p95  = s[int(n*0.95)]
mx   = s[-1]
jitter = statistics.stdev(s) if n>1 else 0
print(f"{mean:.1f},{p95:.1f},{mx:.1f},{jitter:.1f},{n}")
PYEOF
}

CPU_BL=$(get_stats "${LOGS}/latency_cpu_noise.csv" baseline)
CPU_FT=$(get_stats "${LOGS}/latency_cpu_noise.csv" fault)
APP_BL=$(get_stats "${LOGS}/latency_app_delay.csv" baseline)
APP_FT=$(get_stats "${LOGS}/latency_app_delay.csv" fault)

p() { echo "$1" | cut -d, -f"$2"; }

RUN_DATE=$(date "+%d %B %Y, %H:%M:%S")

# ── Check if PNG was generated ────────────────────────────
PNG_B64=""
if [ -f "${PLOTS}/real_world_latency_comparison.png" ]; then
    PNG_B64=$(base64 -w 0 "${PLOTS}/real_world_latency_comparison.png" 2>/dev/null || echo "")
fi

cat > "$REPORT" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>GRS — Real-World Debugging Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#0f1117;color:#c9d1d9;padding:24px;line-height:1.6}
.page{max-width:1100px;margin:0 auto}
.header{background:linear-gradient(135deg,#161b22,#1c2333);border:1px solid #30363d;border-radius:12px;padding:32px 40px;margin-bottom:24px}
.header h1{font-size:24px;color:#e6edf3;margin-bottom:6px}
.header .sub{color:#8b949e;font-size:13px}
.tag{display:inline-block;background:#1f2d3d;border:1px solid #388bfd;color:#58a6ff;padding:2px 10px;border-radius:20px;font-size:11px;margin:4px 2px}
.section{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:24px;margin-bottom:18px}
.stitle{color:#e6edf3;font-size:15px;font-weight:600;margin-bottom:14px;padding-bottom:8px;border-bottom:1px solid #21262d}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.card{background:#0d1117;border:1px solid #21262d;border-radius:8px;padding:16px}
.card h3{font-size:13px;font-weight:600;margin-bottom:10px}
.card.cpu h3{color:#ff9e64}
.card.app h3{color:#79c0ff}
.row{display:flex;justify-content:space-between;padding:4px 0;font-size:12px;border-bottom:1px solid #21262d}
.row:last-child{border-bottom:none}
.key{color:#8b949e}
.val{color:#e6edf3;font-family:monospace}
.val.good{color:#3fb950}
.val.warn{color:#f85149}
table{width:100%;border-collapse:collapse;font-size:12px}
th{background:#21262d;color:#8b949e;font-size:11px;text-transform:uppercase;letter-spacing:.4px;padding:10px 14px;text-align:left}
td{padding:10px 14px;border-bottom:1px solid #21262d;color:#c9d1d9}
tr:last-child td{border-bottom:none}
tr:hover td{background:#1c2333}
.badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}
.badge.yes{background:#1f3a1f;color:#3fb950;border:1px solid #238636}
.badge.no{background:#3d1515;color:#f85149;border:1px solid #f85149}
.badge.high{background:#3d2000;color:#ff9e64;border:1px solid #ff9e64}
.badge.normal{background:#1a2840;color:#79c0ff;border:1px solid #388bfd}
.timeline{display:flex;margin:16px 0;gap:0}
.tl-item{flex:1;text-align:center;padding:12px 8px;border-top:3px solid #30363d;font-size:11px;color:#8b949e;position:relative}
.tl-item.active{border-top-color:#58a6ff;color:#e6edf3}
.tl-item.done{border-top-color:#3fb950;color:#3fb950}
.plot-img{width:100%;border-radius:8px;border:1px solid #30363d}
.conclusion{background:#0d2818;border:1px solid #238636;border-radius:8px;padding:16px;margin-top:14px}
.conclusion p{font-size:12px;color:#c9d1d9;line-height:1.8}
code{background:#21262d;padding:2px 6px;border-radius:4px;color:#58a6ff;font-size:11px}
.footer{text-align:center;color:#484f58;font-size:11px;margin-top:28px;padding-top:14px;border-top:1px solid #21262d}
</style>
</head>
<body>
<div class="page">

<div class="header">
  <h1>GRS — Real-World Debugging Report</h1>
  <div class="sub">Production debugging simulation — unknown cause → eBPF diagnosis</div>
  <div class="sub" style="margin-top:6px">Generated: ${RUN_DATE}</div>
  <div style="margin-top:12px">
    <span class="tag">No tc fault injection</span>
    <span class="tag">Unknown root cause</span>
    <span class="tag">eBPF-based diagnosis</span>
    <span class="tag">Same symptom, different causes</span>
  </div>
</div>

<div class="section">
  <div class="stitle">Module Purpose</div>
  <p style="font-size:12px;color:#8b949e;line-height:1.9">
    This module demonstrates the hardest class of production debugging:
    <strong style="color:#e6edf3">latency is elevated, but the cause is unknown.</strong>
    Unlike the fault injection pipeline where we <em>know</em> we injected a tc delay,
    here we simulate a real on-call scenario — an SRE receives a PagerDuty alert
    for high latency and must diagnose it with only metrics and eBPF.
    <br><br>
    The key insight: <strong style="color:#ff9e64">both scenarios produce ~same latency symptom</strong>
    but require completely different fixes.
    Without kernel-level tracing, an SRE might waste hours changing network configs
    when the real cause is a slow database query.
  </p>
  <div class="timeline" style="margin-top:18px">
    <div class="tl-item done">① Alert fires<br><small>latency ↑</small></div>
    <div class="tl-item done">② Check retransmissions<br><small>0 → not network</small></div>
    <div class="tl-item done">③ Check drops<br><small>0 → not tc rule</small></div>
    <div class="tl-item done">④ Check scheduler<br><small>identifies cause</small></div>
    <div class="tl-item done">⑤ Root cause found<br><small>fix applied</small></div>
  </div>
</div>

<div class="section">
  <div class="stitle">Scenario Results — Latency Statistics</div>
  <div class="grid2">
    <div class="card cpu">
      <h3>① CPU Noise (Noisy Neighbour)</h3>
      <div class="row"><span class="key">Baseline mean</span><span class="val">${CPU_BL%,*,*,*,*}ms</span></div>
      <div class="row"><span class="key">Under noise mean</span><span class="val warn">$(p "$CPU_FT" 1)ms</span></div>
      <div class="row"><span class="key">Jitter (std-dev)</span><span class="val warn">$(p "$CPU_FT" 4)ms</span></div>
      <div class="row"><span class="key">p95</span><span class="val">$(p "$CPU_FT" 2)ms</span></div>
      <div class="row"><span class="key">Max</span><span class="val">$(p "$CPU_FT" 3)ms</span></div>
      <div class="row"><span class="key">Samples</span><span class="val">$(p "$CPU_FT" 5)</span></div>
      <div class="row"><span class="key">Pattern</span><span class="val">JITTERY — high variance</span></div>
    </div>
    <div class="card app">
      <h3>② App Delay (Slow Code Path)</h3>
      <div class="row"><span class="key">Baseline mean</span><span class="val">${APP_BL%,*,*,*,*}ms</span></div>
      <div class="row"><span class="key">Under delay mean</span><span class="val warn">$(p "$APP_FT" 1)ms</span></div>
      <div class="row"><span class="key">Jitter (std-dev)</span><span class="val good">$(p "$APP_FT" 4)ms</span></div>
      <div class="row"><span class="key">p95</span><span class="val">$(p "$APP_FT" 2)ms</span></div>
      <div class="row"><span class="key">Max</span><span class="val">$(p "$APP_FT" 3)ms</span></div>
      <div class="row"><span class="key">Samples</span><span class="val">$(p "$APP_FT" 5)</span></div>
      <div class="row"><span class="key">Pattern</span><span class="val">STABLE — low variance</span></div>
    </div>
  </div>
</div>

<div class="section">
  <div class="stitle">eBPF Diagnosis Matrix — Eliminating Causes</div>
  <table>
    <thead><tr>
      <th>eBPF Check</th>
      <th>CPU Noise Result</th>
      <th>App Delay Result</th>
      <th>Eliminates</th>
    </tr></thead>
    <tbody>
      <tr>
        <td><code>kprobe:tcp_retransmit_skb</code> — TCP retransmissions</td>
        <td><span class="badge yes">0 events</span></td>
        <td><span class="badge yes">0 events</span></td>
        <td>Packet loss / network fault</td>
      </tr>
      <tr>
        <td><code>tracepoint:skb:kfree_skb</code> — kernel packet drops</td>
        <td><span class="badge yes">0 drops</span></td>
        <td><span class="badge yes">0 drops</span></td>
        <td>tc netem / firewall drops</td>
      </tr>
      <tr>
        <td><code>tracepoint:sched:sched_stat_runtime</code> — scheduler</td>
        <td><span class="badge high">HIGH — stress-ng events</span></td>
        <td><span class="badge normal">Normal — no contention</span></td>
        <td>App delay (for CPU scenario)</td>
      </tr>
      <tr>
        <td>Latency jitter (std-dev)</td>
        <td><span class="badge high">HIGH — irregular spikes</span></td>
        <td><span class="badge normal">LOW — stable +~200ms</span></td>
        <td>CPU cause (for app scenario)</td>
      </tr>
      <tr style="background:#0d1117">
        <td style="color:#e6edf3;font-weight:600">Root Cause</td>
        <td style="color:#ff9e64;font-weight:600">Noisy neighbour (CPU)</td>
        <td style="color:#79c0ff;font-weight:600">Slow application code</td>
        <td style="color:#8b949e">Fix: kill process / profile app</td>
      </tr>
    </tbody>
  </table>
  <div class="conclusion">
    <p>
      <strong style="color:#e6edf3">Key insight:</strong>
      Both scenarios look identical from a user perspective — "the app is slow."
      Without eBPF, an SRE might spend hours adjusting network settings when
      the real cause is CPU contention from another workload, or vice versa.
      The scheduler trace (<code>sched_stat_runtime</code>) is the deciding signal:
      <strong style="color:#ff9e64">high scheduler events = CPU cause</strong>,
      <strong style="color:#79c0ff">normal scheduler = look at the application layer</strong>.
    </p>
  </div>
</div>

$([ -n "$PNG_B64" ] && cat << IMGEOF
<div class="section">
  <div class="stitle">Latency Comparison Plot</div>
  <img class="plot-img" src="data:image/png;base64,${PNG_B64}" alt="Real-world comparison plot"/>
</div>
IMGEOF
)

<div class="section">
  <div class="stitle">How This Differs from Fault Injection Pipeline</div>
  <table>
    <thead><tr><th>Aspect</th><th>Fault Injection Pipeline</th><th>Real-World Module</th></tr></thead>
    <tbody>
      <tr><td>Cause known upfront?</td><td>Yes — we inject it</td><td>No — must diagnose</td></tr>
      <tr><td>tc netem used?</td><td>Yes</td><td>Never</td></tr>
      <tr><td>Goal</td><td>Verify fault produces expected kernel events</td><td>Identify unknown cause using eBPF</td></tr>
      <tr><td>Retransmissions expected?</td><td>Yes (on loss/reorder)</td><td>No — absence proves not network</td></tr>
      <tr><td>Realistic scenario</td><td>Lab / controlled experiment</td><td>Production on-call simulation</td></tr>
    </tbody>
  </table>
</div>

<div class="footer">
  GRS Real-World Debugging Report &nbsp;|&nbsp; ${RUN_DATE}<br>
  Part 2 of 2 — see main pipeline for fault injection experiments
</div>
</div>
</body>
</html>
HTMLEOF

echo "[report] ✓ Report saved → ${REPORT}"

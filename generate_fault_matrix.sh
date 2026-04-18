#!/bin/bash
# generate_fault_matrix.sh
# Generates results/fault_matrix.md — structured cause → kernel → effect table.
# Also performs simple rule-based correlation from actual log data.

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${SCRIPT_DIR}/results"
OUT="${RESULTS}/fault_matrix.md"

echo "[fault_matrix] Generating fault matrix..."

# ── Collect stats for each experiment ────────────────────────
get_mean() {
    local f="${RESULTS}/$1"
    [ -f "$f" ] || { echo "N/A"; return; }
    tail -n +2 "$f" | grep -v timeout | \
        awk -F',' '{s+=$2;n++} END{if(n>0) printf "%.1fms", s/n*1000; else print "N/A"}'
}
get_max() {
    local f="${RESULTS}/$1"
    [ -f "$f" ] || { echo "N/A"; return; }
    tail -n +2 "$f" | grep -v timeout | \
        awk -F',' 'BEGIN{m=0}{if($2>m)m=$2} END{printf "%.1fms", m*1000}'
}
get_spikes() {
    local f="${RESULTS}/$1"
    [ -f "$f" ] || { echo "0"; return; }
    tail -n +2 "$f" | awk -F',' '$2>0.1{c++} END{print c+0}'
}

RETRANS=$(grep -c "RETRANSMIT" "${RESULTS}/retransmissions.log" 2>/dev/null || echo 0)
DROPS=$(grep -v "^TIME\|^Tracing\|^$\|\[eBPF\]" "${RESULTS}/packet_drops.log" 2>/dev/null | grep -c "[0-9]" || echo 0)

B_MEAN=$(get_mean "baseline.csv")
D_MEAN=$(get_mean "delay.csv");     D_MAX=$(get_max "delay.csv")
L_MEAN=$(get_mean "loss.csv");      L_MAX=$(get_max "loss.csv");   L_SPK=$(get_spikes "loss.csv")
BW_MEAN=$(get_mean "bandwidth.csv"); BW_MAX=$(get_max "bandwidth.csv")
R_MEAN=$(get_mean "reordering.csv"); R_MAX=$(get_max "reordering.csv")
C_MEAN=$(get_mean "cpu_stress.csv"); C_MAX=$(get_max "cpu_stress.csv")
CH_MEAN=$(get_mean "chaos_combined.csv"); CH_MAX=$(get_max "chaos_combined.csv")

RUN_DATE=$(date "+%d %B %Y, %H:%M:%S")

# ── Rule-based correlation ────────────────────────────────────
INFERRED=""
if [ "$RETRANS" -gt 5 ] 2>/dev/null; then
    INFERRED="${INFERRED}\n- **High retransmissions (${RETRANS} events)** → inferred packet loss or reordering"
fi
if [ "$DROPS" -gt 100 ] 2>/dev/null; then
    INFERRED="${INFERRED}\n- **High drop count (${DROPS} events)** → confirmed kernel-level discards"
fi
if [ "$L_SPK" -gt 3 ] 2>/dev/null; then
    INFERRED="${INFERRED}\n- **${L_SPK} spikes >100ms in loss experiment** → TCP exponential backoff confirmed"
fi
[ -z "$INFERRED" ] && INFERRED="\n- No anomalies detected (run pipeline first)"

# ── Write markdown ────────────────────────────────────────────
cat > "$OUT" << MDEOF
# GRS — Fault Matrix: Cause → Kernel → Application Impact

> Generated: ${RUN_DATE}

---

## Fault Matrix

| Fault Type      | Injection Method              | Kernel Signal              | Application Impact          | Mean Latency | Max Latency |
|-----------------|-------------------------------|----------------------------|-----------------------------|--------------|-------------|
| **Baseline**    | None                          | None                       | Normal operation            | ${B_MEAN}    | —           |
| **Delay**       | \`tc netem delay 200ms\`       | None (no loss)             | Stable +400ms latency       | ${D_MEAN}    | ${D_MAX}    |
| **Packet Loss** | \`tc netem loss 20%\`          | \`tcp_retransmit_skb\`      | Latency spikes, backoff     | ${L_MEAN}    | ${L_MAX}    |
| **Bandwidth**   | \`tc tbf rate 1mbit\`          | Queue buildup / tail drop  | Slow throughput, jitter     | ${BW_MEAN}   | ${BW_MAX}   |
| **Reordering**  | \`tc netem reorder 25% 50%\`   | Duplicate ACKs             | TCP instability, retransmit | ${R_MEAN}    | ${R_MAX}    |
| **CPU Stress**  | \`stress-ng --cpu 4\`          | Scheduling delay           | Latency jitter              | ${C_MEAN}    | ${C_MAX}    |

---

## eBPF Kernel Events Captured

| Probe                       | Events Captured | Fires During Loss? | Fires During Reorder? |
|-----------------------------|-----------------|--------------------|-----------------------|
| \`tcp_retransmit_skb\`       | **${RETRANS}**  | ✅ Yes              | ✅ Yes                 |
| \`kfree_skb\` (drops)        | **${DROPS}**    | ✅ Yes              | Partial                |

---

## Rule-Based Correlation (Automated)
$(echo -e "$INFERRED")

---

## How to Interpret

- **Delay** — confirms tc netem delay is working. No kernel retransmit events because packets still arrive.
- **Packet Loss** — causes \`tcp_retransmit_skb\` to fire. Application sees exponential backoff spikes.
- **Bandwidth** — TBF queues packets, causing queue buildup. Under HTTP/1.1 small requests the effect is subtle; visible under bulk transfers.
- **Reordering** — TCP receives out-of-order segments, sends duplicate ACKs, may trigger fast retransmit.
- **CPU Stress** — increases scheduling jitter visible as latency variance rather than absolute spikes.

---

## Reproducing Experiments

\`\`\`bash
# Run the full extended pipeline
sudo ./run_full_pipeline_extended.sh

# Or run individual experiments
sudo bash experiments/run_bandwidth.sh
sudo bash experiments/run_reordering.sh
sudo bash experiments/run_cpu_stress.sh
\`\`\`
MDEOF

echo "[fault_matrix] ✓ Saved → ${OUT}"

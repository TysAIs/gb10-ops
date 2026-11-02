#!/usr/bin/env bash
# GB10 clock-cap sweep — research tool, NOT the standard.
# The standard is 2200 MHz (deploy/apply-2200.sh). This sweep measures
# other caps for comparison and always restores 2200 MHz on exit.
# Uses llama-benchy (the correct tool): pp=2048, tg=128, 3 runs per cap.
#
# Required environment (use YOUR nodes / endpoint / model):
#   SPARK1=gb10@node1  SPARK2=gb10@node2        # two nodes in the setup
#   VLLM_URL=http://node1:8000/v1           # serving endpoint
#   MODEL=<served model name>
# Optional:
#   CAPS="2000 2100 2200"                   # caps to test

set -e

: "${SPARK1:?set SPARK1, e.g. gb10@node1}"
: "${SPARK2:?set SPARK2, e.g. gb10@node2}"
: "${VLLM_URL:?set VLLM_URL, e.g. http://node1:8000/v1}"
: "${MODEL:?set MODEL to the served model name}"
CAPS="${CAPS:-2000 2100 2200}"
RESULTS_DIR="/tmp/sweep-results-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$RESULTS_DIR"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$RESULTS_DIR/sweep.log"; }

set_cap() {
    local mhz=$1 host
    log "Setting cap to ${mhz} MHz on both nodes..."
    for host in "$SPARK1" "$SPARK2"; do
        ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$host" "sudo nvidia-smi -lgc 0,$mhz" 2>&1 | grep -q "All done" \
            && log "  $host: OK" || log "  $host: FAILED"
    done
}

restore() {
    log "Restoring 2200 MHz..."
    ssh -o StrictHostKeyChecking=no "$SPARK1" "sudo nvidia-smi -lgc 0,2200" 2>/dev/null || true
    ssh -o StrictHostKeyChecking=no "$SPARK2" "sudo nvidia-smi -lgc 0,2200" 2>/dev/null || true
    log "Done."
}
trap restore EXIT INT TERM

log "GB10 Clock-Cap Sweep starting"
log "Results: $RESULTS_DIR"
log ""

for MHZ in $CAPS; do
    log "===== ${MHZ} MHz ====="
    set_cap "$MHZ"
    sleep 10

    # Background power/temp sampling on SPARK1
    log "Starting metrics sampling..."
    ssh -o StrictHostKeyChecking=no "$SPARK1" \
        "for i in \$(seq 1 120); do nvidia-smi --query-gpu=timestamp,power.draw,temperature.gpu,clocks.gr --format=csv,noheader; sleep 2; done" \
        > "$RESULTS_DIR/metrics-${MHZ}.csv" 2>/dev/null &
    METRICS_PID=$!

    log "Running llama-benchy (pp=2048, tg=128, 3 runs)..."
    uvx llama-benchy \
        --base-url "$VLLM_URL" \
        --model "$MODEL" \
        --served-model-name "$MODEL" \
        --pp 2048 \
        --tg 128 \
        --exact-tg \
        --runs 3 \
        --latency-mode generation \
        --format json \
        2>&1 | tee "$RESULTS_DIR/benchy-${MHZ}.json" | tail -20

    kill $METRICS_PID 2>/dev/null || true
    wait $METRICS_PID 2>/dev/null || true

    log "Completed ${MHZ} MHz"
    log ""
    sleep 30  # cooldown
done

log "Sweep complete! Results in $RESULTS_DIR"

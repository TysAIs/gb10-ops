#!/usr/bin/env bash
# GB10 Proper Clock-Cap Sweep
# Uses llama-benchy (the correct tool) with proper methodology.
# Tests: 2000, 2100, 2200, 2300 MHz static caps.
#
# For each cap:
#   - Sets cap on BOTH Sparks (allspark + arbiter)
#   - Samples power/temp/clock in background
#   - Runs llama-benchy with pp=2048, tg=128, 3 runs
#   - Records results

set -e

SPARK1="itxji@10.0.0.4"  # allspark (head)
SPARK2="itxji@10.0.0.23"  # arbiter (worker)
VLLM_URL="http://10.0.0.4:8000/v1"
MODEL="Qwen/Qwen3.8-Flash-Next-Uncensored"
RESULTS_DIR="/tmp/sweep-results-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$RESULTS_DIR"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$RESULTS_DIR/sweep.log"; }

set_cap() {
    local mhz=$1
    log "Setting cap to ${mhz} MHz on both Sparks..."
    ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$SPARK1" "sudo nvidia-smi -lgc 0,$mhz" 2>&1 | grep -q "All done" && log "  allspark: OK" || log "  allspark: FAILED"
    ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no "$SPARK2" "sudo nvidia-smi -lgc 0,$mhz" 2>&1 | grep -q "All done" && log "  arbiter: OK" || log "  arbiter: FAILED"
}

# Safety: restore 2200 on exit
trap 'log "Restoring 2200 MHz..."; ssh -o StrictHostKeyChecking=no '"$SPARK1"' "sudo nvidia-smi -lgc 0,2200" 2>/dev/null; ssh -o StrictHostKeyChecking=no '"$SPARK2"' "sudo nvidia-smi -lgc 0,2200" 2>/dev/null; log "Done."; exit' EXIT INT TERM

log "GB10 Clock-Cap Sweep starting"
log "Results: $RESULTS_DIR"
log ""

for MHZ in 2000 2100 2200 2300; do
    log "===== ${MHZ} MHz ====="
    set_cap "$MHZ"
    sleep 10

    # Start background power/temp sampling on allspark
    log "Starting metrics sampling..."
    ssh -o StrictHostKeyChecking=no "$SPARK1" \
        "for i in \$(seq 1 120); do nvidia-smi --query-gpu=timestamp,power.draw,temperature.gpu,clocks.gr --format=csv,noheader; sleep 2; done" \
        > "$RESULTS_DIR/metrics-${MHZ}.csv" 2>/dev/null &
    METRICS_PID=$!

    # Run llama-benchy
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

    # Stop metrics sampling
    kill $METRICS_PID 2>/dev/null || true
    wait $METRICS_PID 2>/dev/null || true

    log "Completed ${MHZ} MHz"
    log ""
    sleep 30  # cooldown
done

log "Sweep complete! Results in $RESULTS_DIR"

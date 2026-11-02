#!/usr/bin/env bash
# Apply the 2200 MHz GPU clock cap to GB10 nodes with systemd persistence.
# Based on miaai-lab/sparkLimiter deployment pattern.
#
# Usage:
#   ./apply-2200.sh                    # auto-discover nodes (or set GB10_HOSTS)
#   ./apply-2200.sh spark1 spark2      # specific hosts
#   ./apply-2200.sh --uninstall        # remove cap, restore defaults

set -e

SERVICE="gb10-clock-cap"
UNIT_PATH="/etc/systemd/system/${SERVICE}.service"

if [ "$1" = "--uninstall" ]; then
    if [ $# -lt 2 ]; then
        echo "Usage: $0 --uninstall <user@host> [user@host ...]" >&2
        exit 1
    fi
    echo "Removing clock cap from all nodes..."
    for host in "${@:2}"; do
        [ -z "$host" ] && continue
        echo "=== $host ==="
        ssh -t "$host" "sudo systemctl disable --now ${SERVICE}.service; sudo nvidia-smi -rgc; sudo rm -f ${UNIT_PATH}; sudo systemctl daemon-reload; echo 'Removed'"
    done
    exit 0
fi

# Hosts come from arguments, else $GB10_HOSTS (space-separated), else a
# small auto-discovery probe of generic candidate names. Probing is safe:
# a candidate is only used if it answers SSH and reports a GB10 GPU.
HOSTS=("$@")
if [ ${#HOSTS[@]} -eq 0 ] && [ -n "$GB10_HOSTS" ]; then
    read -ra HOSTS <<< "$GB10_HOSTS"
fi
if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "Auto-discovering GB10 nodes..."
    for h in spark1 spark2 spark3 spark4 dgx-spark gb10; do
        if ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" "nvidia-smi -L" 2>/dev/null | grep -qi "GB10"; then
            HOSTS+=("$h")
            echo "Found: $h"
        fi
    done
fi

if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "No GB10 nodes found. Provide hosts manually: ./apply-2200.sh user@host1 user@host2 (or set GB10_HOSTS)"
    exit 1
fi

UNIT=$(cat <<EOF
[Unit]
Description=GB10 GPU Clock Cap (2200 MHz)
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-smi -lgc 0,2200
ExecStop=/usr/bin/nvidia-smi -rgc
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
)

for host in "${HOSTS[@]}"; do
    echo ""
    echo "=== $host ==="
    # Apply cap immediately
    ssh -t "$host" "sudo nvidia-smi -lgc 0,2200" 2>&1 | grep -q "All done" && echo "Cap applied" || echo "FAILED"
    # Install systemd service for persistence and start it now
    echo "$UNIT" | ssh -t "$host" "sudo tee ${UNIT_PATH} > /dev/null && sudo systemctl daemon-reload && sudo systemctl enable --now ${SERVICE}.service && echo 'Service installed'"
    # Verify: service active. clocks.max can still read 3003 under a
    # lock on GB10 — the real proof is ~2190 MHz SM clock under load.
    ssh -t "$host" "systemctl is-active ${SERVICE}.service && nvidia-smi --query-gpu=clocks.sm,clocks.max.sm --format=csv,noheader" \
        && echo "Verified: service active (confirm ~2190 MHz under load)" || echo "VERIFY FAILED"
done

echo ""
echo "Done. 2200 MHz cap applied to ${#HOSTS[@]} node(s)."

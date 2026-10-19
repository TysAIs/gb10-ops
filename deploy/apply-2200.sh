#!/usr/bin/env bash
# Apply 2200 MHz clock cap to all DGX Sparks with systemd persistence.
# Based on miaai-lab/sparkLimiter deployment pattern.
#
# Usage:
#   ./apply-2200.sh                    # auto-discover Sparks
#   ./apply-2200.sh spark1 spark2      # specific hosts
#   ./apply-2200.sh --uninstall        # remove cap, restore defaults

set -e

CLOCKS="0,2200"
SERVICE="gb10-clock-cap"
UNIT_PATH="/etc/systemd/system/${SERVICE}.service"

if [ "$1" = "--uninstall" ]; then
    echo "Removing clock cap from all Sparks..."
    for host in "${@:2}"; do
        [ -z "$host" ] && continue
        echo "=== $host ==="
        ssh -t "$host" "sudo systemctl disable --now ${SERVICE}.service; sudo nvidia-smi -rgc; sudo rm -f ${UNIT_PATH}; sudo systemctl daemon-reload; echo 'Removed'"
    done
    exit 0
fi

# Auto-discover or use provided hosts
HOSTS=("$@")
if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "Auto-discovering Sparks..."
    # Simple discovery: check common hostnames/IPs
    for h in 10.0.0.4 10.0.0.23 allspark arbiter; do
        if ssh -o ConnectTimeout=3 -o BatchMode=yes "$h" "nvidia-smi -L" 2>/dev/null | grep -qi "GB10"; then
            HOSTS+=("$h")
            echo "Found: $h"
        fi
    done
fi

if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "No Sparks found. Provide hosts manually: ./apply-2200.sh user@host1 user@host2"
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
    # Install systemd service for persistence
    echo "$UNIT" | ssh -t "$host" "sudo tee ${UNIT_PATH} > /dev/null && sudo systemctl daemon-reload && sudo systemctl enable ${SERVICE}.service && echo 'Service installed'"
done

echo ""
echo "Done. 2200 MHz cap applied to ${#HOSTS[@]} Spark(s)."

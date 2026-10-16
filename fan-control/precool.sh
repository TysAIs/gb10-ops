#!/usr/bin/env bash
# Fan pre-cooling for DGX Spark
# Boost fans BEFORE heavy workloads, not after temps rise.
# Requires: https://github.com/christopherowen/dgx-spark-fan-control
#
# Usage: ./precool.sh [level] [wait_seconds]
#   ./precool.sh 8 120    # Level 8, wait 2 min

set -e
LEVEL="${1:-8}"
WAIT="${2:-120}"

command -v dgx-fan-control >/dev/null || {
    echo "ERROR: dgx-fan-control not installed"
    echo "See: https://github.com/christopherowen/dgx-spark-fan-control"
    exit 1
}

echo "Setting fan floor to $LEVEL..."
sudo dgx-fan-control set-state "$LEVEL"
echo "Waiting ${WAIT}s..."
sleep "$WAIT"
echo "Done. Run your workload now."
echo "Restore with: dgx-fan-control automatic"

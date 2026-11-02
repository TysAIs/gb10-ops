#!/usr/bin/env bash
# Fan pre-cooling for GB10: OPTIONAL, not part of the gb10-ops standard.
# Boost fans BEFORE heavy workloads, not after temps rise.
# The standard story is stock EC thermal behavior + the 2200 MHz cap.
#
# Caveats before you install the tool this wraps:
#   - Owen's dgx-spark-fan-control is validated on EC 3.5.8 and
#     UNTESTED on EC 3.13.7.
#   - Secure Boot is enabled on GB10 nodes: its kernel module needs a
#     MOK signing key enrolled via a console reboot.
# Requires: https://github.com/christopherowen/dgx-spark-fan-control
#
# Usage: bash precool.sh [level] [wait_seconds]
#   bash precool.sh 8 120    # Level 8, wait 2 min

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

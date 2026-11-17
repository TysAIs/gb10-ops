#!/usr/bin/env bash
# TEST DOUBLE, not upstream's installer.
#
# tests/apply-selftest.sh runs deploy/apply.sh against a fake node root with
# no GB10, no daemon and no network. deploy/apply.sh asks the installer to
# install atticd; on a fake node that has to be something, and it must not be
# a fake that always succeeds for the wrong reason. This double models the
# only two behaviours apply.sh depends on:
#
#   --check   exit 1 unless the node's driver is the one upstream validated
#             (580.178.04), which is the same rule the gate enforces
#   install   write /run/spark-attic/status.json and enable attic.service
#
# FAKE_LENT_MIB=N makes the install report borrows that should not exist, so
# the self-test can prove apply.sh rejects a daemon that is already lending.
#
# Everything it writes goes under $NODE_ROOT.
set -u
R="${NODE_ROOT:?this double needs NODE_ROOT}"
check_only=0
[ "${1:-}" = "--check" ] && check_only=1

drv=$(sed -n 's/.*[[:space:]]\([0-9][0-9.]*\)[[:space:]]*Release.*/\1/p' \
      "$R/proc/driver/nvidia/version" 2>/dev/null | head -1)
if [ "$drv" != "580.178.04" ]; then
    echo "check: driver ${drv:-none} has no node-validated shim; refusing"
    exit 1
fi
echo "check: driver $drv validated, heap mode"
[ "$check_only" -eq 1 ] && exit 0

mkdir -p "$R/run/spark-attic" "$R/var/lib/fake-units/attic.service" || exit 2
printf '{"state":"ready","size_mib":2044,"lent_mib":%s,"validated":true,"driver":"%s","mode":"heap"}\n' \
    "${FAKE_LENT_MIB:-0}" "$drv" > "$R/run/spark-attic/status.json"
echo active  > "$R/var/lib/fake-units/attic.service/active"
echo enabled > "$R/var/lib/fake-units/attic.service/enabled"
echo "installed atticd (test double)"
exit 0

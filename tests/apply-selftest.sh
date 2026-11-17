#!/usr/bin/env bash
# Self-test for deploy/apply.sh. No GB10, no ssh, no privilege, no network:
# every case runs the real deploy/apply.sh against a fake node root, with
# systemctl/sysctl/spark-attic/curl replaced by the doubles in tests/fixtures.
#
#   bash tests/apply-selftest.sh
#
# What it proves, in order: the run is read-only in dry-run, an apply applies,
# a second apply is a no-op, --verify passes, a blocked node is refused
# untouched, a daemon that is already lending fails the run, rollback reverses
# both stages, and rollback is itself idempotent.
#
# Exit 0 when every case matches, 1 on the first mismatch.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
APPLY="$HERE/../deploy/apply.sh"
GATE="$HERE/../deploy/carveout-gate.sh"
DOUBLE="$HERE/fixtures/attic-installer-double.sh"
BIN="$HERE/fixtures/bin"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/apply-selftest.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
pass() { echo "ok   $1"; }
bad()  { echo "FAIL $1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@" | sed 's/^/    /'; fails=$((fails+1)); }

[ -f "$APPLY" ] || { echo "FAIL: $APPLY missing"; exit 1; }

# fixture DIR [key=value ...]: a headless node that the gate calls ELIGIBLE,
# with the drift this runbook is meant to close: snapd disabled but running.
# Keys: driver boost lent  (driver also decides whether the gate and the
# installer's preflight pass).
fixture() {
    local d=$1; shift
    local driver="580.178.04" boost="15000"
    local kv
    for kv in "$@"; do
        case "$kv" in
            driver=*) driver="${kv#driver=}" ;;
            boost=*)  boost="${kv#boost=}" ;;
        esac
    done
    rm -rf "$d"; mkdir -p "$d"/{proc/driver/nvidia,proc/sys/vm,sys/module/nvidia_drm/parameters,etc/modprobe.d,snapshot,var/lib/fake-units/snapd.service,var/lib/fake-units/snapd.socket}
    printf 'aarch64\n' > "$d/snapshot/machine_arch"
    printf '7.0.0-1019-nvidia-64k\n' > "$d/snapshot/uname_r"
    printf '65536\n' > "$d/snapshot/pagesize"
    printf 'NVIDIA GB10\n' > "$d/snapshot/nvidia_smi_gpu"
    printf 'multi-user.target\n' > "$d/snapshot/get_default"
    printf 'NVRM version: NVIDIA UNIX Open Kernel Module for aarch64  %s  Release Build  (x@y)  Tue Jul  7 13:36:23 UTC 2026\n' \
        "$driver" > "$d/proc/driver/nvidia/version"
    printf '%s\n' "$boost" > "$d/proc/sys/vm/watermark_boost_factor"
    printf '45166\n' > "$d/proc/sys/vm/min_free_kbytes"
    printf 'N\n' > "$d/sys/module/nvidia_drm/parameters/modeset"
    printf 'options nvidia-drm modeset=0\n' > "$d/etc/modprobe.d/zz-nvidia-drm-override.conf"
    printf 'BOOT_IMAGE=/boot/vmlinuz-x ro quiet crashkernel=1G-:0M\n' > "$d/proc/cmdline"
    printf 'MemTotal:       129798784 kB\nMemAvailable:   18478656 kB\n' > "$d/proc/meminfo"
    printf 'Node 0, zone   Normal    814    650    181    192    336    128     53      2      0      1      1      2      0      0\n' \
        > "$d/proc/buddyinfo"
    echo active   > "$d/var/lib/fake-units/snapd.service/active"
    echo disabled > "$d/var/lib/fake-units/snapd.service/enabled"
    echo active   > "$d/var/lib/fake-units/snapd.socket/active"
    echo disabled > "$d/var/lib/fake-units/snapd.socket/enabled"
}

treehash() { find "$1" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1; }

run_apply() { # ROOT MODE INVENTORY-LINE [extra apply.sh flags...]
    local root=$1 mode=$2 inv=$3; shift 3
    local invfile="$WORK/inv.txt"
    printf '%s\n' "$inv" > "$invfile"
    PATH="$BIN:$PATH" FAKE_LENT_MIB="${FAKE_LENT_MIB:-0}" ATTIC_INSTALLER="$DOUBLE" \
        bash "$APPLY" --root "$root" --inventory "$invfile" "$mode" "$@" 2>&1
}

expect() { # name rc-wanted pattern [forbidden]
    local name=$1 want_rc=$2 want=$3 forbid=${4:-}
    printf '%s\n' "$OUT" > "$WORK/last.out"
    if [ "$RC" -ne "$want_rc" ]; then
        bad "$name: exit $RC, wanted $want_rc" "$OUT"; return
    fi
    case "$OUT" in *"$want"*) : ;; *) bad "$name: no '$want' in output" "$OUT"; return ;; esac
    if [ -n "$forbid" ]; then
        case "$OUT" in *"$forbid"*) bad "$name: unexpected '$forbid'" "$OUT"; return ;; esac
    fi
    pass "$name"
}

# ---------------------------------------------------------------- 1. dry run
R1="$WORK/node1"
fixture "$R1"
h_before=$(treehash "$R1")
OUT=$(run_apply "$R1" --dry-run "gb10@node1"); RC=$?
h_after=$(treehash "$R1")
expect dry-run 0 "verdict PLAN-ONLY"
for want in "gate ELIGIBLE" "stage1 watermark pending" "stage2 attic pending not-installed" "would write"; do
    case "$OUT" in *"$want"*) pass "dry-run shows '$want'" ;; *) bad "dry-run: no '$want'" "$OUT" ;; esac
done
[ "$h_before" = "$h_after" ] && pass "dry-run changed nothing" || bad "dry-run changed the tree"

# ---------------------------------------------------------------- 2. apply
OUT=$(run_apply "$R1" --apply "gb10@node1"); RC=$?
expect apply 0 "verdict APPLIED-OR-NOOP"
for want in "gate ELIGIBLE" "stage1 watermark applied reads 0" "stage1 snapd applied" "verify attic ok state ready"; do
    case "$OUT" in *"$want"*) pass "apply shows '$want'" ;; *) bad "apply: no '$want'" "$OUT" ;; esac
done
[ -f "$R1/etc/sysctl.d/90-watermark-boost.conf" ] && pass "apply wrote the sysctl drop-in" || bad "apply: drop-in missing"
[ "$(cat "$R1/proc/sys/vm/watermark_boost_factor")" = "0" ] && pass "apply readback is 0" || bad "apply: readback $(cat "$R1/proc/sys/vm/watermark_boost_factor")"
[ "$(cat "$R1/var/lib/gb10-ops/watermark.previous")" = "15000" ] && pass "apply recorded the pre-apply value" || bad "apply: pre-apply value not recorded"
grep -q '"lent_mib":0' "$R1/run/spark-attic/status.json" && pass "apply left lent_mib at 0" || bad "apply: lent_mib is not 0"
[ "$(cat "$R1/var/lib/fake-units/snapd.service/active")" = "inactive" ] && pass "apply stopped snapd.service" || bad "apply: snapd.service still active"
[ "$(cat "$R1/var/lib/fake-units/snapd.socket/active")" = "inactive" ] && pass "apply stopped snapd.socket" || bad "apply: snapd.socket still active"
h_applied=$(treehash "$R1")

# ---------------------------------------------------------------- 3. idempotent
OUT=$(run_apply "$R1" --apply "gb10@node1"); RC=$?
expect idempotent-apply 0 "verdict APPLIED-OR-NOOP"
h_reapply=$(treehash "$R1")
[ "$h_applied" = "$h_reapply" ] && pass "second apply changed nothing" || bad "second apply changed the tree"
case "$OUT" in *"state applied"*) bad "second apply re-applied a stage" "$OUT" ;; *) pass "second apply reported noop only" ;; esac
for want in "stage1 watermark noop" "stage1 snapd noop" "stage2 attic noop"; do
    case "$OUT" in *"$want"*) pass "second apply: '$want'" ;; *) bad "second apply: no '$want'" "$OUT" ;; esac
done

# ---------------------------------------------------------------- 4. verify
OUT=$(run_apply "$R1" --verify "gb10@node1"); RC=$?
expect verify 0 "verdict VERIFIED"
case "$OUT" in *"verify serving skipped"*) pass "verify: serving skipped when none declared" ;; *) bad "verify: serving was not skipped" "$OUT" ;; esac

# A doctor false negative must not fail a node whose status.json is ready: the
# rollout saw upstream's installer report a missing libcuda that was present.
OUT=$(FAKE_DOCTOR_FAIL=1 run_apply "$R1" --verify "gb10@node1"); RC=$?
expect doctor-false-negative 0 "doctor warn"
case "$OUT" in *"verify attic ok state ready"*) pass "doctor false negative still verifies the daemon" ;; *) bad "doctor false negative hid the daemon state" "$OUT" ;; esac

# ---------------------------------------------------------------- 5. blocked
R2="$WORK/node2"
fixture "$R2" driver=550.54.14
h_before=$(treehash "$R2")
OUT=$(run_apply "$R2" --apply "gb10@node2"); RC=$?
expect blocked-apply 1 "node verdict BLOCKED"
h_after=$(treehash "$R2")
[ "$h_before" = "$h_after" ] && pass "blocked node was not touched" || bad "blocked node changed"
OUT=$(run_apply "$R2" --apply "gb10@node2" --stage 1); RC=$?
expect blocked-stage1-only 0 "stage1 watermark applied"
case "$OUT" in *"gate note not ELIGIBLE"*) pass "stage 1 says the gate does not guard it" ;; *) bad "stage 1 did not explain the gate" "$OUT" ;; esac
R6="$WORK/node6"
fixture "$R6" driver=550.54.14
OUT=$(run_apply "$R6" --dry-run "gb10@node6"); RC=$?
expect blocked-plan 1 "not eligible for the full run"
case "$OUT" in *"stage1 watermark pending"*) pass "blocked plan still shows the stage 1 plan" ;; *) bad "blocked plan hid the stage 1 plan" "$OUT" ;; esac

# ---------------------------------------------------------------- 6. lending
R3="$WORK/node3"
fixture "$R3"
OUT=$(FAKE_LENT_MIB=7 run_apply "$R3" --apply "gb10@node3"); RC=$?
expect lending-fails 1 "lent_mib"
case "$OUT" in *"wanted 0"*) pass "lending: the failure names the expectation" ;; *) bad "lending: the failure does not name lent_mib 0" "$OUT" ;; esac

# ---------------------------------------------------------------- 7. rollback
OUT=$(run_apply "$R1" --rollback "gb10@node1"); RC=$?
expect rollback 0 "verdict ROLLED-BACK"
[ -f "$R1/etc/sysctl.d/90-watermark-boost.conf" ] && bad "rollback left the drop-in" || pass "rollback removed the drop-in"
[ "$(cat "$R1/proc/sys/vm/watermark_boost_factor")" = "15000" ] && pass "rollback restored the pre-apply value" || bad "rollback: readback $(cat "$R1/proc/sys/vm/watermark_boost_factor")"
[ -f "$R1/run/spark-attic/status.json" ] && bad "rollback left the daemon status" || pass "rollback uninstalled the daemon"
h_rolled=$(treehash "$R1")
OUT=$(run_apply "$R1" --rollback "gb10@node1"); RC=$?
expect rollback-idempotent 0 "verdict ROLLED-BACK"
case "$OUT" in *"rollback watermark noop"*) pass "second rollback: watermark noop" ;; *) bad "second rollback: watermark not noop" "$OUT" ;; esac
case "$OUT" in *"rollback attic noop"*) pass "second rollback: attic noop" ;; *) bad "second rollback: attic not noop" "$OUT" ;; esac
h_rolled2=$(treehash "$R1")
[ "$h_rolled" = "$h_rolled2" ] && pass "second rollback changed nothing" || bad "second rollback changed the tree"

# ---------------------------------------------------------------- 8. serving
R4="$WORK/node4"
fixture "$R4"
OUT=$(run_apply "$R4" --apply "gb10@node4 http://127.0.0.1:8000/health"); RC=$?
expect apply-with-health 0 "verdict APPLIED-OR-NOOP"
OUT=$(FAKE_SERVING_CODE=200 run_apply "$R4" --verify "gb10@node4 http://127.0.0.1:8000/health"); RC=$?
expect health-ok 0 "verify serving ok 200"
OUT=$(FAKE_SERVING_CODE=503 run_apply "$R4" --verify "gb10@node4 http://127.0.0.1:8000/health"); RC=$?
expect health-down 1 "serving: http://127.0.0.1:8000/health answered '503'"

# ---------------------------------------------------------------- 9. inventory
for n in 1 2 8; do
    : > "$WORK/inv$n.txt"
    for i in $(seq 1 "$n"); do echo "gb10@node$i" >> "$WORK/inv$n.txt"; done
    OUT=$(bash "$APPLY" --inventory "$WORK/inv$n.txt" --check-inventory 2>&1); RC=$?
    expect "inventory-$n" 0 "inventory ok $n node(s)"
done
: > "$WORK/inv9.txt"
for i in $(seq 1 9); do echo "gb10@node$i" >> "$WORK/inv9.txt"; done
OUT=$(bash "$APPLY" --inventory "$WORK/inv9.txt" --check-inventory 2>&1); RC=$?
expect inventory-9 0 "warn: 9 nodes"
OUT=$(bash "$APPLY" --inventory "$WORK/inv9.txt" --check-inventory --allow-any-count 2>&1); RC=$?
case "$OUT" in *"warn:"*) bad "allow-any-count still warned" "$OUT" ;; *) pass "allow-any-count is quiet" ;; esac

printf 'gb10@node1\ngb10@node1\n' > "$WORK/dup.txt"
OUT=$(bash "$APPLY" --inventory "$WORK/dup.txt" --check-inventory 2>&1); RC=$?
expect duplicate-refused 2 "listed twice"
printf 'gb10@node1 http://x/health extra\n' > "$WORK/extra.txt"
OUT=$(bash "$APPLY" --inventory "$WORK/extra.txt" --check-inventory 2>&1); RC=$?
expect three-fields-refused 2 "more than two fields"
: > "$WORK/empty.txt"
OUT=$(bash "$APPLY" --inventory "$WORK/empty.txt" --check-inventory 2>&1); RC=$?
expect empty-refused 2 "no nodes"
OUT=$(bash "$APPLY" --inventory "$WORK/dup.txt" 2>&1); RC=$?
expect mode-required 2 "name a mode"

# ---------------------------------------------------------------- 10. ssh path
# Everything above ran with --root, which never exercises the ssh call, the
# environment it passes or the node script it pipes. The transport is the
# part most likely to be wrong in a script nobody can run on a real node
# from CI, so it is tested with an ssh double that runs the same command
# string locally against a fixture root (tests/fixtures/bin/ssh).
R5="$WORK/node5"
fixture "$R5"
printf 'gb10@node5\n' > "$WORK/invssh.txt"
OUT=$(PATH="$BIN:$PATH" FAKE_SSH_ROOT="$R5" FAKE_LENT_MIB=0 ATTIC_INSTALLER="$DOUBLE" \
      bash "$APPLY" --inventory "$WORK/invssh.txt" --apply 2>&1); RC=$?
expect ssh-path-apply 0 "verdict APPLIED-OR-NOOP"
case "$OUT" in *"gate ELIGIBLE"*) pass "ssh path: the gate's own ssh snapshot round-trip worked" ;; *) bad "ssh path: gate did not read the fixture node" "$OUT" ;; esac
[ -f "$R5/run/spark-attic/status.json" ] && pass "ssh path: the node script ran and wrote status" || bad "ssh path: status.json missing"
h_ssh=$(treehash "$R5")
OUT=$(PATH="$BIN:$PATH" FAKE_SSH_ROOT="$R5" FAKE_LENT_MIB=0 ATTIC_INSTALLER="$DOUBLE" \
      bash "$APPLY" --inventory "$WORK/invssh.txt" --apply 2>&1); RC=$?
expect ssh-path-idempotent 0 "verdict APPLIED-OR-NOOP"
[ "$h_ssh" = "$(treehash "$R5")" ] && pass "ssh path: second apply changed nothing" || bad "ssh path: second apply changed the tree"

OUT=$(PATH="$BIN:$PATH" FAKE_SSH_ROOT="$R5" FAKE_SSH_FAIL_HOST=gb10@node9 FAKE_LENT_MIB=0 \
      bash "$APPLY" --inventory <(printf 'gb10@node9\n') --dry-run 2>&1); RC=$?
expect ssh-unreachable 3 "node verdict SKIPPED"

# ---------------------------------------------------------------- 11. purity
# The runbook's claims must stay true as the script changes: the gate is
# still the only thing that decides eligibility, and stage 3 is not reachable.
grep -q 'carveout-gate.sh' "$APPLY" && pass "apply.sh calls the gate" || bad "apply.sh does not call the gate"
grep -qi 'spark-attic' "$APPLY" && pass "apply.sh installs the gated daemon only" || bad "apply.sh does not name the daemon"
if grep -qi 'SPARK_ATTIC_PLACE\|kv_cache\|allocate_kv_cache' "$APPLY"; then
    bad "apply.sh mentions engine placement: stage 3 must not be reachable from it"
else
    pass "apply.sh cannot reach stage 3"
fi

echo ""
if [ "$fails" -eq 0 ]; then echo "PASS: every apply case matched"; exit 0; fi
echo "FAIL: $fails case(s)"; exit 1

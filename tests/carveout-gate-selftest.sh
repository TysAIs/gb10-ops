#!/usr/bin/env bash
# Self-test for deploy/carveout-gate.sh. Builds fixture snapshots and
# asserts the verdict of each. Needs no GB10 and no privilege: every case
# is a directory of files that stands in for a node's read-only state.
# The lender case also binds a throwaway unix socket under such a directory
# and runs gather() against it, so python3 (stdlib only) is required.
#
#   bash tests/carveout-gate-selftest.sh
#
# Exit 0 when every case matches, 1 on the first mismatch.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/../deploy/carveout-gate.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/carveout-selftest.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0

# fixture DIR [key=value ...]: a headless, eligible node, optionally edited.
# Keys: gpu driver kernel modeset machine dm holders lender splash boost buddy
fixture() {
    local d=$1; shift
    local gpu="NVIDIA GB10" driver="580.178.04" kernel="7.0.0-1019-nvidia-64k"
    local modeset="N" machine="aarch64" dm="" holders="" lender="" splash=""
    local boost="0" buddy=""
    local kv
    for kv in "$@"; do
        case "$kv" in
            gpu=*) gpu="${kv#gpu=}" ;; driver=*) driver="${kv#driver=}" ;;
            kernel=*) kernel="${kv#kernel=}" ;; modeset=*) modeset="${kv#modeset=}" ;;
            machine=*) machine="${kv#machine=}" ;; dm=*) dm="${kv#dm=}" ;;
            holders=*) holders="${kv#holders=}" ;; lender=*) lender="${kv#lender=}" ;;
            splash=*) splash="${kv#splash=}" ;; boost=*) boost="${kv#boost=}" ;;
            buddy=*) buddy="${kv#buddy=}" ;;
        esac
    done
    mkdir -p "$d"/{proc/driver/nvidia,proc/sys/vm,sys/module/nvidia_drm/parameters,etc/modprobe.d,snapshot}
    printf '%s\n' "$machine" > "$d/snapshot/machine_arch"
    printf '%s\n' "$kernel" > "$d/snapshot/uname_r"
    printf '65536\n' > "$d/snapshot/pagesize"
    printf 'NVRM version: NVIDIA UNIX Open Kernel Module for aarch64  %s  Release Build  (x@y)  Tue Jul  7 13:36:23 UTC 2026\n' "$driver" \
        > "$d/proc/driver/nvidia/version"
    printf '%s\n' "$boost" > "$d/proc/sys/vm/watermark_boost_factor"
    printf '45166\n' > "$d/proc/sys/vm/min_free_kbytes"
    printf '%s\n' "$modeset" > "$d/sys/module/nvidia_drm/parameters/modeset"
    printf 'options nvidia-drm modeset=0\n' > "$d/etc/modprobe.d/zz-nvidia-drm-override.conf"
    printf '%s\n' "$gpu" > "$d/snapshot/nvidia_smi_gpu"
    printf 'multi-user.target\n' > "$d/snapshot/get_default"
    [ -n "$dm" ] && printf '%s\n' "$dm" > "$d/snapshot/display_managers"
    [ -n "$holders" ] && printf '%s\n' "$holders" > "$d/snapshot/modeset_holders"
    [ -n "$lender" ] && printf '%s\n' "$lender" > "$d/snapshot/other_lenders"
    printf 'BOOT_IMAGE=/boot/vmlinuz-x ro quiet %s crashkernel=1G-:0M\n' "$splash" > "$d/proc/cmdline"
    printf 'MemTotal:       129798784 kB\nMemAvailable:   18478656 kB\n' > "$d/proc/meminfo"
    if [ -n "$buddy" ]; then
        printf '%s\n' "$buddy" > "$d/proc/buddyinfo"
    else
        # a serving node: free memory in small blocks only (64 KiB pages)
        printf 'Node 0, zone   Normal    814    650    181    192    336    128     53      2      0      1      1      2      0      0\n' \
            > "$d/proc/buddyinfo"
    fi
}

check() { # name expected-exit expected-pattern [forbidden-pattern]
    local name=$1 want_rc=$2 want=$3 forbid=${4:-}
    local out rc
    out=$(bash "$GATE" --from "$WORK/$name" 2>&1); rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        echo "FAIL $name: exit $rc, wanted $want_rc"; echo "$out" | sed 's/^/    /'; fails=$((fails+1)); return
    fi
    case "$out" in *"$want"*) : ;; *)
        echo "FAIL $name: no '$want' in output"; echo "$out" | sed 's/^/    /'; fails=$((fails+1)); return ;;
    esac
    if [ -n "$forbid" ]; then
        case "$out" in *"$forbid"*)
            echo "FAIL $name: unexpected '$forbid'"; echo "$out" | sed 's/^/    /'; fails=$((fails+1)); return ;;
        esac
    fi
    echo "ok   $name"
}

fixture "$WORK/eligible"
check eligible 0 "verdict ELIGIBLE" "warn "

fixture "$WORK/driver-shipped-unvalidated" driver=580.196.07
check driver-shipped-unvalidated 1 "not node-validated" "verdict ELIGIBLE"

fixture "$WORK/driver-noshim" driver=550.54.14
check driver-noshim 1 "has no shim"

fixture "$WORK/no-driver" driver=""
sed -i 's/.*/none/' "$WORK/no-driver/proc/driver/nvidia/version"
check no-driver 1 "no NVIDIA driver loaded"

fixture "$WORK/display-holder" holders="2208001 Xorg"
check display-holder 1 "holds /dev/nvidia-modeset"

fixture "$WORK/display-manager" dm="gdm3 active"
check display-manager 1 "display manager is active"

fixture "$WORK/other-lender" lender="/run/dispram/dispram.sock"
check other-lender 1 "one lender per node" "verdict ELIGIBLE"
out=$(bash "$GATE" --from "$WORK/other-lender" 2>&1)
case "$out" in *"/run/dispram/dispram.sock"*) echo "ok   other-lender-named" ;;
               *) echo "FAIL other-lender-named: the blocked line does not name the socket"; fails=$((fails+1)) ;; esac

# The other-lender constant must BE the path dispramd really binds
# (kindling-spark-os dispramd.py, gr8 knobs/system.yaml, talos-dgx-kernel
# dispramd.c). A wrong constant makes this gate report 0 lenders on a node
# that is already lending, which is the one thing it exists to catch.
# Equality, not containment: '/run/dispram/dispram.sock.old' contains the
# right path and would pass a substring test while watching a socket no
# lender binds.
lender_expected="/run/dispram/dispram.sock"
lender_const=$(sed -n 's/^OTHER_LENDERS="\(.*\)"$/\1/p' "$GATE")
if [ "$lender_const" = "$lender_expected" ]; then
    echo "ok   lender-constant"
else
    echo "FAIL lender-constant: OTHER_LENDERS is '$lender_const', wanted '$lender_expected'"
    fails=$((fails+1))
fi

# Behavioural: every case above hands --from a fabricated snapshot, so the
# code that probes OTHER_LENDERS has never run — the constant was only ever
# compared as a string. Bind a socket where dispramd binds it, stage it under
# GATE_ROOT, and make gather() itself report it. This is the only case that
# goes red for a wrong constant without reading the constant: a mutation to
# '/run/dispram/dispram.sock.old' probes a path nobody bound and records no
# lender, so the gate would call a lending node clean.
lender_gather() {
    local fake="$WORK/fake-node" sock snap got rc
    sock="$fake$lender_expected"
    snap="$WORK/gathered"
    mkdir -p "${sock%/*}" || { echo "FAIL lender-gather: cannot stage $fake"; fails=$((fails+1)); return; }
    if ! python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock" 2>"$WORK/bind.err"; then
        echo "FAIL lender-gather: cannot bind $sock: $(cat "$WORK/bind.err")"; fails=$((fails+1)); return
    fi
    GATE_ROOT="$fake" bash "$GATE" --snapshot "$snap" >/dev/null 2>&1; rc=$?
    got=""
    [ -f "$snap/snapshot/other_lenders" ] && got=$(tr -d '\r' < "$snap/snapshot/other_lenders")
    if [ "$rc" -eq 0 ] && [ "$got" = "$lender_expected" ]; then
        echo "ok   lender-gather"
    else
        echo "FAIL lender-gather: snapshot/other_lenders is '${got:-<absent>}' (--snapshot exit $rc), wanted '$lender_expected'"
        fails=$((fails+1))
    fi
}
lender_gather

fixture "$WORK/not-gb10" gpu="NVIDIA H100 80GB HBM3"
check not-gb10 1 "no GB10"

fixture "$WORK/not-aarch64" machine="x86_64"
check not-aarch64 1 "not aarch64"

fixture "$WORK/untested-kernel" kernel="6.17.0-1032-nvidia" modeset="Y" splash="splash"
check untested-kernel 0 "verdict ELIGIBLE" "blocked "
out=$(bash "$GATE" --from "$WORK/untested-kernel" 2>&1)
for want in "kernel-tested no" "modeset reads 'Y'" "splash still on the kernel command line"; do
    case "$out" in *"$want"*) : ;; *) echo "FAIL untested-kernel: no '$want'"; fails=$((fails+1)) ;; esac
done

fixture "$WORK/buddy" buddy="Node 0, zone   Normal   1197    357    281    217     81    129    108     70     53     56     35     25      1      0"
out=$(bash "$GATE" --from "$WORK/buddy" 2>&1)
case "$out" in *"largest-free-block-mib 256"*) echo "ok   buddy-largest-block" ;;
               *) echo "FAIL buddy-largest-block: $(echo "$out" | grep largest)"; fails=$((fails+1)) ;; esac

fixture "$WORK/unreadable-modeset"
rm -f "$WORK/unreadable-modeset/sys/module/nvidia_drm/parameters/modeset"
out=$(bash "$GATE" --from "$WORK/unreadable-modeset" 2>&1)
case "$out" in *"modeset unreadable"*) echo "ok   unreadable-modeset" ;;
               *) echo "FAIL unreadable-modeset"; fails=$((fails+1)) ;; esac

fixture "$WORK/boost" boost=15000
out=$(bash "$GATE" --from "$WORK/boost" 2>&1)
case "$out" in *"watermark-boost-factor 15000"*) echo "ok   watermark-report" ;;
               *) echo "FAIL watermark-report"; fails=$((fails+1)) ;; esac

# An empty-but-present marker file must count 0, not "0\n0". The shipped
# gather() never creates these files empty, but --from DIR gates saved
# snapshots, where an empty file is the normal shape.
for which in display_managers modeset_holders other_lenders; do
    name="empty-${which//_/-}"
    fixture "$WORK/$name"
    : > "$WORK/$name/snapshot/$which"
    out=$(bash "$GATE" --from "$WORK/$name" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL $name: exit $rc, wanted 0"; echo "$out" | sed 's/^/    /'; fails=$((fails+1)); continue
    fi
    case "$out" in *"verdict ELIGIBLE"*) : ;; *)
        echo "FAIL $name: no ELIGIBLE verdict"; echo "$out" | sed 's/^/    /'; fails=$((fails+1)); continue ;;
    esac
    case "$out" in *"blocked "*|*"integer expected"*)
        echo "FAIL $name: an empty file produced a block"; echo "$out" | sed 's/^/    /'; fails=$((fails+1)); continue ;;
    esac
    case "$which" in
        display_managers) want="display-manager inactive" ;;
        modeset_holders)  want="modeset-holders 0" ;;
        other_lenders)    want="other-lenders 0" ;;
    esac
    case "$out" in *"$want"*) echo "ok   $name" ;; *)
        echo "FAIL $name: no '$want'"; echo "$out" | sed 's/^/    /'; fails=$((fails+1)) ;;
    esac
done

echo ""
if [ "$fails" -eq 0 ]; then echo "PASS: every gate case matched"; exit 0; fi
echo "FAIL: $fails case(s)"; exit 1

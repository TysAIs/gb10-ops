#!/usr/bin/env bash
# Display-carveout lending: read-only gate for GB10 nodes.
#
# The optional component this gates is spark-attic's atticd
# (github.com/bertholomus/spark-attic), which lends a headless GB10's
# display carveout to CUDA. docs/DISPLAY-CARVEOUT.md is the analysis,
# docs/APPLY-PLAN-2026-11.md is the staged plan for our own nodes. This
# script only DECIDES whether a node may lend. It never installs, never
# writes to the node, never stops or starts anything.
#
# Why a gate at all: atticd already refuses to lend on a driver it has
# not validated, and refuses while a display is in use. What it cannot
# know is whether THIS standard wants the carveout lent on that node: a
# UEFI Display Reserved Memory setting of Auto has already handed that
# memory back to the system, and a second carveout lender on the same
# node would fight atticd over RM's heap. Both are settled by a human
# reading this verdict, not by the daemon.
#
# Usage:
#   bash carveout-gate.sh                    # gate this machine
#   bash carveout-gate.sh node1 node2        # gate over ssh (BatchMode)
#   bash carveout-gate.sh --from DIR         # gate a saved snapshot
#   bash carveout-gate.sh --snapshot DIR     # gather a snapshot, then gate it
#   bash carveout-gate.sh --self-test        # fixture run, needs no GB10
#
# Output is one "key value" line per check and a final verdict, so it
# greps and diffs like deploy/apply-grub-default.sh. Exit codes:
#   0 eligible, 1 blocked, 2 error, 3 skipped (no ssh on that host).
#
# No privilege is needed: every input is world-readable except the
# nvidia_drm modeset parameter, which is read through sudo when it is
# free and reported "unreadable" when it is not. A blocked node is not a
# broken node: it is a node where lending is the wrong choice today, or
# where the driver would refuse anyway.

set -uo pipefail

DRIVERS_VALIDATED="580.178.04"   # node-validated upstream, heap mode only
DRIVERS_SHIPPED="580.178.04 580.196.07 595.112.07 615.71.09 615.71.10 615.78.08 620.70.06"
KERNELS_TESTED="7.0.0-1019-nvidia-64k 7.0.0-1024-nvidia 7.0.0-1024-nvidia-64k"
# The other carveout lender upstream names is Kindling's dispramd. Its
# control socket is this path in kindling-spark-os (dispram/dispramd.py,
# dispram/python/dispram.py, overlay/etc/systemd/system/dispramd.service),
# Kindling gr8 (knobs/system.yaml, docs/ENV.md) and talos-dgx-kernel
# (dispram/dispramd.c), all read 2026-11-16.
OTHER_LENDERS="/run/dispram/dispram.sock"

MODE="gate"
HOSTS=()
FROM=""
DEST=""

i=1
while [ $i -le $# ]; do
    arg="${!i}"
    case "$arg" in
        --from) MODE="from"; i=$((i+1)); FROM="${!i}" ;;
        --snapshot) MODE="snapshot"; i=$((i+1)); DEST="${!i}" ;;
        --self-test) MODE="selftest" ;;
        -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
        *) HOSTS+=("$arg") ;;
    esac
    i=$((i+1))
done

# ---------------------------------------------------------------- self-test
# --self-test runs the fixture suite from tests/ next to this script. It
# needs no GB10, no privilege and no node: every case is a directory of
# files standing in for a node's read-only state.
if [ "$MODE" = "selftest" ]; then
    here=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || here=""
    suite="$here/../tests/carveout-gate-selftest.sh"
    if [ -z "$here" ] || [ ! -f "$suite" ]; then
        echo "ERROR: --self-test needs tests/carveout-gate-selftest.sh beside this script (looked in ${here:-<unresolved>}/../tests)" >&2
        exit 2
    fi
    exec bash "$suite"
fi

# ---------------------------------------------------------------- snapshot
# Read-only gather into a directory. Every file written is a copy of
# something the gate reads; nothing on the node is touched.
gather() {
    local out=$1
    # GATE_ROOT (tests only) stages a fake node tree: every node path read
    # below resolves under it, so the selftest can bind a socket at the
    # path dispramd binds and prove gather() finds it itself. Unset, this
    # is the real root. Commands with no file form (uname, systemctl,
    # nvidia-smi, getconf) always run locally.
    local r="${GATE_ROOT:-}"
    mkdir -p "$out"/proc/driver/nvidia "$out"/proc/sys/vm \
             "$out"/sys/module/nvidia_drm/parameters "$out"/etc/modprobe.d "$out"/snapshot 2>/dev/null

    uname -r > "$out/snapshot/uname_r" 2>/dev/null
    uname -m > "$out/snapshot/machine_arch" 2>/dev/null
    getconf PAGESIZE > "$out/snapshot/pagesize" 2>/dev/null
    cp "$r/proc/driver/nvidia/version" "$out/proc/driver/nvidia/version" 2>/dev/null
    cp "$r/proc/sys/vm/watermark_boost_factor" "$out/proc/sys/vm/watermark_boost_factor" 2>/dev/null
    cp "$r/proc/sys/vm/min_free_kbytes" "$out/proc/sys/vm/min_free_kbytes" 2>/dev/null
    cp "$r/proc/buddyinfo" "$out/proc/buddyinfo" 2>/dev/null
    cp "$r/proc/cmdline" "$out/proc/cmdline" 2>/dev/null
    grep -E '^(MemTotal|MemAvailable)' "$r/proc/meminfo" > "$out/proc/meminfo" 2>/dev/null
    { cat "$r/sys/module/nvidia_drm/parameters/modeset" 2>/dev/null \
      || sudo -n cat "$r/sys/module/nvidia_drm/parameters/modeset" 2>/dev/null; } \
        > "$out/sys/module/nvidia_drm/parameters/modeset" 2>/dev/null
    cp "$r/etc/modprobe.d/zz-nvidia-drm-override.conf" "$out/etc/modprobe.d/" 2>/dev/null

    nvidia-smi --query-gpu=name --format=csv,noheader > "$out/snapshot/nvidia_smi_gpu" 2>/dev/null
    systemctl get-default > "$out/snapshot/get_default" 2>/dev/null
    for d in gdm gdm3 lightdm sddm; do
        a=$(systemctl is-active "$d" 2>/dev/null) || continue
        [ "$a" = "active" ] && echo "$d active" >> "$out/snapshot/display_managers"
    done
    # Anything but nvidia-persistenced holding the modeset device means a
    # display stack is up: spark-attic's first display signal.
    for p in "$r"/proc/[0-9]*/fd/*; do
        t=$(readlink "$p" 2>/dev/null) || continue
        case "$t" in
            */nvidia-modeset)
                pid=$(echo "$p" | cut -d/ -f3)
                comm=$(cat "/proc/$pid/comm" 2>/dev/null)
                echo "$pid $comm" >> "$out/snapshot/modeset_holders" ;;
        esac
    done 2>/dev/null
    # Record the node path, never the staged one: the gate reports what a
    # human would look for on the node.
    for s in $OTHER_LENDERS; do
        [ -S "$r$s" ] && echo "$s" >> "$out/snapshot/other_lenders"
    done
    return 0
}

if [ "$MODE" = "snapshot" ]; then
    gather "$DEST"
    exit $?
fi

if [ "$MODE" = "gate" ] && [ ${#HOSTS[@]} -gt 0 ]; then
    overall=0
    for host in "${HOSTS[@]}"; do
        echo ""
        echo "===== $host ====="
        tmp=$(mktemp -d "${TMPDIR:-/tmp}/carveout-gate.XXXXXX") || exit 2
        # The node runs this same script in snapshot mode and streams it
        # back as a tar: one ssh call, no file left behind on the node.
        if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
                'd=$(mktemp -d) || exit 2; bash -s -- --snapshot "$d" >/dev/null && tar -C "$d" -cf - . ; rc=$?; rm -rf "$d"; exit $rc' \
                < "$0" 2>/dev/null | tar -C "$tmp" -xf - 2>/dev/null; then
            echo "SKIP: could not snapshot $host"
            rm -rf "$tmp"
            [ $overall -eq 0 ] && overall=3
            continue
        fi
        if [ -z "$(ls -A "$tmp" 2>/dev/null)" ]; then
            echo "SKIP: empty snapshot from $host"
            rm -rf "$tmp"
            [ $overall -eq 0 ] && overall=3
            continue
        fi
        bash "$0" --from "$tmp"
        rc=$?
        rm -rf "$tmp"
        [ $rc -ne 0 ] && overall=$rc
    done
    exit $overall
fi

if [ "$MODE" = "gate" ] && [ ${#HOSTS[@]} -eq 0 ]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/carveout-gate.XXXXXX") || exit 2
    trap 'rm -rf "$tmp"' EXIT
    gather "$tmp"
    FROM="$tmp"
fi

# -------------------------------------------------------------------- gate
R="${FROM:-/}"
[ -d "$R" ] || { echo "ERROR: no such snapshot: $R" >&2; exit 2; }
read1() { head -1 "$R/$1" 2>/dev/null | tr -d '\r'; }
has()   { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
# grep -c prints 0 AND exits 1 on an empty file, so `|| echo 0` appends a
# second 0 and the value becomes "0\n0", which every [ -gt ] below rejects.
# Count non-empty lines and default the empty string (missing file) to 0.
count_lines() {
    local n
    n=$(grep -c . "$R/snapshot/$1" 2>/dev/null)
    printf '%s' "${n:-0}"
}
blocked=(); warn=()
block()   { blocked+=("$1"); }
warn_on() { warn+=("$1"); }

arch=$(read1 snapshot/machine_arch)
gpu=$(read1 snapshot/nvidia_smi_gpu)
kernel=$(read1 snapshot/uname_r)
pagesize=$(read1 snapshot/pagesize)
pagesize=${pagesize:-65536}
driver=$(sed -n 's/.*[[:space:]]\([0-9][0-9.]*\)[[:space:]]*Release.*/\1/p' "$R/proc/driver/nvidia/version" 2>/dev/null | head -1)
[ -n "$driver" ] || driver=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$R/proc/driver/nvidia/version" 2>/dev/null | head -1)
modeset=$(read1 sys/module/nvidia_drm/parameters/modeset)
dm=$(count_lines display_managers)
holders=$(count_lines modeset_holders)
lenders=$(count_lines other_lenders)
lender_where=""
[ -f "$R/snapshot/other_lenders" ] && lender_where=$(tr '\n' ' ' < "$R/snapshot/other_lenders" | sed 's/[[:space:]]*$//')
default_target=$(read1 snapshot/get_default)
memavail=$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9]*\) kB/\1/p' "$R/proc/meminfo")
largest=$(awk -v pg="$pagesize" '
    { line = $0
      sub(/^Node[ ]+[0-9]+, zone[ ]+[A-Za-z0-9_]+[ ]+/, "", line)
      n = split(line, c, /[ ]+/)
      top = -1
      for (i = 1; i <= n; i++) if (c[i] + 0 > 0) top = i - 1
      if (top >= 0) { mib = (2 ^ top) * pg / 1048576; if (mib > max) max = mib } }
    END { printf "%d", max + 0 }' "$R/proc/buddyinfo" 2>/dev/null)

echo "arch ${arch:-(unknown)}"
echo "gpu ${gpu:-(none reported)}"
echo "kernel ${kernel:-(unknown)}"
echo "pagesize $pagesize"
echo "driver ${driver:-(none)}"
echo "driver-shipped $(has "$driver" "$DRIVERS_SHIPPED" && echo yes || echo no)"
echo "driver-validated $(has "$driver" "$DRIVERS_VALIDATED" && echo yes || echo no)"
echo "modeset ${modeset:-unreadable}"
echo "modeset-override $([ -s "$R/etc/modprobe.d/zz-nvidia-drm-override.conf" ] && echo present || echo absent)"
echo "display-manager $([ "${dm:-0}" -gt 0 ] && echo active || echo inactive)"
echo "modeset-holders $((holders + 0))"
echo "other-lenders $((lenders + 0))"
echo "default-target ${default_target:-(unknown)}"
echo "kernel-tested $(has "$kernel" "$KERNELS_TESTED" && echo yes || echo no)"
echo "memavailable-mib $( [ -n "${memavail:-}" ] && echo $((memavail / 1024)) || echo unknown )"
echo "largest-free-block-mib ${largest:-unknown}"
echo "watermark-boost-factor $(read1 proc/sys/vm/watermark_boost_factor)"
echo "min-free-kbytes $(read1 proc/sys/vm/min_free_kbytes)"

# ---- verdict -----------------------------------------------------------
[ "$arch" = "aarch64" ] || block "not aarch64"
case "$gpu" in *GB10*) : ;; *) block "nvidia-smi reports no GB10" ;; esac
if [ -z "$driver" ]; then
    block "no NVIDIA driver loaded"
elif ! has "$driver" "$DRIVERS_VALIDATED"; then
    if has "$driver" "$DRIVERS_SHIPPED"; then
        block "driver $driver ships a shim but is not node-validated: atticd would lend nothing until attic-update.sh validates it on the node"
    else
        block "driver $driver has no shim: build and validate it before installing"
    fi
fi
[ "${dm:-0}" -eq 0 ] || block "a display manager is active: atticd lends nothing while a display is in use"
[ "${holders:-0}" -eq 0 ] || block "a process other than nvidia-persistenced holds /dev/nvidia-modeset"
[ "${lenders:-0}" -eq 0 ] || block "another carveout lender socket exists${lender_where:+ ($lender_where)}: one lender per node"
has "$kernel" "$KERNELS_TESTED" || warn_on "kernel $kernel is outside upstream's tested matrix: node-test the numbers before trusting them"
[ "$modeset" = "N" ] || warn_on "modeset reads '${modeset:-unreadable}', not N: this standard keeps modeset off, and with KMS on a later-attached display is not visible to atticd's connector check"
[ "$default_target" = "multi-user.target" ] || warn_on "default target is ${default_target:-(unknown)}, not multi-user.target"
grep -q splash "$R/proc/cmdline" 2>/dev/null && warn_on "splash still on the kernel command line (see docs/MEMORY-RECLAIM.md)"

for w in ${warn[@]+"${warn[@]}"}; do echo "warn $w"; done
if [ ${#blocked[@]} -gt 0 ]; then
    for b in "${blocked[@]}"; do echo "blocked $b"; done
    echo "verdict BLOCKED"
    exit 1
fi
echo "verdict ELIGIBLE"
if [ ${#warn[@]} -eq 0 ]; then
    echo "next (a human runs these; this script changes nothing):"
    echo "  curl -fsSL https://github.com/bertholomus/spark-attic/releases/download/v0.1.2/install.sh | sudo bash -s -- --check"
else
    echo "next: settle every warn line above, then rerun this gate before installing"
fi
exit 0

#!/usr/bin/env bash
# Pin the GRUB default boot entry to an EXPLICIT kernel entry on GB10 nodes.
#
# The standard is an explicit entry, never GRUB_DEFAULT=saved: with "saved"
# the real boot target lives in /boot/grub/grubenv, so one grub-set-default,
# grub-reboot or maintainer script silently changes which kernel a node boots
# while /etc/default/grub still looks correct. An explicit entry string is
# declarative, greppable and diffable across the fleet.
#
# This changes configuration only. It never reboots: the new default takes
# effect at the next natural boot. Serving stays up.
#
# Usage:
#   bash apply-grub-default.sh --check node1 node2     # read-only drift report
#   bash apply-grub-default.sh node1 node2             # apply (idempotent)
#   GB10_HOSTS="node1 node2" bash apply-grub-default.sh
#
# Optional environment:
#   KERNEL=6.17.0-1032-nvidia    target kernel (must be installed on the node)
#   SUBMENU="Advanced options for DGX OS GNU/Linux"
#   ENTRY_PREFIX="DGX OS GNU/Linux, with Linux"
#
# Privilege: the remote side needs root or passwordless sudo to write
# /etc/default/grub and regenerate grub.cfg. --check needs no privilege for
# the /etc/default/grub read; it cross-checks grub.cfg only when sudo is free.
#
# Exit codes: 0 aligned/applied, 1 drift found (--check), 2 error,
#             3 skipped (no privilege on that node).

set -uo pipefail

KERNEL="${KERNEL:-6.17.0-1032-nvidia}"
SUBMENU="${SUBMENU:-Advanced options for DGX OS GNU/Linux}"
ENTRY_PREFIX="${ENTRY_PREFIX:-DGX OS GNU/Linux, with Linux}"
WANT="${SUBMENU}>${ENTRY_PREFIX} ${KERNEL}"

MODE="apply"
HOSTS=()
for arg in "$@"; do
    case "$arg" in
        --check) MODE="check" ;;
        --apply) MODE="apply" ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) HOSTS+=("$arg") ;;
    esac
done
if [ ${#HOSTS[@]} -eq 0 ] && [ -n "${GB10_HOSTS:-}" ]; then
    read -ra HOSTS <<< "$GB10_HOSTS"
fi
if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "Usage: bash $0 [--check] <host> [<host> ...]   (or set GB10_HOSTS)" >&2
    exit 2
fi

REMOTE=$(mktemp "${TMPDIR:-/tmp}/gb10-grub-default.XXXXXX.sh")
trap 'rm -f "$REMOTE"' EXIT

cat > "$REMOTE" <<'REMOTE_SCRIPT'
# Runs ON the GB10 node. Env in: MODE, WANT, KERNEL.
set -u
CFG=/etc/default/grub
GRUBCFG=/boot/grub/grub.cfg
newcfg=""
cleanup() {
    [ -n "$newcfg" ] && { [ "$(id -u)" -eq 0 ] && rm -f "$newcfg" || sudo -n rm -f "$newcfg"; }
    rm -f "/tmp/grub.new.$$" "/tmp/grub-mkconfig.log.$$"
}
trap cleanup EXIT
DEF_RE='^[[:space:]]*set default='
# Report the UNCONDITIONAL default. grub.cfg also carries a
# `set default="${next_entry}"` one-shot override (grub-reboot); that is not
# the persistent default and must not be reported as one.
default_of() {
    if [ -r "$1" ]; then
        grep -hE "$DEF_RE" "$1"
    else
        sudo -n grep -hE "$DEF_RE" "$1" 2>/dev/null
    fi | grep -v 'next_entry' | head -1 | sed -e 's/^[[:space:]]*set default=//'
}

[ -r "$CFG" ] || { echo "ERROR: $CFG not readable"; exit 2; }
cur=$(grep -E '^[[:space:]]*GRUB_DEFAULT=' "$CFG" | head -1 | sed -e 's/^[[:space:]]*GRUB_DEFAULT=//')
[ -n "$cur" ] || cur="(unset)"

# Is the target entry actually present in the generated menu? Only trusted
# when this account can read /boot/grub/grub.cfg (mode 600 root) or has sudo.
menu_ok="unknown"
if [ -r "$GRUBCFG" ]; then
    if grep -qF "menuentry '${WANT#*>}'" "$GRUBCFG"; then menu_ok="yes"; else menu_ok="no"; fi
elif sudo -n true 2>/dev/null; then
    if sudo -n grep -qF "menuentry '${WANT#*>}'" "$GRUBCFG" 2>/dev/null; then menu_ok="yes"; else menu_ok="no"; fi
fi

want_quoted="\"${WANT}\""
if [ "$MODE" = "check" ]; then
    echo "config GRUB_DEFAULT=${cur}"
    echo "target ${want_quoted}"
    echo "kernel-image $( [ -e "/boot/vmlinuz-${KERNEL}" ] && echo present || echo MISSING )"
    echo "menu-entry ${menu_ok}"
    if [ -r "$GRUBCFG" ] || sudo -n true 2>/dev/null; then
        echo "cfg-default $(default_of "$GRUBCFG")"
    else
        echo "cfg-default (unreadable without sudo)"
    fi
    echo "running-kernel $(uname -r)"
    if [ "$cur" = "$want_quoted" ]; then echo "verdict ALIGNED"; exit 0; fi
    echo "verdict DRIFT"
    exit 1
fi

# ---- apply -------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then
        SUDO="sudo -n"
    else
        echo "SKIP: needs root or passwordless sudo on $(hostname); nothing changed"
        exit 3
    fi
fi

if [ ! -e "/boot/vmlinuz-${KERNEL}" ]; then
    echo "ERROR: /boot/vmlinuz-${KERNEL} missing; not touching the default"
    exit 2
fi

stamp=$(date +%Y%m%d-%H%M%S)
$SUDO cp -p "$CFG" "${CFG}.bak-${stamp}" || exit 2
# Replace only the GRUB_DEFAULT line; every other line is left byte-identical.
awk -v w="$WANT" '
    /^[[:space:]]*GRUB_DEFAULT=/ { print "GRUB_DEFAULT=\"" w "\""; seen=1; next }
    { print }
    END { if (!seen) print "GRUB_DEFAULT=\"" w "\"" }
' "$CFG" > "/tmp/grub.new.$$" || exit 2
$SUDO install -m 644 -o root -g root "/tmp/grub.new.$$" "$CFG" || exit 2

# Regenerate into a temp file, verify, then install: a failed grub-mkconfig
# must never leave a truncated grub.cfg on a node with a hidden GRUB_TIMEOUT.
# The temp file is created BY ROOT: with fs.protected_regular set (the Ubuntu
# default), root cannot O_CREAT-truncate a file another user made in a sticky
# /tmp, and grub-mkconfig's redirect fails with "cannot create".
newcfg=$($SUDO mktemp /boot/grub/.grub-cfg-gb10.XXXXXX) || exit 2
if ! $SUDO grub-mkconfig -o "$newcfg" >/tmp/grub-mkconfig.log.$$ 2>&1; then
    echo "ERROR: grub-mkconfig failed; grub.cfg untouched. Log:"
    tail -5 /tmp/grub-mkconfig.log.$$
    exit 2
fi
$SUDO chmod 644 "$newcfg"
if ! grep -qF "menuentry '${WANT#*>}'" "$newcfg"; then
    echo "ERROR: generated menu has no entry '${WANT#*>}'; grub.cfg untouched"
    exit 2
fi
if ! $SUDO grub-script-check "$newcfg" 2>/dev/null; then
    echo "ERROR: grub-script-check rejected the generated config; grub.cfg untouched"
    exit 2
fi
$SUDO install -m 600 -o root -g root "$newcfg" "$GRUBCFG" || exit 2

echo "config GRUB_DEFAULT=$(grep -E '^[[:space:]]*GRUB_DEFAULT=' "$CFG" | head -1 | sed -e 's/^[[:space:]]*GRUB_DEFAULT=//')"
echo "cfg-default $(default_of "$GRUBCFG")"
echo "menu-entry yes"
echo "running-kernel $(uname -r) (unchanged; new default applies at next boot)"
echo "verdict APPLIED"
exit 0
REMOTE_SCRIPT

overall=0
for host in "${HOSTS[@]}"; do
    echo ""
    echo "===== $host ====="
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
        "MODE=$(printf '%q' "$MODE") WANT=$(printf '%q' "$WANT") KERNEL=$(printf '%q' "$KERNEL") bash -s" < "$REMOTE" 2>&1)
    rc=$?
    printf '%s\n' "$out"
    [ $rc -ne 0 ] && [ $rc -ne 1 ] && overall=$rc
    [ $rc -eq 1 ] && [ "$MODE" = "check" ] && overall=1
    [ $rc -eq 3 ] && [ "$MODE" = "apply" ] && [ $overall -eq 0 ] && overall=3
done
exit $overall

#!/usr/bin/env bash
# Apply the carveout stages to 1 to 8 GB10 nodes, idempotently.
#
# This wraps three things that already exist in this repo and adds no new
# capability of its own:
#
#   gate    deploy/carveout-gate.sh   read-only: may THIS node lend?
#   stage 1 watermark_boost_factor=0, stop the drift-running snapd
#   stage 2 spark-attic's atticd (github.com/bertholomus/spark-attic)
#
# It never touches the serving recipe, the engine, the model, the fabric,
# clocks or the kernel. Stage 3 (engine consumption of the carveout) is not
# implemented anywhere in this repo and is not reachable from this script:
# stage 2 installs a daemon that lends nothing until something borrows.
#
# Read AGENT-APPLY.md before running it. That file is the runbook: it names
# the expected output and the stop condition for every step.
#
# Usage:
#   bash deploy/apply.sh --inventory inventory.txt --check-inventory
#   bash deploy/apply.sh --inventory inventory.txt --dry-run
#   bash deploy/apply.sh --inventory inventory.txt --apply
#   bash deploy/apply.sh --inventory inventory.txt --verify
#   bash deploy/apply.sh --inventory inventory.txt --rollback
#   bash deploy/apply.sh node1 node2 --dry-run        # nodes as arguments
#   bash deploy/apply.sh --inventory inventory.txt --apply --stage 1
#   bash deploy/apply.sh --inventory inventory.txt --verify --stage 1
#   bash deploy/apply.sh --root DIR --apply           # test hook, see below
#
# Inventory file: one node per line, blank lines and '#' comments ignored.
#   <ssh-target> [serving-health-url]
#   gb10@node1
#   gb10@node2 http://node1.example:8000/health
# Any count from 1 to 8. A single node needs no switch, no cluster and no
# fabric: with one node you write one line and stop there. Health URLs are
# optional; when one is declared, --verify reads it once, after the stages,
# and it must answer 200.
#
# Modes:
#   --check-inventory
#               parses the inventory, prints the nodes it would act on and
#               exits. No ssh, no gate, nothing on any node.
#   --dry-run   read-only. Runs the gate, reads the node's current state and
#               prints what --apply would do. Nothing is written anywhere.
#   --apply     stage 1 and stage 2, in that order, per node. Idempotent: a
#               node already in the standard state reports "noop" and exits
#               0; a node whose daemon reports a borrow (lent_mib) is not a
#               noop, it fails.
#   --verify    re-reads everything --apply checked, changes nothing.
#   --rollback  reverses stage 2, then stage 1a, in that order.
#
# Flags:
#   --stage 1|2|all     restrict --dry-run, --apply, --verify and --rollback
#                       to one stage (default all)
#   --inventory FILE    node list (see above)
#   --allow-any-count   do not warn when the inventory has more than 8 nodes
#   --root DIR          run against a fake node root instead of over ssh.
#                       Test hook for tests/apply-selftest.sh: no ssh, no
#                       privilege, no GB10. Never use it on a real node.
#
# Environment:
#   ATTIC_INSTALLER      installer to use. Default is upstream's pinned
#                        v0.1.2 install.sh. A local path is allowed (the
#                        self-test uses one); it must be upstream's installer.
#   ATTIC_OTHER_SOCKETS  passed to the installer verbatim. Set it only when
#                        the node runs a lender the gate does not watch; the
#                        gate blocks on the socket we know about.
#   GB10_HOSTS           space-separated nodes, used when neither the
#                        inventory nor the arguments name any.
#
# Exit codes: 0 every node applied/noop/verified, 1 at least one node failed
# or was blocked, 2 usage error, 3 no failures but at least one node was
# skipped (no ssh, or no root/passwordless sudo on the node).

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/carveout-gate.sh"
DEFAULT_INSTALLER="https://github.com/bertholomus/spark-attic/releases/download/v0.1.2/install.sh"

MODE=""
STAGE="all"
INVENTORY=""
ROOT=""
ALLOW_ANY_COUNT=0
NODES=()          # entries: "<ssh-target>|<serving-url>"

usage() { sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) MODE="plan" ;;
        --apply) MODE="apply" ;;
        --verify) MODE="verify" ;;
        --rollback) MODE="rollback" ;;
        --check-inventory) MODE="check" ;;
        --stage) shift; STAGE="${1:-}" ;;
        --inventory) shift; INVENTORY="${1:-}" ;;
        --root) shift; ROOT="${1:-}" ;;
        --allow-any-count) ALLOW_ANY_COUNT=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) NODES+=("$1|") ;;
    esac
    shift
done

if [ -z "$MODE" ]; then
    echo "ERROR: name a mode: --check-inventory, --dry-run, --apply, --verify or --rollback" >&2
    usage >&2
    exit 2
fi
case "$STAGE" in 1|2|all) : ;; *) echo "ERROR: --stage takes 1, 2 or all" >&2; exit 2 ;; esac
[ -x "$GATE" ] || [ -r "$GATE" ] || { echo "ERROR: $GATE missing; run this from the repo" >&2; exit 2; }

# ---------------------------------------------------------------- inventory
if [ -n "$INVENTORY" ]; then
    [ -r "$INVENTORY" ] || { echo "ERROR: cannot read inventory $INVENTORY" >&2; exit 2; }
    NODES=()
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%#*}
        line=$(printf '%s' "$line" | tr '\t' ' ')
        # trim
        line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -z "$line" ] && continue
        set -- $line
        node=$1
        url=${2:-}
        [ $# -gt 2 ] && { echo "ERROR: $INVENTORY: '$line' has more than two fields (node [health-url])" >&2; exit 2; }
        NODES+=("$node|$url")
    done < "$INVENTORY"
fi

if [ ${#NODES[@]} -eq 0 ] && [ -n "${GB10_HOSTS:-}" ]; then
    for h in $GB10_HOSTS; do NODES+=("$h|"); done
fi
if [ ${#NODES[@]} -eq 0 ]; then
    echo "ERROR: no nodes. Write an inventory file (AGENT-APPLY.md step 2) or pass nodes as arguments." >&2
    exit 2
fi

# duplicates are almost always a copy-paste mistake in the inventory
seen=" "
for entry in "${NODES[@]}"; do
    n=${entry%%|*}
    case "$seen" in
        *" $n "*) echo "ERROR: node '$n' is listed twice in the inventory" >&2; exit 2 ;;
    esac
    seen="$seen$n "
done

if [ ${#NODES[@]} -gt 8 ] && [ "$ALLOW_ANY_COUNT" -eq 0 ]; then
    echo "warn: ${#NODES[@]} nodes. This runbook is written and tested for 1 to 8; above 8,"
    echo "warn: nothing here is wrong, but you are outside what has been exercised."
fi

echo "nodes ${#NODES[@]} mode $MODE stage $STAGE"

if [ "$MODE" = check ]; then
    i=0
    for entry in "${NODES[@]}"; do
        i=$((i+1))
        echo "node $i ${entry%%|*}$( [ -n "${entry#*|}" ] && echo " health ${entry#*|}" || echo " health none" )"
    done
    echo "inventory ok ${#NODES[@]} node(s)"
    exit 0
fi

# ---------------------------------------------------------------- node body
# One script, run either on the node over ssh as root, or locally against a
# fake root for the self-test. Everything it writes goes through $R, so with
# R empty (a real node) it writes the real paths.
REMOTE=$(mktemp "${TMPDIR:-/tmp}/gb10-apply.XXXXXX.sh") || exit 2
trap 'rm -f "$REMOTE"' EXIT

cat > "$REMOTE" <<'REMOTE_SCRIPT'
set -u
MODE="${MODE:-plan}"
STAGE="${STAGE:-all}"
R="${NODE_ROOT:-}"
SERVING_URL="${SERVING_URL:-}"
INSTALLER="${ATTIC_INSTALLER:-https://github.com/bertholomus/spark-attic/releases/download/v0.1.2/install.sh}"
OTHER_SOCKETS="${ATTIC_OTHER_SOCKETS:-}"

ETC="$R/etc"
CONF="$ETC/sysctl.d/90-watermark-boost.conf"
STATUS="$R/run/spark-attic/status.json"
fails=0
fail() { echo "FAIL $*"; fails=$((fails+1)); }

SUDO=""
if [ -z "$R" ] && [ "$(id -u)" -ne 0 ] && { [ "$MODE" = apply ] || [ "$MODE" = rollback ]; }; then
    if sudo -n true 2>/dev/null; then
        SUDO="sudo -n"
    else
        echo "SKIP needs root or passwordless sudo on this node; nothing changed"
        exit 3
    fi
fi

# ---- reads -------------------------------------------------------------
wm_now()      { sysctl -n vm.watermark_boost_factor 2>/dev/null | tr -d ' \r' | head -1; }
unit_active() { local a; a=$(systemctl is-active "$1" 2>/dev/null); printf '%s' "${a:-unknown}"; }
unit_enabled(){ local e; e=$(systemctl is-enabled "$1" 2>/dev/null); printf '%s' "${e:-unknown}"; }
jstr()  { [ -f "$STATUS" ] && sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATUS" | head -1; }
jnum()  { [ -f "$STATUS" ] && sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATUS" | head -1; }
jbool() { [ -f "$STATUS" ] && sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$STATUS" | head -1; }

wm_standard_file() { [ -f "$CONF" ] && grep -qxF 'vm.watermark_boost_factor = 0' "$CONF"; }
attic_present()    { [ -f "$STATUS" ] || [ "$(unit_enabled attic.service)" != not-found ]; }
attic_ready() {
    [ "$(jstr state)" = ready ] || return 1
    [ "$(jbool validated)" = true ] || return 1
    local s; s=$(jnum size_mib); [ -n "$s" ] && [ "$s" -gt 0 ]
}

installer_run() {
    if [ -n "$OTHER_SOCKETS" ]; then export ATTIC_OTHER_SOCKETS="$OTHER_SOCKETS"; fi
    case "$INSTALLER" in
        http://*|https://*) curl -fsSL "$INSTALLER" | $SUDO bash -s -- "$@" ;;
        *) if [ -f "$INSTALLER" ]; then $SUDO bash "$INSTALLER" "$@"
           else echo "ERROR installer not found: $INSTALLER"; return 2; fi ;;
    esac
}

check_serving() {
    [ -n "$SERVING_URL" ] || { echo "verify serving skipped (no endpoint declared in inventory)"; return 0; }
    local code
    code=$(curl -fsS -m 10 -o /dev/null -w '%{http_code}' "$SERVING_URL" 2>/dev/null)
    if [ "${code:-000}" = 200 ]; then
        echo "verify serving ok $code"
        return 0
    fi
    fail "serving: $SERVING_URL answered '${code:-no-response}', wanted 200"
    return 1
}

# ---- stage 1 -----------------------------------------------------------
stage1_watermark() {
    local cur state
    cur=$(wm_now)
    case "$MODE" in
    plan)
        if [ "$cur" = 0 ] && wm_standard_file; then
            echo "stage1 watermark noop reads 0 standard-file yes"
        else
            echo "stage1 watermark pending reads ${cur:-unknown} standard-file $(wm_standard_file && echo yes || echo no)"
            echo "would write /etc/sysctl.d/90-watermark-boost.conf: vm.watermark_boost_factor = 0"
            echo "would run sysctl --system; expect readback 0"
        fi
        ;;
    apply)
        if [ "$cur" = 0 ] && wm_standard_file; then
            echo "stage1 watermark noop reads 0 standard-file yes"
            return 0
        fi
        $SUDO mkdir -p "$ETC/sysctl.d" 2>/dev/null || { fail "watermark: cannot create $ETC/sysctl.d"; return 1; }
        # Remember the value we found, once, so --rollback can put it back.
        # Deleting the drop-in and running 'sysctl --system' does NOT restore
        # the kernel default: no stock file sets this knob, so the live value
        # would stay 0 until a reboot. The recorded value is the only exact
        # inverse, and it is kept across re-applies.
        PREV="$R/var/lib/gb10-ops/watermark.previous"
        if [ ! -f "$PREV" ] && [ -n "${cur:-}" ]; then
            $SUDO mkdir -p "$R/var/lib/gb10-ops" 2>/dev/null
            printf '%s\n' "$cur" | $SUDO tee "$PREV" >/dev/null 2>&1
        fi
        printf 'vm.watermark_boost_factor = 0\n' | $SUDO tee "$CONF" >/dev/null 2>&1 \
            || { fail "watermark: cannot write $CONF"; return 1; }
        $SUDO sysctl --system >/dev/null 2>&1 || { fail "watermark: 'sysctl --system' failed"; return 1; }
        cur=$(wm_now)
        if [ "$cur" != 0 ]; then
            fail "watermark: readback '${cur:-unknown}', wanted 0"
            return 1
        fi
        echo "stage1 watermark applied reads 0"
        ;;
    verify)
        state=$( [ "$cur" = 0 ] && wm_standard_file && echo ok || echo FAIL )
        if [ "$state" = ok ]; then
            echo "verify watermark ok reads 0 standard-file yes"
        else
            fail "watermark: reads '${cur:-unknown}', file $(wm_standard_file && echo yes || echo no)"
        fi
        ;;
    rollback)
        PREV="$R/var/lib/gb10-ops/watermark.previous"
        local prev=""
        [ -f "$PREV" ] && prev=$(head -1 "$PREV" | tr -d ' \r')
        if [ -f "$CONF" ] || { [ -n "$prev" ] && [ "$(wm_now)" = 0 ]; }; then
            [ -f "$CONF" ] && $SUDO rm -f "$CONF" || true
            if [ -n "$prev" ]; then
                $SUDO sysctl -w "vm.watermark_boost_factor=$prev" >/dev/null 2>&1 \
                    || fail "watermark: could not restore vm.watermark_boost_factor=$prev"
            else
                fail "watermark: no recorded pre-apply value; set the value you want by hand (the stock default is 15000)"
            fi
            $SUDO rm -f "$PREV" >/dev/null 2>&1
            echo "rollback watermark reverted reads $(wm_now) (restored to the pre-apply value ${prev:-unknown})"
        else
            echo "rollback watermark noop (standard file absent, reads $(wm_now))"
        fi
        ;;
    esac
}

stage1_snapd() {
    local sa se oa oe
    sa=$(unit_active snapd.service); se=$(unit_enabled snapd.service)
    oa=$(unit_active snapd.socket);  oe=$(unit_enabled snapd.socket)
    case "$MODE" in
    plan)
        if [ "$se" = not-found ] && [ "$oe" = not-found ]; then
            echo "stage1 snapd noop units-absent"
        elif [ "$sa" = inactive ] && [ "$oa" = inactive ]; then
            echo "stage1 snapd noop service $sa/$se socket $oa/$oe"
        else
            echo "stage1 snapd pending service $sa/$se socket $oa/$oe"
            echo "would stop snapd.service and snapd.socket (both disabled: they stay stopped)"
        fi
        ;;
    apply)
        if [ "$se" = not-found ] && [ "$oe" = not-found ]; then
            echo "stage1 snapd noop units-absent"
            return 0
        fi
        if [ "$sa" = inactive ] && [ "$oa" = inactive ]; then
            echo "stage1 snapd noop service $sa/$se socket $oa/$oe"
            return 0
        fi
        [ "$se" = not-found ] || $SUDO systemctl stop snapd.service >/dev/null 2>&1
        [ "$oe" = not-found ] || $SUDO systemctl stop snapd.socket  >/dev/null 2>&1
        sa=$(unit_active snapd.service); oa=$(unit_active snapd.socket)
        if [ "$sa" = active ] || [ "$oa" = active ]; then
            fail "snapd: still active after stop (service $sa, socket $oa)"
            return 1
        fi
        echo "stage1 snapd applied service $sa socket $oa"
        ;;
    verify)
        if [ "$se" = not-found ] && [ "$oe" = not-found ]; then
            echo "verify snapd ok units-absent"
        elif [ "$sa" = inactive ] && [ "$oa" = inactive ]; then
            echo "verify snapd ok service $sa socket $oa"
        else
            fail "snapd: service $sa/$se socket $oa/$oe; stage 1b stops both"
        fi
        ;;
    rollback)
        echo "rollback snapd unchanged state service $sa/$se socket $oa/$oe (stopping a disabled unit is not a configuration change)"
        ;;
    esac
}

# ---- stage 2 -----------------------------------------------------------
stage2_attic() {
    local lent
    case "$MODE" in
    plan)
        if attic_ready; then
            lent=$(jnum lent_mib)
            if [ "${lent:-x}" != 0 ]; then
                echo "stage2 attic installed state $(jstr state) size_mib $(jnum size_mib) lent_mib ${lent:-missing} (--apply would refuse: stage 2 leaves lent_mib 0)"
            else
                echo "stage2 attic noop state $(jstr state) size_mib $(jnum size_mib) lent_mib ${lent:-unknown}"
            fi
        elif attic_present; then
            echo "stage2 attic pending-installed state $(jstr state) (not ready; installer would repair)"
            echo "would run installer --check, then the installer"
        else
            echo "stage2 attic pending not-installed"
            echo "would run installer --check, then the installer (upstream validated driver required)"
        fi
        ;;
    apply)
        if attic_ready; then
            # attic_ready() answers "is the daemon installed and validated",
            # which is not the same question as "is this the state stage 2
            # leaves behind". A daemon that already lends (something borrowed
            # the carveout) is installed and ready, so this branch is reached;
            # reporting it as a noop would call the run clean while --verify
            # fails the same node on lent_mib. Refuse instead.
            lent=$(jnum lent_mib)
            if [ "${lent:-x}" != 0 ]; then
                echo "stage2 attic installed state $(jstr state) size_mib $(jnum size_mib) lent_mib ${lent:-missing}"
                fail "attic: lent_mib '${lent:-missing}', wanted 0 (stage 2 adds a daemon, it does not lend)"
                return 1
            fi
            echo "stage2 attic noop state $(jstr state) size_mib $(jnum size_mib) lent_mib $lent"
            return 0
        fi
        echo "stage2 preflight: installer --check"
        if ! installer_run --check; then
            fail "attic: installer preflight failed; not installing on this node"
            return 1
        fi
        echo "stage2 install: upstream installer"
        if ! installer_run; then
            fail "attic: installer failed"
            return 1
        fi
        verify_attic
        ;;
    verify)
        verify_attic
        ;;
    rollback)
        if ! attic_present; then
            echo "rollback attic noop (not installed)"
            return 0
        fi
        $SUDO systemctl disable --now attic.service >/dev/null 2>&1
        if command -v spark-attic >/dev/null 2>&1; then
            $SUDO spark-attic uninstall >/dev/null 2>&1 || fail "attic: 'spark-attic uninstall' failed"
        fi
        if [ -f "$STATUS" ] && [ "$(jstr state)" = ready ]; then
            fail "attic: still reports ready after uninstall"
            return 1
        fi
        echo "rollback attic reverted (unit disabled, daemon uninstalled; the key and logs are kept, --purge removes them)"
        ;;
    esac
}

verify_attic() {
    local st val size lent drv rc=0
    st=$(jstr state); val=$(jbool validated); size=$(jnum size_mib); lent=$(jnum lent_mib); drv=$(jstr driver)
    [ "$st" = ready ]       || { fail "attic: state '${st:-missing}', wanted ready"; rc=1; }
    [ "$val" = true ]       || { fail "attic: validated '${val:-missing}', wanted true"; rc=1; }
    [ -n "$size" ] && [ "${size:-0}" -gt 0 ] || { fail "attic: size_mib '${size:-missing}', wanted > 0"; rc=1; }
    [ "${lent:-x}" = 0 ]    || { fail "attic: lent_mib '${lent:-missing}', wanted 0 (stage 2 adds a daemon, it does not lend)"; rc=1; }
    # status.json is the daemon's own state and is authoritative. 'doctor' is
    # advisory: upstream's install.sh runs under 'set -o pipefail', so its
    # 'ldconfig -p | grep -q' can turn SIGPIPE into a false "libcuda.so.1 is
    # missing" on a node where the library resolves fine. A doctor failure is
    # reported, never fatal; see docs/DISPLAY-CARVEOUT.md.
    if spark-attic doctor >/dev/null 2>&1; then
        echo "verify attic doctor ok"
    else
        echo "verify attic doctor warn 'spark-attic doctor' exited non-zero; status.json above is authoritative (known upstream false negative, docs/DISPLAY-CARVEOUT.md)"
    fi
    [ $rc -eq 0 ] && echo "verify attic ok state $st validated $val size_mib $size lent_mib $lent driver ${drv:-unknown}"
    return $rc
}

# ---- run ---------------------------------------------------------------
if [ "$STAGE" = "1" ] || [ "$STAGE" = "all" ]; then
    stage1_watermark
    stage1_snapd
fi
if [ "$STAGE" = "2" ] || [ "$STAGE" = "all" ]; then
    stage2_attic
fi
if [ "$MODE" = "verify" ]; then
    check_serving
fi

if [ "$fails" -gt 0 ]; then
    echo "verdict FAIL $fails check(s)"
    exit 1
fi
case "$MODE" in
    plan)     echo "verdict PLAN-ONLY (nothing changed)" ;;
    apply)    echo "verdict APPLIED-OR-NOOP" ;;
    verify)   echo "verdict VERIFIED" ;;
    rollback) echo "verdict ROLLED-BACK" ;;
esac
exit 0
REMOTE_SCRIPT

[ -s "$REMOTE" ] || { echo "ERROR: could not write the node script" >&2; exit 2; }

# ---------------------------------------------------------------- per node
overall=0
have_skip=0
for entry in "${NODES[@]}"; do
    node=${entry%%|*}
    url=${entry#*|}
    echo ""
    echo "===== $node ====="

    if [ -n "$ROOT" ]; then
        # Test hook: no ssh, no privilege. The gate reads the same fake root.
        gate_out=$(bash "$GATE" --from "$ROOT" 2>&1); grc=$?
    else
        gate_out=$(bash "$GATE" "$node" 2>&1); grc=$?
    fi
    verdict=$(printf '%s\n' "$gate_out" | sed -n 's/^verdict //p' | tail -1)
    blocked=$(printf '%s\n' "$gate_out" | sed -n 's/^blocked //p')
    warns=$(printf '%s\n' "$gate_out" | sed -n 's/^warn //p')
    [ -n "$warns" ] && printf '%s\n' "$warns" | sed 's/^/gate warn /'
    echo "gate $( [ -n "$verdict" ] && echo "$verdict" || echo "unknown (exit $grc)" )"

    gate_ok=1
    if [ "${verdict:-}" = ELIGIBLE ]; then gate_ok=0; fi

    if [ "$grc" -eq 3 ] || [ -z "${verdict:-}" ]; then
        # The gate could not snapshot the node: no ssh, no route. That is a
        # skip, not a failed check, and nothing is attempted afterwards.
        echo "node verdict SKIPPED (gate could not reach the node over ssh)"
        have_skip=1
        continue
    fi

    if [ "$gate_ok" -ne 0 ]; then
        printf '%s\n' "$blocked" | sed 's/^/gate blocked /'
        if [ "$MODE" = apply ] && { [ "$STAGE" = 2 ] || [ "$STAGE" = all ]; }; then
            echo "node verdict BLOCKED (gate refused stage 2; nothing changed on this node)"
            overall=1
            continue
        fi
        if [ "$STAGE" = 2 ]; then
            echo "node verdict BLOCKED"
            overall=1
            continue
        fi
        if [ "$MODE" = plan ]; then
            # A plan that cannot be applied as written is not a clean plan:
            # report the node as not eligible so the run's exit code says so.
            overall=1
        fi
        echo "gate note not ELIGIBLE: stage 1 is node hygiene and does not need the gate; stage 2 would be refused"
    fi


    if [ -n "$ROOT" ]; then
        out=$(MODE="$MODE" STAGE="$STAGE" NODE_ROOT="$ROOT" SERVING_URL="$url" \
              ATTIC_INSTALLER="${ATTIC_INSTALLER:-$DEFAULT_INSTALLER}" \
              ATTIC_OTHER_SOCKETS="${ATTIC_OTHER_SOCKETS:-}" \
              bash "$REMOTE" 2>&1); rc=$?
    else
        out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$node" \
              "MODE=$(printf '%q' "$MODE") STAGE=$(printf '%q' "$STAGE") \
               SERVING_URL=$(printf '%q' "$url") \
               ATTIC_INSTALLER=$(printf '%q' "${ATTIC_INSTALLER:-$DEFAULT_INSTALLER}") \
               ATTIC_OTHER_SOCKETS=$(printf '%q' "${ATTIC_OTHER_SOCKETS:-}") bash -s" \
              < "$REMOTE" 2>&1); rc=$?
    fi
    printf '%s\n' "$out"

    case "$rc" in
        0) echo "node verdict OK" ;;
        3) echo "node verdict SKIPPED (no ssh, or no root/passwordless sudo on the node)"
           have_skip=1 ;;
        *) echo "node verdict FAIL (exit $rc)"; overall=1 ;;
    esac
done

echo ""
if [ "$overall" -ne 0 ]; then
    echo "RESULT: $([ "$MODE" = plan ] && echo "at least one node is not eligible for the full run" || echo "at least one node failed; fix it and re-run, the rest are already applied or untouched")"
    exit 1
fi
if [ "$have_skip" -eq 1 ]; then
    echo "RESULT: no failures, but at least one node was skipped"
    exit 3
fi
case "$MODE" in
    plan)     echo "RESULT: plan only, nothing changed on any node" ;;
    apply)    echo "RESULT: every node applied or already applied" ;;
    verify)   echo "RESULT: every node verified" ;;
    rollback) echo "RESULT: every node rolled back" ;;
esac
exit 0

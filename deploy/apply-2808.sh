#!/usr/bin/env bash
# Apply 2808 MHz CPU clock cap to all GB10 nodes with systemd persistence.
# Mirrors deploy/apply-2200.sh (GPU) for the CPU side: CPPC auto_select
# must be OFF or scaling_max_freq changes are ignored by hardware, so the
# cap sets auto_select=0 on every cpufreq policy first, then
# scaling_max_freq=2808000 on every policy. Robust to policy count:
# iterates /sys/devices/system/cpu/cpufreq/policy*.
#
# Run from a host that can reach the nodes over Tailscale SSH as root.
#
# Usage:
#   ./apply-2808.sh                    # nodes from $GB10_HOSTS
#   ./apply-2808.sh node1 node2        # specific nodes
#   ./apply-2808.sh --uninstall        # remove cap, restore defaults

set -e

CAP="2808000"
SERVICE="gb10-cpu-cap"
UNIT_PATH="/etc/systemd/system/${SERVICE}.service"
HELPER_PATH="/usr/local/bin/${SERVICE}"

if [ "$1" = "--uninstall" ]; then
    if [ $# -lt 2 ]; then
        echo "Usage: $0 --uninstall <node> [node ...]" >&2
        exit 1
    fi
    echo "Removing CPU clock cap from all nodes..."
    for host in "${@:2}"; do
        [ -z "$host" ] && continue
        echo "=== $host ==="
        tailscale ssh "root@$host" "systemctl disable --now ${SERVICE}.service; rm -f ${UNIT_PATH} ${HELPER_PATH}; systemctl daemon-reload; echo 'Removed (CPUs restored to stock by ExecStop)'"
    done
    exit 0
fi

# Nodes come from arguments, else $GB10_HOSTS (space-separated Tailscale
# names or SSH-reachable hostnames). No fleet defaults are baked in.
HOSTS=("$@")
if [ ${#HOSTS[@]} -eq 0 ] && [ -n "$GB10_HOSTS" ]; then
    read -ra HOSTS <<< "$GB10_HOSTS"
fi
if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "No nodes given. Usage: ./apply-2808.sh <node> [node ...] (or set GB10_HOSTS)"
    exit 1
fi

HELPER=$(cat <<EOF
#!/usr/bin/env bash
# gb10-cpu-cap: apply or restore the 2808 MHz CPU clock cap.
# Installed by deploy/apply-2808.sh; run by ${SERVICE}.service at boot.
set -e
BASE=/sys/devices/system/cpu/cpufreq
CAP=${CAP}
case "\$1" in
    apply)
        # auto_select OFF first, or the cap is ignored by hardware
        for d in \$BASE/policy*; do echo 0 > \$d/auto_select; done
        for d in \$BASE/policy*; do echo \$CAP > \$d/scaling_max_freq; done
        ;;
    restore)
        for d in \$BASE/policy*; do cat \$d/cpuinfo_max_freq > \$d/scaling_max_freq; done
        for d in \$BASE/policy*; do echo 1 > \$d/auto_select; done
        ;;
    *) echo "usage: \$0 apply|restore" >&2; exit 1 ;;
esac
EOF
)

UNIT=$(cat <<EOF
[Unit]
Description=Cap GB10 CPU clock for thermal and power headroom

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${HELPER_PATH} apply
ExecStop=${HELPER_PATH} restore

[Install]
WantedBy=multi-user.target
EOF
)

for host in "${HOSTS[@]}"; do
    echo ""
    echo "=== $host ==="
    # Install helper + systemd service for persistence
    echo "$HELPER" | tailscale ssh "root@$host" "tee ${HELPER_PATH} > /dev/null && chmod +x ${HELPER_PATH}"
    echo "$UNIT" | tailscale ssh "root@$host" "tee ${UNIT_PATH} > /dev/null"
    # Enable and start: starting the unit applies the cap immediately
    tailscale ssh "root@$host" "systemctl daemon-reload && systemctl enable --now ${SERVICE}.service && echo 'Service installed and started'"
    # Verify by reading back
    tailscale ssh "root@$host" "BASE=/sys/devices/system/cpu/cpufreq; total=\$(ls -d \$BASE/policy* | wc -l); capped=\$(grep -l '^${CAP}\$' \$BASE/policy*/scaling_max_freq | wc -l); autooff=\$(grep -l '^0\$' \$BASE/policy*/auto_select | wc -l); echo \"policies: \$total, at ${CAP}: \$capped, auto_select=0: \$autooff\"; [ \"\$capped\" = \"\$total\" ] && [ \"\$autooff\" = \"\$total\" ] && echo 'Cap verified' || echo 'FAILED'"
done

echo ""
echo "Done. 2808 MHz CPU cap applied to ${#HOSTS[@]} node(s)."

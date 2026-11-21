#!/usr/bin/env bash
# netns-jail.sh — ROOT fallback jail for machines where systemd's cgroup IP
# filters are unavailable (very old kernels). Requires root (sudo): the jail
# uses a network namespace whose only route out is a host veth gated by an
# nftables FORWARD allowlist — everything else (internet, DNS, other LAN hosts)
# is simply unroutable.
#
#   sudo ./scripts/netns-jail.sh -- ./scripts/inside-jail.sh jailsh
#   sudo ./scripts/netns-jail.sh -- bash
#
# TARGET_HOST must be set in .env; EXPLORER_ALLOW_COARSE_LAN=1 loosens services.
set -euo pipefail

NS=explorer-jail
VETH_HOST=veth-expl
VETH_NS=eth0
SUBNET_PREFIX=10.98.76

CMD=("$@"); [[ ${CMD[0]:-} == "--" ]] && CMD=("${CMD[@]:1}")
[[ ${#CMD[@]} -gt 0 ]] || { echo "usage: sudo $0 -- <command...>" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "need root (sudo) — namespaces must be owned by root" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CONFIG_FILE="${EXPLORER_CONFIG:-$SCRIPT_DIR/config/explorer.$SUDO_USER.json}"
set -a; . "$SCRIPT_DIR/.env"; set +a

mapfile -t PROPS < <("$PYTHON_BIN" "$SCRIPT_DIR/scripts/jail-props.py" "$CONFIG_FILE")

RULES=()
for p in "${PROPS[@]}"; do
  case "$p" in
    IPAddressPortAllow=*)
      v="${p#IPAddressPortAllow=}"; host="${v%:*}"; port="${v#*:}"
      RULES+=("ip saddr $SUBNET_PREFIX.0/24 ip daddr $host tcp dport $port accept")
      ;;
  esac
done

cleanup() {
  ip netns del "$NS" 2>/dev/null || true
  ip link del "$VETH_HOST" 2>/dev/null || true
  nft delete table inet explorer 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s "$SUBNET_PREFIX.0/24" -j MASQUERADE 2>/dev/null || true
}

cleanup
trap cleanup EXIT

ip netns add "$NS"
ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
ip link set "$VETH_NS" netns "$NS"
ip addr add "$SUBNET_PREFIX.1/24" dev "$VETH_HOST"
ip link set "$VETH_HOST" up
ip netns exec "$NS" ip addr add "$SUBNET_PREFIX.2/24" dev "$VETH_NS"
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip link set "$VETH_NS" up
ip netns exec "$NS" ip route add default via "$SUBNET_PREFIX.1"

sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s "$SUBNET_PREFIX.0/24" -j MASQUERADE

nft add table inet explorer
nft add chain inet explorer fw '{ type filter hook forward priority 0; policy drop; }'
nft add rule inet explorer fw ct state established,related accept
for r in "${RULES[@]}"; do nft add rule inet explorer fw $r; done

SUDO_UID="${SUDO_UID:-0}"; SUDO_GID="${SUDO_GID:-0}"
runuser -u "#$SUDO_UID" -- true 2>/dev/null || SUDO_UID=root

set +e
ip netns exec "$NS" runuser -u "#$SUDO_UID" -- env \
  HOME="$(getent passwd "$SUDO_UID" | cut -d: -f6)" \
  USER="$(id -un "$SUDO_UID")" LOGNAME="$(id -un "$SUDO_UID")" \
  PATH="$PATH" TARGET_HOST="${TARGET_HOST:-}" \
  "${CMD[@]}"
rc=$?
set -e
exit "$rc"

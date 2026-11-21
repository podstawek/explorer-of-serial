#!/usr/bin/env bash
# install-jail.sh — ONE-TIME admin setup for explorer's systemd jail.
# You (the human) run this with sudo. Two tiny artifacts, both easy to remove:
#   /etc/systemd/system/net-jail.slice   (grouping only; filters come from the
#                                         per-run -p properties, attached to
#                                         each transient scope)
#   /etc/sudoers.d/explorer-jail         (NOPASSWD for systemd-run for YOU only)
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] || { echo "run via sudo as your own user (not bare root)" >&2; exit 1; }

SR_BIN="$(command -v systemd-run)"

cat > /etc/systemd/system/net-jail.slice <<EOF
[Unit]
Description=Network jail for explorer agent runs
# permit many sequential/transient jailed runs without start-rate penalties
StartLimitIntervalSec=0
EOF

umask 077
cat > /etc/sudoers.d/explorer-jail <<EOF
# explorer harness: allow running systemd-run (network jails) without password
$TARGET_USER ALL=(ALL) NOPASSWD: $SR_BIN
EOF
chmod 0440 /etc/sudoers.d/explorer-jail
visudo -cf /etc/sudoers.d/explorer-jail

systemctl daemon-reload
echo "Installed: net-jail.slice + sudoers rule (NOPASSWD) for $TARGET_USER"
echo "Remove: sudo rm -f /etc/sudoers.d/explorer-jail /etc/systemd/system/net-jail.slice && sudo systemctl daemon-reload"

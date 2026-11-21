#!/usr/bin/env bash
# stop.sh — stop a running explorer run WITHOUT touching any state or files
# (that's what reset.sh / clean-slate.sh are for). Idempotent: safe to run
# when nothing is running.
#
# Stopped, in order: supervisor units (if installed), go.sh launcher, the jail
# scope's `opencode run` (systemd kills its whole cgroup when the scope dies;
# the [x] regex tricks keep pkill from matching THIS script or your shell).
# TERM first — inside-jail.sh's EXIT trap then writes the honest
# `# RESULT: INCOMPLETE (did not complete cleanly)` sentinel — 30s grace,
# then KILL for whatever remains (opencode serve, stray ssh children).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# alive(): patterns identical to reset.sh, so both agree on what "the run" is.
alive() { pgrep -f 'explorer/go[.]sh|[o]pencode run .*--agent explorer' >/dev/null 2>&1; }

if ! alive; then
  echo "not running — nothing to stop."
  exit 0
fi

echo "== stopping run (TERM) =="
systemctl stop explorer.service explorer-watchdog.timer 2>/dev/null || true
pkill -TERM -f 'explorer/go[.]sh' 2>/dev/null
pkill -TERM -f '[o]pencode run .*--agent explorer' 2>/dev/null

# grace: let inside-jail.sh's EXIT trap finalize RESULT.md
for _ in $(seq 30); do
  alive || break
  sleep 1
done

if alive; then
  echo "== still alive after 30s — KILL =="
  pkill -KILL -f 'explorer/go[.]sh' 2>/dev/null
  pkill -KILL -f '[o]pencode run .*--agent explorer' 2>/dev/null
fi
pkill -KILL -f '[o]pencode serve.*harness-home' 2>/dev/null
sleep 1
pkill -KILL -f '[s]sh pi' 2>/dev/null

if alive; then
  echo "WARN: still alive:"; pgrep -af 'explorer/go[.]sh|[o]pencode run .*--agent explorer'
  exit 1
fi
echo "stopped."
if [[ -f RESULT.md ]]; then
  echo "RESULT.md now reads: $(head -n1 RESULT.md)"
  echo "(if that is the INCOMPLETE sentinel, it is this stop, not a verdict — pause+resume overwrites it)"
fi

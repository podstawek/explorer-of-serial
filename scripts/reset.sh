#!/usr/bin/env bash
# reset.sh — STOP the exercise and wipe it clean, back to a fresh tree.
#
#   scripts/reset.sh                 stop + wipe local run state
#   scripts/reset.sh --wipe-pi       ... and clear /home/explorer on the Pi
#   scripts/reset.sh --start         ... and immediately launch a fresh run
#   (flags combinable: scripts/reset.sh --wipe-pi --start)
#
# What is stopped:  go.sh, the jail scope (systemd kills its whole cgroup),
#                   opencode session/server, its ssh children.
# What is archived (moved, not deleted): FINDINGS.md, RESULT.md, TASK.md,
#                   logs/*, evidence/, .run-state/, .harness-home/ (agent session DBs)
#                   -> ../explorer-archive/aborted-<timestamp>/
#                   Destination is deliberately OUTSIDE the project tree:
#                   anything a future run can read is a leak (self-answering taint).
# What is NEVER touched: task.md, code, config/, docs/, jail slice, sudoers.
#
# Tunables (used by scripts/clean-slate.sh; defaults unchanged):
#   RESET_ARCHIVE=DIR       archive destination instead of logs/aborted-$TS
#   RESET_NO_ARCHIVE=1      skip the archive step entirely (stop/wipe/preflight/start only)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
TS=$(date +%Y%m%d-%H%M%S)
ARCHIVE="${RESET_ARCHIVE:-../explorer-archive/aborted-$TS}"

WIPE_PI=0; START=0
for a in "$@"; do
  case "$a" in
    --wipe-pi) WIPE_PI=1 ;;
    --start)   START=1 ;;
    *) echo "unknown flag: $a"; exit 2 ;;
  esac
done

echo "== stopping run =="
# the run's own scope first (kills opencode + children in one cgroup),
# then belt+braces by pattern ([x] tricks keep pkill from matching this
# script's own command line or an interactive shell).
systemctl stop explorer.service explorer-watchdog.timer 2>/dev/null || true
pkill -TERM -f 'explorer/go[.]sh' 2>/dev/null
pkill -TERM -f '[o]pencode run .*--agent explorer' 2>/dev/null
sleep 3
pkill -KILL  -f 'explorer/go[.]sh' 2>/dev/null
pkill -KILL  -f '[o]pencode run .*--agent explorer' 2>/dev/null
pkill -KILL  -f '[o]pencode serve.*harness-home' 2>/dev/null
pkill -KILL -f '[s]sh pi' 2>/dev/null
sleep 1
if pgrep -af 'explorer/go[.]sh|[o]pencode run .*--agent explorer' >/dev/null 2>&1; then
  echo "WARN: still alive:"; pgrep -af 'explorer/go[.]sh|[o]pencode run .*--agent explorer'
else
  echo "  all stopped"
fi

# Generated summary articles must never linger in the tree where a later run
# could discover and read them (self-answering taint). Sweep them to the
# archive — even on RESET_NO_ARCHIVE=1 (resume), while keeping run memory.
shopt -s nullglob; sums=(summary-*.html); shopt -u nullglob
if (( ${#sums[@]} )); then
  if [[ "${RESET_NO_ARCHIVE:-0}" == 1 ]]; then
    sdest="../explorer-archive/summaries"
  else
    sdest="$ARCHIVE/summaries"
  fi
  mkdir -p "$sdest" && mv -f -- "${sums[@]}" "$sdest/" \
    && echo "  swept ${#sums[@]} generated summary page(s) -> $sdest"
fi

if [[ "${RESET_NO_ARCHIVE:-0}" == 1 ]]; then
  echo "== archive skipped (RESET_NO_ARCHIVE=1) =="
else
  echo "== archiving evidence =="
  mkdir -p "$ARCHIVE"
  for f in FINDINGS.md RESULT.md TASK.md; do [[ -e "$f" ]] && mv "$f" "$ARCHIVE/"; done
  [[ -e .run-state ]]    && mv .run-state "$ARCHIVE/run-state"
  shopt -s nullglob
  # logs/aborted-* = legacy in-tree archives (pre out-of-tree default); sweep them too.
  for f in logs/run-*.log logs/netcheck-*.txt logs/launch-*.out logs/ffprobe* logs/aborted-*; do mv -- "$f" "$ARCHIVE/" 2>/dev/null; done
  shopt -u nullglob
  [[ -d .harness-home ]] && mv .harness-home "$ARCHIVE/harness-home"
  # evidence/ is run state: a run's scratch dumps here must never survive
  # into the next run's sandbox.
  [[ -d evidence ]] && mv evidence "$ARCHIVE/evidence"
  mkdir -p .harness-home logs evidence
  printf '# Findings\n\n(run not started yet)\n' > FINDINGS.md
  git add -A FINDINGS.md 2>/dev/null && git commit -qm "reset.sh: wiped run state $TS" 2>/dev/null || true
  echo "  moved to $ARCHIVE/  (FINDINGS, RESULT, logs, evidence, .run-state, .harness-home)"
  echo "  PERMANENT ERASE:  rm -rf '$ARCHIVE'"
fi

if [[ "$WIPE_PI" == 1 ]]; then
  echo "== wiping /home/explorer on the Pi =="
  PI_ALIAS="$(grep -m1 '^EXPLORER_TARGET=' .env | cut -d= -f2)"
  [[ -n "$PI_ALIAS" ]] || PI_ALIAS=pi
  # NEVER delete .ssh — that holds the key we log in with, and the Pi is
  # key-only for us (recovering from wiping it needs a manual password login).
  if ssh -o BatchMode=yes -o ConnectTimeout=8 "$PI_ALIAS" 'find "$HOME" -mindepth 1 -maxdepth 1 -not -name .ssh -exec rm -rf {} + 2>/dev/null; echo ok'; then
    echo "  Pi home cleared"
  else
    echo "  WARN: could not reach Pi — clear /home/explorer manually"
  fi
fi

if [[ "$START" == 1 ]]; then
  echo "== pre-flight: model endpoints + ssh to target =="
  FAIL=0
  PI_ALIAS="$(grep -m1 '^EXPLORER_TARGET=' .env | cut -d= -f2)"; [[ -n "$PI_ALIAS" ]] || PI_ALIAS=pi
  if ssh -o BatchMode=yes -o ConnectTimeout=8 "$PI_ALIAS" 'echo ok' >/dev/null 2>&1; then
    echo "  ssh $PI_ALIAS: ok (key auth)"
  else
    echo "  FATAL: ssh $PI_ALIAS key-auth failed — a run would just flail. Fix access before --start."; FAIL=1
  fi
  for u in $(grep -E '^SPARK_URL=|^THORGAL_URL=' .env | cut -d= -f2); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$u/models" 2>/dev/null || echo 000)
    if [[ "$code" == 200 ]]; then echo "  $u: ok"; else echo "  FATAL: $u/models -> $code"; FAIL=1; fi
  done
  [[ "$FAIL" == 1 ]] && { echo "== NOT started =="; exit 1; }
  echo "== launching fresh run =="
  TASK_FILE="${TASK_FILE:-task.md}" setsid nohup ./go.sh > "logs/launch-$TS.out" 2>&1 < /dev/null &
  sleep 3
  echo "  launched pid $! — watch: tail -f $(ls -t logs/run-*.log 2>/dev/null | head -1)"
else
  echo "done. Fresh start:  TASK_FILE=task.md ./go.sh   (or: scripts/reset.sh --start)"
fi

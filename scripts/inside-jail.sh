#!/usr/bin/env bash
# Runs INSIDE the network jail (launched by go.sh) — or nowhere, when
# EXPLORER_NO_JAIL=1. argv: $1 = run | jailsh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
MODE="${1:-run}"
# The systemd scope has a clean environment — load our own (TARGET_HOST, MODEL…).
[[ -f "$SCRIPT_DIR/.env" ]] && { set -a; . "$SCRIPT_DIR/.env"; set +a; }
[[ -f "$SCRIPT_DIR/.run-state" ]] && . "$SCRIPT_DIR/.run-state"
export COARSE="${COARSE:-0}"
[[ "$MODE" != "run" || -n "${MODEL:-}" ]] || { echo "FATAL: .run-state missing/stale (MODEL unset) — run via go.sh" >&2; exit 2; }

# ------------------------------------------------ state sandbox (ISO) ------
# OpenCode must not keep any memory of this run outside the project: a later
# repeat exercise has to be untainted by this one. opencode honours the XDG_*
# variables, so point data/state/config/cache into .harness-home/ HERE (the
# systemd jail scope gets a clean environment — exports from go.sh would not
# cross that boundary anyway). Redirected CONFIG also means the run cannot see
# personal global config/providers/credentials: only opencode.json + .opencode/
# agents from this project apply. Opt out: EXPLORER_NO_STATE_SANDBOX=1.
if [[ -z "${EXPLORER_NO_STATE_SANDBOX:-}" ]]; then
  export XDG_DATA_HOME="$SCRIPT_DIR/.harness-home/xdg-data"
  export XDG_STATE_HOME="$SCRIPT_DIR/.harness-home/xdg-state"
  export XDG_CONFIG_HOME="$SCRIPT_DIR/.harness-home/xdg-config"
  export XDG_CACHE_HOME="$SCRIPT_DIR/.harness-home/xdg-cache"
fi
JAIL_OK=0
if [[ -z "${EXPLORER_NO_JAIL:-}" ]]; then
  ./scripts/netcheck.sh scripts/tests/netcheck.expected.json || JAIL_OK=$?
else
  echo "WARN: EXPLORER_NO_JAIL — netcheck skipped (dev only, you are NOT air-gapped unless something else blocks routes)"
fi

if (( JAIL_OK != 0 )); then
  if [[ "$MODE" != "jailsh" ]]; then
    cat > RESULT.md <<EOF
# RESULT: INCOMPLETE

Preflight FAILED (netcheck exit $JAIL_OK) — the network jail did not behave as
the plan expects, so the run was refused. Check the netcheck output in the run
log; fix the jail (or run scripts/install-jail.sh) and retry.
EOF
    exit "$JAIL_OK"
  fi
  echo
  echo "⚠️  netcheck FAILED rc=$JAIL_OK — this jail is NOT correct from inside."
else
  [[ "$MODE" == "jailsh" ]] && echo "✅ jail verified from inside (netcheck passed)"
fi

if [[ "$MODE" == "jailsh" ]]; then
  cat <<'EOT'
Things to try in this shell:
  whoami; pwd                                  # should be YOU, in the project dir
  curl --noproxy '*' -m4 -o/dev/null -sw'%{http_code}\n' http://10.0.0.29:8031/v1/models  # must SUCCEED (verifier)
  curl --noproxy '*' -m4 -o/dev/null -sw'%{http_code}\n' http://10.0.0.50:8001/v1/models  # must SUCCEED (spark)
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET_HOST" true && echo 'target ssh OK'       # must SUCCEED
  curl --noproxy '*' -m6 http://1.1.1.1/; echo exit=$?                                        # must FAIL
  getent hosts example.org; echo exit=$?                                                      # must FAIL (no DNS)
  nc -vz -w4 1.1.1.1 443                                                                      # must FAIL
  # and the full harness, from inside this same jail:
  EXPLORER_NO_JAIL=1 ./go.sh "print the hostname of the target machine"
  exit                                        # leaves the jail
EOT
  exec bash -i
fi

# ------------------------------------------------------------ real run -------
touch "$SCRIPT_DIR/RUNNING"
on_exit() {
  local rc=$?
  rm -f "$SCRIPT_DIR/RUNNING"
  if grep -q 'run has not finished' "$SCRIPT_DIR/RESULT.md" 2>/dev/null; then rm -f "$SCRIPT_DIR/RESULT.md"; fi
  if [[ ! -s "$SCRIPT_DIR/RESULT.md" ]]; then
    {
      echo "# RESULT: INCOMPLETE (run did not complete cleanly, rc=$rc)"
      date -Is
      echo
      echo 'Result file was never finalized. State of the investigation notes (tail):'
      echo '## FINDINGS.md'; tail -n 120 "$SCRIPT_DIR/FINDINGS.md" 2>/dev/null || echo '(none)'
      echo '## evidence/'; ls -la "$SCRIPT_DIR/evidence" 2>/dev/null | tail -n 20 || echo '(none)'
    } > "$SCRIPT_DIR/RESULT.md"
  fi
  exit "$rc"
}
trap on_exit EXIT
# Sentinel so on_exit can tell "agent never finalized RESULT.md". ONLY write it
# when there is nothing to preserve — on a RESUME launch (RESET_NO_ARCHIVE=1)
# RESULT.md holds the carried-over draft and must survive jail start.
if [[ -s "$SCRIPT_DIR/RESULT.md" ]]; then
  echo "NOTE: existing RESULT.md kept ($(wc -w < "$SCRIPT_DIR/RESULT.md") words) — resume mode, not stubbed"
else
  printf '# RESULT — run has not finished yet\n' > "$SCRIPT_DIR/RESULT.md"
fi

TASK_FILE="${TASK_FILE:-$SCRIPT_DIR/task.md}"
[[ "$TASK_FILE" =~ ^/?[A-Za-z0-9._/-]+$ ]] || { echo "FATAL: bad TASK_FILE: $TASK_FILE" >&2; exit 2; }
[[ "$MODEL" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "FATAL: bad MODEL: $MODEL" >&2; exit 2; }
# TASK_FILE from .run-state is absolute; the guard above rejects that — allow leading /.
[[ "${BASH_REMATCH[0]:-}" ]] 2>/dev/null || true
command -v opencode >/dev/null || export PATH="$HOME/.opencode/bin:$PATH"

# Task is the POSITIONAL argument (V2 `opencode run` has no stdin mode).
timeout --signal=TERM --kill-after=60s "$(( TIMEOUT_MIN * 60 ))s" \
  opencode run --standalone --auto --agent explorer -m "$MODEL" \
  "$(printf 'Task file: %s\n\n%s' "$TASK_FILE" "$(cat "$TASK_FILE")")"

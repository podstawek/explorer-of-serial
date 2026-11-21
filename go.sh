#!/usr/bin/env bash
# explorer — headless, fully-offline dual-model run.
#
#   ./go.sh  # task as argument
#   TASK_FILE=my-task.md ./go.sh                              # or a task file
#   ./go.sh --jail-sh                                           # debug: interactive shell INSIDE the jail
#   EXPLORER_TIMEOUT=480 ./go.sh "…"       (whole minutes)
#
# Flow: config → network jail → (inside jail: netcheck gate → opencode run →
# RESULT.md guarantee). See docs/JAIL.md in this repo for manual testing.
# The agent under test must match
# config/explorer.<user>.json (see config/README.md).
#
# Switches:
#   EXPLORER_NO_JAIL=1           no jail (development only!)
#   EXPLORER_NO_COMMENTATOR=1    skip the live narration page (scripts/commentate.py)
#   COMMENTER_PORT=NNNN          live page port (default 8705)
#   EXPLORER_ALLOW_USER_JAIL=1   jail via user systemd. WARNING: only root can
#                                install the eBPF cgroup IP filters; unprivileged
#                                instances SILENTLY IGNORE them. netcheck inside
#                                will expose that — never ship it unchecked.
#   EXPLORER_CONFIG=path         default config/explorer.$(id -un).json
#   EXPLORER_TIMEOUT / EXPLORER_MAX_STEPS   override config values
#
# One-time admin setup on the machine (run it yourself as root):
#   sudo scripts/install-jail.sh
# Fallback if the kernel lacks cgroup-IP-filter support: scripts/netns-jail.sh.
#
# State isolation: while inside the jail, OpenCode persists ALL its state (db,
# logs, session storage) inside this directory under .harness-home/ — the
# machine-global ~/.local/{share,state} and ~/.config stay untainted (see
# scripts/inside-jail.sh; EXPLORER_NO_STATE_SANDBOX=1 opts out). Leftovers from
# early runs predate that hook: scripts/purge-harness-state.sh erases them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PYTHON_BIN="${PYTHON_BIN:-python3}"
CONFIG_FILE="${EXPLORER_CONFIG:-$SCRIPT_DIR/config/explorer.$(id -un).json}"
ENV_FILE="$SCRIPT_DIR/.env"
JAIL_SLICE="net-jail.slice"
mkdir -p "$SCRIPT_DIR/logs" "$SCRIPT_DIR/notes" "$SCRIPT_DIR/evidence"

die() { echo "FATAL: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

case "${1:-}" in
  --jail-sh) MODE="jailsh" ;;
  -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
  "") MODE="run" ;;
  *) MODE="run" ;;
esac

[[ -f "$CONFIG_FILE" ]] || die "config not found: $CONFIG_FILE (see config/README.md)"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found (copy .env.example)"
export PATH="$HOME/.opencode/bin:$PATH"
command -v opencode >/dev/null 2>&1 || die "opencode not in PATH"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "python3 required (config + jail assembly)"
command -v systemd-run >/dev/null 2>&1 || warn "systemd-run missing — jail modes unavailable; netns fallback only"

set -a; . "$ENV_FILE"; set +a

# ------------------------------------------------------------ config read ----
cfg() { # cfg <dotted.path> <default>
  "$PYTHON_BIN" - "$CONFIG_FILE" "$1" "${2:-}" <<'PY'
import json, sys
cur = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        print(sys.argv[3]); sys.exit(0)
    cur = cur[part]
print(cur)
PY
}

TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$SCRIPT_DIR/logs/run-$TS.log"
export LOG_FILE

RUN_MODEL=""; RUN_TIMEOUT=""; RUN_STEPS=""
if [[ -n "${EXPLORER_ALLOW_COARSE_LAN:-}" ]]; then COARSE=1; else COARSE="${COARSE:-0}"; fi
export COARSE
if [[ "$MODE" == "run" ]]; then
  TASK_TEXT="${*:-}"
  if [[ -z "$TASK_TEXT" && -z "${TASK_FILE:-}" && ! -t 0 ]]; then
    read -r -d '' TASK_TEXT || true
  fi
  [[ -n "$TASK_TEXT" || -n "${TASK_FILE:-}" ]] || die "no task: pass it as an argument or set TASK_FILE=path"
  [[ -n "$TASK_TEXT" ]] && printf '%s\n' "$TASK_TEXT" > "$SCRIPT_DIR/task.md"
  RUN_MODEL="$(cfg default_agent_model spark/qwen38)"
  RUN_STEPS="${EXPLORER_MAX_STEPS:-$(cfg agents.explorer.steps 80)}"
  [[ -n "$(cfg provider packageName)" ]] || die "config missing provider.packageName"
fi
RUN_TIMEOUT="${EXPLORER_TIMEOUT:-$(cfg settings.timeout_minutes 1440)}"
[[ "$RUN_TIMEOUT" =~ ^[0-9]+$ ]] || die "EXPLORER_TIMEOUT must be whole minutes (got: $RUN_TIMEOUT)"

# Parameters cross the jail boundary via a state file: sudo + systemd-run give
# the scope a clean environment, so exports alone would NOT survive.
SRC_TASK="${TASK_FILE:-$SCRIPT_DIR/task.md}"
[[ -n "${EXPLORER_TARGET:-}" ]] || die ".env must set EXPLORER_TARGET (ssh alias of the target machine)"
if [[ "$MODE" == "jailsh" && ! -f "$SRC_TASK" ]]; then
  SRC_TASK=/dev/null; : > "$SCRIPT_DIR/task.md" 2>/dev/null || SRC_TASK=/dev/null
fi
[[ -f "$SRC_TASK" ]] || die "task file not found: $SRC_TASK"
# TASK.md = task + generated lab environment (authoritative copy used by the run).
RUN_TASK="$SCRIPT_DIR/TASK.md"
{
  cat "$SRC_TASK"
  echo
  echo "---"
  echo "## Lab environment (auto-generated $(date -u '+%F %T UTC'))"
  echo "- SSH target — invoke exactly: \`ssh ${EXPLORER_TARGET}\`"
  echo "- Workspace files you may write: FINDINGS.md and RESULT.md only."
  echo "- The verifier is invoked with the \`task\` tool, agent \"verifier\"."
  echo "- No other network exists; ssh failures to the target mean it is DOWN."
} > "$RUN_TASK"
{
  echo "MODEL='$RUN_MODEL'"
  echo "TIMEOUT_MIN='$RUN_TIMEOUT'"
  echo "MAX_STEPS='$RUN_STEPS'"
  echo "COARSE='$COARSE'"
  echo "TASK_FILE='$RUN_TASK'"
} > "$SCRIPT_DIR/.run-state"
MODEL="$RUN_MODEL"; TIMEOUT_MIN="$RUN_TIMEOUT"; MAX_STEPS="$RUN_STEPS"

# ------------------------------------------------------------------ jail -----
if [[ "$COARSE" == "1" ]]; then
  warn "EXPLORER_ALLOW_COARSE_LAN — whole private space allowed (docs/JAIL.md); internet still denied"
fi
JAIL_PROPS_OUT="$("$PYTHON_BIN" "$SCRIPT_DIR/scripts/jail-props.py" "$CONFIG_FILE")" || die "jail allowlist invalid"
mapfile -t _props <<< "$JAIL_PROPS_OUT"
[[ ${#_props[@]} -gt 0 ]] || die "jail allowlist empty"
# systemd-run takes unit properties ONLY via -p/--property=; as bare
# positionals the first one is mistaken for the command to execute.
JAIL_PROPS=()
for p in "${_props[@]}"; do
  [[ -n "$p" ]] || continue
  JAIL_PROPS+=(-p "$p")
done

if [[ "$MODE" == "run" || "$MODE" == "jailsh" ]]; then
  if [[ -n "${EXPLORER_NO_JAIL:-}" ]]; then
    JAIL=()
    warn "EXPLORER_NO_JAIL — running WITHOUT the network jail!"
  elif [[ -n "${EXPLORER_ALLOW_USER_JAIL:-}" ]]; then
    JAIL=(systemd-run --user --scope --slice="$JAIL_SLICE" "${JAIL_PROPS[@]}")
    warn "user-mode jail — if netcheck fails inside, this systemd silently ignored the IP filters"
  else
    command -v sudo >/dev/null 2>&1 || die "no sudo: required for system-mode jail (dev-only overrides exist; see header)"
    # probe the EXACT sudoers grant (NOPASSWD covers systemd-run only, not e.g. `true`)
    sudo -n /usr/bin/systemd-run --version >/dev/null 2>&1 \
      || die "passwordless sudo for systemd-run required — one-time: sudo scripts/install-jail.sh"
    command -v systemd-run >/dev/null 2>&1 || die "systemd-run missing — use scripts/netns-jail.sh instead"
    JAIL=(sudo systemd-run --scope --slice="$JAIL_SLICE"
          --uid="$(id -u)" --gid="$(id -g)"
          --setenv=HOME="$HOME" --setenv=PATH="$PATH"
          --setenv=USER="$(id -un)" --setenv=LOGNAME="$(id -un)"
          "${JAIL_PROPS[@]}")
  fi
fi

run_inner() {
  if [[ ${#JAIL[@]} -gt 0 ]]; then
    "${JAIL[@]}" bash "$SCRIPT_DIR/scripts/inside-jail.sh" "$MODE"
  else
    bash "$SCRIPT_DIR/scripts/inside-jail.sh" "$MODE"
  fi
}

if [[ "$MODE" == "jailsh" ]]; then
  echo "==> opening interactive shell inside the network jail (netcheck runs first)"
  rc=0; run_inner || rc=$?
  exit "$rc"
fi

echo "==> explorer run $TS | model=$MODEL timeout=${TIMEOUT_MIN}m jail=${#JAIL[@]}"

# ---------------------------------------------------------- commentator ----
# Read-only bystander (scripts/commentate.py + docs/HOW_TO_RUN.md): tails the
# harness DB, narrates episodes to a live web page. Runs OUTSIDE the jail so
# it can reach the model endpoint; it never touches the run itself. Disable
# with EXPLORER_NO_COMMENTATOR=1; port via COMMENTER_PORT (default 8705).
if [[ "${EXPLORER_NO_COMMENTATOR:-0}" != "1" ]]; then
  if [[ -n "${EXPLORER_NO_STATE_SANDBOX:-}" ]]; then
    CM_DB="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"
  else
    CM_DB="$SCRIPT_DIR/.harness-home/xdg-data/opencode/opencode.db"
  fi
  LIVE_DIR="$SCRIPT_DIR/../explorer-live/run-$TS"
  mkdir -p "$LIVE_DIR"
  "$PYTHON_BIN" -u "$SCRIPT_DIR/scripts/commentate.py" --web --db "$CM_DB" \
      --events "$LIVE_DIR/events.jsonl" --outdir "$LIVE_DIR" \
      --port "${COMMENTER_PORT:-8705}" > "$LIVE_DIR/commenter.log" 2>&1 &
  COMMENTATOR_PID=$!
  trap '[[ -n "${COMMENTATOR_PID:-}" ]] && kill "$COMMENTATOR_PID" 2>/dev/null || true' EXIT
  echo "    commentator: http://$(hostname -I 2>/dev/null | cut -d' ' -f1 || echo localhost):${COMMENTER_PORT:-8705}/ (log+events: $LIVE_DIR/)"
fi

rc=0
( run_inner & pid=$!; trap '[[ -n "${LOG_FILE:-}" ]] && touch "$SCRIPT_DIR/ABORT" && kill -TERM "$pid" 2>/dev/null' INT TERM; wait "$pid" ) 2>&1 | tee "$LOG_FILE" || rc=${PIPESTATUS[0]}
[[ -f "$SCRIPT_DIR/ABORT" ]] && rm -f "$SCRIPT_DIR/ABORT"

echo "---- run rc=$rc ----"
tail -n 25 "$SCRIPT_DIR/RESULT.md" 2>/dev/null || warn "no RESULT.md produced"
echo "log: $LOG_FILE"
exit "$rc"

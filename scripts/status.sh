#!/usr/bin/env bash
# status.sh — read-only snapshot: is a run going, what is it doing, how far did
# the last one get. Touches nothing.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

alive() { pgrep -f 'explorer/go[.]sh|[o]pencode run .*--agent explorer' >/dev/null 2>&1; }

if alive; then
  echo "STATE: RUNNING"
  pgrep -af 'explorer/go[.]sh|[o]pencode run .*--agent explorer' | sed 's/^/  pid /'
else
  echo "STATE: not running"
fi
[[ -e RUNNING ]] && echo "  (RUNNING sentinel file present — leftover if STATE says not running)"

# --- newest log: idle time + tail -------------------------------------------
LOG=$(ls -t logs/run-*.log 2>/dev/null | head -1)
if [[ -n "$LOG" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$LOG") ))
  printf '%s\n' "LOG: $LOG  (last write ${age}s ago)"
  # idle heuristic: RUNNING present + no log write for >10min is worth a look
  if alive && (( age > 600 )); then
    echo "  ⚠️ running but log silent for $((age/60))min — could be a long tool call (e.g. a wait/monitor loop), check the tail below"
  fi
  echo "--- last lines ---"
  tail -n 6 "$LOG" | sed 's/^/  /'
  echo "--------------------"
fi

# --- launch exit code of most recent launch (if it ended) --------------------
LOUT=$(ls -t logs/launch-*.out 2>/dev/null | head -1)
if [[ -n "$LOUT" ]]; then
  rc=$(grep -o 'run rc=[0-9-]*' "$LOUT" | tail -1)
  [[ -n "$rc" ]] && echo "LAST LAUNCH: $(basename "$LOUT") → ${rc}"
fi

# --- RESULT.md: sentinel vs real verdict -------------------------------------
if [[ -f RESULT.md ]]; then
  first=$(head -n1 RESULT.md)
  echo "RESULT.md: $first"
  case "$first" in
    *RESULT\ —\ run\ has\ not\ finished*) echo "  (in-flight sentinel — the run overwrites this as it works)" ;;
    *"did not complete cleanly"*)       echo "  (abort sentinel from a stop/kill — NOT an agent verdict)" ;;
  esac
fi

# --- verifier usage from the sandbox DB (best-effort, read-only) -------------
DB=".harness-home/xdg-data/opencode/opencode.db"
if [[ -f "$DB" && -r "$DB" ]]; then
  python3 - "$DB" <<'PY' 2>/dev/null || true
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
try:
    n_msg = db.execute("select count(*) from session_message").fetchone()[0]
    rows = db.execute(
        "select id, parent_id, agent, title, tokens_input+tokens_output, "
        "datetime(time_created/1000,'unixepoch') from session_v2 "
        "order by time_created").fetchall()
    print(f"SESSIONS: {len(rows)} in sandbox DB, {n_msg} messages "
          "(primary + children = verifier consults/subagents)")
    for sid, par, agent, title, tok, tc in rows:
        kind = "primary" if not par else f"child({par[:12]}…)"
        print(f"  {tc}  {kind:<28} agent={agent or '?':<10} {tok or 0:>8} tok  {title or ''}")
except Exception:
    pass
PY
fi

# --- why did it stop? ---------------------------------------------------------
if ! alive; then
  if [[ -f RESULT.md ]] && ! head -n1 RESULT.md | grep -qi 'not finished\|did not complete'; then
    echo "HINT: RESULT.md has a final verdict — the run finished (check its text)."
  elif [[ -n "$LOG" ]] && (( $(date +%s) - $(stat -c %Y "$LOG") > 120 )); then
    echo "HINT: not running, RESULT.md has no verdict — it was stopped/aborted; see the log tail above."
  fi
fi

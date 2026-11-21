#!/usr/bin/env bash
# Erase every trace this exercise left in the machine-GLOBAL OpenCode state.
#
# Since the state sandbox (see inside-jail.sh) landed, harness runs persist
# everything under ././.harness-home/. But early runs (pre-sandbox smoke tests,
# manual probes) wrote real sessions into the shared state of the machine:
#   ~/.local/share/opencode/opencode.db   (sessions, project/worktree rows)
#   ~/.local/share/opencode/snapshot/<pid>, shell/<pid>
#   ~/.local/state/opencode/prompt-history.jsonl (entries mentioning this dir)
#   ~/.local/share/opencode/log/opencode.log (mentions; shared + live)
# Run this AFTER converting to the sandbox so a later, different exercise in
# another directory inherits nothing from this one.
#
#   scripts/purge-harness-state.sh [--dry-run] [--truncate-log] [dir ...]
#
#   --dry-run       show what would be removed, change nothing
#   --truncate-log  also blank the shared opencode.log (it is live-appended;
#                   harmless, but someone may be tailing it)
#   dir ...         override: project dirs considered "this exercise"
#                   (default: this repo + the old ~/explorer-wt clone)
set -euo pipefail

DRY=0; TRUNC=0; DIRS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --truncate-log) TRUNC=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) DIRS+=("$a") ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ ${#DIRS[@]} -gt 0 ]] || DIRS=("$SCRIPT_DIR" "$HOME/explorer-wt")

DATA="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/opencode"
DB="$DATA/opencode.db"
OPENCODE="${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}"
command -v "$OPENCODE" >/dev/null 2>&1 || OPENCODE=opencode
command -v sqlite3 >/dev/null || { echo "FATAL: sqlite3 required" >&2; exit 1; }
[[ -f "$DB" ]] || { echo "no global db at $DB — nothing to purge"; exit 0; }

run() { if (( DRY )); then echo "DRY: $*"; else "$@"; fi; }

# SQL condition matching sessions/rows that belong to the exercise dirs.
COND="0"
for d in "${DIRS[@]}"; do COND="$COND OR directory = '$d' OR directory LIKE '$d/%'"; done

sql() { sqlite3 "$DB" "$1"; }
mapfile -t PIDS < <(
  sql "SELECT project_id FROM session_v2 WHERE $COND
       UNION SELECT project_id FROM worktree WHERE $COND;" )

echo "== exercise dirs: ${DIRS[*]}"
echo "== project ids:   ${PIDS[*]:-none}"

# 1. Sessions via the opencode CLI itself (proper cascade to messages, parts,
#    inbox, jobs, permissions, blobs, events). Root sessions first: the CLI
#    cascade-deletes children, whose ids then 404 — tolerate that, another
#    earlier run may already have removed rows too.
mapfile -t SESSIONS < <(
  sql "SELECT id FROM session_v2 WHERE $COND ORDER BY parent_id IS NOT NULL;")
echo "== sessions:      ${#SESSIONS[@]} in global db"
for s in "${SESSIONS[@]}"; do
  out=$(run "$OPENCODE" session delete "$s" 2>&1) || true
  echo "$out" | grep -v 'not found' | sed 's/^/   /' || true
done

# 2. Leftover db rows the CLI may not have cascaded (verify + clean project
#    identity rows: worktree/project_directory/project).
if (( ! DRY )); then
  for t in session_message session_part session_inbox job instruction_state blob_ref; do
    n=$(sql "SELECT count(*) FROM $t WHERE session_id IN (SELECT id FROM session_v2 WHERE $COND);" 2>/dev/null || echo 0)
    [[ "$n" != 0 ]] && echo "WARN: $n stale rows left in $t (schema changed?)"
  done
fi
PIDLIST="''"; for p in "${PIDS[@]}"; do PIDLIST="$PIDLIST,'$p'"; done
run sqlite3 "$DB" "DELETE FROM worktree WHERE $COND;
DELETE FROM project_directory WHERE project_id IN ($PIDLIST);
DELETE FROM project WHERE id IN ($PIDLIST)
  AND id NOT IN (SELECT DISTINCT project_id FROM session_v2);"

# 3. Per-project working dirs (git snapshots + shell session files).
for p in "${PIDS[@]}"; do
  for sub in snapshot shell; do
    [[ -e "$DATA/$sub/$p" ]] && { echo "rm -rf $DATA/$sub/$p"; run rm -rf "$DATA/$sub/$p"; }
  done
done

# 4. Prompt-history entries that mention the exercise paths. Interactive users
#    (and this setup chat) type the "~/…" short form, so match both variants.
PH="$STATE/prompt-history.jsonl"
PATTERNS=()
for d in "${DIRS[@]}"; do PATTERNS+=("$d" "${d/#$HOME/\~}"); done
if [[ -f "$PH" ]]; then
  hit=0
  for d in "${PATTERNS[@]}"; do grep -qF "$d" "$PH" && hit=1; done
  if (( hit )); then
    echo "filtering $PH (entries mentioning exercise dirs)"
    if (( DRY )); then grep -Fn "${PATTERNS[0]}" "$PH" || true
    else
      TMP="$(mktemp)"; : > "$TMP"
      while IFS= read -r line; do
        keep=1
        for d in "${PATTERNS[@]}"; do [[ "$line" == *"$d"* ]] && keep=0; done
        (( keep )) && printf '%s\n' "$line"
      done < "$PH" > "$TMP"
      mv "$TMP" "$PH"
    fi
  fi
fi

# 5. Legacy file-based storage (v1) — any file mentioning the exercise paths.
if [[ -d "$DATA/storage" ]]; then
  GREP_EXPRS=(); for d in "${DIRS[@]}"; do GREP_EXPRS+=(-e "$d"); done
  while IFS= read -r f; do echo "rm $f"; run rm -f "$f"; done < <(grep -rlF "${GREP_EXPRS[@]}" "$DATA/storage" 2>/dev/null || true)
fi

# 6. Shared log — report always, blank only on request.
LOG="$DATA/log/opencode.log"
if [[ -f "$LOG" ]]; then
  mentions=$(grep -cF "${DIRS[0]}" "$LOG" 2>/dev/null || true)
  echo "log mentions of exercise dir in $LOG: ${mentions:-0}"
  if (( TRUNC )); then echo "truncating $LOG"; run truncate -s 0 "$LOG";
  else echo "(pass --truncate-log to blank it; shared with running sessions)"; fi
fi

# 7. State-file scan (kv/model/frecency): read-only awareness.
for f in kv.json model.json frecency.jsonl; do
  p="$STATE/$f"
  [[ -f "$p" ]] && for d in "${DIRS[@]}"; do
    grep -qF "$d" "$p" && echo "NOTE: $p still mentions $d"
  done
done

echo "== verification:"
echo "   sessions left:  $(sql "SELECT count(*) FROM session_v2 WHERE $COND;")"
echo "   worktrees left: $(sql "SELECT count(*) FROM worktree  WHERE $COND;")"
echo "done."

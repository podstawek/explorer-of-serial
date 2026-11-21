#!/usr/bin/env bash
# clean-slate.sh — archive EVERYTHING from every past run OUTSIDE the project
# tree, leaving a pristine working copy: the next run can find nothing about
# previous runs anywhere in the repo (agent sandbox DB, logs, evidence, notes
# all gone from the tree).
#
#   scripts/clean-slate.sh              stop + archive everything from the tree
#   scripts/clean-slate.sh --wipe-pi    ... and clear /home/explorer on the Pi
#   scripts/clean-slate.sh --start      ... then pre-flight + launch a fresh run
#
# Destination: ../explorer-archive/run-<timestamp>/ (override:
# CLEAN_SLATE_ARCHIVE=DIR). Structure: the current run's files at the top
# (FINDINGS/RESULT/TASK/logs/.run-state/harness-home — reset.sh's layout) and
# everything *older* that was still lying around in logs/ and evidence/ under
# history/. Delegates to scripts/reset.sh (single source for stop/wipe/
# pre-flight guards) — never duplicates them here.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
TS=$(date +%Y%m%d-%H%M%S)
ARCHIVE="${CLEAN_SLATE_ARCHIVE:-../explorer-archive/run-$TS}"

WIPE_PI=0; START=0
for a in "$@"; do
  case "$a" in
    --wipe-pi) WIPE_PI=1 ;;
    --start)   START=1 ;;
    *) echo "unknown flag: $a"; exit 2 ;;
  esac
done

echo "== clean slate: archiving to $ARCHIVE =="

# 1) stop the run (if any) + move current FINDINGS/RESULT/TASK/logs/
#    .run-state/.harness-home straight out-of-tree, stub FINDINGS.md.
RESET_ARGS=()
[[ "$WIPE_PI" == 1 ]] && RESET_ARGS+=(--wipe-pi)
RESET_ARCHIVE="$ARCHIVE" scripts/reset.sh ${RESET_ARGS[@]+"${RESET_ARGS[@]}"} || exit $?

# 2) sweep the *older* leftovers still sitting in the tree into the same
#    archive under history/ (previous aborted-* archives, smoke runs,
#    evidence/ from any run).
shopt -s nullglob
moved=0
mkdir -p "$ARCHIVE/history"
for f in logs/* evidence; do
  mv -- "$f" "$ARCHIVE/history/" 2>/dev/null && moved=1
done
shopt -u nullglob
[[ "$moved" == 1 ]] && echo "  swept older leftovers into $ARCHIVE/history/"
mkdir -p logs evidence

if [[ "${START}" == 1 ]]; then
  # 3) fresh launch: pre-flight gate only — must NOT re-archive (the FINDINGS
  #    stub created above is what the new run starts from).
  echo
  RESET_NO_ARCHIVE=1 scripts/reset.sh --start
else
  echo
  echo "clean slate ready. Start with:  TASK_FILE=task.md ./go.sh"
  echo "                         or:     scripts/clean-slate.sh --start"
fi

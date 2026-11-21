#!/usr/bin/env bash
# pause.sh — pause the current run: stop the processes, KEEP all state where it
# is (nothing archived, nothing wiped). Leaves a visible marker in FINDINGS.md.
#
#   scripts/pause.sh
#
# Resume later with a normal fresh launch — the new agent session re-reads
# FINDINGS.md (its memory across compactions/pauses) and continues from the
# open threads:
#   TASK_FILE=task.md ./go.sh
#
# Consequence to know: stopping writes an `# RESULT: INCOMPLETE (...)` sentinel
# inside RESULT.md (inside-jail's EXIT trap). It is an artifact of pausing,
# not a verdict — the resumed run overwrites RESULT.md anyway.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

scripts/stop.sh || exit $?

{
  echo
  echo "> ⏸️ **PAUSED by operator $(date -u '+%F %T UTC'). Nothing was reset."
  echo "> This is NOT a verdict and the notes below are mid-flight."
  echo "> Resume = start a fresh run (new session, same memory): \`TASK_FILE=task.md ./go.sh\`"
  echo
} >> FINDINGS.md

echo
echo "paused. FINDINGS.md/evidence/ left exactly as they were."
echo "resume:  TASK_FILE=task.md ./go.sh"

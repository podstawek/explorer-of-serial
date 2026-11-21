# EXPLORER harness — operating protocol

You are inside a sealed offline lab. Two models cooperate with no human:
the **explorer** (you, primary) and the **verifier** (subagent, invoked via the
`task` tool). This file is the shared contract — obey it over your system prompt.

## 0. Hard rules
- Zero human in the loop. NEVER ask questions; no clarifications exist.
- The internet is OFF by construction (jail + deny-rules). Network failures are
  expected; never try to work around them, treat them as facts.
- All knowledge about the TARGET machine must come from live `ssh` commands run
  in THIS session — never from memory, training data, or invention.
- Read-only on the target (commands like `cat/ls/ps/ss/uname/df/stat`). No
  writes, installs, service changes — unless TASK.md explicitly grants them.
- On the TARGET stay inside `/home/explorer` as your only USER area: never
  read, list, glob or `cat` anything under another user's home directory
  (any `/home/<other>`, incl. their dot-files and `~/.ssh`) — even "just
  looking" is a rule violation and poisoned evidence (someone else's archive,
  not your finding). No `find /` or `grep -r /` sweeps that crawl user homes;
  scope searches to your own home and to system paths (`/dev`, `/sys`,
  `/proc`, `/usr`) only.
- Never touch this workspace (files here) beyond FINDINGS.md, RESULT.md and
  evidence/. Scratch files (probe scripts, teed logs, temp dumps) go in
  `/tmp/explorer-run/` ONLY — writes elsewhere get permission-denied and each
  denial is a wasted step in a headless run.

## 1. Files
- `TASK.md` — your mission. The ONLY source of what "done" means.
- `FINDINGS.md` — your working notes + draft (evidence log: command → output
  excerpts → what you concluded from it). Update as you go; it persists your
  context across long sessions.
- `RESULT.md` — the deliverable. Written when (and only when) verifier-approved.

## 2. Loop (budget: whole run has a hard wall-clock cap and many hundreds of steps)
1. Read TASK.md. List the concrete question(s) it asks.
2. Explore the target over ssh in small steps (`ssh <target> '<cmd>'`, quoting
   carefully — your shell's quoting, not the remote's, applies first). Prefer
   read-only commands that gather several facts at once.
3. Append raw evidence to FINDINGS.md as you go (command + trimmed output).
4. Draft answers in FINDINGS.md tied to evidence.
5. Consult the verifier ADVISORYLY during exploration — see §2.2. These
   consults do NOT count against the final gate.
6. FINAL GATE (adversarial), HARD BUDGET — 3 rounds TOTAL (initial call + at
   most 2 re-submits):
   a. SUBMISSION PACKET = FILE-POINTER, never a pasted draft:
      1) one-paragraph task restatement + what the draft claims;
      2) the ABSOLUTE PATH of the current candidate RESULT.md plus its
         integrity lines exactly as printed by `ls -l <path>` and
         `sha256sum <path>`;
      3) absolute paths of every evidence file the claims rest on;
      4) what changed since the previous verdict (round 2+ only).
      BEFORE every submission run the canonical citation auditor
      (`python3 scripts/cite_audit.py` — it exits non-zero on unresolved
      refs) and paste its one-line verdict into the packet. Do not
      hand-roll a different auditor; extend that script.
      The verifier's FIRST action is to read the draft at that path, and it
      grades what the FILE says. NOBODY ever echoes the draft back: do not
      copy RESULT.md into the submission — whole, partial, or as an
      "appended full text". Inline draft echoes have killed verifier
      sessions (output cap → compaction → dead verdict). Quotation budget:
      excerpts of ≤5 lines, only when the argument needs one.
       ONE-SHOT GRADING: the verifier slot is ~32k tokens and its context is
       hostile: auto-compaction near ~16-17k (run 4: verdicts from a SUMMARY),
       and SILENT tool-output eviction on any second tool call after the draft
       read (run 5: honest "no readable draft path" after a successful read).
       The only reliable contract: read the draft once, verdict in the very
       next turn, ZERO other tool calls. So every packet ENDS with
       this instruction line verbatim:
       `GRADE MODE: one-shot — read the draft once, then verdict immediately; no other tool calls.`
       `SCOPE: the draft status header line and the Verification section are gate metadata — never grade them.`
       Expect no help from the verifier beyond that one pass: if a round
       returns NOT SCORABLE/VOID twice, finish per (e)/(f) rather than burn
       rounds on a flaky channel.
   b. APPROVED → edit the result file's header line to `# RESULT: COMPLETE`
      (keep all content), stop.
   c. REJECTED → fix ONLY the rejected points IN THE FILE, re-submit (rounds
      2, 3) in the same packet format with fresh integrity lines.
   d. NOT SCORABLE: if a packet is malformed (draft path missing or
      unreadable, or cited evidence neither on disk nor quoted), the verifier
      may answer `VERDICT: NOT SCORABLE` instead of a content verdict. Fixing
      the packet and re-submitting then costs NO round — but this grace
      exists once per gate; every procedural miss after it burns a round.
      VOID replies: a verifier response with NO verbatim `VERDICT:` line is
      VOID — a dead session, not a verdict: it burns no round and no grace;
      re-submit once, and after 2 consecutive voids treat the verifier as
      unreachable (f).
   e. After the 3rd verdict: a 4th rewrite is FORBIDDEN. Ship your best
      version NOW as `# RESULT: INCOMPLETE` with a one-line disposition per
      open issue (accepted-and-fixed / disputed-with-reason / irreducible),
      and record the round count in the Verification section.
   f. Verifier unreachable at the gate: retry once, then ship
      `# RESULT: INCOMPLETE` stating plainly "verifier unreachable — final
      verification did not occur". Never claim or imply approval you did not
      get.
   The verifier may veto CLAIMS; it never orders or forbids experiments.
   A verdict of INCOMPLETE backed by evidence beats an unbounded loop.

## 2.2 Advisory consults (cheap — do NOT skip them)
A mid-run check-in costs minutes; a final-gate rejection costs hours. Consult
the verifier (tool `task`, agent `verifier`) at these triggers, ≤2 short
exchange rounds each:
- the moment you form your FIRST hypothesis about what the target
  device/protocol/interface is — test your reasoning while alternatives are
  still cheap to explore;
- whenever you notice nothing new has landed in FINDINGS.md for ~45 minutes —
  before picking your next experiment, ask "what am I probably not seeing?";
- BEFORE any irreversible or state-changing act on the target (firmware
  writes, flashing, anything a power-cycle may not undo);
- right after a compaction, before any big decision (§2.5).
Keep consults cheap: the verifier sees ONLY your brief, so include raw hex /
verbatim transcript excerpts (trimmed to the relevant lines), ranked candidate
hypotheses, and concrete next-experiment options. Ask targeted questions — do
not paste your whole notebook.

## 2.5 Long-run discipline (this run may last many hours)
- Your context window will be compacted while you work — that is normal and it
  is NOT a reason to restart or finish early. Your durable memory is on disk:
  **FINDINGS.md is your brain between compactions.** Keep it current after every
  significant probe: what you tested, the exact command, the trimmed output, and
  the conclusion.
- After a compaction (or whenever you feel unsure where you left off): read
  AGENTS.md, then FINDINGS.md top-to-bottom, then `ls evidence/ 2>/dev/null`,
  and continue from the open threads — never start the investigation over
  from zero. Re-state in FINDINGS.md, with evidence refs, what you now
  believe CONFIRMED vs HYPOTHESIS.
- NEVER re-run a write/irreversible experiment whose completion you cannot
  confirm from FINDINGS.md — re-running it can destroy the subject (a run
  that "verified" a memory deposit by re-sending the bytes may brick the
  only device). Re-check with read-only observation instead.
- Maintain a `## TODO` section at the top of FINDINGS.md: the open hypotheses
  and next concrete probes. Update it whenever you learn something. It is your
  resume point.
- A long investigation produces MANY probes; do not rush to conclude just
  because much has happened. The wall-clock cap (12h default) is the only
  deadline. Do not self-impose earlier deadlines, and do not end the session
  with RESULT.md unwritten unless you have actually run the final verifier
  round (or hit the cap).

## 3. RESULT.md format
```
# RESULT: COMPLETE | INCOMPLETE
## Task
<one-paragraph restatement>
## Findings
<the answers; every claim: statement + `command:` + quoted output>
## Open questions
<things you could not determine, and why — this is a strength, not a failure>
## Verification
<verifier rounds run, verdict, biggest issue it caught and how you fixed it>
```
Use `COMPLETE` ONLY on verifier `VERDICT: APPROVED` (§2.6b). Use `INCOMPLETE`
whenever you did not get approval or did not answer the core question with
evidence. Honest incompleteness >> fabricated completeness.

## 4. SSH etiquette in this lab
- Target host and its user are fixed; use plain `ssh <host> '<cmd>'` — the
  harness pre-resolves everything; the host key is trusted.
- Long-running remote commands hang the whole run: keep each to quick commands;
  bound risky ones with `timeout 15 ...` on the remote side.
- Binary/large outputs (e.g. `cat` a database) are useless to you: summarize or
  head them (`... | head -50`).
- If ssh says "Connection ... denied/refused": the target is offline — note it,
  retry once later, do NOT retry in a loop.

## 5. Budget discipline
You have a fixed wall-clock cap and a generous step budget. Anti-stall rule: if
10 consecutive steps produce nothing new (repeated identical commands, re-reading
the same file, no new evidence in FINDINGS.md), pick the most informative
UNtried probe from your TODO list and run it. If TODO is empty and the core
question is answered with evidence, go straight to the verifier round.
Halfway through the wall-clock budget (check timestamps in your notes) you
should have a draft in FINDINGS.md — extras come after the core question.

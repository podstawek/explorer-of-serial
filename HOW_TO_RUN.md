# How to run — lifecycle commands

Operator commands for a run of the explorer agent. All paths relative to the
project root.

| action | command | one-liner |
|---|---|---|
| **start** | `TASK_FILE=task.md ./go.sh` | plain launch |
| **start (safe)** | `scripts/reset.sh --start` | pre-flight gate + launch |
| **status** | `scripts/status.sh` | read-only: running?, progress, last verdict |
| **stop** | `scripts/stop.sh` | kill the run, touch no files |
| **pause** | `scripts/pause.sh` | stop + marker in FINDINGS.md, resume later |
| **clean slate** | `scripts/clean-slate.sh --wipe-pi` | archive everything out-of-tree, fresh stub |

## start

```
cd ~/your/project/dir
TASK_FILE=task.md ./go.sh            # plain launch (logs to logs/run-<ts>.log)
```

Or with a **pre-flight gate**: `scripts/reset.sh --start` refuses to launch
(printing `== NOT started ==`, exit 1 — no bypass) unless:

- `ssh pi` works with key auth, and
- both model endpoints answer 200 on `/models` (solver on spark, verifier on
  thorgal).

Without those, a run just flails and wastes a 12h window. Note this is
reset-then-start: it stops any running run and archives its state to
`../explorer-archive/aborted-<ts>/` (outside the tree, so a
future run can never discover it). For a gated launch onto a freshly cleaned tree,
use `clean-slate.sh --start` below.

`go.sh` regenerates `TASK.md` from `task.md` (plus a lab-environment section)
on every launch — edit `task.md`, never `TASK.md`.

## status — read-only

```
scripts/status.sh
```

Prints: whether a run is alive (pids), the `RUNNING` sentinel, the current run
log with its idle age and last lines (flags >10 min of silence while running —
usually just a long monitor loop), the exit code of the last launch
(`run rc=`), the first line of `RESULT.md` while **distinguishing real verdicts
from in-flight/abort sentinels**, and the session roster from the sandbox DB —
primary explorer session plus one child per verifier consultation. Touches
nothing.

## stop

```
scripts/stop.sh
```

Kills only the run's processes (launcher, `opencode run`, jail server, stray
`ssh pi` children; TERM → 30s grace → KILL). Sends nothing to the Pi, deletes
nothing; idempotent. The grace period exists so inside-jail's EXIT trap can
write the honest `# RESULT: INCOMPLETE (did not complete cleanly)` sentinel.
That sentinel is an artifact of stopping — not a verdict.

Caveat: this stops processes **on our side, and on the Pi only those connected
through our ssh**. A run that `setsid`'d a helper directly on the Pi survives;
`clean-slate.sh --wipe-pi` clears its files, and after any doubt check the Pi
with `ssh pi 'pgrep -u explorer -a python3'`.

## pause

```
scripts/pause.sh
```

stop + a `⏸️ PAUSED` marker appended to FINDINGS.md. Nothing is reset or
archived. Resume = just start a fresh run (`TASK_FILE=task.md ./go.sh`): the
new agent session re-reads FINDINGS.md — its durable memory across compactions
*and* pauses — and continues from the open threads. There is no process-level
"attach"; FINDINGS.md is the state.

## clean slate

```
scripts/clean-slate.sh              # archive current+old run state out-of-tree
scripts/clean-slate.sh --wipe-pi    # ... and clear /home/explorer on the Pi
scripts/clean-slate.sh --wipe-pi --start   # ... then pre-flight + fresh launch
```

Moves everything from every run **outside the project tree** to
`../explorer-archive/run-<timestamp>/`:

```
run-<ts>/            FINDINGS.md, RESULT.md, TASK.md, run logs,
                     run-state/, harness-home/   (current run — reset.sh layout)
run-<ts>/history/    older leftovers: previous aborted-* archives,
                     smoke runs, evidence/
```

…leaves a pristine working copy: FINDINGS.md reset to `(run not started yet)`,
empty `logs/` and `evidence/`, and an **empty `.harness-home/`** — so the next
run's agent has no session DB, logs, or notes of any previous run anywhere in
the repo. `--wipe-pi` additionally clears `/home/explorer` on the Pi (never
`.ssh` — that holds the key we log in with). Override the destination with
`CLEAN_SLATE_ARCHIVE=DIR`. Permanent erase of an archive is manual:
`rm -rf` the archive dir.

Delegates stopping, archiving, Pi-wipe and the `--start` pre-flight to
`scripts/reset.sh` — the single source for those guardrails (its tunables:
`RESET_ARCHIVE=DIR`, `RESET_NO_ARCHIVE=1`).

## commentate — live narration (the Commenter)

A third pair of eyes: it opens the same harness session DB `status.sh` peeks
at — strictly read-only, in a separate process — digests each episode of the
run (tool calls and results, consults, verdicts, gate passes, compactions),
and has a small OpenAI-compatible model narrate the whole thing in prose. The
Commenter can never influence a run: it reads the DB only, its own output
goes out-of-tree (default `../explorer-live/`, `--outdir` to move it), and it
starts no services and controls no processes.

```
scripts/commentate.py --db              # narrate the live run in a spare terminal
scripts/commentate.py --web --db        # narrate to a live webpage (port 8705)
scripts/commentate.py --replay FILE     # re-run saved commentary (--speed N to hurry)
scripts/commentate.py --replay-db DB    # one chronological pass over an archived run DB
scripts/commentate.py --runs            # runs-library page: every run, replay buttons
```

The live page shows narration as chat bubbles under one big elapsed-time clock
plus two side rails — which files the agents are adding/changing/reading as
they work, and "Discoveries": the interesting data clips (hex dumps, protocol
hits, code fragments) the run uncovers — with a footer indexing every file
involved. Point `COMMENTER_URL` / `COMMENTER_MODEL` at any OpenAI-compatible
endpoint serving a small model; a slow narrator never stalls the page (events
keep streaming, narration catches up) and a dead one leaves the event feed
running. `Ctrl-C` to stop. Since it only reads the DB, start it any time —
before, during, or after `./go.sh run` — and leave it open across the whole
run. In practice you never start it by hand: every `./go.sh` run launches
`--web --db` itself, prints the page URL at the top of the log, and stops it
when the run ends; each run's commentary, event archive and narrator log land
in `../explorer-live/run-<TS>/`. Opt out with `EXPLORER_NO_COMMENTATOR=1`,
move the port with `COMMENTER_PORT=…`. The page (and the runs library) bind
`0.0.0.0` by default, so any machine on the LAN can open the printed
`http://<this-machine's IP>:8705/` URL; pass `--bind 127.0.0.1` to lock it
back to the local machine.

`--runs` serves a small library page instead: every run that left traces —
`../explorer-archive/*`, `../explorer-live/*`, and the current tree — listed
newest-first with its status badge (complete / incomplete / aborted), task,
duration and which sources survived. Each row's ▶ replay button spawns its own
detached page server on the next free port: runs with `commentary.jsonl` replay
instantly (no model calls); runs with only the session DB get re-narrated live
at the speed picked in the header. Running replays are reused (registry in
`../explorer-live/.replay-servers.json`), and each one logs to
`../explorer-live/replays/<run>.log`. A run that is happening *right now*
appears at the top as soon as `go.sh`'s Commenter starts, with a pulsing
● live badge and a **watch live** button — the run registers itself by writing
`live.json` (port + pid) into its `../explorer-live/run-<TS>/` directory; the
page refreshes every 15 s, so new runs, statuses and finished replays show up
without restarting the library.

## Choosing

- Curious what's happening → always `status.sh`; it is read-only.
- Watching a live run unfold in prose → open the page URL `./go.sh` prints;
  `scripts/commentate.py --db` (or `--web --db`) still works in a second
  terminal for extra viewers or old DBs.
- Stop for the night, continue the *investigation* later → `pause.sh`.
- Abandon this run's conclusions, but keep the evidence dir → `stop.sh`
  (archives nothing; archive later manually or via reset.sh).
- Next run must see a fresh world (new device, new task, or pollution-free
  rerun) → `clean-slate.sh --wipe-pi [--start]`.

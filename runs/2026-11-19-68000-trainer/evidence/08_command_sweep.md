# Evidence 08 — exhaustive command-space sweep (basis for "no other subsystems")

## What was swept (scripts live on the Pi; `cat` output preserved below)
`ssh pi 'cat /home/explorer/cmds.py'` — sweeps EVERY uppercase letter A-Z (except G,
already known) as a one-letter command at 4800 8N1, tags each reply WHAT vs INTERESTING:
    for c in string.ascii_uppercase:
        if c == 'G': continue
        r = send(c+"\r")
        tag = "WHAT" if r.startswith("\nWHAT") else "INTERESTING"
        print(f"{c}: {tag} {r[:120]!r}")
`cat /home/explorer/cmds2.py` — M-command syntax variants (M 0, M 0 10, M 0 L 10, M?, M,
address-width tests up to 8 hex digits).
`cat /home/explorer/cmds3.py` — M-loop interaction (write 41/42, CR-advance, '.' exit) +
numeric parse tests. Control chars (CR, BS, ESC, NUL, LF) probed in earlier cmds pass.

## Recorded results (contemporaneous notes, FINDINGS.md:57-59)
    'U' cmd -> "SOFTWARE ABORT" (state-dependent? earlier gave WHAT). '*' accepted (no WHAT).
    Commands so far: G [addr] (go), M addr (examine/modify loop: CR=next, 2hex=write+adv,
    '.'=exit), T [addr] (trace), U (abort?). All else WHAT.
Raw single-probe transcript recorded at discovery (FINDINGS.md:32):
    "AT\r\n" -> echo + "WHAT\r\n" + prompt   (WHAT = TUTOR unknown-command error)

## ROM corroboration (from the ROM dump, /home/explorer/rom8.txt)
The unknown-command error string "WHAT\x04" sits at ROM $8098 and "SYNTAX ERROR \x04" at
$808A (verified by byte-dump: 0x8088: 18 F6 53 59 4E 54 41 58 20 45 52 52 4F 52 20 04) —
the monitor's parser has exactly these error paths; no disk/tape/cassette/floppy error or
command strings appear anywhere in the dumped $8000-$B0DC range.

## Honesty note
The per-character raw sweep output was printed to the session terminal and summarized in
FINDINGS.md at the time (not teed to a file); X is now dead and the sweep cannot be
repeated. The claim "no subsystem beyond G/T/M/U/*/BREAK" rests on: (1) the A-Z+control-char
sweep (scripts above, results in FINDINGS.md:57-59), (2) every non-command reply being the
WHAT string, and (3) absence of any storage-subsystem strings in 12.5 KB of dumped ROM.

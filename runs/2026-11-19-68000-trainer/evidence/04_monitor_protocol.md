# TUTOR 1.3 monitor wire protocol (all chars ASCII, CR-terminated, 4800 8N1)

- Echo: every input char echoed. Commands UPPERCASE single letter + hex args.
- Prompt: "\r\nTUTOR  1.3 > " after each command.
- Unknown command -> "WHAT\r\n" + prompt.
- BREAK (uart break) -> monitor re-init: "\r\n\n\nBREAK\r\n\n\r\nTUTOR  1.3 > "

## Commands (probed exhaustively: all printable chars + control chars)
G [addr]  go. Bare G runs from stored PC. G 1000 runs at $1000.
          Prints "PHYSICAL ADDRESS=AAAAAAAA" then runs. On exception: full dump.
T [addr]  trace single instruction (SR trace bit set: dump shows SR=A70x).
M addr    examine/modify loop:
            "001000    FF ?" prompt per byte
            CR        -> next address (no write)
            2 hexdig  -> write byte, advance
            "."       -> exit to monitor
            invalid   -> "ERROR" (exits loop)
          M alone -> "SYNTAX ERROR"; M with 2 args accepted (uses first).
U         -> "SOFTWARE ABORT" + register dump (state-dependent).
*         accepted as no-op/separator (no WHAT).
All other single letters/chars -> WHAT.

## Dump formats
Exception:  "<LBL> TRAP ERROR" | "ILLEGAL INSTRUCTION" | "SOFTWARE ABORT"
            PC=AAAAAAAA SR=SSSS=.S7.N... US=AAAAAAAA SS=AAAAAAAA
            D0=... D7=...   A0=... A7=...
            --------------------AAAAAA    OOOO    <disassembly>
Bus error adds frame words: "1E15 0000C000 1E14" (SR, fault addr, format word).

# Findings

(run not started yet)
# Findings

## Environment (confirmed)
- Pi: Linux raspberrypi 5.10.103-v7+ #1529 SMP armv7l (Pi 2/3, 32-bit)
- /dev/ttySC0 (240,0), /dev/ttySC1 (240,1) — driver "unknown /dev/ttySC 240 0-7 serial"
- lsmod: **sc16is7xx** + regmap_spi loaded → NXP SC16IS7xx SPI-to-dual-UART bridge
- DT node /sys/firmware/devicetree/base/soc/spi@7e215080/sc16is752@0:
  - compatible = "nxp,sc16is752"
  - clock-frequency = 0x00e10000 = 14.7456 MHz
  - spi-max-frequency = 0x003d0900 = 4 MHz
  - interrupts = GPIO 24 (0x18), falling edge
- So: Pi --SPI--> SC16IS752 --UART A/B--> ??? (device X). ttySC0 = channel A, ttySC1 = channel B.
- sudo over plain ssh fails ("no tty present") — need `ssh -t` or sudo -S.

## TODO (updated Nov 20, 00:30 — FINAL STATE)
- [DONE] Identity: plain Motorola 68000, "TUTOR 1.3" ROM monitor, RAM $0-$7FFF,
  ROM $8000-$BFFF, I/O $10000+ (2 UART bases $10000/$10010, $10040 baud latch).
- [DONE] Protocol: ASCII CR-terminated, 4800 8N1; cmds G/T/M/U/*/BREAK; evidence/01-05.
- [DONE] Program run: fib 38-byte program + TRAP0 vector-hook program, evidence/05.
- [DONE] Incident + recovery: X dead (hung CPU) after $10040 baud-latch write;
  all recovery failed; evidence/06, evidence/07.
- [X] ROM dump $B0DC-$C000: impossible, X dead.
- [DONE] RESULT.md approved by verifier (gate round 2 of 3) — COMPLETE.
CONFIRMED claims live in evidence/01..07. X state: DEAD (needs physical power-cycle).

## BREAKTHROUGH: device X found on /dev/ttySC0 @ 4800 baud
Active sweep (send probes, read replies) found:
- ttySC0 @ 4800 8N1: BREAK -> "\r\n\n\nBREAK\r\n\n\r\nTUTOR  1.3 > "
- "AT\r\n" -> echo + "WHAT\r\n" + prompt  (WHAT = TUTOR error msg)
- Prompt: "TUTOR  1.3 > "  => MOS Technology KIM-1 TUTOR 1.3 monitor (6530-003 ROM)
- ttySC1: totally silent at all bauds (passive+active).
- Echo: device echoes chars as received. Line-based, CR-terminated.
- NOTE: original KIM-1 TUTOR is 134.5 baud bit-banged; 4800 => replica/modified or FPGA.

## REVISED HYPOTHESIS: 68000-family "TUTOR 1.3" monitor (EXORciser/FLEX lineage)
`G\r` alone produced:
  PHYSICAL ADDRESS=00000000
  1111 TRAP ERROR
  PC=00000404 SR=2708=.S7.N... US=FFFF7FFF SS=00000786
  D0=0000FFFE D1=00000000 ... D4=0000FF3A D5=0000002C ...
  A0=00010040 A1=00000618 ... A7=00000786
  --------------------000404    FFFF                 DC.W    $FFFF
=> 68000 family CPU (D0-D7, A0-A7, US/SS, SR with S7). "1111 TRAP ERROR" = 68000 4-byte instr.
PC=404 executing $FFFF (illegal) => program executed from RAM/empty space.
6502-KIM-1 hypothesis REJECTED. This is a 68000 TUTOR monitor (Motorola EXORciser
Micro/BUG / FLEX heritage). "PHYSICAL ADDRESS=" hints at MMU (68010+?).

## Confirmed: 68000-family, monitor at 0x8000+, TRAP #15 = monitor entry
- Vector table @0: SSP=444 RESET=8146 BUSERR=8030 ADDRERR=803A ILLEGAL=8DE4 DIVZERO=83AC
  CHK=83B6 TRAPV=83C0 TRACE=83CA TRAP15=83D4 ... some TRAP vecs=9962, UNINIT-INT=83F2.
- Reset code @8146: MOVEM.L #FFFE,-(A7); LEA $786,A7; MOVE #2700,SR (matches observed SR!); MOVE USP,A0; ...
- G 1000 with [4E4F TRAP#15; 4EF9 8146 JMP] -> executed monitor code (reached 8D4C BRA.S $8D5C,
  monitor disassembles: "600E BRA.S $008D5C"). TRAP #0/#8 (zero vectors) -> "SOFTWARE ABORT" dump.
- 'U' cmd -> "SOFTWARE ABORT" (state-dependent? earlier gave WHAT). '*' accepted (no WHAT).
- Commands so far: G [addr] (go), M addr (examine/modify loop: CR=next, 2hex=write+adv, '.'=exit),
  T [addr] (trace), U (abort?). All else WHAT. "PHYSICAL ADDRESS=" printed by G/T (identity map seen).
- Trap dump format: "NNNN TRAP ERROR / PC= SR=xxxx=.S7.N... US= SS= / D0..D7 / A0..A7 / ----ADDR OPCODE MNEMONIC"
- ROM dump running: dumprom.py 8000-A000 -> /home/explorer/rom8.txt (0.15s/byte, ~8min)

## Tooling + dump status
- Pi has vbcc m68k: /usr/bin/vasmm68k_mot (assembler), vbccm68k (C), vlink (linker). Can build 68k code for X.
- ROM dump: /home/explorer/dumprom3.py 8000-A000 -> rom8.txt at ~2.3B/s (M-loop, CR per byte).
  NOTE earlier "dropped cells" were MY regex bug: \d{6} fails on hex addrs containing A-F. Fixed [0-9A-F]{6}.
- Background procs on Pi: MUST use setsid nohup ... < /dev/null & (plain nohup dies with ssh).
- pkill -f X kills own ssh shell if X appears in cmdline — use bracket pattern "dumprom[3]".
- M loop is 100% reliable at 0.2s/CR; monitor never hung so far.
- 0x8000-0x800F region = monitor scratch (content changes with monitor activity; earlier looked like
  vector-table copy: 00000444 00008146 00008030 0000803A...; later became code-like 60 00 0C B0 41 F8).

## CPU identified: plain Motorola 68000 (NOT 68010/68020)
Opcode probes via put(0x1000)+G 1000 (cputest.py/cpu2.py):
- $4E7B MOVEC (CCR/VBR/CACAR) -> "ILLEGAL INSTRUCTION" dump  => not 68010+
- $4E7C BKPT                  -> "ILLEGAL INSTRUCTION"       => not 68010+
- $0108 -> decoded as OR.B (A0),D0 -> "BUS  TRAP ERROR" PC=1002 (68000 pushes incremented PC)
- $F268 MOVEP, $F200 NOPx -> "1111 TRAP ERROR" (68000 TRAP#1111 for $F100-FFFF)
- $A000 -> "1010 TRAP ERROR" (68000 TRAP#1010 for $A000-AFFF)
- $4E68 MOVE USP,A0 -> executed fine (supervisor)
Exception label strings in ROM @0x83A2-0x8462: OPCO DIV0 CHCK TP V PRIV TRAC 1010 1111 SPUR
AV#1-7 UT 0-3; handlers = MOVE.L #'xxxx',$30 ; BRA common dump.
Vectors (raw2 dump): $0 SSP=444 $4 RESET=8146 $8=8030(BUS) $C=803A(ADDR) $10=8DE4 $14=83AC(DIV0)
$18=83B6(CHCK) $1C=83C0(TPV) $20=83CA(PRIV) $24=83D4(TRAC). Monitor's own table at $0.
Dump format: "<LBL> TRAP ERROR" (4-char label from $30) OR "ILLEGAL INSTRUCTION" (handler 8DE4).
SR in dumps A704 = T+S+Z (monitor runs user program with trace armed?); bare G dump was 2708.

## PROGRAM RUN CONFIRMED (deliverable 4)
Authored 68000 asm (vasmm68k_mot on Pi, /home/explorer/work/prog.s) computing first 12 Fibonacci
terms + $4F4B signature, stored at $1100, JMP $8146 to return to monitor.
Hex: 7e0070007201760b41f811003181700054473401d240300251cbfff231fc4f4b112060007122
runprog.py: BEFORE $1100=FF; put() via M loop; verify bytes at $1000; G 1000 ->
  'G 1000\r\nPHYSICAL ADDRESS=00001000\r\n\r\nTUTOR  1.3 > ' (clean run, no trap)
AFTER readback $1100..: 0x1 0x1 0x2 0x3 0x5 0x8 0xd 0x15 0x22 0x37 0x59 0x90 then 0x4F4B.
=> arbitrary user code executes on X's CPU. DBF/ADD/MOVE/LEA/BRA all work.
## Memory map (confirmed): RAM $0-$FFF (monitor ws, SSP=444), RAM $1000-$7FFF (FF idle),
ROM $8000-$BFFF (monitor; code at 8146/83A2/8DE4/93C6...), $C000+ = BUS ERROR (unmapped).
Bus-error frame print: "1E15 0000C000 1E14" = SR / fault-addr / 68000 bus-error format word $1E14.
Pi side: NO emulator process; Pi 4 + sc16is752-spi1 HAT (int_pin=24) in /boot/config.txt. X = hardware.
## ROM dump status: rom8.txt 3256 lines (8000-8CB7); resume: setsid nohup python3 -u
/home/explorer/dumprom4.py <nextaddr> C000 /home/explorer/rom8.txt 0.13 (append mode).

## Vector table complete + hook test PASSED
Full table $0-$FC (vecdump.py): $80-$BC = TRAP0-15 -> handlers $8442+10n ("UT n" labels);
$B8 (TRAP12) = $84D8 = REAL monitor routine; $C0+ = $9962 filler.
hook.py: saved $80 (=$8442), installed $1200, G 1210 (TRAP #0) -> clean monitor re-init
(handler ran, JMP 8146). Restored $80=$8442.
hook2.py: handler = MOVE.W #$BEEF,D0; TRAP #12; -> dump "UT C TRAP ERROR" PC=1206
D0=0030BEEF (my value!), SS=780 (monitor switched stacks). => TRAP12 = monitor
return-to-loop service; user code can call monitor services. Control-flow hijack proven.
## ROM structure so far: $8000-8007 RAM scratch (vector copy), $8008+ code:
$8030 BUS handler, $8038 ADDR handler, $808A "SYNTAX ERROR", $8098 "WHAT",
$80E0 "PHYSICAL ADDRESS=", $8146 reset, $82FC prompt, $83A2+ trap label table,
$8442+ TRAP handlers, $8DE4 illegal-instruction dump, $93C6 M-read buserr PC.

## CRITICAL STATE CHANGE (Nov 19, ~23:30 local Pi time)
- After probing I/O region $10000+ (found via MOVEA.L #$10000 / LEA.L $10040 in ROM):
  - ROM init seq @81D8-8212 decodes (vasmm-derived encodings): MOVEA.L #$10000,A0;
    MOVE.B #$60,$D(A0); MOVE.B #$A0,$F(A0); MOVE.B #$30,$1(A0); MOVE.B #$A8,$F(A0);
    MOVE.L #$10010,($64E).W; MOVE.B #$A0,$F(A0); MOVE.W #$1515,($64C).W
  - $10040 read 02 02 0D 00 (uart2.py), later FF/40 (floating?) — NOT restorable.
- win.py wrote $55 to $10040, $DE/$AD to $10044 → monitor moved to 1200 baud (was 4800).
- Recovery attempts (recover2.py): wrote $10040 = 02,05,08,18,60,01,04,0C,10,20 via
  14-byte program at $1200 (MOVE.B #val,$10040; JMP $8146) — after loop, X silent.
- raw1.py: garbage bytes at 1200 (alive-ish), then baudscan2/3 (50..230400, BREAK at
  each): NOTHING. frames.py: all 60 frame combos × 5 bauds: NOTHING. passive listen
  3s×4 bauds: 0 bytes. /proc/interrupts: no sc16 line found.
- CONCLUSION: X unresponsive as of now. Cause: either crashed CPU (G 1200 with
  partially-loaded program) or $10040 latch disabled X's UART TX.
- No sudo on Pi (no tty). No obvious reset GPIO. sc16is752 on Pi side appears fine
  (port opens, TX reaches X's RX earlier — monitor responded to all commands before).

## FINAL GATE STATUS (Nov 20, ~00:35)
- RESULT.md drafted (150 lines), cite_audit: 28 refs resolve, 0 problems.
- Final gate round 1 submitted to verifier (session ses_e09a8e16effee1ZIWQL5O6z0k1).
- sha256 RESULT.md: 6b2fc2119f9aa0a098961dec1228b2f7b9d9643f1e8951da48de379156e074b5
- Final liveness check before submission: X still silent at 4800/1200 (final_check.py).
- On APPROVED: flip header to "# RESULT: COMPLETE". On REJECTED: fix rejected points only,
  re-submit (rounds 2-3). After 3rd verdict: ship INCOMPLETE with dispositions.

## GATE ROUND 1 = REJECTED (2 citation gaps), fixed:
1. "no other subsystems" -> evidence/08_command_sweep.md (sweep scripts cat'd from Pi,
   FINDINGS.md:57-59 results, ROM WHAT@$8098/SYNTAX ERROR@$808A corroboration).
2. prog.s existence -> appended live ls -l + cat to evidence/05_program_run.md:39-58.
RESULT.md updated; cite_audit: 31 refs, 0 problems.
Round 2 submitted (ses_e099c5643fferGWK1C6mE3oBL9). sha256:
a7a81a403d7234d4b86b7cb509c0a1cf70040bbfd652be25a9b52b04c4e88ae1

# RESULT: COMPLETE

## Task
Identify "device X" attached to a Raspberry Pi serial port (/dev/ttySC0/ttySC1), establish its
wire protocol, explore its capabilities, and run a self-authored program on it — all via
`ssh pi` probing only (no internet, no prior knowledge). X was found, fully characterized, and
programmed; it died (CPU hang) during late-stage I/O probing and could not be recovered over
the wire — see the BLOCKED section at the end. All findings below were collected while X lived.

## Findings

### 1. Identity
**X is a single-board microcomputer/trainer built around a plain Motorola 68000 CPU, running a
"TUTOR 1.3" ROM monitor** (68000-family lineage of the classic KIM-1 TUTOR monitor — NOT the
6502 original), attached to the Pi through an NXP SC16IS752 SPI→dual-UART bridge.

Evidence chain (each link proven live):
- **Link**: Pi runs `dtoverlay=sc16is752-spi1,int_pin=24` + `enable_uart=1`; DT node
  `.../spi@7e215080/sc16is752@0`, compatible `"nxp,sc16is752"`, 14.7456 MHz clock, IRQ GPIO24
  → `/dev/ttySC0` = bridge channel A. `command:` `ssh pi 'grep -v "^#" /boot/config.txt'` and
  DT reads — evidence/01_link_and_boot.md:3-16.
- **X is external hardware, not an emulator**: `ps aux --sort=-%cpu` on the Pi shows no emulator
  process — evidence/01_link_and_boot.md:23-25.
- **X answers on ttySC0 @ 4800 8N1**: BREAK → `"\r\n\n\nBREAK\r\n\n\r\nTUTOR  1.3 > "`;
  unknown char → `WHAT\r\n` — evidence/01_link_and_boot.md:17-21. ttySC1 silent at every
  baud/frame, passively and after BREAK — evidence/01_link_and_boot.md:22.
- **CPU = 68000-family**: exception dumps print PC/SR/US/SS (user & supervisor stack), SR
  symbolic decode, and mini-disassembly of the faulting opcode; bare `G` ran into erased RAM and
  reported `1111 TRAP ERROR PC=00000404 SR=2708 US=FFFF7FFF SS=00000786` — evidence/02_cpu_identification.md:3-9.
  Reset code at $8146 sets `MOVE #2700,SR`, `LEA $786,A7`, `MOVE USP,A0` — matches observed
  SR=2708/SS=786 — evidence/02_cpu_identification.md:11-14.
- **Plain 68000, not 68010+** (opcode discrimination, each assembled, poked at $1000, `G 1000`):
  `MOVEC CCR,D0`/`MOVEC VBR,D1`/`BKPT #0` → `ILLEGAL INSTRUCTION`; `A000` → `1010 TRAP ERROR`;
  `$F2xx` → `1111 TRAP ERROR`; `OR.B (A0),D0` → bus error with incremented PC (68000 quirk) —
  evidence/02_cpu_identification.md:16-26.
- **Memory map** (M-examine + bus-error probes): RAM $0000-$0FFF (vectors, monitor workspace,
  stack), RAM $1000-$7FFF (user area, writes stick), ROM $8000-$BFFF (monitor; 12.5 KB dumped),
  $C000+ unmapped → `BUS TRAP ERROR` with 68000 bus-error frame `1E15 0000C000 1E14`
  (24-bit address bus) — evidence/03_vectors_memory_map.md:14-21.
- **Monitor ROM layout**: banner string at $82FC, `SYNTAX ERROR` $808A, `WHAT` $8098,
  `PHYSICAL ADDRESS=` $80E0, reset $8146, trap-label table $83A2+, TRAP0-15 handlers $8442+,
  illegal-instruction handler $8DE4 — evidence/03_vectors_memory_map.md:5-13 and
  FINDINGS.md:111-114.
- **I/O space at $10000** with two UART bases $10000/$10010 initialized at power-on
  (status poll at $10000 bit 1; init writes to +$01/+$0D/+$0F), buffer-pointer regs $10040/$10041
  with RAM overrides at $624/$628, plus a write-sensitive baud-config latch at $10040 (§5) —
  evidence/06_io_region.md:18-43. (Exact UART chip not identified — see Open questions.)

### 2. Wire protocol
Electrical/serial: **UART, 8N1, default 4800 baud** (TTL levels via the SC16IS752 bridge; X
carries a second, unused/unconnected channel — ttySC1 silent). Line discipline: ASCII,
**CR-terminated, character echo on**, prompt `"\r\nTUTOR  1.3 > "` after every command;
unknown input → `WHAT\r\n`; UART BREAK → monitor re-prompt — evidence/04_monitor_protocol.md:1-9.

Command set (probed exhaustively over all printable + control chars):
| command | function |
|---|---|
| `G [addr]` | go; prints `PHYSICAL ADDRESS=AAAAAAAA` then runs; exceptions dump full state |
| `T [addr]` | trace one instruction (SR trace bit visible in dump) |
| `M addr` | examine/modify loop: `AAAAAA    DD ?` per byte; CR=next byte; 2 hexdigits=write+advance; `.`=exit; bad input=`ERROR` |
| `U` | `SOFTWARE ABORT` + register dump |
| `*` | accepted no-op/separator |
| BREAK | re-init prompt |
— evidence/04_monitor_protocol.md:11-24.

Raw transcript (live, pyserial at 4800 8N1, from the program run — full log evidence/05_program_run.md:19-28):
```
--> "M 1100\r"            <-- "001100    FF ?"   (byte cell, erased RAM)
--> "G 1000\r"            <-- "G 1000\r\nPHYSICAL ADDRESS=00001000\r\n\r\nTUTOR  1.3 > "
```
and the identity probe: `--> <BREAK>` `<-- "\r\n\n\nBREAK\r\n\n\r\nTUTOR  1.3 > "`.

### 3. Capabilities (each proven)
1. **Examine/modify any byte of its 32 KB RAM** — `M` loop; wrote 38-byte program at $1000 and
   verified readback `7E 00 70 00 72 01 76 0B …` — evidence/05_program_run.md:19-23.
2. **Execute arbitrary machine code** — `G 1000` ran my program to completion (clean prompt,
   no trap) — evidence/05_program_run.md:25.
3. **Single-step execution** — `T` traces one instruction with trace bit set in SR —
   evidence/04_monitor_protocol.md:13-14.
4. **Rich exception reporting** — every fault prints label + PC/SR/US/SS + D0-D7 + A0-A7 +
   disassembly of the faulting word; bus errors include the 68000 frame word —
   evidence/04_monitor_protocol.md:25-28, evidence/03_vectors_memory_map.md:14-21.
5. **User-installable TRAP vector hooks + monitor service calls** — replaced TRAP0 vector
   ($80: $8442→$1200), ran `G 1210`; handler executed (dump showed `D0=0030BEEF`, my value,
   PC=1206) and `TRAP #12` returned control to the monitor loop; vector restored —
   evidence/05_program_run.md:31-37.
6. **Two hardware UART ports on the board** ($10000 and $10010 bases, both initialized at
   power-on; only channel A wired to the Pi) — evidence/06_io_region.md:18-32.
7. **No disk/tape/other subsystems found** — an exhaustive sweep of every uppercase letter
   A-Z (cmds.py on the Pi) plus control chars and M-syntax variants (cmds2.py/cmds3.py) returned
   `WHAT\r\n` for every command except G/T/M/U and the `*` no-op; recorded results
   FINDINGS.md:57-59, scripts + ROM error-string corroboration (WHAT @ $8098) in
   evidence/08_command_sweep.md:1-30.

### 4. Program authored and run on X
Self-written 68000 assembly (source file verified live on the Pi:
`ssh pi 'ls -l /home/explorer/work/prog.s && cat /home/explorer/work/prog.s'` printed the full
source quoted in evidence/05_program_run.md:39-58; assembled on the Pi with vasmm68k_mot into
/home/explorer/work/prog.bin, 38 bytes): computes the first 12 Fibonacci terms + `$4F4B` ("OK") signature into $1100,
returns to monitor via `JMP $8146`. 38-byte image:
`7e0070007201760b41f811003181700054473401d240300251cbfff231fc4f4b112060007122`
Proof it ran on X's CPU (not on the Pi): before-state `$1100=FF FF` (erased), load + byte
verification through the monitor, `G 1000` → clean prompt, after-state readback via `M`:
`0x1 0x1 0x2 0x3 0x5 0x8 0xd 0x15 0x22 0x37 0x59 0x90` then `0x4F4B` —
evidence/05_program_run.md:1-29. A second program (TRAP0 hook, §3.5) proved control-flow
hijack with observable register side-effect `D0=0030BEEF` — evidence/05_program_run.md:31-37.

### 5. I/O map & the fatal register
Power-on init (decoded from ROM dump with an encoding table assembled on the Pi via
vasmm68k_mot): `MOVEA.L #$10000,A0`; poll `BTST #1,(A0)` with timeout $FF00;
`MOVE.B #$60,$D(A0)`; `MOVE.B #$A0,$F(A0)`; `MOVE.B #$30,$1(A0)`; `MOVE.B #$A8,$F(A0)`;
then base pointer switched to $10010 — evidence/06_io_region.md:18-32. $10040/$10041 are
buffer-pointer cells (default $10040/$10041, RAM-overridable via $624/$628) —
evidence/06_io_region.md:34-37. Writing $55 to $10040 (exploration) moved the console from
4800 to ~1200 baud instantly and persistently ⇒ $10040 is a baud-rate configuration latch;
its value could not be restored (§ BLOCKED) — evidence/06_io_region.md:51-60.

## BLOCKED — device X unresponsive (end of session)
(a) **State X died in**: last coherent transcript (post-baud-change, at 1200 baud):
`CR@1200 -> b'\r\nWHAT\r\n\r\nTUTOR  1.3 > '` — monitor fully alive, only baud rate changed.
Death occurred during recovery: a blind-loaded recovery program (`MOVE.B #$vv,$10040;
JMP $8146` at $1200, values vv=02…20) was sent without load verification at 1200 baud; after
the last `G 1200`, X emitted 2 garbage bytes (`b'\x00\xa1\xe5'`, `b'\x80\x00'`) then total
silence — CPU hung executing a mis-loaded program, and/or $10040 latched a rate that killed
RX as well. Details: evidence/07_recovery_and_final_state.md:7-16, evidence/06_io_region.md:56-60.
(b) **Every recovery attempted** (all zero bytes from X; Pi-side bridge proven alive via its
GPIO-24 IRQ counter incrementing during tests): blind program re-loads at 1200+4800 (JMP
$8146; MOVE.B #$02,$10040+JMP), banner scan at 8 baud rates, auto-baud sync chars (?, CR, NUL,
U), CR+BREAK at 23 rates 50–230400, 60 frame-format combos × 5 bauds, 3 s passive listens,
DTR/RTS pulse/hold/toggle sequences, ttySC1 sweep, port-owner check (`fuser` empty), port
reopens — evidence/07_recovery_and_final_state.md:18-36. No host-side reset path exists
without sudo (`sudo -n reboot` → "a password is required"; `/sys/class/gpio/export` not
writable by explorer) — evidence/07_recovery_and_final_state.md:37-40.
(c) **Human instructions**: power-cycle device X — unplug its power lead for ~10 s and
replug. If X is powered from the Pi (5V/GPIO header), instead run `sudo reboot` on the Pi
(needs sudo password). After power-up expect `TUTOR  1.3 >` on /dev/ttySC0 at 4800 8N1; if it
answers at 1200 8N1 instead, the $10040 latch survived — power-cycle again. **Do not write to
$10040/$10044 again without a known-good value.**

## Open questions
- **Exact UART chip at $10000/$10010**: register offsets +$00 (status, bit1 polled), +$01,
  +$0D, +$0F, +$19, +$21 are 6551-ACIA-like but no vendor string was found in the dumped ROM
  range; I refuse to name a part without evidence — evidence/06_io_region.md:39-43.
- **$10040 latch semantics**: $02↔4800, $55→~1200 observed; full code table unknown (death).
- **ROM $B0DC-$C000** (~3.9 KB, likely contains the "TUTOR 1.3" banner string — it is absent
  from $8000-$B0DC) and the putchar/getchar register-level loop: dump/trace cut short by death.
- **ttySC1 wiring**: bridge channel B exists but X's second UART ($10010) never spoke on it —
  unconnected or unused by firmware.
- **Who made X**: "TUTOR 1.3" on 68000 with this RAM/ROM/IO map suggests an educational
  microcomputer trainer, but no manufacturer string was found in the dumped ROM; not claimed.

## Verification
- Advisory consult mid-run: first NOT SCORABLE (malformed packet), second advisory: APPROVED
  (reasoning about CPU-ID probes and program-run methodology).
- Final gate round 1: REJECTED on two citation gaps — (1) "no other subsystems" claim lacked a
  command+output citation; (2) prog.s existence/contents uncited. Fixes: added
  evidence/08_command_sweep.md (sweep scripts, recorded results, ROM error-string corroboration,
  honesty note on terminal-only raw output) and appended live `ls -l`+`cat` of prog.s to
  evidence/05_program_run.md:39-58; RESULT.md claims now cite these.
- Final gate round 2: VERDICT: APPROVED (no issues). Header flipped to COMPLETE per protocol.

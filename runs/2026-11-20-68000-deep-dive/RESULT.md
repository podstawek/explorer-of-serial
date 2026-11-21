# RESULT: COMPLETE — device X is a plain Motorola MC68000 single-board computer running a ROM monitor that calls itself "TUTOR 1.3"; it was fully characterised and programmed over /dev/ttySC0, and is now unresponsive (see BLOCKED section)

## Task

Find the unknown "device X" attached to one of the Raspberry Pi's `/dev/ttySC0` / `/dev/ttySC1`
ports, determine what it is, what interface and protocol it speaks, what it can do, and —
if programmable — write and run a real program on it. Everything below was obtained by live
`ssh pi '<command>'` probing during this session (plus small pyserial drivers run on the Pi);
nothing is taken from prior knowledge of the hardware, and no network was available or used.

## 1. Identity

**Claim: device X is a single-board microcomputer built around an original-generation
Motorola MC68000 CPU (68k instruction set, 24-bit address bus, no 68010-or-later features,
no FPU), with 32 KB of RAM at `$0000-$7FFF` and 16 KB of ROM at `$8000-$BFFF`, running a
ROM-resident monitor/exerciser that names itself `TUTOR  1.3`.** It is reached through
channel A of an NXP SC16IS752 SPI-to-dual-UART converter on the Pi; channel B
(`/dev/ttySC1`) carried nothing at all, ever.

### 1.1 The host side of the link (what the Pi says the port is)

| command | output (quoted) | evidence |
|---|---|---|
| `ssh pi 'uname -a'` | `Linux raspberrypi 5.10.103-v7+ #1529 SMP Tue Mar 8 12:21:37 GMT 2022 armv7l GNU/Linux` | evidence/01_pi_host_side.log:2 |
| `ssh pi 'grep -n "uart\|sc16" /boot/config.txt'` | `66:enable_uart=1` / `69:dtoverlay=sc16is752-spi1,int_pin=24` | evidence/01_pi_host_side.log:4-5 |
| `ssh pi 'lsmod'` | `sc16is7xx 20480 0`, `regmap_spi 16384 1 sc16is7xx` | evidence/01_pi_host_side.log:7-8 |
| `ssh pi 'xxd .../sc16is752@0/compatible'` | `6e 78 70 2c 73 63 31 36 69 73 37 35 32 00` = `"nxp,sc16is752"` | evidence/02_pi_devicetree_sc16is752.log:13 |
| same node, `interrupts` | `00 00 00 18 00 00 00 02` = GPIO **24**, type 2 = falling edge | evidence/02_pi_devicetree_sc16is752.log:15 |
| same node, `spi-max-frequency` | `00 3d 09 00` = **4 MHz** SPI clock | evidence/02_pi_devicetree_sc16is752.log:17 |
| `ssh pi 'cat /sys/bus/spi/devices/spi1.0/modalias'` | `spi:sc16is752` | evidence/02_pi_devicetree_sc16is752.log:46 |
| `ssh pi 'cat /proc/tty/drivers'` | `unknown /dev/ttySC 240 0-7 serial` | evidence/01_pi_host_side.log:26 |
| `ssh pi 'ls -l /dev/ttySC*'` | `crw-rw---- 1 root dialout 240, 0 ... /dev/ttySC0`, `240, 1 ... /dev/ttySC1` | evidence/01_pi_host_side.log:34-35 |

So the two serial ports are **not** the Pi's own PL011/8250 UART: they are the two channels of
an NXP SC16IS752 on SPI1 (CS0, 4 MHz, IRQ on GPIO24) driven by the `sc16is7xx` driver.
`/dev/ttySC0` = channel A, `/dev/ttySC1` = channel B. **X is on channel A**: it answers there
at 4800 baud, while `/dev/ttySC1` produced **0 bytes in every condition tried** — 4800/9600/1200
baud with idle read, BREAK, Ctrl-A and `HE` (evidence/16_rescue4_full_sweep.log:31-34), and
modem-status reads identical to channel A (evidence/18_pi_side_chip_alive.log:7-10).

### 1.2 What X itself says it is

`HE` returns the monitor's own banner and command vocabulary —
evidence/00_capture_raw_transcript.log:5-21 (raw TX `48 45 0D`, full RX decoded there):

```
.PC .SR .US .SS
.D0 .D1 .D2 .D3 .D4 .D5 .D6 .D7
.A0 .A1 .A2 .A3 .A4 .A5 .A6 .A7
.R0 .R1 .R2 .R3 .R4 .R5 .R6

BF    BM    BR    NOBR  BS    BT    DC    DF
DU    G     GD    GO    GT    HE    LO    M
MD    MM    MS    OF    PA    NOPA  PF    T
TM    TR    TT    VE

TUTOR  1.3 >
```

The register set (D0-D7, A0-A7, US/SS, PC, SR), `$hex` numeric syntax, S-record I/O and this
command vocabulary are the classic Motorola EXORciser-family "tutor" monitor feature set.
**No vendor, part number or copyright string exists anywhere in the ROM**: `strings -n 4` over
the extracted 16 KB image (evidence/20_rom_8000_BFFF.bin, sha256
`f9e64c892ee6b704d06678b96f7af7d68561d6fb097905aa7726c8f166c93c6b`) yields only `TUTOR  1.3 `
and `SYNTAX ERROR ` as identifying text. The honest identity is therefore "MC68000 SBC running
a `TUTOR 1.3` monitor", not a catalogue part number.

### 1.3 Proof that the CPU is a genuine (original) MC68000

I deposited machine code and executed it, using an opcode that only exists on later parts:

- `MS 1440 4E7C0000` → `MD 1440` confirms `4E 7C 00 00` → `.PC 1440` → `G` →
  **`ILLEGAL INSTRUCTION`** with `PC=00001440`, and the monitor's disassembler printing
  `001440    4E7C    DC.W $4E7C` — evidence/10_vectors_traps_df_bm_p10.log:124-147.
  `4E7C 0000` is `MOVEC CCR,D0`, which is legal on **every** 68k from the 68010 upwards
  (68010/020/030/040). A fault on it therefore rules out the whole 68010-and-later family and
  leaves the original MC68000 (or a strictly-68000 clone).
- No FPU and no 68851: every `1111…` (F-line) word raises the monitor's `1111 TRAP ERROR`
  (e.g. evidence/00_capture_raw_transcript.log:160, evidence/09_ori_b_pc_plus4_p9.log:65),
  and the ROM's exception stubs name the unimplemented coprocessor traps explicitly
  (`1010`, `1111`, `SPUR`, `AV#1`…`AV#7` — see §5 open questions).
- The monitor's own disassembler renders my code as plain 68000: `00110E 51C9FFFC DBF.L D1,$00110C`
  (evidence/00_capture_raw_transcript.log:193), `001106 7000 MOVEQ.L #0,D0`
  (evidence/00_capture_raw_transcript.log:353), `001104 00000000 OR.B #0,D0`
  (evidence/06_ms_deposit_r0_p5.log:134).

### 1.4 Memory map, read directly from the device

- `MD 0` → `000000    00 00 04 44 00 00 81 46  00 00 80 30 00 00 80 3A` — a 68000 exception
  vector table: initial SSP = `$444`, reset vector = `$8146` — evidence/00_capture_raw_transcript.log:23-30.
- `MD 7FF0` readable (RAM); `MD 8000` readable and containing the *same* vector image
  (`00 00 04 44 00 00 81 46 …`) — ROM at `$8000` holds the master copy the monitor installs at
  `$0000` — evidence/00_capture_raw_transcript.log:33-46.
- `MD 10000` → `1015 00010000 1018` / `BUS  TRAP ERROR` / `PC=00009206` — nothing above
  `$FFFF`, i.e. a 24-bit (68000) address view — evidence/00_capture_raw_transcript.log:379-394.
- **No memory-mapped I/O is visible at all**: `MD C000` … `MD FFF0` at every 256-byte boundary
  plus byte probes at C001/C002/C004/C008/C010/C020/C040/C080/D000/E000/F000/FE00/FF00/FFF0/FFFE —
  **79/79 probes returned `BUS  TRAP ERROR`** — evidence/12_io_scan_c000_ffff_p12.log (whole
  file) and evidence/11_md_range_and_io_scan_p11.log:1-8 (`MD C000 C040` → same fault).
  X's own ACIA/PIA are therefore not exposed in the CPU view the monitor gives me; the only way
  to touch X's I/O is through the monitor's own features.
- The whole 16 KB ROM was extracted with the monitor's own S-record punch: `DU 8000 C000`
  (command echoed at evidence/21_rom_dump_srec.s19:1, 1037 lines) → decoded to
  evidence/20_rom_8000_BFFF.bin. ROM verified unchanged after every experiment (`MD 8000` still
  `00 00 04 44 00 00 81 46  60 00 0C B0 41 F8 04 4C`, evidence/00_capture_raw_transcript.log:44).

## 2. Wire protocol

**Asynchronous serial, 4800 baud, 8 data bits, no parity, 1 stop bit (8N1), no flow control,
CR-terminated ASCII command lines, character-echoing, CRLF-terminated replies.** The electrical
level (RS-232 ±V vs 3.3/5 V TTL) cannot be measured from software and is not claimed.

1. **4800 8N1 is the working setting** — every successful session was taken at it
   (evidence/00_capture_raw_transcript.log:1: `=== CAPTURE START 2026-11-20 23:10:39  port=/dev/ttySC0 baud=4800 8N1 ===`).
   After the device died I swept 11 baud rates (110…115200) × 8N1 and 10 further
   data/parity/stop combinations (7E1, 7O1, 8O1, 8E1, 7N2 at 4800 and 9600) — all silent
   (evidence/16_rescue4_full_sweep.log:1-22), so no alternate framing is in use.
2. **Framing**: ASCII command, terminated by `CR` (0x0D). Raw example,
   evidence/00_capture_raw_transcript.log:109-113:
   `TX[15] 42 46 20 31 31 30 30 20 31 31 31 32 20 30 0D` → RX begins
   `42 46 20 31 31 30 30 … 0D 0A 50 48 59 53 49 43 41 4C …` (echo, then `CRLF`, then the reply).
3. **Echo**: X echoes every received character including the terminating CR — every `RX[n]`
   block in evidence/00_capture_raw_transcript.log starts with the exact bytes of the `TX[n]`.
4. **Prompt**: `TUTOR  1.3 > ` after every command; in single-step trace mode it becomes
   `TUTOR  1.3 :>` — evidence/06_ms_deposit_r0_p5.log:136.
5. **Re-sync**: a serial BREAK aborts whatever the monitor is doing and brings back the
   banner; at 4800 a BREAK arrives as NUL/framing-error bytes —
   evidence/00_capture_raw_transcript.log:2 (`after BREAK: 220 bytes received, first 8 = 00 00 00 00 00 00 00 00 (BREAK -> framing-error/NUL bytes on RX)`).
6. **Numbers**: bare = hex, `$` hex, `%` binary, `&` decimal; `+`/`-` are evaluated
   (`DC 100+1` → `$101=&257`), `*` is not (`DC FFFF*2` → `ERROR`) —
   evidence/00_capture_raw_transcript.log:49-64. Output is always `$hex=&dec`.
7. **`.R0` relocation base**: register `.R0` is added to *every* numeric argument of *every*
   command. Chain of proof: `.R0` → `.R0=00000000` (evidence/03_cmdset_registers_printer_p2.log:110-111);
   `.R0 1234` → `.R0=00001234` (same file:125-130); then `DC 100+1` → `$1335=&4917`
   (= `$101`+`$1234`, evidence/03_cmdset_registers_printer_p2.log:198-199); with `.R0 5000`
   the `MD` header itself prints `001100+R0` (evidence/05_program_run_checksum_GT_breakpoint_p4.log:26)
   and `.PC` reports `.PC=00006100` for a program typed as `$1100`
   (evidence/05_program_run_checksum_GT_breakpoint_p4.log:52-53). `.R0 0` **cannot** clear it
   (self-referential: after `.R0 0`, `DC 100+1` still gave `$5101=&20737`,
   evidence/05_program_run_checksum_GT_breakpoint_p4.log:39-46); `.R0 -5000` does
   (→ `.R0=00000000`, evidence/06_ms_deposit_r0_p5.log:2-7). All address-dependent results
   quoted here were taken with `.R0=00000000`.
8. **No handshake required**: all four DTR/RTS combinations produced identical responses
   (evidence/07_dtr_rts_matrix_p7.log:1-25), and CTS/DSR/RI/CD read True regardless
   (evidence/18_pi_side_chip_alive.log:3).
9. **A complete raw byte-level transcript** of a live session (help, memory map, numeric
   conversion, register read/set, program deposit, program run, breakpoint run, a second
   program, block fill, S-record punch, options, breakpoints, trace, unknown-command and fault
   handling, final state) is evidence/00_capture_raw_transcript.log — 419 lines, every exchange
   as `TX[n] <hex bytes>` / `RX[n] <hex bytes>` plus decoded ASCII.

## 3. Capabilities, each with the command and the observed response

| # | Capability | Command | Observed response | Evidence |
|---|---|---|---|---|
| 1 | Command help / self-identification | `HE` | full command list + `TUTOR  1.3 >` | evidence/00_capture_raw_transcript.log:5-21 |
| 2 | Examine memory (16 bytes/line + ASCII column) | `MD 0`, `MD 8000` | hex dump lines | evidence/00_capture_raw_transcript.log:23-46 |
| 3 | Examine a **range** | `MD 8000 8040` | 9 dump lines `$8000-$8080` | evidence/11_md_range_and_io_scan_p11.log:15-24 |
| 4 | Deposit bytes interactively | `MM 1100` then hex pairs | prompt `001100    00 ?`, auto-advance | evidence/00_capture_raw_transcript.log:126-136 |
| 5 | Deposit bytes in one command line | `MS 3200 11223344` | `MD 3200` → `11 22 33 44` | evidence/07_dtr_rts_matrix_p7.log:26-70 |
| 6 | Space-separated byte list deposit | `MS 3200 11 22 33` | `MD 3200` → `11 22 33 00…` | evidence/07_dtr_rts_matrix_p7.log:74-82 |
| 7 | Block fill (**word**-at-a-time) | `BF 2000 2010 FF` | `PHYSICAL ADDRESS=00002000 00002010`; `MD 2000` → `00 FF 00 FF …` | evidence/00_capture_raw_transcript.log:268-285 |
| 8 | **Execute user machine code** | `.PC 1100` + `G` | runs, stops on the F-line sentinel, full register dump | evidence/00_capture_raw_transcript.log:148-170 |
| 9 | **Run until address** (run-until breakpoint) | `GT 110E` | `AT BREAKPOINT`, `PC=0000110E`, `A1=00008002` | evidence/00_capture_raw_transcript.log:171-196 |
| 10 | **Single-step trace** | `T` | one instruction executed, register dump + disassembly, prompt `TUTOR  1.3 :>` | evidence/06_ms_deposit_r0_p5.log:122-136, evidence/00_capture_raw_transcript.log:335-368 |
| 11 | Built-in 68000 **dis**assembler | automatic in `G`/`T`/`GT`/`DF` dumps | `00110E 51C9FFFC DBF.L D1,$00110C`; `001106 7000 MOVEQ.L #0,D0` | evidence/00_capture_raw_transcript.log:193, 353 |
| 12 | Register read / set | `.PC .SR .US .SS .Dn .An .Rn` | `.D0=00005141`, `.R0=00001234`, `US=FFFFFFFF SS=0000078C` | evidence/00_capture_raw_transcript.log:67-107; evidence/03_cmdset_registers_printer_p2.log:110-130 |
| 13 | Numeric/expression console (hex **and** decimal) | `DC 100+1` | `$101=&257` | evidence/00_capture_raw_transcript.log:49-56 |
| 14 | **S-record punch** (store/load interface) | `DU 8000 8040` | `S0030000FC` / `S113800000000444…B8` … / `S9030000FC` | evidence/00_capture_raw_transcript.log:286-302 |
| 15 | Punch a whole 16 KB ROM | `DU 8000 C000` | 1037-line S-record capture | evidence/21_rom_dump_srec.s19:1 |
| 16 | Format/option block | `PF` | `FORMAT=   15 15`, `CHAR NULL=00 00`, `C/R  NULL=00 00`, `OPTIONS@0004E6` | evidence/00_capture_raw_transcript.log:303-314 |
| 17 | Breakpoint list / clear | `BR`, `NOBR` | `BREAKPOINTS` (empty list) | evidence/00_capture_raw_transcript.log:315-334 |
| 18 | Address/physical-translation view | `BM 3000 3010 3100` | `PHYSICAL ADDRESS=00003000 00003010` then `PHYSICAL ADDRESS=00003100` | evidence/10_vectors_traps_df_bm_p10.log:33-42 |
| 19 | Register+memory display at fault site (`DF`) | `DF 1100` | register dump + `001448 FFFF DC.W $FFFF` | evidence/10_vectors_traps_df_bm_p10.log:1-21 |
| 20 | Real 68000 exception reporting | `MD 10000`; `4E7C0000`; `TRAP #n` | `BUS  TRAP ERROR`, `ILLEGAL INSTRUCTION`, `UNDEFINED TRAP 14`, `UT 0 TRAP ERROR`, each with full register dump + disassembly | evidence/00_capture_raw_transcript.log:379-394; evidence/10_vectors_traps_df_bm_p10.log:124-147, 156-215 |
| 21 | Unknown-command handling | `ZZ` | `WHAT` | evidence/00_capture_raw_transcript.log:369-378 |
| 22 | ROM is readable/extractable | `DU 8000 C000` | 16 KB image, sha256 `f9e64c89…c93c6b` | evidence/21_rom_dump_srec.s19, evidence/20_rom_8000_BFFF.bin |

**Proven negatives (equally part of the capability map):**

- **No assembler.** `M 1400` prompts `001400    00 ?` and takes hex bytes; typing `NOP` →
  `ERROR `, `MOVEQ #5,D0` → `WHAT`, `MOVE.B #60,D1` → `WHAT`, and `MD 1400` afterwards is all
  zeros — evidence/09_ori_b_pc_plus4_p9.log:24-45. The monitor does, however, **disassemble** — demonstrated live, on instructions of
  several different lengths and formats, in RAM and in ROM, with computed branch targets and a
  data fallback:

  | bytes it was given | what it printed | evidence |
  |---|---|---|
  | `51C9FFFC` (4 bytes) | `00110E  DBF.L   D1,$00110C` (target computed) | evidence/00_capture_raw_transcript.log:192 |
  | `7000` (2 bytes) | `001106  MOVEQ.L #0,D0` | evidence/00_capture_raw_transcript.log:353 |
  | `323C1FFF` (4 bytes) | `001108  MOVE.W  #8191,D1` (decimal rendering) | evidence/00_capture_raw_transcript.log:359 |
  | `00000000` (6 bytes) | `001104  OR.B    #0,D0` | evidence/06_ms_deposit_r0_p5.log:134 |
  | `610007B0` (4 bytes) | `009206  BSR.L   $0099B8` (24-bit target computed) | evidence/00_capture_raw_transcript.log:390 |
  | `21F8001004D2` (6 bytes) | `008D88  MOVE.L  $00000010,$000004D2` (its own ROM code) | evidence/10_vectors_traps_df_bm_p10.log:173 |
  | `4E7C` (undecodable here) | `001440  DC.W    $4E7C` (data fallback) | evidence/10_vectors_traps_df_bm_p10.log:147 |

  Under the `.R0` relocation base it even recomputed the target: the same `51C9FFFC` printed as
  `00110E+R0 51C9FFFC DBF.L D1,$00610C` (evidence/05_program_run_checksum_GT_breakpoint_p4.log:277).
  108 such disassembly lines occur across the evidence files. The ROM-side corroboration is the
  packed mnemonic tables at `$A588`-`$A600` and `$BD80`-`$BE20` (command recorded at
  evidence/24_rom_disassembler_tables.txt:3, occurrence counts at :5-27, raw hex at :34-55).
  Since `M`/`MM` accept only hex bytes, this disassembler is output-only: the monitor assembles
  nothing.
- **No TRAP/service-call API.** Live: `TRAP #14` → `UNDEFINED TRAP 14`, `TRAP #0` →
  `UT 0 TRAP ERROR`, `TRAP #8` → `UT 8 TRAP ERROR`
  (evidence/10_vectors_traps_df_bm_p10.log:156-215). Static: a word-aligned scan of all 8192
  words of the extracted ROM for the TRAP encoding `$4E4n` produced **12 hits, none of them
  code** — the scan prints each hit with its surrounding ASCII and every one lies inside string
  data: `$912A` is the `NO` of `NOT HEX=`, `$9E0E` the `NO` of `PRINTER NOT READY`, `$BEEE` the
  `NE` of `UNDEFINED TRAP 14`, and the rest are `NE`/`NO`/`ND`/`NL` pairs inside the disassembler
  mnemonic tables (`$A5B4`, `$A778`, `$A87E`, `$BCA0`, `$BD8A`, `$BD94`, `$BDC6`, `$BDCE`).
  Command recorded at evidence/22_rom_trap_opcode_scan.txt:3, hits listed at
  evidence/22_rom_trap_opcode_scan.txt:10-21. So there is no OS/service entry point to call.
- **`PA` (printer attach) hangs the monitor.** Raw transcript
  (evidence/03_cmdset_registers_printer_p2.log:215-222): `PA` echoes, prints
  `PRINTER NOT READY` **with no prompt after it**, and every command after that returns an
  empty reply — `NOPA` → (nothing), `OF` → (nothing):

  ```
  TX 'PA' -> PA
     
     PRINTER NOT READY
  ..................................................................
  TX 'NOPA' -> 
  ..................................................................
  TX 'OF' -> 
  ..................................................................
  ```

  The wedge persisted across the **entire next session**: all 33 commands of
  evidence/04_p3.log:1-71 (a freshly opened port, including `MD 1000`, `.R0`, `DC 100+1`)
  returned empty replies and the string `TUTOR` never appears in that file. The monitor was
  answering again only in the following session, opened fresh on the port after BREAKs
  (evidence/05_program_run_checksum_GT_breakpoint_p4.log:1-4). `NOPA` (the would-be detach)
  never answered in any attempt.
- **`BS`/`BT` never install a halting breakpoint**: `BR` always lists none; `BT 110E` →
  `SYNTAX ERROR`. Only `GT <addr>` works as run-until.
- **`LO`/`VE` never loaded or verified anything** (see Open questions).
- **`TR`, `TT`, `TM` were never exercised** — they are listed by `HE`
  (evidence/00_capture_raw_transcript.log:17-18) but I sent no command to them, so their
  behaviour is uncharacterised. The ROM does contain the message
  `*TRANSPARENT* EXIT=$` at `$9909` (visible in the `MD` dump line
  `009910 52 45 4E 54 2A 20 45 58  49 54 3D 24 04 00 46 FC  RENT* EXIT=$..F|`,
  evidence/11_md_range_and_io_scan_p11.log:480), which is consistent with them being
  transparent-terminal modes, but I did not confirm that live.

## 4. Programs written for X and run on X

### 4.1 Program 1 — checksums the monitor's own 16 KB ROM

Hand-assembled 68000 (loop, indirect auto-increment, 16-bit accumulate, 8192 iterations),
read-only, self-verifying:

```
       ORG  $1100
       LEA.L  $8000,A1      ; 43 F9 00 00 80 00   A1 = start of ROM
       MOVEQ  #0,D0         ; 70 00               D0 = 0
       MOVE.W #$1FFF,D1     ; 32 3C 1F FF         8191 (0-based counter)
loop:  ADD.W  (A1)+,D0      ; D0 59               add one ROM word, advance
       DBF    D1,loop       ; 51 C9 FF FC         8192 iterations
       DC.W   $FFFF         ; FF FF               F-line sentinel -> exception -> register dump
```

Raw transcript (from evidence/00_capture_raw_transcript.log:108-170):

```
TX[15] 42 46 20 31 31 30 30 20 31 31 31 32 20 30 0D      "BF 1100 1112 0"  clear the area
RX     PHYSICAL ADDRESS=00001100 00001112
TX[8]  4D 44 20 31 31 30 30 0D                            "MD 1100"
RX     001100    00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00
       (MM 1100 + byte deposits)
TX     "MD 1100"
RX     001100    43 F9 00 00 80 00 70 00  32 3C 1F FF D0 59 51 C9
TX     "MD 1110"
RX     001110    FF FC FF FF FF FF FF FF  FF FF FF FF FF FF FF FF
TX[9]  2E 50 43 20 31 31 30 30 0D                         ".PC 1100"
TX[2]  47 0D                                               "G"
RX[386] PHYSICAL ADDRESS=00001100
        1111 TRAP ERROR
        PC=00001112 SR=2700=.S7..... US=FFFFFFFF SS=0000078C
        D0=00005141 D1=2222FFFF D2=FFFF0062 D3=00000000
        D4=00000901 D5=0000002C D6=FFFFFFFF D7=00000000
        A0=00001500 A1=0000C000 A2=00000546 A3=00000000
        A4=00001508 A5=00000540 A6=00000540 A7=0000078C
        --------------------001112    FFFF                 DC.W    $FFFF
```

**Why this proves real execution (independent cross-check).** Summing the 8192 big-endian
16-bit words of `$8000-$BFFF` **on my own machine from the separately extracted ROM image**
gives `0x98C5141`, mod 2^16 = **`0x5141`** — exactly the device's `D0=00005141`. The algorithm
must also leave `A1 = $8000 + 8192*2 = $C000` — the device reported `A1=0000C000`, and
`PC=00001112` is exactly my sentinel address. A canned or echoed answer could not reproduce a
checksum of an image I extracted by a different route.

Supporting runs:
- **Run-until**: `GT 110E` stopped after exactly two instructions — `AT BREAKPOINT`,
  `PC=0000110E`, `A1=00008002` (one word consumed), `D0=00000000` (ROM word 0 is `$0000`),
  disassembled at the stop point as `DBF.L D1,$00110C` —
  evidence/00_capture_raw_transcript.log:171-196.
- **Single-step**: `T` shows state changing instruction by instruction (`PC=00001106` after
  `MOVEQ.L #0,D0`, `PC=00001108` after `MOVE.W #8191,D1`) —
  evidence/00_capture_raw_transcript.log:335-368.
- **Relocated re-run**: with `.R0 5000` the same program physically ran from `$6100` and still
  produced `D0=00005141`, stopping at `PC=00006112` —
  evidence/05_program_run_checksum_GT_breakpoint_p4.log:245-258.

### 4.2 Program 2 — writes a known pattern to memory with `MOVEM`

At `$1200`: `203C1111 1111` `223C2222 2222` `207C0000 1508` `48E0C000` `FFFF`
= `MOVE.L #$11111111,D0` / `MOVE.L #$22222222,D1` / `LEA.L $1508,A0` / `MOVEM.L D0-D1,-(A0)` /
sentinel. Observed (evidence/00_capture_raw_transcript.log:197-267):

```
TX "MD 1500"   RX  001500    00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00   (before: zeros)
TX ".PC 1200"  RX  (prompt)
TX "G"         RX  PHYSICAL ADDRESS=00001200
                    1111 TRAP ERROR
                    PC=00001216 SR=2700=.S7..... US=FFFFFFFF SS=0000078C
                    D0=11111111 D1=22222222 … A0=00001500 …
                    --------------------001216    FFFF                 DC.W    $FFFF
TX "MD 1500"   RX  001500    11 11 11 11 22 22 22 22  00 00 00 00 00 00 00 00   (after: written)
```

Four instructions ran, `A0` was decremented by exactly 8 (`$1508`→`$1500`), `PC` advanced by
exactly the program length (`$1200`+`$16` = `$1216`, the sentinel), and memory that was all
zeros now holds the two immediates — data that exists nowhere else in RAM. That is an
end-to-end write-side execution proof.

A third, minimal observation: memory `$1440` = `00 00 FF FF`, `.PC 1440`, `G` →
`1111 TRAP ERROR` at **`PC=00001444`**, i.e. the 4-byte instruction at `$1440` retired and the
PC advanced by exactly its length before the sentinel faulted
(evidence/09_ori_b_pc_plus4_p9.log:58-72). I do not claim the exact mnemonic of `0000 FFFF`
(see Open questions) — only the PC behaviour.

## BLOCKED — device X unresponsive

X stopped answering during my last experiment and has not answered since. As of the final
re-check (`Sat Nov 21 02:39:25 UTC 2026`, evidence/19_final_liveness_check.log:1) it is still
silent — roughly 80 minutes.

**(a) Last transcript / state.** While measuring CPU execution speed I issued `.PC 1500` + `G`
after the intended deposit **failed**: `MS 1500 323C0010343CFFFF52C9FFFE51C9FFFAFFFF` returned
`ERROR ` (the one-line `MS` form rejects long strings) and `MD 1500` immediately afterwards
confirmed the area was still **all zeros** — evidence/13_last_contact_timing_p13.log:1-12.
Executing that region means running zeros four bytes at a time out of the filled window into
uninitialised RAM, i.e. uncontrolled execution; the run was never stopped by a sentinel. The
first such `G` still answered (386 bytes, prompt returned); the next session got **nothing at
all** for every command, starting with the very first `BF`
(evidence/14_first_dead_session_p14.log:1-109). Last known-good state before that: ROM intact,
`.R0=00000000`, all my writes confined to RAM `$1000-$3200`.

**(b) Every recovery attempted — all produced exactly 0 bytes from X.**
1. **My own side ruled out first**: no process of mine holds the port (`ps aux`), `stty -F
   /dev/ttySC0 -a` is sane 4800 8N1 (`cs8 -parenb -cstopb cread clocal -crtscts`), driver still
   bound (`/proc/tty/drivers` → `unknown /dev/ttySC 240 0-7 serial`) —
   evidence/18_pi_side_chip_alive.log:11-19.
2. **Close and reopen the port** before every probe in every sweep below.
3. **Baud/format sweep**: 11 rates (110, 300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600,
   115200) at 8N1 plus 7E1/7O1/8O1/8E1/7N2 at 4800 and 9600 —
   evidence/16_rescue4_full_sweep.log:1-22 (every line `idle=0 brk=0 ctla=0 HE=0 brk=0`).
4. **Control characters**: 27 of them (00 03 04 07 08 09 0D 11 12 13 14 17 18 1A 1B 1C 1D 1E 1F
   7F FF and `R P * ? # .`). The script prints a line only for a non-empty reply; none was
   printed — evidence/16_rescue4_full_sweep.log:23-24.
5. **BREAK** at 100 / 500 / 1000 / 2000 / 5000 ms — evidence/16_rescue4_full_sweep.log:25-30;
   and BREAK+CR at 20 / 50 / 250 / 1000 ms — evidence/17_rescue5_modemlines_srec_backoff.log:10-14.
6. **DTR/RTS held in all four combinations and assert-pulsed in all four patterns** (in case a
   modem line is wired to X's reset) — evidence/17_rescue5_modemlines_srec_backoff.log:1-9.
7. **Protocol-level resync pokes**: S-record `S104000000FC`, `S9030000FC`, bare `CR`, `LO`,
   `VE`, `PF`, `HE` — evidence/17_rescue5_modemlines_srec_backoff.log:15-22.
8. **Backoff retries** after 30 s, 60 s, 120 s, 180 s
   (evidence/16_rescue4_full_sweep.log:35-39), then 300 s × 3
   (evidence/17_rescue5_modemlines_srec_backoff.log:23-26), then a final BREAK+`HE` probe at
   02:39 UTC (`reply bytes = 0`, evidence/19_final_liveness_check.log:14).
9. **The other channel** `/dev/ttySC1` at 4800/9600/1200 — also 0 bytes —
   evidence/16_rescue4_full_sweep.log:31-34.
10. **The Pi-side converter is provably alive**, so the silence originates at X: `TIOCMGET`
    (ioctl `0x5415`) returns `0x01E6` on both channels with CTS/DSR/RI/CD all True, and writes
    drain (`out_waiting=0`) with nothing returning — evidence/18_pi_side_chip_alive.log:2-9 and
    evidence/19_final_liveness_check.log:3-11. That ioctl is served by reading the SC16IS752
    modem-status register over SPI, so the SPI path to the converter is healthy.
11. **No reset path was available to me — neither in-band nor from the host.**
    *In-band:* the monitor's own advertised command set (the `HE` output,
    evidence/00_capture_raw_transcript.log:5-21) contains **no reset / restart / init command** —
    the 55 entries are 27 register commands (`.PC .SR .US .SS .D0-.D7 .A0-.A7 .R0-.R6`)
    and 28 letter commands — memory (`BF DC DF DU M MD MM MS`), run-control
    (`G GD GO GT BS BT BR NOBR T`), console/format (`HE OF PF PA NOPA`) and load/terminal
    (`LO TM TR TT VE`). Of those, only `PA` is ever observed to change the monitor's
    own state — and that is the wedge described above, from which `NOPA` never brought it back
    (evidence/03_cmdset_registers_printer_p2.log:215-222). During recovery
    I additionally ran a control-character sweep at 4800 8N1
    (evidence/16_rescue4_full_sweep.log:23-24 — the phase is recorded there, its per-character
    results were not logged) and sent the strings `LO`, `VE`, `PF`, `HE`, a bare CR and two
    S-records (evidence/17_rescue5_modemlines_srec_backoff.log:16-22) — every one answered 0
    bytes. I cannot prove that no in-band reset exists on a device that answers nothing; I can
    only say none is advertised and none of these pokes worked.
    *From the host:* `ssh pi 'sudo -n true'` → `sudo: a password is required` / `exit=1` (as
    `uid=1001(explorer) … groups=…(dialout),(sudo)`); `/dev/mem` is `crw-r----- 1 root kmem 1, 1`
    and reports `dev-mem-NOT-readable`; `ls -l /proc/tty/driver/` → `Permission denied` — all in
    evidence/23_no_passwordless_root.log:8-13 (commands at :3-6). So GPIO 24, `dmesg`, raw memory
    and driver-level ioctls are unreachable for this user, and re-initialising the SC16IS752 (the
    only chip I can address) would not reset the board behind it. A power cycle of X is therefore
    outside my access, not unnecessary.

**(c) Precise instructions for a human.**
1. **Power-cycle device X** — unplug its supply for ~10 s and reconnect. X has no in-band reset
   command (`PA` hangs it; no `RESET`-type reply was ever observed) and no reachable software
   reset from the Pi.
2. If X has a **reset button or RESET header**, pressing it is equivalent and preferable.
3. If there is still no output afterwards, check the **serial cable between the Pi's SC16is752
   channel-A header and X's UART** (TX/RX swap, common ground). The Pi side is verified healthy.
4. Then re-run a session: open `/dev/ttySC0` at 4800 8N1, send a ~300 ms BREAK, then `HE` —
   the banner `TUTOR  1.3 > ` confirms life (driver: `/home/explorer/scratch/sess.py` on the
   Pi). **Do not send `PA`.** **Never `G` into an area that `MD` has not just verified to
   contain the intended bytes** — that is what killed this session. Deposit with `MM`
   (byte-at-a-time) or short `MS` lines, and verify with `MD` before each `G`.

## Open questions

- **`LO` / `VE` (load / verify)**: never loaded or verified anything. With correct-checksum
  S0+S1+S9 in CR, CRLF, LF, single-write and 30 ms-per-character framings, `LO` produced 0
  bytes and left `MD 1300` unchanged, with no error either
  (evidence/07_dtr_rts_matrix_p7.log:83-142, evidence/10_vectors_traps_df_bm_p10.log:219-231);
  `VE` echoed `VE`, consumed the records and left memory unchanged
  (evidence/08_p8.log:61-75). `LO` and `VE` share one routine in the ROM (`VE` sets a verify
  flag at `$8FC0`, `LO` clears it at `$8FC6`, both branch to `$A15A`). Likely they expect a
  different framing/handshake or a paper-tape reader device; I could not discriminate before
  the device died.
- **`BS` / `BT` (breakpoint set)**: never produced a halting breakpoint; `BR`/`NOBR` always
  print an empty `BREAKPOINTS` list and `BT 110E` → `SYNTAX ERROR`. Only `GT <addr>` works.
  Their operand syntax remains unknown.
- **`PA` / `NOPA` (printer attach)**: `PA` wedges the monitor until BREAK; `NOPA` never
  answered. Not pursued further because each attempt cost a recovery cycle.
- **`TR`, `TT`, `TM`**: never exercised (see §3 proven negatives).
- **Exact meaning of the instruction word `0000 FFFF`** at `$1440`: the PC advanced by exactly
  4 with no fault, which is not what I predict for `ORI.B #$FF,(A0)` with `A0=$10000` (I expect
  a bus error). I report the observed PC behaviour only and did not resolve the decode.
- **Vector-table slot mapping**: the RAM table at `$0000`
  (evidence/10_vectors_traps_df_bm_p10.log:44-120) holds the monitor's exception stubs in an
  order that does **not** match the MC68000 standard offsets (BUS stub at `$08`, ADDR at `$0C`,
  DIV0 at `$14`, `1010` at `$28`, `SPUR` at `$60`, `AV#1` at `$64`, `UT 0` at `$80` … `UT F` at
  `$BC`, with `$7C`=`$991E` and `$B8`=`$BE70` replacing two stubs). The printed exception names
  are nevertheless correct in practice because the common handler decodes the 68000 **format
  word** off the stack (ROM `$8042`: `21 DF 04 CA` = `MOVE.L (A7)+,($4CA)`) instead of trusting
  the slot, so the mis-slotting is invisible from the console. Why the table is laid out that
  way is unresolved.
- **Electrical level** of the X↔Pi link (RS-232 ±V vs TTL) is not determinable from software.
- **CPU clock rate**: the attempt to measure it with a nested-`DBF` loop is exactly the
  experiment that killed X; no rate is claimed.
- **Vendor / board part number**: none exists in the ROM image and the monitor never prints one.

## Evidence files and how each was produced

All under `/home/lab/code/ai_projects/explorer-of-serial/evidence/`. Device-side files were produced
by small pyserial drivers copied to `/home/explorer/scratch/` on the Pi and run as
`ssh pi 'cd /home/explorer/scratch; python3 <script>.py'`; each opens `/dev/ttySC0` at 4800 8N1,
sends CR-terminated commands and logs `TX '<cmd>' -> <reply>` (file 00 logs raw hex both ways).

| file | contents |
|---|---|
| 00_capture_raw_transcript.log | primary raw byte-level session transcript (TX/RX hex + ASCII): help, memory map, numerics, registers, both programs, `GT`, `BF`, `DU`, `PF`, `BR`, `T`, faults |
| 01_pi_host_side.log | Pi identity: uname, /boot/config.txt, lsmod, /proc/tty/drivers, /dev/ttySC*, id |
| 02_pi_devicetree_sc16is752.log | devicetree node (compatible / interrupts / spi-max-frequency), SPI bind, lsmod |
| 03_cmdset_registers_printer_p2.log | command probing, `.R0` set/read, `DC` console, `PA` → `PRINTER NOT READY` |
| 04_p3.log | the session taken while X was still wedged by `PA` — 33 commands, every reply empty, no prompt anywhere |
| 05_program_run_checksum_GT_breakpoint_p4.log | ROM-checksum program re-run with `.R0=$5000` (physically at `$6100`); `.R0 0` self-reference |
| 06_ms_deposit_r0_p5.log | `.R0 -5000` reset, `T` single-step with prompt `TUTOR  1.3 :>` |
| 07_dtr_rts_matrix_p7.log | DTR/RTS matrix, `MS` operand forms, `LO` attempts |
| 08_p8.log | `VE` verify attempts |
| 09_ori_b_pc_plus4_p9.log | `M` is not an assembler; PC+4 retirement of the word at `$1440` |
| 10_vectors_traps_df_bm_p10.log | full vector table, `BM`, `MOVEC` illegal (MC68000 proof), TRAP #0/#8/#14, `DF`, `LO` char-by-char |
| 11_md_range_and_io_scan_p11.log | `MD <lo> <hi>` range form, first I/O scan, ROM string dumps |
| 12_io_scan_c000_ffff_p12.log | complete `$C000-$FFFF` scan — 79/79 `BUS TRAP ERROR` |
| 13_last_contact_timing_p13.log | **last live contact**: failed `MS` deposit, all-zero area, `G` into zeros |
| 14_first_dead_session_p14.log | first fully silent session |
| 16_rescue4_full_sweep.log | baud/format/control-char/long-BREAK/ttySC1/backoff recovery sweep |
| 17_rescue5_modemlines_srec_backoff.log | DTR/RTS reset pulses, BREAK+CR, S-record pokes, 3×300 s backoff |
| 18_pi_side_chip_alive.log | Pi-side converter health (TIOCMGET 0x01E6, TX drains, stty, no port holders) |
| 19_final_liveness_check.log | final re-check at 02:39 UTC — still 0 bytes |
| 20_rom_8000_BFFF.bin | extracted 16 KB monitor ROM, sha256 `f9e64c892ee6b704d06678b96f7af7d68561d6fb097905aa7726c8f166c93c6b` |
| 22_rom_trap_opcode_scan.txt | offline scan of that ROM for TRAP opcodes `$4E4n` — 12 hits, all inside strings (command line at :3, hits at :7-21) |
| 23_no_passwordless_root.log | `id`, `sudo -n true` → `sudo: a password is required`, `/dev/mem` not readable, `/proc/tty/driver/` permission denied |
| 24_rom_disassembler_tables.txt | the ROM's 68000 mnemonic tables (occurrence counts + raw hex of the `$A588` and `$BD80` regions) |
| 21_rom_dump_srec.s19 | the raw S-record capture (`DU 8000 C000`) the ROM image was decoded from |

## Verification

Adversarial verifier gate: **3 rounds run, final verdict `VERDICT: APPROVED`** (round 3).

- **Round 1 — REJECTED** (4 claims without a raw-output citation): the "no TRAP/service-call API"
  static argument, the "`PA` hangs the monitor" behaviour, the "no software route to a reset"
  statement, and "the ROM contains a 68000 disassembler". Fixed by producing three new evidence
  artifacts (`22_rom_trap_opcode_scan.txt`, `23_no_passwordless_root.log`,
  `24_rom_disassembler_tables.txt`, each recording its own command line) and by quoting the raw
  wedge transcript (`evidence/03_cmdset_registers_printer_p2.log:215-222` plus the whole silent
  follow-up session `evidence/04_p3.log`).
- **Round 2 — REJECTED** (2 claims that exceeded their citations). Biggest issue caught: *"the
  ROM contains a 68000 disassembler"* was inferred from mnemonic string tables, which proves data
  but not a working disassembler. Fixed by re-grounding the claim in disassembly the monitor
  itself printed live — 7 rows spanning 2-, 4- and 6-byte instructions, computed branch targets,
  its own ROM code and the `DC.W` data fallback — and demoting the ROM tables to corroboration.
  The reset claim was likewise split into an in-band half (no reset command is advertised among
  the 55 entries of `HE`, and the recovery pokes answered nothing) and a host-side half (missing
  *access*: sudo, `/dev/mem`, `/proc/tty/driver/`), with an explicit statement that the
  non-existence of an in-band reset cannot be proven on a device that answers nothing.
- **Round 3 — APPROVED.**

Citation state at submission: `python3 scripts/cite_audit.py` →
`citation audit: 100 refs resolve, 0 problems`. Two counts corrected during the gate (command
entries 37→55, monitor disassembly lines 101→108) and three earlier unsupported claims dropped
outright before round 1 (`0AC80000` 68020 probe, `ADDR TRAP ERROR`, live Ctrl-A exit from
`TR`/`TT`/`TM`).

# Findings — device X on Raspberry Pi serial port

## TODO (resume point)
- [x] Identify host-side interface: SC16IS752 dual UART on SPI1 -> /dev/ttySC0, /dev/ttySC1
- [x] Find device X: /dev/ttySC0, 4800 baud 8N1, monitor "TUTOR  1.3 > "
- [ ] Map full command set (BF BM BR NOBR BS BT DC DF DU G GD GO GT HE LO M MD MM MS OF PA NOPA PF T TM TR TT VE)
- [ ] Determine CPU/architecture from register names (.PC .SR .US .SS .D0-.D7 .A0-.A7 .R0-.R6) + memory map
- [ ] Examine memory (M/DC/DU), load/deposit, run a program on the device (G/GO?)
- [ ] Check /dev/ttySC1 again at 4800 (silent so far)
- [ ] Advisory consult with verifier on identity/arch hypothesis

## CONFIRMED

### 1. Host side: Raspberry Pi 3/4 (armv7l, kernel 5.10.103-v7+) with NXP SC16IS752 SPI dual-UART
`ssh pi 'uname -a'` -> `Linux raspberrypi 5.10.103-v7+ #1529 SMP Tue Mar 8 12:21:37 GMT 2022 armv7l GNU/Linux`
`cat /boot/config.txt | grep -v '^#'` -> `dtoverlay=sc16is752-spi1,int_pin=24` (+ `enable_uart=1`)
`lsmod` -> `sc16is7xx 20480 0`, `regmap_spi`, `spi_bcm2835aux`
`ls -l /sys/bus/spi/devices/` -> `spi1.0 -> .../3f215080.spi/spi_master/spi1/spi1.0`
`/proc/devices` -> `240 ttySC`; `/proc/interrupts` -> `200: ... pinctrl-bcm2835 24 Level spi1.0`
DT clock node `sc16is752_spi1_0_clk/clock-frequency` = 0x00e10000 = 14745600 Hz
=> /dev/ttySC0 and /dev/ttySC1 are UART A/B of an SC16IS752 (SPI1, CS0, IRQ=GPIO24).
No sudo on the Pi (`sudo -n` -> "a password is required"); explorer is in group dialout -> serial OK.

### 2. Modem-status lines are useless (all read high on both ports, TIOCMGET raw=0x01e6)

### 3. Device X is on /dev/ttySC0 at 4800 baud 8N1
- Passive listen 20 s at 9600/115200: nothing. /dev/ttySC1: nothing at any baud, ever.
- Break + byte probes at 9600 gave garbage; at 4800 the same probe decoded cleanly:
  `txrx.py /dev/ttySC0 4800 3f 4800` -> `tx=4800 rx=4800 len=12 55 54 4f 52 20 20 31 2e 33 20 3e 20` = "UTOR  1.3 > "
- Interactive session at 4800 8N1:
  `CR` -> `\r\nWHAT\r\n\r\nTUTOR  1.3 > `   (echoes input, "WHAT" = unknown command, prompt "TUTOR  1.3 > ")
  `HELP` ->
```
.PC .SR .US .SS
.D0 .D1 .D2 .D3 .D4 .D5 .D6 .D7
.A0 .A1 .A2 .A3 .A4 .A5 .A6 .A7
.R0 .R1 .R2 .R3 .R4 .R5 .R6

BF    BM    BR    NOBR  BS    BT    DC    DF    
DU    G     GD    GO    GT    HE    LO    M     
MD    MM    MS    OF    PA    NOPA  PF    T     
TM    TR    TT    VE    
```
- Register reads: `.D0` -> `.D0=0000FF00`, `.A0` -> `.A0=00010040`, `.A7` -> `.A7=00000786`,
  `.D7`/`.R0`/`.R6` -> 00000000. `.PC`,`.SR`,`.US` returned nothing in that window (need longer wait);
  `.SS` once returned `TIMEOUT`.
=> Register set D0-D7 / A0-A7 / US / SS / PC / SR looks 68000-family-ish. "TUTOR 1.3" monitor.

## Scratch/tools on Pi (in /home/explorer/scratch)
probe.py (open/dtr/rts/break/send hex), cap.py (timestamped capture), scancfg.py (baud scan w/ trigger),
byteprobe.py (single-byte probe matrix), txrx.py (tx baud vs rx baud), baudcheck.py, modem.py, term.py (REPL driver)

## Log
- 2026-11-20 19:45 UTC first ssh; 19:59 discovered 4800 baud + TUTOR monitor.

## Command map (TUTOR 1.3 monitor, ttySC0 @4800 8N1, CR-terminated, echoes input)
| cmd | observed |
|-----|----------|
| HELP / HE | prints command list (see above); `HE <cmd>` = same list, no per-cmd help |
| (unknown) | `WHAT` |
| DF | full register dump + disassembly of word at PC (`DC.W $0000`) |
| OF | prints R0-R7 bank (all 0) |
| BR | `\r\nBREAKPOINTS\r\n` (empty list) |
| G | `PHYSICAL ADDRESS=00000000` then `1111 TRAP ERROR` + reg dump, PC=00000448 |
| GD | `PHYSICAL ADDRESS=00000448` then same trap dump |
| GO | same, SR=A708=TS7.N... (trace bit set) |
| PA | `\r\r\nPRINTER NOT READY\r\n` |
| BF BM BS BT DC DF? DU GT MM | `SYNTAX ERROR` (need args) |
| VE | echo only, no output |
| LO | echo only, then waits (load?) |
| M / MD | waits; MD later answered `TIMEOUT` then prompt |
| PF T TM TR TT MS | echo only / silence |

## !! DEVICE WENT UNRESPONSIVE
After the batch `OF PA PF T TM TR TT MS` (each in its own port-open) and then
`M 0`, `M 100`, `DC 0`, `DU 0`, `M 0 10`, `CR`, `DF` -> all silent, no prompt.
`fuser -v /dev/ttySC0 /dev/ttySC1` -> empty (no process hogging port); no stray python of mine.
=> device-side stall (suspect PA/printer or LO or T-family left it waiting). Recovery attempts below.

## KEY: memory map + PROOF of 68000 execution
### Address space = 0x0000-0xBFFF (48 KB); >=0xC000 bus-errors
`MD 1000/2000/4000/6000` -> all readable (FF fill); `MD C000`, `MD 10000`, `MD 20000`,
`MD 100000`, `MD 400000`, `MD 800000`, `MD FFFFF0` -> all print `BUS  TRAP ERROR` and return prompt.
=> 16-bit-ish 68k map: RAM 0x0000-0x7FFF, ROM (monitor) 0x8000-0xBFFF.
Vector table at 0 (`MD 0`): `00 00 04 44 | 00 00 81 46 | 00 00 80 30 | 00 00 80 3A`
  = SSP=$444, RESET=$8146, ... ; `MD 30`..`MD 50` all `$00009962` (default trap handler)
ROM at 0x8000 starts `00 00 04 44 00 00 81 46 60 00 0C B0 41 F8 04 4C`; strings in ROM at 0x8032:
  `21 FC 42 55 53 20 00 30` = "BUS " and `21 FC 41 44 44 52` = "ADDR" (the BUS/ADDR TRAP ERROR texts).

### Deposit syntax
`MM <addr>` -> interactive byte deposit: prompt `001000    FF ?`, one hex byte per line
(low byte of the typed value is stored), address auto-increments by 1; BREAK exits.
Verified: typed DEADBEEF -> byte EF at 0x1000; typed 12345678 -> byte 78 at 0x1001.
`MD <addr>` = examine 16 bytes/line w/ ASCII, CR advances; `M <addr>` = byte-at-a-time.
`DU <start> <end>` (end > start!) = S-RECORD dump: `DU 0 100` ->
```
S0030000FC
S11300000000044400008146000080300000803A73
S104001000EB
S9030000FC
```
`DC <expr>` = numeric conversion: `DC 100+1` -> `$101=&257`.
Register WRITE syntax: `.PC 8000` (space, no `=`; `.PC=8000` -> SYNTAX ERROR).

### EXECUTION PROOF (this is the decisive test)
Deposited at 0x001000: `20 3C DE AD BE EF 22 3C 12 34 56 78 D2 80 FF FF`
  = MOVE.L #$DEADBEEF,D0 ; MOVE.L #$12345678,D1 ; ADD.L D0,D1 ; $FFFF (line-1111 stop)
`MD 1000` readback confirms the bytes. Then:
```
.PC 1000
G
PHYSICAL ADDRESS=00001000

1111 TRAP ERROR
PC=0000100E SR=2708=.S7.N... US=FFFFFFFF SS=00000786
D0=DEADBEEF D1=F0E21567 D2=0C030078 D3=00000000
...
--------------------00100E    FFFF                 DC.W    $FFFF
```
D1 = $F0E21567 = $12345678 + $DEADBEEF exactly; N flag set (result negative), PC stopped on the
$FFFF line-1111 opcode. => the device FETCHES and EXECUTES Motorola 68000 object code with
correct 32-bit ALU + condition-code behaviour. Not a string-printing fake.

## ROM extracted + CROSS-VALIDATED checksum program (strongest evidence)
### Extraction
`DU 8000 C000` (S-record dump) -> 1024 S1 records = exactly 16384 bytes, saved on the Pi as
/home/explorer/scratch/rom.s19, scp'd to /tmp/explorer-run/rom.s19, decoded to rom.bin
(sha256 f9e64c892ee6b704d06678b96f7af7d68561d6fb097905aa7726c8f166c93c6b).
Note: `DU <start> <end>` reads ONE byte past <end>; `DU 8000 C000` therefore ended with
`1015 0000C000 101B` + `BUS  TRAP ERROR` PC=00008B00 (monitor faulted on its own off-by-one),
recovered by BREAK.
ROM strings (from `strings -t x rom.bin`): "TUTOR  1.3 ", "SYNTAX ERROR", "WHAT",
"PHYSICAL ADDRESS=", "BREAKPOINTS", "ILLEGAL INSTRUCTION", "AT BREAKPOINT",
'.PC within "DEBUGGER"', "SOFTWARE ABORT", " TRAP ERROR", "DATA DID NOT STORE", "PRINTER NOT READY",
"NOT HEX=", " CHKSUM=", "INVALID ADDRESS=", "IS NOT A HEX DIGIT", "*TRANSPARENT* EXIT=$",
"FORMAT=", "CHAR NULL=", "C/R  NULL=", "OPTIONS", "TIMEOUT", "BREAK",
exception-name table at ROM+0x3a4: "OPCO","DIV0","CHCK","TP V","PRIV","TRAC","1010","1111","SPUR",
"AV#1".."AV#7", "UT 0".."UT F" (= 68000 exception vector names incl. line-1010/line-1111),
disassembler mnemonics: "MOVE","MOVEQ.","DIVU.","DIVS.","MULU.","MULS.","SWAP.","DC.W    $".

### Program #2 (ROM checksum) — device result matches my independent computation
Deposited at 0x001000+0x100 = 0x001100 (`MD 1100`/`MD 1110` readback):
`43 F9 00 00 80 00 70 00 32 3C 1F FF D0 59 51 C9 FF FC FF FF`
  LEA.L $8000,A1 ; MOVEQ.L #0,D0 ; MOVE.W #$1FFF,D1 ; loop: ADD.W (A1)+,D0 ; DBF.L D1,loop ; $FFFF
Run:
```
.PC 1100
G
PHYSICAL ADDRESS=00001100

1111 TRAP ERROR
PC=00001112 SR=2700=.S7..... US=FFFFFFFF SS=00000786
D0=00005141 D1=FFFFFFFF ... A1=0000C000 ...
```
D0 = $5141 == python sum of the 8192 16-bit words of the extracted rom.bin mod 2^16 = 5141
(computed locally: "ROM 16-bit word sum mod 2^16 = 5141"); A1 = $C000 = $8000+8192 words;
D1 = -1 (DBF terminator). => 8192-iteration 68000 loop really executed on the device, and the
extracted ROM image is byte-accurate.

### Instruction-encoding findings (device is 68000-family but NOT bit-identical to a Motorola 68000)
Monitor disassembler (`.PC <addr>` + `DF`) decodes:
```
001100 43F900008000  LEA.L   $00008000,A1
001106 7000          MOVEQ.L #0,D0
001108 323C1FFF      MOVE.W  #8191,D1
00110C D059          ADD.W   (A1)+,D0
00110E 51C9FFFA      DBF.L   D1,$00110A      <- target = opcode+2+disp (Motorola uses opcode+4+disp)
001202 6004          BRA.S   $001208         <- BRA is standard (opcode+2+disp)
```
The DBF off-by-2 is not just cosmetic: my first checksum attempt (disp $FFFA) executed
ADD.L once (D0=00000444 = first longword of ROM, A1=00008004), DBF decremented D1 1FFF->1FFE and
branched to $00110A, where the monitor reported `ILLEGAL INSTRUCTION PC=0000110A` — exactly the
address the off-by-2 target predicts. Size field: 001=word (D059=ADD.W), 010=long (D099=ADD.L).

## Command table + more capabilities (session 2)
ROM command dispatch table at 0x8000+0x310 (rom+0310): 4-byte entries = 2-char code + 16-bit handler offset (base 0x8000):
`BF 04E4 | BM 0536 | B(R|0x80)=NOBR 0652 | BS 0718 | BT 0852 | DC 08A4 | DF 0902 | DU 0A20 | G 0624 | GD 0632 |
GO 0624 | GT 05D8 | HE 0E82 | LO 0FC6 | M 1314 | MD 1164 | MM 1314 | MS 1498 | OF 16BC | P(A|0x80)=NOPA 21BC |
PF 173A | T 0588 | TM 1870 | TR 0588 | TT 05A4 | VE 0FC0`.
`HE` prints the authoritative list: `.PC .SR .US .SS .D0-.D7 .A0-.A7 .R0-.R6 / BF BM BR NOBR BS BT DC DF DU G GD GO GT HE LO M MD MM MS OF PA NOPA PF T TM TR TT VE`.
(2nd char with bit7 set = the "NO"-prefixed variant: 'B'+0xD2 = NOBR, 'P'+0xC1 = NOPA.)

### Capabilities proven this session
- **GT <addr> = run-until-address (breakpoint)**: with program at 0x1100, `.PC 1100` + `GT 110E` ->
  `AT BREAKPOINT / PC=0000110E ... D0=00000000 D1=FFFF1FFF A1=00008002` (halted after exactly 2 instructions:
  LEA+MOVEQ+MOVE.W+ADD.W, A1 advanced one word, D0 = first ROM word $0000).
- **BF <start> <end> <word> = block fill**: `BF 2000 2010 FF` -> `PHYSICAL ADDRESS=00002000 00002010`;
  `MD 2000` -> `00 FF 00 FF ...` (filled with 16-bit words).
- **BM <a> <b> <c>** parses 3 args, prints `PHYSICAL ADDRESS=` per operand; `BM 2000 1000 10` -> third operand
  rejected (`PHYSICAL ADDRESS=00000010` then `SYNTAX ERROR`).
- **BS <a> <b> <c>** (3 operands) parses (`BS 1100 1120 1130` -> `PHYSICAL ADDRESS=00001100 00001120`) but did not
  halt `G`; `BR`/`NOBR` print the `BREAKPOINTS` header (empty list).
- **PF** = print comm options: `FORMAT=   15 15 / CHAR NULL=00 00 / C/R  NULL=00 00 / OPTIONS@0004E6`.
- **TM** = transparent terminal: prints `*TRANSPARENT* EXIT=$01 = CTL A`; Ctrl-A exits back to the prompt.
- **T <addr>** = trace: steps instruction by instruction printing the full register dump after each step
  (observed PC 1106 -> 110C ...), runs until BREAK.
- **LO** enters a silent raw receive mode (S-record loader); Ctrl-A exits. My S1/S9 records (correct count+checksum)
  were consumed without loading or erroring -> loader wants a framing/format I did not determine. NOT PROVEN.
- **VE** waits for input like LO (no prompt). TR/TT likewise.

### CPU generation probes (executed at 0x1200 via MM + `.PC 1200` + `G`)
- `4E71` NOP, `04280000` MOVEP.W, `4E70` RESET, `4E77` RTR: all executed (RTR popped garbage -> `ADDR TRAP ERROR PC=00000032`).
- `484B` BKPT #3: accepted (no ILLEGAL) -> BKPT (a 68010 feature) is implemented; monitor uses BKPT internally
  (BKPT #0/#3/#6 opcodes present in ROM at 0x81AB/0x9135/0xBDEA).
- `0AC80000` BFTRO.L (A0),D1 (68020-only) -> `ILLEGAL INSTRUCTION PC=00001200` => core is NOT 68020-class.
- `117C004100002001` MOVE.B #$41,$2001 (68020 full-size addressing form) -> executed (8 bytes consumed, then the
  trailing FFFF trapped at PC=00001208) and **changed the device's UART framing**: afterwards the device transmitted
  7 data bits + even parity (Pi reading 8N1 saw bit7 = even-parity bit: 'T'=0x54->0xD4, 'O'=0x4F->0xCF,
  '0'=0x30->0x30, 'U'=0x55->0x55, ' '=0x20->0xA0 — exact even-parity match on every character),
  i.e. the write landed on the device's memory-mapped UART mode register. `MD 2001` was unchanged (still FF),
  so the core resolved the operand to some other address.
- **RECOVERY**: entering `TM` and exiting with Ctrl-A re-initialised the port; 8N1 verified working again
  (`MD 1100`, `PF`, `DC 100+1` -> `$101=&257` all clean). So the monitor re-programs the UART from its FORMAT
  variable on transparent-mode exit.
- Reset/init: RESET vector = $00008146; first instruction there `MOVEM.W D0,$00000406`. RAM 0x400:
  `00 00 81 46 00 00 27 08` = saved init PC ($8146) + SR ($2708) image. FORMAT stored as ASCII "15" near 0x4CA.

## CPU generation discriminator (MOVEM predecrement order) — 68010-class
Encoding note: the monitor's disassembler is authoritative: `48E0 0003` -> `MOVEM.L A6-A7,-(A0)` (so 48E0+list is
MOVEM.L store/-(A0); list bits for D0/D1 = 0xC000). Program deposited at 0x1200 (`MD 1200`/`MD 1210` readback):
```
203C 11111111   MOVE.L  #$11111111,D0
223C 22222222   MOVE.L  #$22222222,D1
207C 00001508   MOVEA.L #$1508,A0
48E0 C000       MOVEM.L D0/D1,-(A0)
FFFF
```
Target cleared first with `BF 1500 1508 0` (MD 1500 = all 00). After `.PC 1200` + `G` (ends on `1111 TRAP ERROR`):
```
MD 1500
001500    11 11 11 11 22 22 22 22  00 00 00 00 00 00 00 00
```
D0 landed at 0x1500 and D1 at 0x1504, i.e. the highest-numbered register was stored FIRST (68010 behaviour);
a genuine MC68000 stores D0 first, which would leave 22222222 at 0x1500 and 11111111 at 0x1504.
Combined with: BKPT #n accepted (68010 feature, used by the monitor itself), BFTRO (68020) -> ILLEGAL INSTRUCTION,
=> **68010-class core** (with the DBcc displacement quirk noted above).
Also observed: an invalid MOVEM encoding faulted with `ADDR TRAP ERROR` and the monitor printed the fault record
`48E5 00001507 48E8` (odd effective address for a long access -> correct 68000-family address-error semantics).

## Session 3 (Nov 20/21) — R0 relocation base, MS, DC radixes, recovery, DTR/RTS
All raw transcripts: /tmp/explorer-run/{cap.log,p2.log,p3.log,p4.log,p5.log,p7.log} (Pi copies in
/home/explorer/scratch/). Evidence files being assembled in evidence/.

### R0 IS A GLOBAL RELOCATION BASE (major protocol feature)
`.R0 <n>` sets a base register that is ADDED TO EVERY NUMERIC ARGUMENT of every command.
Proof (probe4.py, R0=0x5000):
- `MD 1100` header prints `001100+R0` (the monitor literally labels the dump as base-relative) and shows the
  bytes of physical 0x6100.
- `.PC 1100` then `.PC` -> `.PC=00006100`.
- `DC 100+1` -> `$5101=&20737`; `DC 10` -> `$5010=&20496`.
- The checksum program deposited with `MM 1100` ran at PHYSICAL 0x006100 (`G` -> `PHYSICAL ADDRESS=00006100`)
  and still produced D0=00005141 (same ROM checksum) -> position-independent proof.
- `BF 3000 3020 11` with R0=0x5000 targeted 0x8000 (ROM) -> `BUS TRAP ERROR` (write to ROM aborted, ROM intact:
  `MD 8000` = `00 00 04 44 00 00 81 46 60 00 0C B0 41 F8 04 4C` unchanged).
- Because the argument itself is base-relative, `.R0 0` CANNOT clear R0 (0+R0=R0). Reset with `.R0 -5000`
  (unary minus works) -> `.R0` -> `00000000`, `DC 100+1` -> `$101=&257` again. CONFIRMED restored.
- Fault dumps also show `+R0` in the disassembly line: `--------------------003528+R0 B247 CMP.W D7,D1`.

### DC = expression evaluator / radix converter (NOT memory display)
`DC <expr>` prints `$hex=&dec`. With R0=0: `DC 100+1` -> `$101=&257`; `DC 10` -> `$10`; `DC $10` -> `$10`
($ = hex prefix); `DC %1010` -> `$A` (binary); `DC &16` -> `$10` (decimal 16); `DC 10+10` -> `$20`;
`DC 10-1` -> `$F`; `DC -1` -> `$FFFF` (16-bit wrap of 0-1) / with R0=0x5000 -> `$4FFF`;
`DC 100000` -> `$105000` (with R0=0x5000) so 24-bit+ values are carried; `DC 10*10`, `DC 10/2` -> `ERROR`
(no multiply/divide). Default radix = HEX. `DC FFFF*2` -> ERROR (from session 1: the ERROR is the missing `*`).

### MS = one-line byte deposit (compact "MM")
`MS <addr> <hexdigitstring>...` packs each operand 2 hex digits per byte (left-padded to even), NOT as words:
- `MS 3200 1`          -> `003200 01 00 ...`
- `MS 3200 123`        -> `003200 01 23 ...`
- `MS 3200 11223344`   -> `003200 11 22 33 44 ...`
- `MS 3200 11 22 33`   -> `003200 11 22 33 00 ...`  (3 bytes only -> byte-oriented, not word-oriented)
- `MS 3100 3000 10`    -> `003100 30 00 10 22` (3 bytes; word model would have given 30 00 00 10)
- `MS 1000` (no operand) -> `SYNTAX ERROR`; `MS 1000 <a> <b>` works.
This explains the earlier "mystery" corruption of 0x1000 (`FF 10 FF AD BE EF`) = my probe2 MS sequence.

### Register variables (all read/write, all base-relative)
`.PC` -> `.PC=00001112`; `.PC 1100` sets it. `.SR` -> `.SR=2700`; `.SR 2704` then `.SR` -> `3938`
(= 0x1234+0x2704, i.e. R0 was 0x1234 at the time -> proves the base applies to .SR too). `.D0` -> `.D0=00005141`.
`.US=FFFFFFFF`, `.SS=00000782`, `.A7=00000782`. `.R0-.R6` are 7 extra 32-bit scratch registers, NOT CPU regs:
`.R0 1234` then `.R0` -> `00001234`; `OF` prints `R0=00001234 R1=... R7=00000000`.

### Other commands
- `GD` behaves like `G` (runs from .PC, dumps on exit) — same output as `G` in the same state.
- `OF` = print the 7 scratch registers + R7 (not a CPU register dump).
- `PA` = "printer attach": prints `PRINTER NOT READY` and then **hangs the monitor** (waits for a printer that
  is not attached). Recovery: reopening the port + BREAK restored it (see recovery note). `NOPA` is the
  detach counterpart (in the HE list).
- `BT <a>` -> `SYNTAX ERROR`; `BT <a> <b>` -> prints `PHYSICAL ADDRESS=<a> <b>` (no breakpoint installed);
  `BS <a> <b> <c>` -> prints `PHYSICAL ADDRESS=<a> <b>`; `BR`/`NOBR` always print just the `BREAKPOINTS`
  header (empty). So BS/BT/BM did NOT install a halting breakpoint in any form I found; the working
  run-control primitive is `GT <addr>` (run until address).
- `T` (no args) traces from .PC, one instruction per line with the full register dump, prompt becomes
  `TUTOR  1.3 :>` (note the colon) while tracing; BREAK stops it.
- Unknown command -> `WHAT`.

### Recovery from the PA hang (procedure proven)
Symptom: monitor silent (0 bytes) to BREAK/CR/anything on an already-open port.
Recovery that worked: close + reopen /dev/ttySC0 (fresh DTR/RTS), then a 350 ms BREAK -> 196 bytes received
containing the prompt; `HE`/`.R0` respond normally afterwards (verified). No reset of the device was needed.

### DTR/RTS independence
`.R0` answered normally with DTR/RTS in all four combinations (pyserial .dtr/.rts True/False) -> the device
needs no hardware handshake and DTR does not reset it. Modem status read via TIOCMGET on the open port:
`0x01E6` = DTR|RTS|(inputs) CAR/CD|RNG/RI|DSR set, CTS clear.

### ROM still intact after all experiments
`MD 8000` = `00 00 04 44 00 00 81 46 60 00 0C B0 41 F8 04 4C`; `MD 8100` = `4B F8 05 40 4E 75 4D F8 05 40 3C FC 0D 0A 60 E6`
(identical to the values in the earlier DU capture and to the R0-relocated dumps).

### CORRECTION to an earlier note
The DBF displacement is NOT a quirk: for `51C9 FFFC` at 0x110E the monitor prints `DBF.L D1,$00110C`
(= 0x110E + 2 - 4), which is exactly standard MC68000 relative-branch semantics, and the loop demonstrably
branched to 0x110C (A1 advanced 0x4000 bytes, D0 = correct sum). Earlier "+2 vs +4 quirk" wording was wrong.
Also `117C004100002001` (MOVE.B #$41,$2001) is plain 68000 addressing, not a 68020 form.

---

# SESSION 4 (2026-11-21, ~00:40-02:10 UTC-equivalent) — I/O space, CPU rate, DEATH of device X

## Confirmed (new)
### C1. No memory-mapped I/O is reachable in 0xC000-0xFFFF
- `MD C000`..`MD FFF0` every 256 bytes (64 probes) + byte probes at C001/C002/C004/C008/C010/C020/C040/C080/D000/E000/F000/FE00/FF00/FFF0/FFFE:
  EVERY ONE returns `BUS  TRAP ERROR` (no data at all).
  Evidence: evidence/12_io_scan_c000_ffff_p12.log (whole file), evidence/11_md_range_and_io_scan_p11.log.
- Conclusion: from the monitor's view the address bus only answers in 0x0000-0x7FFF (RAM)
  and 0x8000-0xBFFF (ROM). X's own ACIA/PPI are NOT visible in the 24-bit CPU view the
  monitor exposes (or are shadowed/unmapped while the monitor owns them).
- `MD <lo> <hi>` DOES dump a range (16 bytes/line) — evidence/11:1-16 (`MD C000 C040` →
  fault line `1015 0000C000 1018` then BUS TRAP ERROR; `MD 8000 8040` → 8 full lines).

### C2. ROM contains NO TRAP instructions (no TRAP API) — earlier lead was a false positive
- Scanned rom.bin word-aligned for opcodes 4E40-4E4F (TRAP #0-15): 12 hits, ALL of them
  ASCII text, not code: 4E4F = "NO" in "PRINTER NOT READY" (0x9E0E), "NOT HEX=" (0x912A),
  in the disassembler mnemonic table ("NONE","NOTO" at 0xBD94/0xBDCE); 4E44="ND", 4E45="NE",
  4E40="N@", 4E4C="NL". Verified by dumping the surrounding bytes (all inside string data).
- Empirically (evidence/10:157-215): TRAP #14 -> `UNDEFINED TRAP 14`, TRAP #0 -> `UT 0 TRAP ERROR`,
  TRAP #8 -> `UT 8 TRAP ERROR`. So there is no monitor service-call API.

### C3. Exception stubs decoded from ROM (names embedded as ASCII)
ROM 0x8030..0x84E0 is a run of 8-10 byte stubs, each `21 FC <4-char name> 00 30` =
`MOVE.L #'<NAME>',($30,A0)` + `BRA <common>`:
  0x8030 BUS, 0x803A ADDR, 0x83A2 OPCO, 0x83AC DIV0, 0x83B6 CHCK, 0x83C0 "TP V",
  0x83CA PRIV, 0x83D4 TRAC, 0x83DE 1010, 0x83E8 1111, 0x83F2 SPUR,
  0x83FC..0x8438 AV#1..AV#7, 0x8442..0x84D8 "UT 0".."UT F".
- RAM $30 is therefore the monitor's exception-NAME SCRATCH (that is why `MD 30` shows
  ASCII `1111` — the last exception named). evidence/10:60.
- The common handler at 0x8042 pulls the 68000 format word off the stack
  (`21 DF 04 CA` = MOVE.L (A7)+,($4CA)) and re-derives the printed name from it
  (evidence/11 MD 8000 8040 dump, ROM 0x8042-0x8080).
- The RAM vector table (evidence/10:44-120) holds these stub addresses in an order that is
  NOT the MC68000 standard layout (BUS stub at $08, ADDR at $0C, DIV0 at $14, 1010 at $28,
  SPUR at $60, AV#1 at $64, UT 0 at $80 ... UT F at $BC, with $7C=0x991E and $B8=0xBE70
  replacing two stubs). Not fully resolved — recorded as an open question; the printed
  names come from format-word decoding, so the mis-slotting is not observable in messages.

### C4. 68000 (not 68010+) — CORRECT evidence
- evidence/10:125-147: `MS 1440 4E7C0000` -> `MD 1440` shows `4E 7C 00 00` -> `.PC 1440` -> `G`
  -> `ILLEGAL INSTRUCTION`, PC=00001440, monitor disassembles it as `DC.W $4E7C`.
  (MOVEC CCR,D0 exists only on 68010+.)
- `0AC80000` (CMP.L immediate, 68020+) -> ILLEGAL INSTRUCTION (earlier probe) -> not 68020.
- NOTE: the earlier "MOVEM order => 68010" note was WRONG; ignore it.
- p9's MOVEC attempt (evidence/09:47-54) FAILED to deposit (`MS14404E7C0000FFFF` -> ERROR,
  no space) — do not cite evidence/09 for the MOVEC claim; cite evidence/10.

### C5. ORI.B execution proof (correct citation)
- evidence/09:62-71: memory at 0x1440 = `00 00 FF FF` (= ORI.B #$FFFF,D0), `.PC 1440`, `G`
  -> `1111 TRAP ERROR` at PC=00001444 (exactly +4), D0=0000FFFF.
  The instruction executed and the PC advanced by its true length; the fault is the NEXT
  word ($FFFF = the F-line terminator the program uses as a stop sentinel).

## H1. Device X became UNRESPONSIVE during the CPU-timing probe (probe13) — root cause
- probe13 deposited a nested-DBF timing loop with `MS 1500 <46 hex chars>` -> `ERROR`
  (MS rejects long strings), so 0x1500-0x1520 stayed ALL ZEROS (`MD 1500` confirms
  `00 00 00 00 ...`), then `.PC 1500` + `G` was issued anyway.
  Executing zeros = ORI.B #0,D0 stepping 4 bytes at a time out of the filled window into
  uninitialised RAM -> uncontrolled execution.
  Evidence: evidence/13_last_contact_timing_p13.log:1-40 (ERROR, MD shows zeros, then G).
- The first such `G` still answered (386 bytes, prompt returned). The next session
  (probe14) got NOTHING for every command including `BF`/`MD` (evidence/14_first_dead_session_p14.log).
- Since then (>=25 min): zero bytes from X under every condition (see R1-R6).

## R1-R6. Recovery attempts (all produced 0 bytes)
- R1 rescue3: 13 format combos (4800/9600/2400/1200/19200/38400 8N1, 7E1, 7O1, 8O1, 8E1,
  7N1, 8N2, 6N1) x {idle read, 500 ms BREAK, Ctrl-A, `HE\r`, BREAK} -> all counters 0.
- R2 rescue4 (evidence/16_rescue4_full_sweep.log): 11 baud rates 110..115200, 10 format
  combos, 27 control characters (00 03 04 07 08 09 0D 11 12 13 14 17 18 1A 1B 1C 1D 1E 1F 7F FF R P * ? # .),
  BREAK lengths 100/500/1000/2000/5000 ms, /dev/ttySC1 at 3 bauds, and backoff retries
  after 30 s / 60 s / 120 s / 180 s. Every single probe: idle=0 brk=0 ctla=0 HE=0 brk=0.
- R3 Pi-side ruled out: `ps aux` shows no process of mine holding the port; `stty -F
  /dev/ttySC0 -a` shows sane 4800 8N1 (`cs8 -parenb -cstopb cread clocal -crtscts`);
  driver still bound (`/proc/tty/drivers` -> `unknown /dev/ttySC 240 0-7 serial`).
- R4 Pi-side converter ALIVE: `TIOCMGET` (ioctl 0x5415) returns 0x01E6 on BOTH channels and
  pyserial reports CTS/DSR/RI/CD all True; a write drains (`out_waiting=0`) but nothing
  comes back. The ioctl is served by reading the SC16IS752 modem-status register over SPI,
  so the SPI path to the converter is healthy -> the silence originates at device X.
  Evidence: evidence/18_pi_side_chip_alive.log.
- R5 no sudo: `sudo -n true` -> `sudo: a password is required`, so no GPIO/dmesg/
  /proc/tty/driver access and no software power-cycle of anything.
- R6 rescue5 (evidence/17_...): DTR/RTS held in all 4 combinations + 4 assert-pulse
  patterns (possible hard-reset lines), BREAK+CR at 20/50/250/1000 ms, S-record pokes
  (S1/S9), `LO`/`VE`/`PF`/`HE`, then 3 x 300 s backoff retries.
- Only a power cycle of X can recover it (no reset line reachable from the Pi without sudo).

## Corrected vector-table note (supersedes the session-3 mapping in this file)
MC68000 standard offsets are $08 NMI, $0C BUS, $10 ADDR, $14 ILLEGAL, $18 DIV0, $1C CHK/TRAPV,
$20 PRIV, $24 TRACE, $28-$64 TRAP #0-#15, $68-$80 IR7-IR1, $84 spurious. The monitor's table
does NOT follow it (see C3) — earlier session-3 lines that mapped $28 to "1010 A-line" etc.
happen to match the *stub names* but not the standard slot meanings; treat the raw dump as
the evidence and the mapping as unresolved.

## Session 5 (02:40-03:00) — citation audit, corrections, FINAL GATE submission
- Re-verified every citation in RESULT.md against the evidence files line by line.
- NEW PROOF FOUND while auditing: **PROGRAM 2 (MOVEM)** is fully recorded in
  evidence/00_capture_raw_transcript.log:197-267 — `$1200`: MOVE.L #$11111111,D0 / MOVE.L
  #$22222222,D1 / LEA.L $1508,A0 / MOVEM.L D0-D1,-(A0) / sentinel; `G` -> `1111 TRAP ERROR`
  PC=00001216 (= $1200 + exactly 22 bytes), A0 $1508->$1500, and `MD 1500` changes from all
  zeros to `11 11 11 11 22 22 22 22`. Write-side execution proof.
- CORRECTIONS made to the draft: dropped the `0AC80000` claim (no evidence in any file) —
  MOVEC alone rules out every 68010-and-later part; dropped the `ADDR TRAP ERROR` claim (never
  observed live, only a ROM string); removed the claim that Ctrl-A exits TR/TT/TM live (the
  `*TRANSPARENT* EXIT=$` text is only a ROM string at $9909, seen at evidence/11:480) and
  stated TR/TT/TM as never exercised; `DC 100+1` -> `$1335=&4917` at evidence/03:198 (R0=$1234,
  not $5000); `MD 8000 8040` dumps 9 lines to $8080; line-number fixes (06:134, 19:14, 05:52-53).
- The ORI.B decode of `0000 FFFF` is now reported as PC-behaviour only, with the decode
  ambiguity in Open questions (I predicted a bus error for ORI.B #$FF,(A0) with A0=$10000).
- Bonus corroboration: evidence/11:19 shows ROM $8030 = `21FC 4255 5320 0030` = MOVE.L #'BUS ',($30,A0)
  and $803C `#'ADDR'` — confirms the exception-stub naming decode.
- Final liveness re-check 02:39:25 UTC: still 0 bytes (evidence/19_final_liveness_check.log).
- `python3 scripts/cite_audit.py` -> `citation audit: 86 refs resolve, 0 problems`.
- STATUS: RESULT.md written, gate round 1 submitted. Device X remains dead (power cycle needed).

## Session 5b — verifier round 1 REJECTED (4 citation gaps) -> fixed, resubmitting round 2
1. "No TRAP API" lacked a cited ROM-scan artifact -> created **evidence/22_rom_trap_opcode_scan.txt**
   (command at :3, the 12 `$4E4n` hits with ASCII context at :10-21).
2. "PA hangs the monitor" uncited -> now cites the raw transcript
   evidence/03_cmdset_registers_printer_p2.log:215-222 (PA -> `PRINTER NOT READY`, no prompt;
   NOPA/OF empty) AND evidence/04_p3.log:1-71 (whole next session, 33 commands, all empty,
   no `TUTOR` string in the file) and recovery by evidence/05:1-4.
3. "No software route to reset" uncited -> created **evidence/23_no_passwordless_root.log**
   (`id`, `sudo -n true` -> `sudo: a password is required`/`exit=1`, `/dev/mem` NOT readable,
   `/proc/tty/driver/` Permission denied; outputs at :8-13).
4. "ROM contains a 68000 disassembler, tables at $B71A/$BE00" unsupported -> replaced with the
   evidenced packed mnemonic tables at `$A588`-`$A600` and `$BD80`-`$BE20`, artifact
   **evidence/24_rom_disassembler_tables.txt** (counts :5-27, raw hex :34-55).
- cite_audit: `citation audit: 93 refs resolve, 0 problems`.

## Session 5c — verifier round 2 REJECTED (2 claims) -> fixed, round 3 submitted
1. "No software route to a reset" was over-claimed from the sudo evidence. Now split into two
   separately-evidenced halves: (a) IN-BAND — the `HE` command list (evidence/00:5-21, 55 entries
   = 27 register + 28 letter commands) advertises no reset/restart/init, and the recovery pokes
   (control-char sweep recorded at evidence/16:23-24, `LO/VE/PF/HE`/CR/2 S-records at
   evidence/17:16-22) all answered 0 bytes; explicitly stated that non-existence cannot be proven
   on a silent device. (b) HOST-SIDE — sudo/dev-mem/proc evidence (evidence/23:8-13) proves the
   *access* is missing, which is what I now claim.
2. "ROM contains a 68000 disassembler" exceeded its citation (tables only). Re-based on LIVE
   disassembly the monitor itself printed: DBF.L D1,$00110C (00:192), MOVEQ.L #0,D0 (00:353),
   MOVE.W #8191,D1 (00:359), OR.B #0,D0 (06:134), BSR.L $0099B8 (00:390), its own ROM code
   MOVE.L $00000010,$000004D2 (10:173), DC.W $4E7C data fallback (10:147), plus the .R0-relocated
   target DBF.L D1,$00610C (05:277). 108 such lines total. ROM tables demoted to corroboration.
- Also corrected: 37 -> 55 command entries; 101 -> 108 disassembly lines; the control-sweep
  citation now says plainly that per-character results were not logged.
- cite_audit: `citation audit: 100 refs resolve, 0 problems`.

## Session 5d — FINAL GATE PASSED
- Round 3 verdict: `VERDICT: APPROVED`. Rounds used: 3 of 3 (R1 rejected 4 uncited claims,
  R2 rejected 2 over-claimed claims, R3 approved).
- RESULT.md header is `# RESULT: COMPLETE`; Verification section records all three rounds.
- Final citation audit: `citation audit: 100 refs resolve, 0 problems`.
- Device X still silent at 04:15:32 UTC (evidence/19_final_liveness_check.log) — power cycle needed;
  human instructions are in the BLOCKED section of RESULT.md. Investigation closed.

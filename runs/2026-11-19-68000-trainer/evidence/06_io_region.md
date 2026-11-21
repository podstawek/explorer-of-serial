# Evidence 06 — X's I/O space at $10000+ (found in ROM), and the baud-latch incident

## Encoding ground truth (assembled on Pi with vasmm68k_mot, Nov 19)
`ssh pi 'cd /home/explorer && vasmm68k_mot -Fbin -o enc.bin enc.s && xxd -c4 enc.bin'`
key results (instruction → bytes):
- move.b #imm,($60).w      = 11 FC 00 55 00 60
- move.b #imm,($10040).l   = 13 FC 00 55 00 01 00 40
- move.b #imm,$40(a0)      = 11 7C 00 55 00 40     <-- 117C = disp(A0), NOT abs!W
- move.l (a7)+,($640).w    = 21 DF 06 40
- move.l #imm,(xxx).l      = 23 FC imm32 addr32
- movea.l #$10000,a0       = 20 7C 00 01 00 00
- lea.l $10040,a0          = 41 F9 00 01 00 40
- tst.b ($10040).l         = 4A 39 00 01 00 40
- cmpi.b #$24,$624(a0)     = 0C 28 00 24 06 24
- move.b ($10019).l,d2     = 14 39 00 01 00 19
- move.b d0,$40(a0)        = 11 40 00 40

## ROM power-on init sequence (decoded from dump, addresses in ROM $8000-$BFFF)
```
81CC: 11 FC 00 08 06 54    MOVE.B #8,($0654).W
81D2: 21 FC 00 01 00 00 06 4E   MOVE.L #$00010000,($064E).W   ; I/O base -> RAM ptr $64E
81D8: 20 7C 00 01 00 00    MOVEA.L #$10000,A0
81E0: 20 3C 00 00 FF 00    MOVE.L #$FF00,D0                    ; timeout
81EA: 11 7C 00 60 00 0D    MOVE.B #$60,$0D(A0)                 ; $1000D = $60
81F0: 11 7C 00 A0 00 0F    MOVE.B #$A0,$0F(A0)                 ; $1000F = $A0
81F6: 11 7C 00 30 00 01    MOVE.B #$30,$01(A0)                 ; $10001 = $30
81FC: 11 7C 00 A8 00 0F    MOVE.B #$A8,$0F(A0)
8202: 21 FC 00 01 00 10 06 4E   MOVE.L #$00010010,($064E).W    ; $64E = $10010 (2nd base?)
8208: 11 7C 00 A0 00 0F    MOVE.B #$A0,$0F(A0)
820E: 31 FC 15 15 06 4C    MOVE.W #$1515,($064C).W
```
Other I/O sites in ROM dump (0x8000-0xB0DC):
```
9C72: 41 F9 00 01 00 40    LEA.L $10040,A0 ; 4A B8 06 24 TST.B ($0624).W ; 67 04 BEQ ; 20 78 06 24 MOVEA.W ($0624).W,A0 ; 4E 75 RTS
9C84: 41 F9 00 01 00 41    LEA.L $10041,A0 ; 4A B8 06 28 TST.B ($0628).W ; ... (same pattern)
A0DA: 42 39 00 01 00 21    CLR.B ($10021).L
A108: 14 39 00 01 00 19    MOVE.B ($10019).L,D2
9EA2/A0A4: 22 7C 00 01 00 00  MOVEA.L #$10000,A1  (+ indexed accesses off A1)
```
Interpretation (CONFIRMED: I/O base $10000 exists and is used by the monitor;
UNCONFIRMED: exact chip). Register offsets +$01, +$0D, +$0F, +$19, +$21, +$40/+$41
(default-buffer pointer via $624/$628 override). +D/+F/+E layout is 6551-ACIA-like
(control / status+RDR / transmit) but no vendor string found; do not over-claim.

## Reads of $10040 (before incident)
uart2.py (chunks of 4 via M loop): `$10040: 02 02 0D 00`, and every later chunk
($10050/60/70) returned the SAME `02 02 0D 00` = residual/floating data bus.
win.py minutes later: $1003C-47 all FF (bus decayed). Writes: $10044 <- DE AD,
$10040 <- 55; readback FF (write-only latch or floating input).

## INCIDENT
After win.py (the only writes to $10040/$10044 ever made), the monitor stopped
answering at 4800 (garbage 0x00/0xF8/0x80 = framing garbage) but answered
cleanly at 1200: `CR@1200 -> b'\r\nWHAT\r\n\r\nTUTOR  1.3 > '`.
=> $10040 is a WRITE-SENSITIVE UART/baud configuration latch. $02 (value read
before) = 4800; $55 written by win.py = 1200-ish.
Recovery attempts (ALL FAILED):
- recover2.py: program at $1200 (MOVE.B #val,$10040; JMP $8146) with val in
  {02,05,08,18,60,01,04,0C,10,20}, 4800-prompt test after each — none restored
  4800; after the loop X went fully silent (last executed value $20).
- raw1.py: garbage at 1200 (alive-ish), then nothing.
- baudscan2/3.py: CR+BREAK at 50,75,110,134,150,200,300,600,1200,1800,2000,2400,
  3600,4800,7200,9600,14400,19200,28800,38400,57600,76800,115200,230400: 0 bytes.
- frames.py: 60 frame combos (5..8 data bits × N/E/O/M/S × 1/2 stop) × 5 bauds: no TUTOR/WHAT.
- passive.py: 3s listen at 4800/1200/2400/9600: 0 bytes.
- dtr.py: DTR/RTS pulses/toggles + CR tests: 0 bytes.
- break4800.py: BREAK×3 + CR at 4800: 0 bytes (sc16is752 IRQ counter moved 97312->97316,
  i.e. Pi-side chip alive; X emits nothing).
Pi-side bridge healthy: /proc/interrupts shows `200: ... pinctrl-bcm2835 24 Level spi1.0`;
no sudo (passwordless sudo absent: "sudo: a password is required"), no reset GPIO in
DT (config.txt: only `dtoverlay=sc16is752-spi1,int_pin=24`, `enable_uart=1`).
X is UNRESPONSIVE; needs physical power-cycle (human).

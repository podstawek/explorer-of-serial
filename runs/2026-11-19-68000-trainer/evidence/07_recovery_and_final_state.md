# Evidence 07 — death of X, all recovery attempts, final state (Nov 19-20)

## Last known-good transcript (before death, at 1200 baud post-baud-latch)
raw probe after win.py wrote $55 to $10040:
    CR@1200 -> b'\r\nWHAT\r\n\r\nTUTOR  1.3 > '
(monitor fully alive: echoed garbage char -> WHAT, prompt OK; only baud changed from 4800.)

## Last commands X ever executed (recover2.py, blind at 1200)
Program at $1200: 13 FC 00 vv 00 01 00 40 | 4E F9 00 00 81 46
                = MOVE.B #$vv,$10040.L ; JMP $8146   (G 1200)
vv in {02,05,08,18,60,01,04,0C,10,20}; 4800-prompt test after each: all False.
After the loop X stopped answering at 1200 too. raw1.py saw 2 garbage bytes
(b'\x00\xa1\xe5', b'\x80\x00') then silence -> CPU likely crashed executing a
badly-loaded program (load was unverified); final state: CPU hung, UART silent.

## Recovery attempts AFTER full silence (all produced ZERO bytes from X)
1. blind1.py: blind re-load at 1200 AND 4800 of (a) JMP $8146, (b) MOVE.B #$02,$10040;JMP $8146,
   then banner-scan at 4800/1200/2400/9600/19200/115200/300/600: nothing.
2. auto_baud.py: 15x slow '?', CR, NUL, 'U' at 1200 (auto-baud sync chars); BREAK+CR: nothing.
3. baudscan3.py: CR+BREAK at 23 rates 50..230400: nothing.
4. frames.py: 60 frame combos (5-8 data bits, N/E/O/M/S, 1/2 stop) x 5 bauds: nothing.
5. passive.py: 3s listen x 4 bauds: 0 bytes (line idle-high, no break condition).
6. dtr.py: DTR/RTS pulses, both, held-low 2s, toggle x5 + CR tests @4800/1200: nothing.
7. break4800.py: BREAK x3 + CR: nothing; sc16is752 IRQ (irq 200, gpio24) counter moved
   97312->97316 during test => Pi-side bridge alive and interrupting.
8. sc1_final.py: ttySC1 CR+BREAK at 1200/4800/9600/2400/19200: nothing (was always silent).
9. Port owner check: `fuser /dev/ttySC0` -> empty (no hog). Ports reopen fine.
10. Host reset paths: `sudo -n reboot` -> "sudo: a password is required";
    `systemctl reboot` -> "Interactive authentication required";
    /sys/class/gpio/export is --w--w---- root:gpio (explorer cannot export);
    gpiochip0/496/504 exist but no writable value nodes; no reset GPIO in DT.
    => no software path resets X or power-cycles the Pi.

## Verdict on X's state
Pi-side link provably healthy (IRQ moves, ports open, TX reached X before the incident).
X emits nothing at any rate/frame, does not react to BREAK/DTR/RTS, RX blind-recovery
programs do not run. X's 68000 is hung/crashed; only physical power-cycle recovers.

## Human recovery instructions
- Power-cycle device X (unplug its power/supply lead ~10 s, replug). If X is powered
  from the Pi (GPIO 5V or USB), instead reboot the Pi: `sudo reboot` (needs sudo password).
- Then expect on /dev/ttySC0 at 4800 8N1: "\r\nTUTOR  1.3 > " after a BREAK.
  If instead it answers at 1200 8N1, the $10040 latch survived; send nothing and
  power-cycle again (latch appears non-resettable by BREAK, reset by power).

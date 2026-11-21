# Nontrivial program authored and executed on X

Source (assembled on Pi with vasmm68k_mot, /home/explorer/work/prog.s):
        ORG    $1000
START:  MOVEQ  #0,D7           ; byte offset
        MOVEQ  #0,D0           ; fib(n-1)
        MOVEQ  #1,D1           ; fib(n)
        MOVEQ  #11,D3          ; 12 terms
        LEA    $1100,A0
LOOP:   MOVE.W D1,0(A0,D7.W)   ; store fib term
        ADDQ.W #2,D7
        MOVE.W D1,D2
        ADD.W  D0,D1
        MOVE.W D2,D0
        DBF    D3,LOOP
        MOVE.W #$4F4B,$1120    ; signature "OK"
        JMP    $8146           ; return to monitor init

Machine code (38 bytes): 7e0070007201760b41f811003181700054473401d240300251cbfff2
                          31fc4f4b112060007122

runprog.py transcript (live):
  BEFORE:  M 1100 -> '001100    FF ?'  '001101    FF ?'   (erased)
  LOAD:    M 1000 loop wrote 38 bytes; verify readback: 7E 00 70 00 72 01 76 0b ...
  RUN:     'G 1000\r\nPHYSICAL ADDRESS=00001000\r\n\r\nTUTOR  1.3 > '  (clean, no trap)
  AFTER:   M 1100.. readback words:
           0x1 0x1 0x2 0x3 0x5 0x8 0xd 0x15 0x22 0x37 0x59 0x90  (fib 1..12)
           then 0x4F4B at $1120 ("OK" signature)
=> X's CPU executed user-authored code: indexed MOVE, ADD, DBF loop, absolute store.

## Second program: TRAP0 vector hook (control-flow hijack + monitor service call)
hook.py: saved vector[$80]=$8442, wrote $00001200 into it, ran G 1210
(handler at $1200: MOVE.W #$BEEF,D0 ; TRAP #12 ; — TRAP #0 at $1210 entered handler).
Observed dump: "UT C TRAP ERROR" PC=00001206, D0=0030BEEF (value written by MY handler),
SS=00000780. => handler executed on X's CPU; TRAP #12 is the monitor's
return-to-prompt service (real code at $84D8), TRAP0-15 vectors at $80-$BC are
user-installable. Vector restored to $8442 afterwards.

## Program source file on the Pi (verified live after X's death)
`ssh pi 'ls -l /home/explorer/work/prog.s && cat /home/explorer/work/prog.s'`:
    -rw-r--r-- 1 explorer explorer 498 Nov 19 21:12 /home/explorer/work/prog.s
            ORG    $1000
    START:
            MOVEQ  #0,D7           ; byte offset
            MOVEQ  #0,D0           ; fib(n-1)
            MOVEQ  #1,D1           ; fib(n)
            MOVEQ  #11,D3          ; 12 terms
            LEA    $1100,A0
    LOOP:   MOVE.W D1,0(A0,D7.W)   ; store fib term
            ADDQ.W #2,D7
            MOVE.W D1,D2
            ADD.W  D0,D1
            MOVE.W D2,D0
            DBF    D3,LOOP
            MOVE.W #$4F4B,$1120    ; signature "OK"
            JMP    $8146           ; return to monitor init
            END
(plus /home/explorer/work/prog.bin, 38 bytes — the image loaded into X.)

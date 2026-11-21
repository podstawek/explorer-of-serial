# CPU = plain Motorola 68000

## Exception/register evidence (bare G dump)
G executes from PC=$404 into erased RAM ($FFFF):
    PHYSICAL ADDRESS=00000000
    1111 TRAP ERROR
    PC=00000404 SR=2708 US=FFFF7FFF SS=00000786
    D0..D7 / A0..A7 lines; then "000404    FFFF    DC.W    $FFFF"
US/SS = user/supervisor stack registers; SR symbolic decode; monitor disassembles
executed opcode (DC.W/BRA.S mnemonics seen) => 68000-family monitor.

## Reset code at $8146 (M-loop dump)
48 B8 00 01 00 00 00 00 00 00 48 E7 FF FE 4F F8 07 86 21 CF ... 46 FC 27 00 4E 68
= MOVEM.L #FFFE,-(A7) / LEA $786,A7 / ... / MOVE #2700,SR / MOVE USP,A0
Matches observed SR=2708 (S=1, IPL7) and SS=786.

## Opcode-level discrimination (put at $1000, G 1000)
$4E7B 0000 MOVEC CCR,D0    -> "ILLEGAL INSTRUCTION"  (68010+ only instr) => NOT 68010+
$4E7B 0801 MOVEC VBR,D1    -> "ILLEGAL INSTRUCTION"
$4E7B 0009 MOVEC CACAR,D2  -> "ILLEGAL INSTRUCTION"  (68020+)
$4E7C 0000 BKPT #0         -> "ILLEGAL INSTRUCTION"  (68010+)
$A000                     -> "1010 TRAP ERROR"       (68000 TRAP#1010 behavior)
$F268 MOVEP / $F200 NOPx  -> "1111 TRAP ERROR"       (68000 TRAP#1111 for $F100-FFFF)
$4E68 MOVE USP,A0         -> executes fine (supervisor mode)
$0108 (OR.B (A0),D0 on 68000) -> "BUS  TRAP ERROR" PC=1002 (incremented PC pushed = 68000)
## Conclusion: Motorola 68000 (68000-only opcode set, 68000 exception semantics)

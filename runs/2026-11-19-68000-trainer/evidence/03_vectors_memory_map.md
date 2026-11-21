# Vector table (monitor's table at $0) and memory map

Raw M-loop dump of $0-$F (cat -A output, each line = one byte cell):
000000 00 | 000001 00 | 000002 04 | 000003 44   => SSP  = 00000444
000004 00 | 000005 00 | 000006 81 | 000007 46   => RESET= 00008146
000008 00 | 000009 00 | 00000A 80 | 00000B 30   => $8   = 00008030 ("BUS " handler)
00000C 00 | 00000D 00 | 00000E 80 | 00000F 3A   => $C   = 0000803A ("ADDR" handler)
Further (clean dump): $10=8DE4 (illegal->"ILLEGAL INSTRUCTION"), $14=83AC DIV0,
$18=83B6 CHCK, $1C=83C0 TPV, $20=83CA PRIV, $24=83D4 TRAC, TRAP vecs -> UT n handlers.

Handler pattern (ROM $83A2+): MOVE.L #'OPCO',$30 ; BRA common_dump
Labels found: OPCO DIV0 CHCK TP V PRIV TRAC 1010 1111 SPUR AV#1..AV#7 UT 0..UT 3
Dump prints "<LBL> TRAP ERROR" + PC/SR/US/SS + D0-D7 + A0-A7 + disassembled opcode.

## Memory map (M reads + bus-error probes)
$0000-$0FFF RAM (vectors, monitor workspace, stack @ $444/$786); writes stick
$1000-$7FFF RAM (reads $FF idle; writes stick - user area)
$8000-$BFFF ROM (monitor code: $8146 reset, $82FC prompt string, $83A2+ trap labels,
       $8DE4 illegal handler, $93C6 in bus-error frame)
$C000+      unmapped: M C000 -> "1E15 0000C000 1E14 / BUS  TRAP ERROR / PC=000093C6"
       ($1E14 = 68000 bus-error format word; 24-bit bus, nothing mapped above $BFFF)

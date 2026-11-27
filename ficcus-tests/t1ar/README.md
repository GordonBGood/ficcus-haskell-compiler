# T1a review scratch tests (docs/T1A-REVIEW.md)

`./run.sh ELM ELM_HOME [Case ...]` (ELM_HOME: a copy of elm-home-difftest/0.19.3): --rc C at -O2 and under ASan+UBSan (live 0), then
JavaScript under node; expected/ holds the C output (FIC_TIME=1700000000000). R6Ports needs `FIC_PORTS_IN=R6Ports.in` (run by hand);
R8Vector is C only (no Vector in JavaScript). R7: compare `/usr/bin/time -f %M` of R7CycleExit and R7PlainExit (O5).
R3TieBreak: C always prints `r: Nothing`; node prints `r: Just 1` in some runs (equal virtual deadlines, finding F2). run.js now flags
such a tie on stderr (`FIC_JS_TIE`) and run.sh reports it; R3TieBreak and R2Within0 (its send and
`receiveWithin 0` are due at 1 ms) are expected to be flagged (`TIE_EXPECTED`); Elm's own `Process.sleep 0` of the outgoing port
manager is not tracked (C has no such timer).

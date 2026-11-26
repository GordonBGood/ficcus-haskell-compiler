# A3b review cases (docs/A3B-REVIEW.md)

`python3 ficcus-tests/a3br/run.py [--elm ../bin/elmficA3b] [--only a,b] [-v]` from the worktree root (TMPDIR on /home is
advisable). Each case is compiled to C with `--no-rc` (gcc -O2) and `--rc` (ASan+UBSan, FIC_STATS, 0 live); a case with
`twin/` is compared with that plain Elm program run by bin/elm0193 + node. Cases without a twin print their output (probes).

Expected on elmficA3b: every twin case ok in both modes; `ff-err-string` NO MEMBER; `ff-err-toplevel` TYPE MISMATCH;
`ext-record` FICCUS "cannot key" (pre-existing); `nonreg-elm`/`nonreg-member` FICCUS "holds more than 2000 different types"
(elmficA4b does not finish on `nonreg-elm`); `nan-sort-elm` differs from Elm on elmficA4b and elmficA3b alike (NaN sort order is
unspecified, decisions slice 4). `ff-many*` are timing inputs (5000 Float literals).

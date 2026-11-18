app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.19.0/Hj-J_zxz7V9YurCSTFcFdu6cQJie4guzsPMUi5kBYUk.tar.br" }

# H21: List.sort of 1e6 Int (same LCG as targets/sort/bench_kernel.c: x = x * 6364136223846793005 + 1442695040888963407, value x >> 33).
# Run: roc build --optimize targets/roc/SortBench.roc && ./targets/roc/SortBench   (use the basic-cli release your roc version matches)
import pf.Stdout
import pf.Utc

lcg : U64 -> U64
lcg = \x -> Num.addWrap (Num.mulWrap x 6364136223846793005) 1442695040888963407

gen : U64, U64, List I64 -> List I64
gen = \n, s, acc ->
    if n == 0 then
        acc
    else
        s2 = lcg s
        gen (n - 1) s2 (List.append acc (Num.toI64 (Num.shiftRightBy s2 33)))

main! = \_ ->
    xs = gen 1_000_000 12345 []
    t0 = Utc.now! {}
    ys = List.sort xs
    t1 = Utc.now! {}
    ms = (Utc.deltaAsNanos t0 t1) // 1_000_000
    Stdout.line! "List.sort 1e6 random: $(Num.toStr ms) ms, first $(Num.toStr (List.first ys |> Result.withDefault 0))"

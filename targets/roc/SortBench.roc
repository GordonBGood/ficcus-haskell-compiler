app [main!] {
    cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
}

# H21: List.sort of 1e6 Int (same LCG as targets/sort/bench_kernel.c: x = x * 6364136223846793005 + 1442695040888963407, value x >> 33).
# Run: roc build --optimize targets/roc/SortBench.roc && ./targets/roc/SortBench   (use the basic-cli release your roc version matches)
import cli.Stdout
import cli.Monotonic

lcg : U64 -> U64
lcg = |x| x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)

gen : U64, U64, List(I64) -> List(I64)
gen = |n, s, acc| {
    if (n <= 0) acc else {
        s2 = lcg(s)
        gen(n - 1, s2, acc.append(s2.to_i64_wrap().shr_wrap(33)))
    }
}

main! = |args| {
    # an external input so that compiler doesn't optimize away the repetition;
    # this defaults to zero when no argument is passed, which is fine...
    inp = match List.get(args, 1) {
        Ok(arg_os_str) => 
            arg_os_str.display() |> U64.from_str() |> Try.ok_or(0.U64)
        Err(_) => 0
    }
    xs = gen(1_000_000, 12345 + inp, [])
    t0 = Monotonic.now!()
    ys = xs.sort()
    t1 = Monotonic.now!()
    ms = t1.since(t0).to_millis()
    Stdout.line!("List.sort 1e6 random: ${ms.to_str()} ms, first ${ys.first().ok_or(0).to_str()}")
}

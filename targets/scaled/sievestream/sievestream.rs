// Incremental prime sieve with streams of closures: the algorithm of sievestream/src/SieveStream.elm, same
// structure (SCALED: limit 5,000,000): a co-inductive stream Cis { head, tail thunk }, a tree of merges of the
// composites of the base primes (merge, pmult, allmlts, pairs, cmpsts), testprm, and the base primes from a
// second instance of the same stream (oddprms is called again inside its own thunk, as in Elm).
// Choices: Cis<T> = struct { hd: T, tl: Box<dyn FnOnce() -> Cis<T>> } (a Box per cell and per closure; every thunk is
// called at most once in each branch of the Elm code, so FnOnce and moves are enough, no Rc); the tail
// recursion of testprm and countCISTo are loops; everything else is the recursion of the Elm code.
#![forbid(unsafe_code)]

struct Cis<T> { hd: T, tl: Box<dyn FnOnce() -> Cis<T>> }

fn cis<T>(hd: T, f: impl FnOnce() -> Cis<T> + 'static) -> Cis<T> { Cis { hd, tl: Box::new(f) } }

fn merge(xs: Cis<i64>, ys: Cis<i64>) -> Cis<i64> {
    let Cis { hd: x, tl: xtl } = xs;
    let Cis { hd: y, tl: ytl } = ys;
    if x < y { cis(x, move || merge(xtl(), cis(y, ytl))) }
    else if x == y { cis(x, move || merge(xtl(), ytl())) }
    else { cis(y, move || merge(cis(x, xtl), ytl())) }
}

fn pmult(bp: i64) -> Cis<i64> {
    fn pmlt(p: i64, adv: i64) -> Cis<i64> { cis(p, move || pmlt(p + adv, adv)) }
    pmlt(bp * bp, bp + bp)
}

fn allmlts(bps: Cis<i64>) -> Cis<Cis<i64>> {
    let Cis { hd: bp, tl: bptl } = bps;
    cis(pmult(bp), move || allmlts(bptl()))
}

fn pairs(s: Cis<Cis<i64>>) -> Cis<Cis<i64>> {
    let Cis { hd: frst, tl: tls } = s;
    let Cis { hd: scnd, tl: tlss } = tls();
    cis(merge(frst, scnd), move || pairs(tlss()))
}

fn cmpsts(s: Cis<Cis<i64>>) -> Cis<i64> {
    let Cis { hd: Cis { hd, tl }, tl: tls } = s;
    cis(hd, move || merge(tl(), cmpsts(pairs(tls()))))
}

fn testprm(mut n: i64, mut cs: Cis<i64>) -> Cis<i64> {
    loop {
        if n < cs.hd {
            return cis(n, move || testprm(n + 2, cs));
        }
        cs = (cs.tl)();
        n += 2;
    }
}

fn oddprms() -> Cis<i64> {
    cis(3, || testprm(5, cmpsts(allmlts(oddprms()))))
}

fn primes_stream() -> Cis<i64> { cis(2, oddprms) }

fn count_primes_to(n: i64) -> i64 {
    let mut s = primes_stream();
    let mut cnt = 0;
    while s.hd <= n {
        cnt += 1;
        s = (s.tl)();
    }
    cnt
}

fn main() {
    let limit: i64 = std::hint::black_box(5000000);
    println!("Found {} Hamming numbers to {} inclusive.", count_primes_to(limit), limit);
}

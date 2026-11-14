// Hamming numbers with a persistent min-heap and logarithmic representation: the loop variant of
// hamheap/src/HammingHeap.elm (SCALED: summed over limits limit - k, k = 1..300).
// Choices: the same structure as the Elm code. The heap is a persistent skew-style tree Option<Box<Br>> with
// the Elm operations pushPQ / siftdown / replaceMinPQ written in the consuming style (a node taken by value
// and rebuilt, so every step allocates a new Box and frees the old one, like the Elm code without reuse); keys
// are the f64 logarithms, values the exponent triples; LogRep is a Copy struct; tvToNum is the Elm
// square-and-multiply (wrapping arithmetic, as the unused last squaring overflows). Indexing is not used.
#![forbid(unsafe_code)]

const REPS: i64 = 300;
type Trival = (i64, i64, i64);
#[derive(Clone, Copy)]
struct LogRep { lr: f64, trv: Trival }

struct Br { k: f64, v: Trival, l: Pq, r: Pq }
type Pq = Option<Box<Br>>;

fn node(k: f64, v: Trival, l: Pq, r: Pq) -> Pq { Some(Box::new(Br { k, v, l, r })) }

fn push(wk: f64, wv: Trival, pq: Pq) -> Pq {
    match pq {
        None => node(wk, wv, None, None),
        Some(b) => {
            let Br { k, v, l, r } = *b;
            if wk <= k { node(wk, wv, push(k, v, r), l) } else { node(k, v, push(wk, wv, r), l) }
        }
    }
}

fn siftdown(wk: f64, wv: Trival, pql: Pq, pqr: Pq) -> Pq {
    match (pql, pqr) {
        (None, _) => node(wk, wv, None, None),
        (Some(bl), None) => {
            if wk <= bl.k { node(wk, wv, Some(bl), None) }
            else { node(bl.k, bl.v, node(wk, wv, None, None), None) }
        }
        (Some(bl), Some(br)) => {
            if wk <= bl.k && wk <= br.k { node(wk, wv, Some(bl), Some(br)) }
            else if bl.k <= br.k {
                let Br { k, v, l, r } = *bl;
                node(k, v, siftdown(wk, wv, l, r), Some(br))
            } else {
                let Br { k, v, l, r } = *br;
                node(k, v, Some(bl), siftdown(wk, wv, l, r))
            }
        }
    }
}

fn replace_min(wk: f64, wv: Trival, pq: Pq) -> Pq {
    match pq { None => None, Some(b) => { let Br { l, r, .. } = *b; siftdown(wk, wv, l, r) } }
}

fn peek(pq: &Pq) -> Option<LogRep> { pq.as_ref().map(|b| LogRep { lr: b.k, trv: b.v }) }

fn tv_to_num(t: Trival) -> i64 {
    fn xpnd(mut x: i64, mut m: i64, mut r: i64) -> i64 {
        while x > 0 {
            if x & 1 != 0 { r = m.wrapping_mul(r); }
            x >>= 1;
            m = m.wrapping_mul(m);
        }
        r
    }
    xpnd(t.2, 5, xpnd(t.1, 3, xpnd(t.0, 2, 1)))
}

const LG2_2: f64 = 1.0;
const LG2_3: f64 = 1.584962500721156;
const LG2_5: f64 = 2.321928094887362;
fn mult2(a: LogRep) -> LogRep { LogRep { lr: a.lr + LG2_2, trv: (a.trv.0 + 1, a.trv.1, a.trv.2) } }
fn mult3(a: LogRep) -> LogRep { LogRep { lr: a.lr + LG2_3, trv: (a.trv.0, a.trv.1 + 1, a.trv.2) } }
fn mult5(a: LogRep) -> LogRep { LogRep { lr: a.lr + LG2_5, trv: (a.trv.0, a.trv.1, a.trv.2 + 1) } }

fn count_hams_to(n: i64) -> i64 {
    let one = LogRep { lr: 0.0, trv: (0, 0, 0) };
    let (mut bpq, mut mpq): (Pq, Pq) = (None, None);
    let mut m235 = mult2(one);
    let im35 = mult3(one);
    let (mut mrg, mut m35, mut m5) = (im35, im35, mult5(one));
    let mut cnt = 1;
    loop {
        if m235.lr < mrg.lr {
            if tv_to_num(m235.trv) > n { return cnt; }
            let omin = peek(&bpq).unwrap_or(m235);
            bpq = replace_min(m235.lr, m235.trv, bpq);
            m235 = mult2(omin);
        } else if mrg.lr < m5.lr {
            if tv_to_num(mrg.trv) > n { return cnt; }
            let omin = peek(&mpq).unwrap_or(mrg);
            let nm35 = mult3(omin);
            bpq = push(mrg.lr, mrg.trv, bpq);
            mpq = replace_min(mrg.lr, mrg.trv, mpq);
            mrg = if nm35.lr < m5.lr { nm35 } else { m5 };
            m35 = nm35;
        } else {
            if tv_to_num(m5.trv) > n { return cnt; }
            let nm5 = mult5(m5);
            bpq = push(m5.lr, m5.trv, bpq);
            mpq = push(m5.lr, m5.trv, mpq);
            mrg = if m35.lr < nm5.lr { m35 } else { nm5 };
            m5 = nm5;
        }
        cnt += 1;
    }
}

fn main() {
    let limit: i64 = std::hint::black_box(9007199254740991);
    let mut total = 0;
    for k in 1..=REPS { total += count_hams_to(limit - k); }
    println!("Found {} Hamming numbers to {} inclusive.", total, limit);
}

// hamroc.rs -- safe Rust for the algorithm of targets/roc/NthHamming.roc: two growable circular buffer queues (multiples of 2: bigq, of 3: smlq;
// front, back, size, Vec, initial size 16, doubled by appending a copy of itself) and one running value fvs for the multiples of 5.
// LogRep = { log2: f64, twos, threes, fives }; counts are u16 as in Roc (16 bytes), or i64 (32 bytes) with `--cfg wide` (as in the Ficus program).
//   mode `direct`: the loop of nthHamming   mode `iter`: Iterator::nth(n - 1) on a struct whose next() is nextHammingCIS (first item = one)
// rustc --edition 2021 -C opt-level=3 -C debug-assertions=no [--cfg wide] hamroc.rs    run: hamroc N [direct|iter]   (default 1000000 direct)
#[cfg(not(wide))]
type Cnt = u16;
#[cfg(wide)]
type Cnt = i64;

#[derive(Clone, Copy)]
struct LogRep { log2: f64, twos: Cnt, threes: Cnt, fives: Cnt }

const LG2: f64 = 1.0;
const LG3: f64 = 1.584962500721156;
const LG5: f64 = 2.321928094887362;
const ONE: LogRep = LogRep { log2: 0.0, twos: 0, threes: 0, fives: 0 };

fn mult2(l: LogRep) -> LogRep { LogRep { log2: l.log2 + LG2, twos: l.twos + 1, ..l } }
fn mult3(l: LogRep) -> LogRep { LogRep { log2: l.log2 + LG3, threes: l.threes + 1, ..l } }
fn mult5(l: LogRep) -> LogRep { LogRep { log2: l.log2 + LG5, fives: l.fives + 1, ..l } }

struct Queue { front: u64, back: u64, size: u64, list: Vec<LogRep> }

fn init_queue(x: LogRep) -> Queue { Queue { front: 0, back: 1, size: 16, list: vec![x; 16] } }

fn peek_queue(q: &Queue) -> LogRep { q.list[q.front as usize] }

fn push_queue(q: &mut Queue, x: LogRep) {
    if q.back == q.front {
        q.list.extend_from_within(0..q.size as usize);
        q.front += q.size;
        q.size *= 2;
    }
    let nb = if q.back >= q.size - 1 { 0 } else { q.back + 1 };
    q.list[q.back as usize] = x;
    q.back = nb;
}

fn replace_queue_with(q: &mut Queue, f: fn(LogRep) -> LogRep) {
    let nfront = if q.front >= q.size - 1 { 0 } else { q.front + 1 };
    let nback = if q.back >= q.size - 1 { 0 } else { q.back + 1 };
    let fval = q.list[q.front as usize];
    q.list[q.back as usize] = f(fval);
    q.front = nfront;
    q.back = nback;
}

fn nth_direct(n: u64) -> LogRep {
    let mut bigq = init_queue(mult2(ONE));
    let mut smlq = init_queue(mult3(ONE));
    let mut fvs = mult5(ONE);
    let mut hd = ONE;
    let mut cnt = 1u64;
    while cnt < n {
        let b = peek_queue(&bigq);
        let s = peek_queue(&smlq);
        let min23 = b.log2.min(s.log2);
        if min23 > fvs.log2 {
            hd = fvs;
            push_queue(&mut bigq, mult2(fvs));
            push_queue(&mut smlq, mult3(fvs));
            fvs = mult5(fvs);
        } else if b.log2 < s.log2 {
            hd = b;
            replace_queue_with(&mut bigq, mult2);
        } else {
            hd = s;
            push_queue(&mut bigq, mult2(s));
            replace_queue_with(&mut smlq, mult3);
        }
        cnt += 1;
    }
    hd
}

struct Hamming { bigq: Queue, smlq: Queue, fvs: LogRep, first: bool }

impl Hamming {
    fn new() -> Hamming { Hamming { bigq: init_queue(mult2(ONE)), smlq: init_queue(mult3(ONE)), fvs: mult5(ONE), first: true } }
}

impl Iterator for Hamming {
    type Item = LogRep;
    fn next(&mut self) -> Option<LogRep> {
        if self.first { self.first = false; return Some(ONE); }
        let b = peek_queue(&self.bigq);
        let s = peek_queue(&self.smlq);
        let min23 = b.log2.min(s.log2);
        let hd;
        if min23 > self.fvs.log2 {
            hd = self.fvs;
            push_queue(&mut self.bigq, mult2(self.fvs));
            push_queue(&mut self.smlq, mult3(self.fvs));
            self.fvs = mult5(self.fvs);
        } else if b.log2 < s.log2 {
            hd = b;
            replace_queue_with(&mut self.bigq, mult2);
        } else {
            hd = s;
            push_queue(&mut self.bigq, mult2(s));
            replace_queue_with(&mut self.smlq, mult3);
        }
        Some(hd)
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let target: u64 = args.get(1).map(|s| s.parse().unwrap()).unwrap_or(1_000_000);
    let mode = args.get(2).map(|s| s.as_str()).unwrap_or("direct");
    let t = if mode == "iter" { Hamming::new().nth((target - 1) as usize).unwrap() } else { nth_direct(target) };
    println!("Hamming number {} = 2^{} * 3^{} * 5^{}", target, t.twos, t.threes, t.fives);
}

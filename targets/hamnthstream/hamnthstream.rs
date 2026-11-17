// hamnthstream.rs -- safe Rust for HamNthStream.fic: the producer is an Iterator over Items { i, j, k, lg } (exponents and the f64 logarithm,
// computed as in hamnth.rs) in increasing order; the state is the Vec queue (cut off in front by drain as in hamnth.rs) and the three pointers.
//   mode `iter`: Iterator::nth(n - 1) on the concrete struct (what LLVM should fuse into the loop of hamnth)
//   mode `dyn` : a Box<dyn Iterator<Item = Item>> hidden from the optimizer (black_box), advanced by n - 1 calls of next() through the vtable
//                and one more for the nth: no devirtualization, one indirect call per element.
// rustc --edition 2021 -C opt-level=3 -C debug-assertions=no hamnthstream.rs   run: hamnthstream N [iter|dyn]   (default 1000000 iter)
use std::hint::black_box;

#[derive(Clone, Copy)]
struct Item { i: i64, j: i64, k: i64, lg: f64 }

const LN2: f64 = 0.6931471805599453;
const LN3: f64 = 1.0986122886681098;
const LN5: f64 = 1.6094379124341003;

fn mk(i: i64, j: i64, k: i64) -> Item { Item { i, j, k, lg: i as f64 * LN2 + j as f64 * LN3 + k as f64 * LN5 } }
fn same(a: Item, b: Item) -> bool { a.i == b.i && a.j == b.j && a.k == b.k }

struct Hamming { q: Vec<Item>, base: i64, p2: i64, p3: i64, p5: i64, first: bool }

impl Hamming {
    fn new() -> Hamming {
        let mut q = Vec::with_capacity(1024);
        q.push(Item { i: 0, j: 0, k: 0, lg: 0.0 });
        Hamming { q, base: 0, p2: 0, p3: 0, p5: 0, first: true }
    }
}

impl Iterator for Hamming {
    type Item = Item;
    fn next(&mut self) -> Option<Item> {
        if self.first {
            self.first = false;
            return Some(self.q[0]);
        }
        let a = self.q[(self.p2 - self.base) as usize];
        let b = self.q[(self.p3 - self.base) as usize];
        let c = self.q[(self.p5 - self.base) as usize];
        let ca = mk(a.i + 1, a.j, a.k);
        let cb = mk(b.i, b.j + 1, b.k);
        let cc = mk(c.i, c.j, c.k + 1);
        let next = if ca.lg <= cb.lg && ca.lg <= cc.lg { ca } else if cb.lg <= cc.lg { cb } else { cc };
        if same(ca, next) { self.p2 += 1; }
        if same(cb, next) { self.p3 += 1; }
        if same(cc, next) { self.p5 += 1; }
        self.q.push(next);
        let dead = self.p5 - self.base;
        if dead >= 65536 && dead * 2 >= self.q.len() as i64 {
            self.q.drain(..dead as usize);
            self.base = self.p5;
        }
        Some(next)
    }
}

const LIMB: i64 = 1_000_000_000;

fn mul(d: &mut Vec<i64>, m: i64) {
    let mut carry = 0i64;
    for x in d.iter_mut() {
        let t = *x * m + carry;
        *x = t % LIMB;
        carry = t / LIMB;
    }
    while carry != 0 {
        d.push(carry % LIMB);
        carry /= LIMB;
    }
}

fn mulpow(d: &mut Vec<i64>, p: i64, chunk_e: i64, mut e: i64) {
    while e > chunk_e {
        mul(d, p.pow(chunk_e as u32));
        e -= chunk_e;
    }
    mul(d, p.pow(e as u32));
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let target: i64 = args.get(1).map(|s| s.parse().unwrap()).unwrap_or(1_000_000);
    let mode = args.get(2).map(|s| s.as_str()).unwrap_or("iter");
    let t = if mode == "dyn" {
        let mut it: Box<dyn Iterator<Item = Item>> = black_box(Box::new(Hamming::new()));
        for _ in 1..target { it.next(); }
        it.next().unwrap()
    } else {
        Hamming::new().nth((target - 1) as usize).unwrap()
    };
    let mut d = vec![1i64];
    mulpow(&mut d, 2, 22, t.i);
    mulpow(&mut d, 3, 13, t.j);
    mulpow(&mut d, 5, 9, t.k);
    let mut s = format!("{}", d[d.len() - 1]);
    for x in d.iter().rev().skip(1) { s.push_str(&format!("{:09}", x)); }
    println!("Hamming number {} = 2^{} * 3^{} * 5^{}", target, t.i, t.j, t.k);
    println!("{} ({} digits)", s, s.len());
}

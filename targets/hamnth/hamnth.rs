// hamnth.rs -- safe Rust for HamNth.fic: the nth Hamming number by the linear three pointer merge over exponent triples,
// ordered by i ln2 + j ln3 + k ln5 in f64. The queue is a Vec cut off in front by drain when the dead part is >= 65536 and as long
// as the live part. rustc --edition 2021 -C opt-level=3 -C debug-assertions=no hamnth.rs   (TARGET: first argument, default 1000000)
#[derive(Clone, Copy)]
struct Trip { i: i64, j: i64, k: i64 }

const LN2: f64 = 0.6931471805599453;
const LN3: f64 = 1.0986122886681098;
const LN5: f64 = 1.6094379124341003;

fn key(t: Trip) -> f64 { t.i as f64 * LN2 + t.j as f64 * LN3 + t.k as f64 * LN5 }
fn same(a: Trip, b: Trip) -> bool { a.i == b.i && a.j == b.j && a.k == b.k }

fn nth(target: i64) -> Trip {
    let mut q: Vec<Trip> = Vec::with_capacity(1024);
    q.push(Trip { i: 0, j: 0, k: 0 });
    let (mut base, mut p2, mut p3, mut p5) = (0i64, 0i64, 0i64, 0i64);
    while base + (q.len() as i64) < target {
        let a = q[(p2 - base) as usize];
        let b = q[(p3 - base) as usize];
        let c = q[(p5 - base) as usize];
        let ca = Trip { i: a.i + 1, j: a.j, k: a.k };
        let cb = Trip { i: b.i, j: b.j + 1, k: b.k };
        let cc = Trip { i: c.i, j: c.j, k: c.k + 1 };
        let (ka, kb, kc) = (key(ca), key(cb), key(cc));
        let next = if ka <= kb && ka <= kc { ca } else if kb <= kc { cb } else { cc };
        if same(ca, next) { p2 += 1; }
        if same(cb, next) { p3 += 1; }
        if same(cc, next) { p5 += 1; }
        q.push(next);
        let dead = p5 - base;
        if dead >= 65536 && dead * 2 >= q.len() as i64 {
            q.drain(..dead as usize);
            base = p5;
        }
    }
    q[(target - 1 - base) as usize]
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
    let target: i64 = std::env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(1_000_000);
    let t = nth(target);
    let mut d = vec![1i64];
    mulpow(&mut d, 2, 22, t.i);
    mulpow(&mut d, 3, 13, t.j);
    mulpow(&mut d, 5, 9, t.k);
    let mut s = format!("{}", d[d.len() - 1]);
    for x in d.iter().rev().skip(1) { s.push_str(&format!("{:09}", x)); }
    println!("Hamming number {} = 2^{} * 3^{} * 5^{}", target, t.i, t.j, t.k);
    println!("{} ({} digits)", s, s.len());
}

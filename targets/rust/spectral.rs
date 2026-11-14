// Spectral-norm, n = 100 and n = 500: the algorithm of targets/elm/spectral (Spectral.elm): ten rounds of
// the power method on A^T A with A(i,j) = 1 / ((i+j)(i+j+1)/2 + i + 1), then sqrt(u.v / v.v).
// Choices: Vec<f64> for vectors; the same operation order as the Elm code (sums left to right, one add and one
// multiply, no reassociation, so the results equal Elm and C bit for bit; rustc does not fuse multiply-add);
// A(i,j) is recomputed in the inner loop (not tabulated); each mulAv/mulAtv returns a new Vec like
// Array.initialize does (iterator collect); indexing checked.
// The result is printed with 9 decimals with integer arithmetic, like the Elm code (round = JavaScript round).
// UNCHECKED (`--cfg unchecked`): get_unchecked on the vector reads in the inner sums; upper bound only.
#![cfg_attr(not(unchecked), forbid(unsafe_code))]

#[cfg(not(unchecked))]
macro_rules! at { ($v:expr, $i:expr) => { $v[$i] }; }
#[cfg(unchecked)]
macro_rules! at { ($v:expr, $i:expr) => { *unsafe { $v.get_unchecked($i) } }; }

fn a(i: usize, j: usize) -> f64 {
    1.0 / ((((i + j) * (i + j + 1)) / 2 + i + 1) as f64)
}

fn mul_av(n: usize, v: &[f64]) -> Vec<f64> {
    (0..n).map(|i| {
        let mut acc = 0.0;
        for j in 0..n { acc = acc + a(i, j) * at!(v, j); }
        acc
    }).collect()
}

fn mul_atv(n: usize, v: &[f64]) -> Vec<f64> {
    (0..n).map(|i| {
        let mut acc = 0.0;
        for j in 0..n { acc = acc + a(j, i) * at!(v, j); }
        acc
    }).collect()
}

fn mul_at_av(n: usize, v: &[f64]) -> Vec<f64> {
    mul_atv(n, &mul_av(n, v))
}

fn dot(x: &[f64], y: &[f64]) -> f64 {
    let mut s = 0.0;
    for i in 0..x.len() { s = s + x[i] * y[i]; }
    s
}

fn spectral_norm(n: usize) -> f64 {
    let mut u = vec![1.0; n];
    let mut v = vec![0.0; n];
    for _ in 0..10 {
        v = mul_at_av(n, &u);
        u = mul_at_av(n, &v);
    }
    (dot(&u, &v) / dot(&v, &v)).sqrt()
}

fn nine(x: f64) -> String {
    let y = x * 1.0e9;
    let f = y.floor();
    let r = (if y - f >= 0.5 { f + 1.0 } else { f }) as i64; // Math.round
    format!("{}.{:09}", r.div_euclid(1_000_000_000), r.rem_euclid(1_000_000_000))
}

fn main() {
    println!("n = 100: {}", nine(spectral_norm(100)));
    println!("n = 500: {}", nine(spectral_norm(500)));
}

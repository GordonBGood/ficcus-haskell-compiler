// Mandelbrot: the algorithm and the report of targets/elm/mandel (Mandelbrot.elm): 600 x 600 grid over
// re in [-1.5, 0.5), im in [-1, 1), at most 200 iterations, escape test norm2 > 4 before each step.
// Choices: Complex is a Copy struct of two f64 (value type, no allocation, like the Elm record); the grid is
// Vec<Vec<i64>> (Array (Array Int)); the statistics are one Copy struct of eleven fields updated by a fold
// (like the Elm record; the compiler may keep them in registers); the bitmap hash packs 8 pixels per byte;
// the exact Elm operation order is kept ((2.0*x)/size - 1.5, z*z + c with the same four products), so the
// output equals Elm bit for bit; Float printing is JavaScript's (js_float, built on Rust's shortest digits);
// JavaScript's Math.round is js_round. Indexing checked. Built without fused multiply-add (rustc never contracts).
#![forbid(unsafe_code)]

const SIZE: usize = 600;
const MAX_ITER: i64 = 200;

#[derive(Clone, Copy)]
struct Complex { re: f64, im: f64 }

fn mul(a: Complex, b: Complex) -> Complex {
    Complex { re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re }
}
fn add(a: Complex, b: Complex) -> Complex { Complex { re: a.re + b.re, im: a.im + b.im } }
fn norm2(z: Complex) -> f64 { z.re * z.re + z.im * z.im }

fn escape(c: Complex) -> i64 {
    let mut z = Complex { re: 0.0, im: 0.0 };
    let mut n = 0;
    loop {
        if n >= MAX_ITER || norm2(z) > 4.0 { return n; }
        z = add(mul(z, z), c);
        n += 1;
    }
}

fn point_at(x: i64, y: i64) -> Complex {
    Complex { re: 2.0 * (x as f64) / (SIZE as f64) - 1.5, im: 2.0 * (y as f64) / (SIZE as f64) - 1.0 }
}

#[derive(Clone, Copy)]
struct Stats { x: i64, y: i64, inside: i64, total: i64, ck: i64,
               min_re: f64, max_re: f64, min_im: f64, max_im: f64, sum_re: f64, sum_im: f64 }

fn fmin(a: f64, b: f64) -> f64 { if a < b { a } else { b } }
fn fmax(a: f64, b: f64) -> f64 { if a > b { a } else { b } }

fn step(n: i64, s: Stats) -> Stats {
    let mut s1 = s;
    s1.x = s.x + 1;
    s1.total = s.total + n;
    s1.ck = (s.ck + n * ((s.x * 7 + s.y * 13) % 101 + 1)) % 1000000007;
    if n == MAX_ITER {
        let p = point_at(s.x, s.y);
        s1.inside += 1;
        s1.min_re = fmin(s1.min_re, p.re);
        s1.max_re = fmax(s1.max_re, p.re);
        s1.min_im = fmin(s1.min_im, p.im);
        s1.max_im = fmax(s1.max_im, p.im);
        s1.sum_re = s1.sum_re + p.re;
        s1.sum_im = s1.sum_im + p.im;
    }
    s1
}

fn pack_byte(row: &[i64], b: usize) -> i64 {
    let mut acc = 0;
    for i in 0..8 { acc = (acc << 1) | if row[b * 8 + i] == MAX_ITER { 1 } else { 0 }; }
    acc
}

fn js_round(x: f64) -> i64 { let f = x.floor(); (if x - f >= 0.5 { f + 1.0 } else { f }) as i64 }

/// String(x) of JavaScript for a finite or non-finite f64
fn js_float(x: f64) -> String {
    if x.is_nan() { return "NaN".to_string(); }
    if x.is_infinite() { return if x > 0.0 { "Infinity" } else { "-Infinity" }.to_string(); }
    if x == 0.0 { return "0".to_string(); }
    let s = format!("{:e}", x.abs()); // shortest digits, "d.ddde-7"
    let (mant, exp) = s.split_once('e').unwrap();
    let digits: String = mant.chars().filter(|c| *c != '.').collect();
    let k = digits.len() as i32;
    let n = exp.parse::<i32>().unwrap() + 1;
    let body = if k <= n && n <= 21 {
        format!("{}{}", digits, "0".repeat((n - k) as usize))
    } else if 0 < n && n <= 21 {
        format!("{}.{}", &digits[..n as usize], &digits[n as usize..])
    } else if -6 < n && n <= 0 {
        format!("0.{}{}", "0".repeat((-n) as usize), digits)
    } else {
        let e = n - 1;
        let sign = if e < 0 { '-' } else { '+' };
        if k == 1 { format!("{}e{}{}", digits, sign, e.abs()) }
        else { format!("{}.{}e{}{}", &digits[..1], &digits[1..], sign, e.abs()) }
    };
    if x < 0.0 { format!("-{}", body) } else { body }
}

fn join<T: ToString>(v: &[T]) -> String { v.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(" ") }

fn main() {
    let grid: Vec<Vec<i64>> = (0..SIZE as i64)
        .map(|y| (0..SIZE as i64).map(|x| escape(point_at(x, y))).collect())
        .collect();
    let mut st = Stats { x: 0, y: 0, inside: 0, total: 0, ck: 0, min_re: 1.0e10, max_re: -1.0e10,
                         min_im: 1.0e10, max_im: -1.0e10, sum_re: 0.0, sum_im: 0.0 };
    for row in &grid {
        st.x = 0;
        for &n in row { st = step(n, st); }
        st.y += 1;
    }
    let mut hash: i64 = 7;
    for row in &grid {
        for b in 0..SIZE / 8 { hash = (hash * 257 + pack_byte(row, b)) % 1000000007; }
    }
    let total = (SIZE * SIZE) as f64;
    println!("grid: {} x {}, max {} iterations", SIZE, SIZE, MAX_ITER);
    println!("inside: {}", st.inside);
    println!("total iterations: {}", st.total);
    println!("count checksum: {}", st.ck);
    println!("bitmap hash: {}", hash);
    let palette: Vec<char> = " .:-=+*#%@".chars().collect();
    for y in 0..24usize {
        let line: String = (0..60usize).map(|x| {
            let n = grid[y * 25 + 12][x * 10 + 5];
            palette[if n >= MAX_ITER { 9 } else { std::cmp::min(8, n / 3) as usize }]
        }).collect();
        println!("{}", line);
    }
    println!("area estimate: {}", js_float(4.0 * st.inside as f64 / total));
    println!("mean iterations: {}", js_float(st.total as f64 / total));
    println!("re range of inside points: {} to {}", js_float(st.min_re), js_float(st.max_re));
    println!("im range of inside points: {} to {}", js_float(st.min_im), js_float(st.max_im));
    println!("centroid: {}, {}", js_float(st.sum_re / st.inside as f64), js_float(st.sum_im / st.inside as f64));
    let zero = std::hint::black_box(0.0f64);
    let floats = [0.1 + 0.2, 1.0 / 3.0, 2.0 / 3.0, 100.0, 1.0e21, 1.0e-7, 123456789.125, 1.5e300, 5.0e-324,
        1.7976931348623157e308, -2.5, 0.0 / zero, 1.0 / zero, -1.0 / zero, 4.35, 0.000001, 1.0e20,
        1.2345678901234567e19, 2.0f64.sqrt(), 9007199254740992.0, 0.5e-6, -zero, 1.0e-6, 1.2345678901234568e20,
        1.0e22, 0.1, 4.9406564584124654e-324, 2.2250738585072014e-308];
    println!("floats: {}", floats.iter().map(|f| js_float(*f)).collect::<Vec<_>>().join(" "));
    println!("isNaN: {}, isInfinite: {}", if (0.0 / zero).is_nan() { "yes" } else { "no" },
             if (1.0 / zero).is_infinite() { "yes" } else { "no" });
    let rs: Vec<i64> = [-2.5, -1.5, -0.5, 0.5, 1.5, 2.5, 0.49999999999999994, 2.4999999999999996].iter().map(|x| js_round(*x)).collect();
    println!("round: {}", join(&rs));
    let fl: Vec<i64> = vec![(-1.5f64).floor() as i64, (-1.5f64).ceil() as i64, (-1.5f64).trunc() as i64, 1.5f64.floor() as i64,
        1.5f64.ceil() as i64, 1.9f64.trunc() as i64, (-1.9f64).trunc() as i64, 3.0f64.floor() as i64, 3.0f64.ceil() as i64];
    println!("floor ceiling truncate: {}", join(&fl));
}

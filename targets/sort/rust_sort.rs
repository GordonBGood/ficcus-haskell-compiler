// H21: slice::sort (stable), sort_unstable and sort_by on Vec<i64>; rustc -O targets/sort/rust_sort.rs -o rs && ./rs
use std::time::Instant;
fn main() {
    let mut st: u64 = 12345;
    let src: Vec<i64> = (0..1_000_000).map(|_| { st = st.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407); (st >> 33) as i64 }).collect();
    for (name, f) in [("sort", 0), ("sort_unstable", 1), ("sort_by", 2)] {
        let mut best = f64::MAX;
        for _ in 0..5 {
            let mut v = src.clone(); let t = Instant::now();
            match f { 0 => v.sort(), 1 => v.sort_unstable(), _ => v.sort_by(|a, b| a.cmp(b)) }
            best = best.min(t.elapsed().as_secs_f64() * 1e3); assert!(v.windows(2).all(|w| w[0] <= w[1]));
        }
        println!("rust {name:14} random 1e6: {best:.2} ms");
    }
}

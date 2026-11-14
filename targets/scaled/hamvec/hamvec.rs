// Hamming numbers, Vec and three cursors: the algorithm of hamvec/src/HammingVec.elm (SCALED: the count to
// (limit - k) is summed for k = 1..1000, see that file; the count is 7715 each time).
// Choices: the memo is a Vec<i64> that grows by push (Elm: Array.push in place); cursors i2, i3, i5 are usize;
// indexing checked. Next = min(2*h[i2], 3*h[i3], 5*h[i5]); every cursor that produced it moves on.
#![forbid(unsafe_code)]

const REPS: i64 = 1000;

fn count_hams_to(n: i64) -> i64 {
    let mut h: Vec<i64> = vec![1];
    let (mut i2, mut i3, mut i5) = (0usize, 0usize, 0usize);
    loop {
        let x2 = 2 * h[i2];
        let x3 = 3 * h[i3];
        let x5 = 5 * h[i5];
        let m = x2.min(x3.min(x5));
        if m > n { return h.len() as i64; }
        h.push(m);
        if x2 == m { i2 += 1; }
        if x3 == m { i3 += 1; }
        if x5 == m { i5 += 1; }
    }
}

fn main() {
    let limit: i64 = std::hint::black_box(9007199254740991);
    let mut total = 0;
    for k in 1..=REPS { total += count_hams_to(limit - k); }
    println!("Found {} Hamming numbers to {} inclusive.", total, limit);
}

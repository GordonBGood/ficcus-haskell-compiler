// Sieve of Eratosthenes, odds only, bit packed: the algorithm and layout of targets/elm/sieve (Sieve.elm)
// and targets/c/primebench.c. Bit k of the buffer stands for the odd number 2k+3; buffer of 16384 bytes
// (8388608 bits), so the primes up to 16777218 are counted. SCALED copy of targets/rust/sieve.rs.
// Choices: the buffer is a Vec<u8> (the Elm "Array Int of bytes"); plain culling loop per prime (the Elm code,
// not the hand unrolled supercull of primebench.c); indexing with bounds checks left in.
// Optional argument N = number of repeats (default 1): the buffer is cleared and the sieve redone N times so
// that the time is measurable (the program is under 1 ms for one run); the output is printed once.
// std::hint::black_box (safe, std) only stops the repeats from being merged into one.
// Build with `--cfg unchecked` for the UNCHECKED variant: get_unchecked on every buffer access (upper bound
// only, never the comparison); `unsafe` appears only under that cfg, the safe build has #![forbid(unsafe_code)].
#![cfg_attr(not(unchecked), forbid(unsafe_code))]
use std::hint::black_box;

#[cfg(not(unchecked))]
macro_rules! at { ($v:expr, $i:expr) => { $v[$i] }; }
#[cfg(unchecked)]
macro_rules! at { ($v:expr, $i:expr) => { *unsafe { $v.get_unchecked($i) } }; }
#[cfg(not(unchecked))]
macro_rules! or_at { ($v:expr, $i:expr, $m:expr) => { $v[$i] |= $m; }; }
#[cfg(unchecked)]
macro_rules! or_at { ($v:expr, $i:expr, $m:expr) => { *unsafe { $v.get_unchecked_mut($i) } |= $m; }; }

const BUF_BYTES: usize = 1048576;
const BUF_BITS: usize = BUF_BYTES * 8;

fn sieve(buf: &mut [u8]) {
    let mut i = 0usize;
    loop {
        let j0 = (i + i) * (i + 3) + 3; // bit index of the square of the prime 2i+3
        if j0 >= BUF_BITS { break; }
        if at!(buf, i >> 3) & (1u8 << (i & 7)) == 0 {
            let bp = i + i + 3;
            let mut j = j0;
            while j < BUF_BITS {
                or_at!(buf, j >> 3, 1u8 << (j & 7));
                j += bp;
            }
        }
        i += 1;
    }
}

fn count_primes(buf: &[u8]) -> u64 {
    let mut cnt = 1; // the prime 2
    for i in 0..BUF_BITS {
        if at!(buf, i >> 3) & (1u8 << (i & 7)) == 0 { cnt += 1; }
    }
    cnt
}

fn main() {
    let loops: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1);
    let mut cnt = 0;
    for _ in 0..loops {
        let mut buf = vec![0u8; BUF_BYTES];
        sieve(black_box(&mut buf));
        cnt = count_primes(black_box(&buf));
    }
    println!("Found {} primes up to {}.", cnt, 2 * BUF_BITS + 2);
}

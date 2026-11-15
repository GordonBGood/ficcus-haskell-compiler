// Fannkuch-redux, n = 10: the algorithm of targets/elm/fannkuch (Fannkuch.elm), which is the benchmarks game
// rotation scheme: the permutation numbers, the flips (reverse the first k+1 elements, k = first element,
// until the first is 0), checksum = sum of +-flips (sign by permutation number parity), max flips.
// Choices: Vec<usize> for perm1, count and the scratch permutation; the permutations are updated in place
// (the Elm code uses persistent arrays, copied when shared; in Rust the scratch copy `perm` plays that part,
// copy_from_slice, no allocation in the loop); slice::reverse for "reverseTo"; all indexing is checked.
// UNCHECKED (`--cfg unchecked`): get_unchecked on perm1/perm/count; upper bound only, never the comparison.
#![cfg_attr(not(unchecked), forbid(unsafe_code))]

const N: usize = 10;

#[cfg(not(unchecked))]
macro_rules! at { ($v:expr, $i:expr) => { $v[$i] }; }
#[cfg(unchecked)]
macro_rules! at { ($v:expr, $i:expr) => { *unsafe { $v.get_unchecked($i) } }; }
#[cfg(not(unchecked))]
macro_rules! set { ($v:expr, $i:expr, $x:expr) => { $v[$i] = $x; }; }
#[cfg(unchecked)]
macro_rules! set { ($v:expr, $i:expr, $x:expr) => { *unsafe { $v.get_unchecked_mut($i) } = $x; }; }

fn main() {
    let mut perm1: Vec<usize> = (0..N).collect();
    let mut perm: Vec<usize> = vec![0; N];
    let mut count: Vec<usize> = vec![0; N];
    let mut r = N;
    let (mut pc, mut cs, mut mx) = (0i64, 0i64, 0i64);
    'outer: loop {
        while r != 1 { set!(count, r - 1, r); r -= 1; }
        // flips of the current permutation
        perm.copy_from_slice(&perm1);
        let mut f = 0i64;
        let mut k = at!(perm, 0);
        while k != 0 {
            // reverse the elements 0..=k
            let (mut i, mut j) = (0usize, k);
            while i < j {
                let (pi, pj) = (at!(perm, i), at!(perm, j));
                set!(perm, i, pj);
                set!(perm, j, pi);
                i += 1;
                j -= 1;
            }
            f += 1;
            k = at!(perm, 0);
        }
        if pc % 2 == 0 { cs += f } else { cs -= f }
        if f > mx { mx = f }
        // next permutation
        loop {
            if r == N { break 'outer; }
            let p0 = at!(perm1, 0);
            for i in 0..r { let x = at!(perm1, i + 1); set!(perm1, i, x); }
            set!(perm1, r, p0);
            let c = at!(count, r) - 1;
            set!(count, r, c);
            if c > 0 { break; }
            r += 1;
        }
        pc += 1;
    }
    println!("{}", cs);
    println!("Pfannkuchen({}) = {}", N, mx);
}

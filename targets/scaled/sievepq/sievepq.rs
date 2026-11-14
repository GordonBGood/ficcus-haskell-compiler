// Incremental prime sieve with a priority queue: the algorithm of sievepq/src/SievePQ.elm (SCALED: limit 6,000,000).
// Choices: the queue is a persistent Option<Box<Br>> tree with the Elm operations pushPQ / siftdown /
// replaceMinPQ in the consuming style (a node is taken by value and rebuilt: a new Box per step, the old one freed).
// DEVIATION from the Elm code, flagged: the Elm code takes the base primes from a second, lazy, self-referential
// stream (oddprms ()) and emits a stream of closures; here the primes found so far are kept in a Vec and read
// with a cursor (they are always already known when needed), and the stream is consumed by a loop. The heap
// work, which dominates, is the same.
// Variant `--cfg binheap` (labelled BinaryHeap, NOT equivalent: an array heap with in place sift, no
// persistence): the same loop with std::collections::BinaryHeap<Reverse<(composite, step)>>.
#![forbid(unsafe_code)]

#[cfg(not(binheap))]
mod pq {
    pub struct Br { k: i64, v: i64, l: Pq, r: Pq }
    pub type Pq = Option<Box<Br>>;
    fn node(k: i64, v: i64, l: Pq, r: Pq) -> Pq { Some(Box::new(Br { k, v, l, r })) }
    pub fn empty() -> Pq { None }
    pub fn peek(pq: &Pq) -> Option<(i64, i64)> { pq.as_ref().map(|b| (b.k, b.v)) }
    pub fn push(wk: i64, wv: i64, pq: Pq) -> Pq {
        match pq {
            None => node(wk, wv, None, None),
            Some(b) => {
                let Br { k, v, l, r } = *b;
                if wk <= k { node(wk, wv, push(k, v, r), l) } else { node(k, v, push(wk, wv, r), l) }
            }
        }
    }
    fn siftdown(wk: i64, wv: i64, pql: Pq, pqr: Pq) -> Pq {
        match (pql, pqr) {
            (None, _) => node(wk, wv, None, None),
            (Some(bl), None) => {
                if wk <= bl.k { node(wk, wv, Some(bl), None) } else { node(bl.k, bl.v, node(wk, wv, None, None), None) }
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
    pub fn replace_min(wk: i64, wv: i64, pq: Pq) -> Pq {
        match pq { None => None, Some(b) => { let Br { l, r, .. } = *b; siftdown(wk, wv, l, r) } }
    }
}

#[cfg(binheap)]
mod pq {
    use std::cmp::Reverse;
    use std::collections::BinaryHeap;
    pub type Pq = BinaryHeap<Reverse<(i64, i64)>>;
    pub fn empty() -> Pq { BinaryHeap::new() }
    pub fn peek(pq: &Pq) -> Option<(i64, i64)> { pq.peek().map(|Reverse(x)| *x) }
    pub fn push(k: i64, v: i64, mut pq: Pq) -> Pq { pq.push(Reverse((k, v))); pq }
    pub fn replace_min(k: i64, v: i64, mut pq: Pq) -> Pq { pq.pop(); pq.push(Reverse((k, v))); pq }
}

use pq::*;

fn count_primes_to(limit: i64) -> i64 {
    let mut primes: Vec<i64> = vec![3]; // base primes: the odd primes found so far
    let mut cnt = 2; // 2 and 3
    let (mut n, mut q, mut bi) = (5i64, 9i64, 0usize);
    let mut heap = empty();
    loop {
        if n >= q {
            let bp = primes[bi];
            let adv = bp + bp;
            let nbp = primes[bi + 1];
            heap = push(q + adv, adv, heap);
            q = nbp * nbp;
            bi += 1;
        } else {
            let nxtc = peek(&heap).map(|(k, _)| k).unwrap_or(q);
            if n >= nxtc {
                while let Some((c, adv)) = peek(&heap) {
                    if c > n { break; }
                    heap = replace_min(c + adv, adv, heap);
                }
            } else {
                if n > limit { return cnt; }
                cnt += 1;
                primes.push(n);
            }
        }
        n += 2;
    }
}

fn main() {
    let limit: i64 = std::hint::black_box(6000000);
    println!("Found {} prime numbers to {} inclusive.", count_primes_to(limit), limit);
}

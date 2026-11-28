// Binary trees with nodes in a Vec (an arena) and indices as links: the algorithm and output of bintree.rs
// (targets/elm/bintree). Safe Rust, std only, default global allocator.
// Choices: Node { l: u32, i: i64, r: u32 } with u32::MAX as the empty tree; a tree is (Vec<Node>, root index).
//  * default build, labelled ARENA: every tree gets its own Vec with the exact capacity (2^(d+1)-1 nodes), built
//    bottom-up by push, and the whole tree is freed by dropping the Vec: one malloc and one free per tree instead
//    of one per node.
//  * `--cfg bump`, labelled BUMP: a hand written bump allocator, i.e. one scratch Vec<Node> reused for every
//    short-lived tree (stretch tree and the trees of the rounds): clear() resets the allocation pointer, capacity
//    is kept, so after the first tree the allocator is not called at all. The long-lived tree, the shared tree
//    and the trees of the map test are ordinary arenas as in the default build.
//  * the shared tree (both children the same object): both links hold the same index, so it has 21 real nodes as in
//    Elm/Ficus; its logical size is counted by walking the DAG (2^21-1 visits).
//  * map over a unique tree is in place on the arena; map over a tree still in use builds a copy into a new arena.
// Differences to the Box program that matter: no per-node malloc/free, nodes of a tree contiguous in memory,
// links are 4 byte indices (a node is 24 bytes), every access is bounds checked.
#![forbid(unsafe_code)]

#[derive(Clone, Copy)]
struct Node { l: u32, i: i64, r: u32 }
const NIL: u32 = u32::MAX;
type Arena = Vec<Node>;

fn build(a: &mut Arena, item: i64, depth: i64) -> u32 {
    let (l, r) = if depth > 0 {
        let l = build(a, 2 * item - 1, depth - 1);
        let r = build(a, 2 * item, depth - 1);
        (l, r)
    } else { (NIL, NIL) };
    a.push(Node { l, i: item, r });
    (a.len() - 1) as u32
}

fn item_check(a: &[Node], t: u32) -> i64 {
    if t == NIL { return 0; }
    let n = &a[t as usize];
    n.i + item_check(a, n.l) - item_check(a, n.r)
}

fn size_tree(a: &[Node], t: u32) -> i64 {
    if t == NIL { return 0; }
    let n = &a[t as usize];
    1 + size_tree(a, n.l) + size_tree(a, n.r)
}

fn map_in_place(a: &mut Arena, t: u32, f: fn(i64) -> i64) {
    if t == NIL { return; }
    let (l, r) = (a[t as usize].l, a[t as usize].r);
    map_in_place(a, l, f);
    a[t as usize].i = f(a[t as usize].i);
    map_in_place(a, r, f);
}

fn map_copy(src: &[Node], dst: &mut Arena, t: u32, f: fn(i64) -> i64) -> u32 {
    if t == NIL { return NIL; }
    let n = src[t as usize];
    let l = map_copy(src, dst, n.l, f);
    let r = map_copy(src, dst, n.r, f);
    dst.push(Node { l, i: f(n.i), r });
    (dst.len() - 1) as u32
}

fn inc(x: i64) -> i64 { x + 1 }

fn owned(item: i64, depth: i64) -> (Arena, u32) {
    let mut a = Vec::with_capacity((1usize << (depth + 1)) - 1);
    let root = build(&mut a, item, depth);
    (a, root)
}

/// a short-lived tree: built, checked, freed
fn checked(scratch: &mut Arena, item: i64, depth: i64) -> i64 {
    #[cfg(not(bump))]
    {
        let _ = scratch;
        let (a, root) = owned(item, depth);
        item_check(&a, root)
    }
    #[cfg(bump)]
    {
        scratch.clear(); // reset the bump pointer, keep the memory
        let root = build(scratch, item, depth);
        item_check(scratch, root)
    }
}

fn shared_size(depth: i64) -> i64 {
    let mut a: Arena = Vec::new();
    fn shared_tree(a: &mut Arena, depth: i64) -> u32 {
        let t = if depth > 0 { let c = shared_tree(a, depth - 1); (c, depth, c) } else { (NIL, 0, NIL) };
        a.push(Node { l: t.0, i: t.1, r: t.2 });
        (a.len() - 1) as u32
    }
    let root = shared_tree(&mut a, depth);
    size_tree(&a, root)
}

const MIN_DEPTH: i64 = 4;
const MAX_DEPTH: i64 = 16;

fn main() {
    let mut scratch: Arena = Vec::new();
    #[cfg(bump)]
    scratch.reserve((1usize << (MAX_DEPTH + 2)) - 1);
    let stretch = MAX_DEPTH + 1;
    println!("stretch tree of depth {} check: {}", stretch, checked(&mut scratch, 0, stretch));
    let (long_a, long_root) = owned(0, MAX_DEPTH);
    let mut depth = MIN_DEPTH;
    while depth <= MAX_DEPTH {
        let iterations = 1i64 << (MAX_DEPTH - depth + MIN_DEPTH);
        let mut acc = 0;
        for i in 1..=iterations {
            acc += checked(&mut scratch, i, depth) + checked(&mut scratch, -i, depth);
        }
        println!("{} trees of depth {} check: {}", 2 * iterations, depth, acc);
        depth += 2;
    }
    println!("long lived tree of depth {} check: {}", MAX_DEPTH, item_check(&long_a, long_root));
    println!("shared tree of depth 20 logical size: {}", shared_size(20));
    let (mut ua, uroot) = owned(1, 16);
    map_in_place(&mut ua, uroot, inc);
    let unique_mapped = item_check(&ua, uroot);
    drop(ua);
    let (ba, broot) = owned(1, 16);
    let mut ca: Arena = Vec::with_capacity(ba.len());
    let croot = map_copy(&ba, &mut ca, broot, inc);
    let copied_mapped = item_check(&ca, croot);
    let base_after = item_check(&ba, broot);
    println!("map over unique tree check: {}", unique_mapped);
    println!("map over shared tree check: {}, original still: {}", copied_mapped, base_after);
}

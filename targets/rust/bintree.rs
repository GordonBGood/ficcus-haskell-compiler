// Binary trees: the algorithm of targets/elm/bintree (BinaryTrees.elm): stretch tree depth 17, trees of depth
// 4,6,..,16 built bottom-up and checked (the two bottomUp calls are separate: every tree really has 2^(d+1)-1
// nodes), one long-lived tree of depth 16, a "shared" tree of depth 20, and map over a unique and over a shared
// tree of depth 16.
// Choices: the tree is Option<Box<Node>> (an empty tree allocates nothing, like the Elm scalar Nil; a node is
// one Box, like one Elm object); the system allocator (not swapped); bulk drop is Rust's recursive drop.
//  * map over a UNIQUE tree: the tree is moved in and its nodes are updated in place (no allocation),
//    which is what Elm's unique update does and what ownership expresses directly;
//  * map over a tree still in use: map_copy builds a new tree from &Tree (persistence).
//  * SHARED tree (both children the same object): a Box cannot be shared. Default build: the tree of depth 20
//    is built in full, 2^21-1 real nodes (the Elm/Ficcus one has 21), so this part allocates more than the other
//    programs. DEVIATION, flagged. Build with `--cfg rc` (variant "Rc") to use Rc for that tree only (21 nodes,
//    logical size computed by walking the DAG, 2^21-1 visits); everything else is identical.
#![forbid(unsafe_code)]

struct Node { l: Tree, i: i64, r: Tree }
type Tree = Option<Box<Node>>;

fn bottom_up(item: i64, depth: i64) -> Tree {
    if depth > 0 {
        Some(Box::new(Node { l: bottom_up(2 * item - 1, depth - 1), i: item, r: bottom_up(2 * item, depth - 1) }))
    } else {
        Some(Box::new(Node { l: None, i: item, r: None }))
    }
}

fn item_check(t: &Tree) -> i64 {
    match t {
        None => 0,
        Some(n) => n.i + item_check(&n.l) - item_check(&n.r),
    }
}

fn map_in_place(t: &mut Tree, f: fn(i64) -> i64) {
    if let Some(n) = t {
        map_in_place(&mut n.l, f);
        n.i = f(n.i);
        map_in_place(&mut n.r, f);
    }
}

fn map_copy(t: &Tree, f: fn(i64) -> i64) -> Tree {
    t.as_ref().map(|n| Box::new(Node { l: map_copy(&n.l, f), i: f(n.i), r: map_copy(&n.r, f) }))
}

fn inc(x: i64) -> i64 { x + 1 }

#[cfg(not(rc))]
fn shared_size(depth: i64) -> i64 {
    fn shared_tree(depth: i64) -> Tree {
        if depth > 0 {
            Some(Box::new(Node { l: shared_tree(depth - 1), i: depth, r: shared_tree(depth - 1) }))
        } else {
            Some(Box::new(Node { l: None, i: 0, r: None }))
        }
    }
    fn size_tree(t: &Tree) -> i64 {
        match t { None => 0, Some(n) => 1 + size_tree(&n.l) + size_tree(&n.r) }
    }
    size_tree(&shared_tree(depth))
}

#[cfg(rc)]
fn shared_size(depth: i64) -> i64 {
    use std::rc::Rc;
    struct RNode { l: Option<Rc<RNode>>, _i: i64, r: Option<Rc<RNode>> }
    fn shared_tree(depth: i64) -> Rc<RNode> {
        if depth > 0 {
            let t = shared_tree(depth - 1);
            Rc::new(RNode { l: Some(Rc::clone(&t)), _i: depth, r: Some(t) })
        } else {
            Rc::new(RNode { l: None, _i: 0, r: None })
        }
    }
    fn size_tree(t: &Option<Rc<RNode>>) -> i64 {
        match t { None => 0, Some(n) => 1 + size_tree(&n.l) + size_tree(&n.r) }
    }
    size_tree(&Some(shared_tree(depth)))
}

const MIN_DEPTH: i64 = 4;
const MAX_DEPTH: i64 = 16;

fn sum_checks(depth: i64, iterations: i64) -> i64 {
    let mut acc = 0;
    for i in 1..=iterations {
        acc += item_check(&bottom_up(i, depth)) + item_check(&bottom_up(-i, depth));
    }
    acc
}

fn main() {
    let stretch = MAX_DEPTH + 1;
    println!("stretch tree of depth {} check: {}", stretch, item_check(&bottom_up(0, stretch)));
    let long_lived = bottom_up(0, MAX_DEPTH);
    let mut depth = MIN_DEPTH;
    while depth <= MAX_DEPTH {
        let iterations = 1i64 << (MAX_DEPTH - depth + MIN_DEPTH);
        println!("{} trees of depth {} check: {}", 2 * iterations, depth, sum_checks(depth, iterations));
        depth += 2;
    }
    println!("long lived tree of depth {} check: {}", MAX_DEPTH, item_check(&long_lived));
    println!("shared tree of depth 20 logical size: {}", shared_size(20));
    let mut unique = bottom_up(1, 16);
    map_in_place(&mut unique, inc);
    let unique_mapped = item_check(&unique);
    drop(unique);
    let base = bottom_up(1, 16);
    let copied_mapped = item_check(&map_copy(&base, inc));
    let base_after = item_check(&base);
    println!("map over unique tree check: {}", unique_mapped);
    println!("map over shared tree check: {}, original still: {}", copied_mapped, base_after);
}

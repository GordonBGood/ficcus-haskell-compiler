// P1, Rust version A2 (impl Fn, the sepBy of the Roc version: a loop that carries the Vec, no `one_of`/`loop` combinator); otherwise as json_comb_impl.rs.
// (was) P1, Rust version A (impl Fn): the combinator library of targets/p1/src/JsonComb.elm with static dispatch. Every parser is
// an `impl Fn(State) -> Step<A> + Copy` (a closure that captures only Copy things: parsers, functions, numbers), so the whole
// grammar is one monomorphized closure type, nothing is allocated for a parser and nothing is reference counted. This is
// the fastest that the combinator style can be in safe Rust, the counterpart of the Rc<dyn Fn> version (json_comb_dyn.rs).
// Differences from the Elm code, all forced by static types: `one_of` takes alternatives pairwise (`one_of!(a, b, c)` is
// or(a, or(b, c)), the same order and the same commit rule); the one recursive rule (value) is cut by a plain function
// (`value_step`), the Rust form of `lazy`; `loop_with` (a maker of the state) and `loop_once` (the state by value, the
// parser is used once) are the two forms of `loop`; sharing a parser is copying a Copy closure.
// Safe Rust, std only. Build: rustc --edition 2021 -C opt-level=3 json_comb_impl.rs -o json_comb_impl ; run: json_comb_impl RECORDS STAGE
#![forbid(unsafe_code)]
#[path = "json_common.rs"]
mod common;
use common::{pow10, unescape, Json};

#[derive(Clone, Copy)]
struct State<'a> {
    src: &'a [u8],
    offset: usize,
}

enum Step<'a, A> {
    Good(bool, A, State<'a>),
    Bad(bool, &'static str),
}
use Step::{Bad, Good};

#[derive(Clone, Copy)]
enum Loop<S, A> {
    More(S),
    Done(A),
}

trait P<'a, A>: Fn(State<'a>) -> Step<'a, A> + Copy {}
impl<'a, A, F: Fn(State<'a>) -> Step<'a, A> + Copy> P<'a, A> for F {}

fn succeed<'a, A: Copy>(a: A) -> impl P<'a, A> {
    move |s| Good(false, a, s)
}

fn map<'a, A, B>(f: impl Fn(A) -> B + Copy, p: impl P<'a, A>) -> impl P<'a, B> {
    move |s| match p(s) {
        Good(c, a, s1) => Good(c, f(a), s1),
        Bad(c, m) => Bad(c, m),
    }
}

fn map2<'a, A, B, C>(f: impl Fn(A, B) -> C + Copy, pa: impl P<'a, A>, pb: impl P<'a, B>) -> impl P<'a, C> {
    move |s| match pa(s) {
        Bad(c, m) => Bad(c, m),
        Good(c1, a, s1) => match pb(s1) {
            Bad(c2, m) => Bad(c1 || c2, m),
            Good(c2, b, s2) => Good(c1 || c2, f(a, b), s2),
        },
    }
}

// the parser that `f` returns is used once, so it may be a FnOnce that owns what it needs
fn and_then<'a, A, B, Q: FnOnce(State<'a>) -> Step<'a, B>>(f: impl Fn(A) -> Q + Copy, pa: impl P<'a, A>) -> impl P<'a, B> {
    move |s| match pa(s) {
        Bad(c, m) => Bad(c, m),
        Good(c1, a, s1) => match f(a)(s1) {
            Bad(c2, m) => Bad(c1 || c2, m),
            Good(c2, b, s2) => Good(c1 || c2, b, s2),
        },
    }
}

fn keep<'a, A, B, F: Fn(A) -> B>(pf: impl P<'a, F>, pa: impl P<'a, A>) -> impl P<'a, B> {
    map2(|f: F, a| f(a), pf, pa)
}

fn ignore<'a, K, X>(pk: impl P<'a, K>, ps: impl P<'a, X>) -> impl P<'a, K> {
    map2(|k, _| k, pk, ps)
}

fn or<'a, A>(p: impl P<'a, A>, q: impl P<'a, A>) -> impl P<'a, A> {
    move |s| match p(s) {
        Good(c, a, s1) => Good(c, a, s1),
        Bad(true, m) => Bad(true, m),
        Bad(false, _) => q(s),
    }
}

macro_rules! one_of {
    ($p:expr) => { $p };
    ($p:expr, $($rest:expr),+) => { or($p, one_of!($($rest),+)) };
}

// lazy: a plain function value is a Copy parser and cuts the recursive type
fn lazy<'a, A, Q: FnOnce(State<'a>) -> Step<'a, A>>(thunk: fn() -> Q) -> impl P<'a, A> {
    move |s| thunk()(s)
}

fn loop_run<'a, S, A, Q: FnOnce(State<'a>) -> Step<'a, Loop<S, A>>>(init: S, f: &impl Fn(S) -> Q, s0: State<'a>) -> Step<'a, A> {
    let mut st = init;
    let mut s = s0;
    let mut progress = false;
    loop {
        match f(st)(s) {
            Good(c, Loop::More(st1), s1) => {
                progress = progress || c;
                st = st1;
                s = s1;
            }
            Good(c, Loop::Done(a), s1) => return Good(progress || c, a, s1),
            Bad(c, m) => return Bad(progress || c, m),
        }
    }
}

fn loop_with<'a, S, A, Q: FnOnce(State<'a>) -> Step<'a, Loop<S, A>>>(init: impl Fn() -> S + Copy, f: impl Fn(S) -> Q + Copy) -> impl P<'a, A> {
    move |s| loop_run(init(), &f, s)
}

fn loop_once<'a, S, A, Q: FnOnce(State<'a>) -> Step<'a, Loop<S, A>>>(init: S, f: impl Fn(S) -> Q) -> impl FnOnce(State<'a>) -> Step<'a, A> {
    move |s| loop_run(init, &f, s)
}

// PRIMITIVES

fn byte_at(s: &State) -> i32 {
    if s.offset < s.src.len() { s.src[s.offset] as i32 } else { -1 }
}

fn symbol<'a>(code: i32) -> impl P<'a, ()> {
    move |s| {
        if byte_at(&s) == code {
            Good(true, (), State { offset: s.offset + 1, ..s })
        } else {
            Bad(false, "symbol")
        }
    }
}

fn word<'a>(codes: &'static [i32]) -> impl P<'a, ()> {
    move |s0| {
        let mut s = s0;
        for &c in codes {
            if byte_at(&s) == c {
                s = State { offset: s.offset + 1, ..s };
            } else {
                return Bad(s.offset > s0.offset, "word");
            }
        }
        Good(true, (), s)
    }
}

fn chomp_if<'a>(is_good: impl Fn(i32) -> bool + Copy) -> impl P<'a, ()> {
    move |s| {
        let b = byte_at(&s);
        if b >= 0 && is_good(b) {
            Good(true, (), State { offset: s.offset + 1, ..s })
        } else {
            Bad(false, "chompIf")
        }
    }
}

fn chomp_while_help(is_good: impl Fn(i32) -> bool, src: &[u8], mut o: usize) -> usize {
    while o < src.len() && is_good(src[o] as i32) {
        o += 1;
    }
    o
}

fn chomp_while<'a>(is_good: impl Fn(i32) -> bool + Copy) -> impl P<'a, ()> {
    move |s| {
        let o = chomp_while_help(is_good, s.src, s.offset);
        Good(o > s.offset, (), State { offset: o, ..s })
    }
}

fn chomp_some<'a>(is_good: impl Fn(i32) -> bool + Copy) -> impl P<'a, ()> {
    ignore(chomp_if(is_good), chomp_while(is_good))
}

fn get_offset<'a>() -> impl P<'a, usize> {
    |s| Good(false, s.offset, s)
}

fn get_chomped_string<'a, A>(p: impl P<'a, A>) -> impl P<'a, String> {
    move |s| match p(s) {
        Good(c, _, s1) => Good(c, String::from_utf8_lossy(&s.src[s.offset..s1.offset]).into_owned(), s1),
        Bad(c, m) => Bad(c, m),
    }
}

fn is_digit(b: i32) -> bool {
    (48..=57).contains(&b)
}

fn int10<'a>() -> impl P<'a, i64> {
    |s| {
        let o = chomp_while_help(is_digit, s.src, s.offset);
        if o > s.offset {
            let v = s.src[s.offset..o].iter().fold(0i64, |acc, &b| acc * 10 + (b as i64 - 48));
            Good(true, v, State { offset: o, ..s })
        } else {
            Bad(false, "digit")
        }
    }
}

fn number<'a>() -> impl P<'a, f64> {
    map2(|neg, x: f64| if neg { -x } else { x }, minus(), unsigned_number())
}

fn minus<'a>() -> impl P<'a, bool> {
    one_of!(map(|_| true, symbol(45)), succeed(false))
}

fn unsigned_number<'a>() -> impl P<'a, f64> {
    and_then(
        |ip: i64| and_then(move |fr: f64| map(move |ex: f64| (ip as f64 + fr) * ex, exponent()), fraction()),
        int10(),
    )
}

fn fraction<'a>() -> impl P<'a, f64> {
    one_of!(keep(map(|_| |f: f64| f, symbol(46)), fraction_digits()), succeed(0.0))
}

fn fraction_digits<'a>() -> impl P<'a, f64> {
    and_then(
        |o0: usize| and_then(move |v: i64| map(move |o1: usize| v as f64 / pow10((o1 - o0) as i64), get_offset()), int10()),
        get_offset(),
    )
}

fn exponent<'a>() -> impl P<'a, f64> {
    one_of!(
        keep(map(|_| |e: f64| e, one_of!(symbol(101), symbol(69))), exponent_body()),
        succeed(1.0)
    )
}

fn exponent_body<'a>() -> impl P<'a, f64> {
    and_then(
        |neg: bool| map(move |e: i64| if neg { 1.0 / pow10(e) } else { pow10(e) }, int10()),
        one_of!(map(|_| false, symbol(43)), map(|_| true, symbol(45)), succeed(false)),
    )
}

// THE JSON GRAMMAR

fn is_space(b: i32) -> bool {
    b == 32 || b == 10 || b == 13 || b == 9
}

fn is_plain(b: i32) -> bool {
    b != 34 && b != 92
}

fn spaces<'a>() -> impl P<'a, ()> {
    chomp_while(is_space)
}

fn lexeme<'a, A>(p: impl P<'a, A>) -> impl P<'a, A> {
    ignore(p, spaces())
}

const NULL_WORD: &[i32] = &[110, 117, 108, 108];
const TRUE_WORD: &[i32] = &[116, 114, 117, 101];
const FALSE_WORD: &[i32] = &[102, 97, 108, 115, 101];

fn value_step<'a>(s: State<'a>) -> Step<'a, Json> {
    one_of!(jarray(), jobject(), jstring(), jnumber(), jtrue(), jfalse(), jnull())(s)
}

fn value<'a>() -> impl P<'a, Json> {
    value_step
}

fn jnull<'a>() -> impl P<'a, Json> {
    map(|_| Json::Null, lexeme(word(NULL_WORD)))
}

fn jtrue<'a>() -> impl P<'a, Json> {
    map(|_| Json::Bool(true), lexeme(word(TRUE_WORD)))
}

fn jfalse<'a>() -> impl P<'a, Json> {
    map(|_| Json::Bool(false), lexeme(word(FALSE_WORD)))
}

fn jnumber<'a>() -> impl P<'a, Json> {
    map(Json::Num, lexeme(number()))
}

fn jstring<'a>() -> impl P<'a, Json> {
    map(Json::Str, string_token())
}

fn string_token<'a>() -> impl P<'a, String> {
    ignore(
        keep(
            ignore(succeed(|raw: String| unescape(raw.as_bytes())), symbol(34)),
            get_chomped_string(string_body()),
        ),
        lexeme(symbol(34)),
    )
}

fn string_body<'a>() -> impl P<'a, ()> {
    loop_with(|| (), |_| one_of!(map(|_| Loop::More(()), string_chunk()), succeed(Loop::Done(()))))
}

fn string_chunk<'a>() -> impl P<'a, ()> {
    one_of!(chomp_some(is_plain), ignore(symbol(92), chomp_if(|_| true)))
}

fn jarray<'a>() -> impl P<'a, Json> {
    ignore(
        keep(ignore(succeed(Json::Arr), lexeme(symbol(91))), sep_by(value(), lexeme(symbol(44)))),
        lexeme(symbol(93)),
    )
}

fn jobject<'a>() -> impl P<'a, Json> {
    ignore(
        keep(ignore(succeed(Json::Obj), lexeme(symbol(123))), sep_by(member(), lexeme(symbol(44)))),
        lexeme(symbol(125)),
    )
}

fn member<'a>() -> impl P<'a, (String, Json)> {
    map2(|k, v| (k, v), string_token(), keep(map(|_| |v: Json| v, lexeme(symbol(58))), value()))
}

// the sepBy of the Roc version (targets/roc/JsonComb.roc): no `one_of` and no `loop`; the first item, then a loop that carries the Vec.
// `step` (sep then item) is built once (a Copy closure costs nothing; Roc builds it at each call, where it costs nothing either).
fn sep_by<'a, A>(item: impl P<'a, A>, sep: impl P<'a, ()>) -> impl P<'a, Vec<A>> {
    move |s| match item(s) {
        Bad(c, m) => if c { Bad(c, m) } else { Good(false, Vec::new(), s) },
        Good(c1, x, s1) => sep_by_help(item, sep, c1, vec![x], s1),
    }
}

fn sep_by_help<'a, A>(item: impl P<'a, A>, sep: impl P<'a, ()>, mut p: bool, mut acc: Vec<A>, mut s: State<'a>) -> Step<'a, Vec<A>> {
    let step = keep(map(|_| |y: A| y, sep), item);
    loop {
        match step(s) {
            Good(c, y, s1) => {
                p = p || c;
                acc.push(y);
                s = s1;
            }
            Bad(true, m) => return Bad(true, m),
            Bad(false, _) => return Good(p, acc, s),
        }
    }
}

fn end_of_input<'a>() -> impl P<'a, ()> {
    |s| if s.offset == s.src.len() { Good(false, (), s) } else { Bad(false, "end of input") }
}

fn document<'a>() -> impl P<'a, Json> {
    ignore(keep(ignore(succeed(|j: Json| j), spaces()), value()), end_of_input())
}

fn run(src: &[u8]) -> Option<Json> {
    match document()(State { src, offset: 0 }) {
        Good(_, a, _) => Some(a),
        Bad(..) => None,
    }
}

fn main() {
    common::run(run);
}

// P1, Rust version A2 (dyn, the sepBy of the Roc version: a loop that carries the Vec, no `one_of`/`loop` combinator); otherwise as json_comb_dyn.rs.
// (was) P1, Rust version A (dyn): the combinator library of targets/p1/src/JsonComb.elm translated line for line. A parser is a
// reference counted `Rc<dyn Fn(State) -> Step<A>>`. Deviation from the task text (Box<dyn Fn>): the Elm parsers are shared
// closures (`value` is used by arrays and objects, `item` by every iteration of a loop), and the safe Rust translation of a
// shared closure is Rc; with Box every use would have to rebuild the parser. Everything else as in the Elm code: the state is
// (source, offset) by value, `Step` is Good(committed, value, state) | Bad(committed, problem), the recursive rules are
// functions of () called from `lazy`, the parser list of `one_of` is built at each call of the thunk.
// Safe Rust, std only. Build: rustc --edition 2021 -C opt-level=3 json_comb_dyn.rs -o json_comb_dyn ; run: json_comb_dyn RECORDS STAGE
#![forbid(unsafe_code)]
#[path = "json_common.rs"]
mod common;
use common::{pow10, unescape, Json};
use std::cell::Cell;
use std::rc::Rc;

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

type Parser<'a, A> = Rc<dyn Fn(State<'a>) -> Step<'a, A> + 'a>;

#[derive(Clone)]
enum Loop<S, A> {
    More(S),
    Done(A),
}

fn succeed<'a, A: Clone + 'a>(a: A) -> Parser<'a, A> {
    Rc::new(move |s| Good(false, a.clone(), s))
}

fn map<'a, A: 'a, B: 'a>(f: impl Fn(A) -> B + 'a, p: Parser<'a, A>) -> Parser<'a, B> {
    Rc::new(move |s| match p(s) {
        Good(c, a, s1) => Good(c, f(a), s1),
        Bad(c, m) => Bad(c, m),
    })
}

fn map2<'a, A: 'a, B: 'a, C: 'a>(f: impl Fn(A, B) -> C + 'a, pa: Parser<'a, A>, pb: Parser<'a, B>) -> Parser<'a, C> {
    Rc::new(move |s| match pa(s) {
        Bad(c, m) => Bad(c, m),
        Good(c1, a, s1) => match pb(s1) {
            Bad(c2, m) => Bad(c1 || c2, m),
            Good(c2, b, s2) => Good(c1 || c2, f(a, b), s2),
        },
    })
}

fn and_then<'a, A: 'a, B: 'a>(f: impl Fn(A) -> Parser<'a, B> + 'a, pa: Parser<'a, A>) -> Parser<'a, B> {
    Rc::new(move |s| match pa(s) {
        Bad(c, m) => Bad(c, m),
        Good(c1, a, s1) => match f(a)(s1) {
            Bad(c2, m) => Bad(c1 || c2, m),
            Good(c2, b, s2) => Good(c1 || c2, b, s2),
        },
    })
}

fn keep<'a, A: 'a, B: 'a>(pf: Parser<'a, Rc<dyn Fn(A) -> B + 'a>>, pa: Parser<'a, A>) -> Parser<'a, B> {
    map2(|f: Rc<dyn Fn(A) -> B + 'a>, a| f(a), pf, pa)
}

fn ignore<'a, K: 'a, X: 'a>(pk: Parser<'a, K>, ps: Parser<'a, X>) -> Parser<'a, K> {
    map2(|k, _| k, pk, ps)
}

fn one_of<'a, A: 'a>(ps: Vec<Parser<'a, A>>) -> Parser<'a, A> {
    Rc::new(move |s| {
        for p in &ps {
            match p(s) {
                Good(c, a, s1) => return Good(c, a, s1),
                Bad(true, m) => return Bad(true, m),
                Bad(false, _) => {}
            }
        }
        Bad(false, "oneOf")
    })
}

fn lazy<'a, A: 'a>(thunk: impl Fn() -> Parser<'a, A> + 'a) -> Parser<'a, A> {
    Rc::new(move |s| thunk()(s))
}

// the state of the loop is handed to the callback by value (a maker gives the initial one at each run); a parser built by the
// callback is used once, so it may own the state
fn loop_<'a, S: 'a, A: 'a>(init: impl Fn() -> S + 'a, f: impl Fn(S) -> Parser<'a, Loop<S, A>> + 'a) -> Parser<'a, A> {
    Rc::new(move |s0| {
        let mut st = init();
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
    })
}

// PRIMITIVES

fn byte_at(s: &State) -> i32 {
    if s.offset < s.src.len() { s.src[s.offset] as i32 } else { -1 }
}

fn symbol<'a>(code: i32) -> Parser<'a, ()> {
    Rc::new(move |s| {
        if byte_at(&s) == code {
            Good(true, (), State { offset: s.offset + 1, ..s })
        } else {
            Bad(false, "symbol")
        }
    })
}

fn word<'a>(codes: &'static [i32]) -> Parser<'a, ()> {
    Rc::new(move |s0| {
        let mut s = s0;
        for &c in codes {
            if byte_at(&s) == c {
                s = State { offset: s.offset + 1, ..s };
            } else {
                return Bad(s.offset > s0.offset, "word");
            }
        }
        Good(true, (), s)
    })
}

fn chomp_if<'a>(is_good: impl Fn(i32) -> bool + 'a) -> Parser<'a, ()> {
    Rc::new(move |s| {
        let b = byte_at(&s);
        if b >= 0 && is_good(b) {
            Good(true, (), State { offset: s.offset + 1, ..s })
        } else {
            Bad(false, "chompIf")
        }
    })
}

fn chomp_while_help(is_good: &dyn Fn(i32) -> bool, src: &[u8], mut o: usize) -> usize {
    while o < src.len() && is_good(src[o] as i32) {
        o += 1;
    }
    o
}

fn chomp_while<'a>(is_good: impl Fn(i32) -> bool + 'a) -> Parser<'a, ()> {
    Rc::new(move |s| {
        let o = chomp_while_help(&is_good, s.src, s.offset);
        Good(o > s.offset, (), State { offset: o, ..s })
    })
}

fn chomp_some<'a>(is_good: impl Fn(i32) -> bool + Clone + 'a) -> Parser<'a, ()> {
    ignore(chomp_if(is_good.clone()), chomp_while(is_good))
}

fn get_offset<'a>() -> Parser<'a, usize> {
    Rc::new(|s| Good(false, s.offset, s))
}

fn get_chomped_string<'a, A: 'a>(p: Parser<'a, A>) -> Parser<'a, String> {
    Rc::new(move |s| match p(s) {
        Good(c, _, s1) => Good(c, String::from_utf8_lossy(&s.src[s.offset..s1.offset]).into_owned(), s1),
        Bad(c, m) => Bad(c, m),
    })
}

fn is_digit(b: i32) -> bool {
    (48..=57).contains(&b)
}

fn int10<'a>() -> Parser<'a, i64> {
    Rc::new(|s| {
        let o = chomp_while_help(&is_digit, s.src, s.offset);
        if o > s.offset {
            let v = s.src[s.offset..o].iter().fold(0i64, |acc, &b| acc * 10 + (b as i64 - 48));
            Good(true, v, State { offset: o, ..s })
        } else {
            Bad(false, "digit")
        }
    })
}

fn number<'a>() -> Parser<'a, f64> {
    map2(|neg, x: f64| if neg { -x } else { x }, minus(), unsigned_number())
}

fn minus<'a>() -> Parser<'a, bool> {
    one_of(vec![map(|_| true, symbol(45)), succeed(false)])
}

fn unsigned_number<'a>() -> Parser<'a, f64> {
    and_then(
        |ip: i64| and_then(move |fr: f64| map(move |ex: f64| (ip as f64 + fr) * ex, exponent()), fraction()),
        int10(),
    )
}

fn fraction<'a>() -> Parser<'a, f64> {
    one_of(vec![
        keep(map(|_| Rc::new(|f: f64| f) as Rc<dyn Fn(f64) -> f64>, symbol(46)), fraction_digits()),
        succeed(0.0),
    ])
}

fn fraction_digits<'a>() -> Parser<'a, f64> {
    and_then(
        |o0: usize| and_then(move |v: i64| map(move |o1: usize| v as f64 / pow10((o1 - o0) as i64), get_offset()), int10()),
        get_offset(),
    )
}

fn exponent<'a>() -> Parser<'a, f64> {
    one_of(vec![
        keep(
            map(|_| Rc::new(|e: f64| e) as Rc<dyn Fn(f64) -> f64>, one_of(vec![symbol(101), symbol(69)])),
            exponent_body(),
        ),
        succeed(1.0),
    ])
}

fn exponent_body<'a>() -> Parser<'a, f64> {
    and_then(
        |neg: bool| map(move |e: i64| if neg { 1.0 / pow10(e) } else { pow10(e) }, int10()),
        one_of(vec![map(|_| false, symbol(43)), map(|_| true, symbol(45)), succeed(false)]),
    )
}

// THE JSON GRAMMAR

fn is_space(b: i32) -> bool {
    b == 32 || b == 10 || b == 13 || b == 9
}

fn is_plain(b: i32) -> bool {
    b != 34 && b != 92
}

fn spaces<'a>() -> Parser<'a, ()> {
    chomp_while(is_space)
}

fn lexeme<'a, A: 'a>(p: Parser<'a, A>) -> Parser<'a, A> {
    ignore(p, spaces())
}

const NULL_WORD: &[i32] = &[110, 117, 108, 108];
const TRUE_WORD: &[i32] = &[116, 114, 117, 101];
const FALSE_WORD: &[i32] = &[102, 97, 108, 115, 101];

fn value<'a>() -> Parser<'a, Json> {
    lazy(|| one_of(vec![jarray(), jobject(), jstring(), jnumber(), jtrue(), jfalse(), jnull()]))
}

fn jnull<'a>() -> Parser<'a, Json> {
    map(|_| Json::Null, lexeme(word(NULL_WORD)))
}

fn jtrue<'a>() -> Parser<'a, Json> {
    map(|_| Json::Bool(true), lexeme(word(TRUE_WORD)))
}

fn jfalse<'a>() -> Parser<'a, Json> {
    map(|_| Json::Bool(false), lexeme(word(FALSE_WORD)))
}

fn jnumber<'a>() -> Parser<'a, Json> {
    map(Json::Num, lexeme(number()))
}

fn jstring<'a>() -> Parser<'a, Json> {
    map(Json::Str, string_token())
}

fn string_token<'a>() -> Parser<'a, String> {
    ignore(
        keep(
            ignore(succeed(Rc::new(|raw: String| unescape(raw.as_bytes())) as Rc<dyn Fn(String) -> String>), symbol(34)),
            get_chomped_string(string_body()),
        ),
        lexeme(symbol(34)),
    )
}

fn string_body<'a>() -> Parser<'a, ()> {
    loop_(|| (), |_| one_of(vec![map(|_| Loop::More(()), string_chunk()), succeed(Loop::Done(()))]))
}

fn string_chunk<'a>() -> Parser<'a, ()> {
    one_of(vec![chomp_some(is_plain), ignore(symbol(92), chomp_if(|_| true))])
}

fn jarray<'a>() -> Parser<'a, Json> {
    ignore(
        keep(
            ignore(succeed(Rc::new(Json::Arr) as Rc<dyn Fn(Vec<Json>) -> Json>), lexeme(symbol(91))),
            sep_by(value(), lexeme(symbol(44))),
        ),
        lexeme(symbol(93)),
    )
}

fn jobject<'a>() -> Parser<'a, Json> {
    ignore(
        keep(
            ignore(succeed(Rc::new(Json::Obj) as Rc<dyn Fn(Vec<(String, Json)>) -> Json>), lexeme(symbol(123))),
            sep_by(member(), lexeme(symbol(44))),
        ),
        lexeme(symbol(125)),
    )
}

fn member<'a>() -> Parser<'a, (String, Json)> {
    map2(
        |k, v| (k, v),
        string_token(),
        keep(map(|_| Rc::new(|v: Json| v) as Rc<dyn Fn(Json) -> Json>, lexeme(symbol(58))), value()),
    )
}

// the sepBy of the Roc version (targets/roc/JsonComb.roc): no `one_of` and no `loop`; the first item, then a loop that carries the Vec.
// `step` (sep then item) is built once per list: the Roc source builds it at each call, where a closure of unboxed captures costs nothing;
// here building it per item would be three Rc allocations that Roc does not pay.
fn sep_by<'a, A: 'a>(item: Parser<'a, A>, sep: Parser<'a, ()>) -> Parser<'a, Vec<A>> {
    Rc::new(move |s| match item(s) {
        Bad(c, m) => if c { Bad(c, m) } else { Good(false, Vec::new(), s) },
        Good(c1, x, s1) => sep_by_help(&item, &sep, c1, vec![x], s1),
    })
}

fn sep_by_help<'a, A: 'a>(item: &Parser<'a, A>, sep: &Parser<'a, ()>, mut p: bool, mut acc: Vec<A>, mut s: State<'a>) -> Step<'a, Vec<A>> {
    let step = keep(map(|_| Rc::new(|y: A| y) as Rc<dyn Fn(A) -> A + 'a>, sep.clone()), item.clone());
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

fn end_of_input<'a>() -> Parser<'a, ()> {
    Rc::new(|s| if s.offset == s.src.len() { Good(false, (), s) } else { Bad(false, "end of input") })
}

fn document<'a>() -> Parser<'a, Json> {
    ignore(
        keep(ignore(succeed(Rc::new(|j: Json| j) as Rc<dyn Fn(Json) -> Json>), spaces()), value()),
        end_of_input(),
    )
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

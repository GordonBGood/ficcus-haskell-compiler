// P1, Rust version C: recursive descent over &[u8], no combinators. Same tree and checksum as targets/p1/src/JsonHand.elm.
// Safe Rust, std only. Build: rustc --edition 2021 -C opt-level=3 json_rd.rs -o json_rd ; run: json_rd RECORDS STAGE
#![forbid(unsafe_code)]
#[path = "json_common.rs"]
mod common;
use common::{pow10, unescape, Json};

fn at(src: &[u8], i: usize) -> i32 {
    if i < src.len() { src[i] as i32 } else { -1 }
}

fn skip_spaces(src: &[u8], mut i: usize) -> usize {
    while matches!(at(src, i), 32 | 10 | 13 | 9) {
        i += 1;
    }
    i
}

fn parse_value(src: &[u8], i: usize) -> Option<(Json, usize)> {
    match at(src, i) {
        91 => parse_array(src, skip_spaces(src, i + 1)),
        123 => parse_object(src, skip_spaces(src, i + 1)),
        34 => {
            let (s, j) = parse_string(src, i + 1)?;
            Some((Json::Str(s), skip_spaces(src, j)))
        }
        116 => Some((Json::Bool(true), skip_spaces(src, i + 4))),
        102 => Some((Json::Bool(false), skip_spaces(src, i + 5))),
        110 => Some((Json::Null, skip_spaces(src, i + 4))),
        _ => {
            let (x, j) = parse_number(src, i)?;
            Some((Json::Num(x), skip_spaces(src, j)))
        }
    }
}

fn parse_array(src: &[u8], mut i: usize) -> Option<(Json, usize)> {
    let mut items = Vec::new();
    if at(src, i) == 93 {
        return Some((Json::Arr(items), skip_spaces(src, i + 1)));
    }
    loop {
        let (v, j) = parse_value(src, i)?;
        items.push(v);
        match at(src, j) {
            44 => i = skip_spaces(src, j + 1),
            93 => return Some((Json::Arr(items), skip_spaces(src, j + 1))),
            _ => return None,
        }
    }
}

fn parse_object(src: &[u8], mut i: usize) -> Option<(Json, usize)> {
    let mut members = Vec::new();
    if at(src, i) == 125 {
        return Some((Json::Obj(members), skip_spaces(src, i + 1)));
    }
    loop {
        if at(src, i) != 34 {
            return None;
        }
        let (k, j) = parse_string(src, i + 1)?;
        if at(src, j) != 58 {
            return None;
        }
        let (v, j3) = parse_value(src, skip_spaces(src, j + 1))?;
        members.push((k, v));
        match at(src, j3) {
            44 => i = skip_spaces(src, j3 + 1),
            125 => return Some((Json::Obj(members), skip_spaces(src, j3 + 1))),
            _ => return None,
        }
    }
}

// i is just after the opening quote; the decoded string and the offset after the closing quote and the spaces
fn parse_string(src: &[u8], i: usize) -> Option<(String, usize)> {
    let mut end = i;
    loop {
        match at(src, end) {
            34 => break,
            -1 => return None,
            92 => end += 2,
            _ => end += 1,
        }
    }
    Some((unescape(&src[i..end]), skip_spaces(src, end + 1)))
}

fn digits_end(src: &[u8], mut i: usize) -> usize {
    while (48..=57).contains(&at(src, i)) {
        i += 1;
    }
    i
}

fn digits_value(src: &[u8], i: usize, end: usize) -> i64 {
    src[i..end].iter().fold(0i64, |acc, &b| acc * 10 + (b as i64 - 48))
}

fn parse_number(src: &[u8], i: usize) -> Option<(f64, usize)> {
    let neg = at(src, i) == 45;
    let i1 = if neg { i + 1 } else { i };
    let i2 = digits_end(src, i1);
    if i2 == i1 {
        return None;
    }
    let ip = digits_value(src, i1, i2);
    let (fr, i3) = if at(src, i2) == 46 {
        let j = digits_end(src, i2 + 1);
        (digits_value(src, i2 + 1, j) as f64 / pow10((j - i2 - 1) as i64), j)
    } else {
        (0.0, i2)
    };
    let b3 = at(src, i3);
    let (ex, i4) = if b3 == 101 || b3 == 69 {
        let b = at(src, i3 + 1);
        let j1 = if b == 43 || b == 45 { i3 + 2 } else { i3 + 1 };
        let j2 = digits_end(src, j1);
        let e = digits_value(src, j1, j2);
        (if b == 45 { 1.0 / pow10(e) } else { pow10(e) }, j2)
    } else {
        (1.0, i3)
    };
    let x = (ip as f64 + fr) * ex;
    Some((if neg { -x } else { x }, i4))
}

fn parse_document(src: &[u8]) -> Option<Json> {
    let (v, j) = parse_value(src, skip_spaces(src, 0))?;
    if j == src.len() { Some(v) } else { None }
}

fn main() {
    common::run(parse_document);
}

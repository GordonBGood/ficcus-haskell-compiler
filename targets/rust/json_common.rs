// P1 JSON benchmark, Rust: what the three parsers share (generator, tree, checksum, escapes). Safe Rust, std only.
// The generator is the one of ficus-tools/gen_json.py (see there for the specification); the tree and the fold are the
// ones of targets/p1/src/JsonTree.elm. Usage of every binary: json_X RECORDS STAGE   (STAGE 0: generate, 1: also take the
// bytes, 2: also parse and print the checksum; 7500 records are about 1 MB, 375000 about 50 MB).

pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

pub struct Gen {
    s: i64,
    pub out: String,
}

const ALPHA: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789 _";
const ESC: [&str; 8] = ["\\\"", "\\\\", "\\/", "\\n", "\\t", "\\b", "\\u00e9", "\\u0041"];

impl Gen {
    fn draw(&mut self) -> i64 {
        self.s = self.s * 48271 % 2147483647;
        self.s
    }

    fn string(&mut self, lo: i64, span: i64) {
        let n = lo + self.draw() % span;
        self.out.push('"');
        for _ in 0..n {
            let r = self.draw();
            let p = ((r / 20) % 38) as usize;
            if r % 20 < 14 {
                self.out.push(ALPHA[p] as char);
            } else {
                self.out.push_str(ESC[p % 8]);
            }
        }
        self.out.push('"');
    }

    fn value(&mut self, d: i64) {
        let r = self.draw();
        let mut k = r % 20;
        if d >= 12 && k < 10 {
            k += 10;
        }
        if k < 5 {
            let n = self.draw() % 5;
            self.out.push('[');
            for i in 0..n {
                if i > 0 {
                    self.out.push_str(", ");
                }
                self.value(d + 1);
            }
            self.out.push(']');
        } else if k < 10 {
            let n = self.draw() % 5;
            self.out.push('{');
            for i in 0..n {
                if i > 0 {
                    self.out.push_str(", ");
                }
                self.string(1, 8);
                self.out.push_str(": ");
                self.value(d + 1);
            }
            self.out.push('}');
        } else if k == 10 {
            self.out.push_str("null");
        } else if k == 11 {
            self.out.push_str("true");
        } else if k == 12 {
            self.out.push_str("false");
        } else if k < 16 {
            if self.draw() % 4 == 0 {
                self.out.push('-');
            }
            let v = self.draw() % 1000000;
            self.out.push_str(&v.to_string());
        } else if k < 18 {
            if self.draw() % 4 == 0 {
                self.out.push('-');
            }
            let ip = self.draw() % 10000;
            let fr = (self.draw() % 64) * 15625;
            self.out.push_str(&format!("{}.{:06}", ip, fr));
            if self.draw() % 8 == 0 {
                let e = self.draw() % 3;
                self.out.push_str(["e1", "E+2", "e0"][e as usize]);
            }
        } else {
            self.string(0, 12);
        }
    }
}

pub fn document(n: i64) -> String {
    let mut g = Gen { s: 12345, out: String::new() };
    g.out.push_str("[\n");
    for i in 0..n {
        if i > 0 {
            g.out.push_str(",\n");
        }
        g.value(2);
    }
    g.out.push_str("\n]\n");
    g.out
}

pub struct Summary {
    pub nodes: i64,
    pub sum: f64,
    pub strlen: i64,
    pub depth: i64,
}

pub fn fold(d: i64, j: &Json, a: &mut Summary) {
    a.nodes += 1;
    a.depth = a.depth.max(d);
    match j {
        Json::Null | Json::Bool(_) => {}
        Json::Num(x) => a.sum += *x,
        Json::Str(s) => a.strlen += s.chars().count() as i64,
        Json::Arr(xs) => {
            for x in xs {
                fold(d + 1, x, a);
            }
        }
        Json::Obj(ps) => {
            for (k, v) in ps {
                a.strlen += k.chars().count() as i64;
                fold(d + 1, v, a);
            }
        }
    }
}

pub fn report(j: &Json) -> String {
    let mut a = Summary { nodes: 0, sum: 0.0, strlen: 0, depth: 0 };
    fold(1, j, &mut a);
    format!("nodes={} sum64={} strlen={} depth={}", a.nodes, (a.sum * 64.0).floor() as i64, a.strlen, a.depth)
}

/// the decoded text of the bytes of a string token (the text is ASCII; \u escapes give the characters)
pub fn unescape(raw: &[u8]) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut i = 0;
    while i < raw.len() {
        let b = raw[i];
        if b != b'\\' {
            out.push(b as char);
            i += 1;
            continue;
        }
        let c = raw[i + 1];
        i += 2;
        match c {
            b'n' => out.push('\n'),
            b't' => out.push('\t'),
            b'b' => out.push('\u{8}'),
            b'f' => out.push('\u{c}'),
            b'r' => out.push('\r'),
            b'u' => {
                let mut v = 0u32;
                for k in 0..4 {
                    v = v * 16 + (raw[i + k] as char).to_digit(16).unwrap_or(0);
                }
                i += 4;
                out.push(char::from_u32(v).unwrap_or('\u{fffd}'));
            }
            _ => out.push(c as char),
        }
    }
    out
}

pub fn pow10(n: i64) -> f64 {
    let mut x = 1.0;
    for _ in 0..n {
        x *= 10.0;
    }
    x
}

/// the main of every binary: generate, take the bytes, parse (stage 2), print
pub fn run(parse: impl Fn(&[u8]) -> Option<Json>) {
    let args: Vec<String> = std::env::args().collect();
    let records: i64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(7500);
    let stage: i32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(2);
    let text = document(records);
    if stage == 0 {
        println!("text length {}", text.len());
        return;
    }
    let src: Vec<u8> = text.into_bytes();
    if stage == 1 {
        println!("vector length {}", src.len());
        return;
    }
    match parse(&src) {
        Some(j) => println!("{}", report(&j)),
        None => println!("error"),
    }
}

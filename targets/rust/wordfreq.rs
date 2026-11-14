// Word frequency: the algorithm of targets/elm/wordfreq (WordFreq.elm): 200000 generated tokens from a 5000
// word vocabulary (Park-Miller seed 20251105, syllables with e-acute, u-diaeresis, o-diaeresis), some tokens
// Capitalized or UPPER CASE, separated by space/comma/full stop/newline; lower-case the text, turn the
// separators into spaces, split into words, count, sort by (count descending, word ascending), report.
// Choices: text is one String built by push_str (the Elm code concatenates a List String); the words are &str
// slices of the lower-cased text (no per-word allocation; Elm words are also shared substrings of one buffer
// only after String.words, so this is slightly favourable to Rust); the dictionary is BTreeMap<&str, i64>, the
// closest match to Dict (an ordered balanced tree; B-tree rather than red-black, so NOT identical in
// structure), updated with get_mut / insert (no allocation on a hit, like Dict.update).
// Variant `--cfg hashmap` (labelled HashMap, NOT equivalent to Dict: unordered, SipHash, amortized resize):
// HashMap<&str, i64>; the result is the same because the entries are fully sorted afterwards.
// Sorting: slice sort_by (stable merge sort, like List.sortWith); string order is byte order, equal to the
// UTF-16 order of JavaScript for the Basic Multilingual Plane text used here. text length = chars().count()
// (UTF-16 length of the BMP text). Case mapping with to_lowercase/to_uppercase (Unicode, same results here).
#![forbid(unsafe_code)]
use std::cmp::Ordering;

#[cfg(not(hashmap))]
type Dict<'a> = std::collections::BTreeMap<&'a str, i64>;
#[cfg(hashmap)]
type Dict<'a> = std::collections::HashMap<&'a str, i64>;

const VOCAB_SIZE: i64 = 5000;
const TOKEN_COUNT: i64 = 200000;
const SYLLABLES: [&str; 16] = ["ka", "ké", "kü", "kö", "sa", "sé", "sü", "sö", "ma", "mé", "mü", "mö", "ta", "té", "tü", "tö"];

fn word_of(k: i64) -> String {
    let mut n = k + 256;
    let mut acc = String::new();
    while n != 0 {
        acc = format!("{}{}", SYLLABLES[(n % 16) as usize], acc);
        n /= 16;
    }
    acc
}

fn next_seed(s: i64) -> i64 { (s * 48271) % 2147483647 }

fn capitalize(w: &str) -> String {
    let mut cs = w.chars();
    match cs.next() {
        Some(c) => c.to_uppercase().collect::<String>() + cs.as_str(),
        None => String::new(),
    }
}

fn generate() -> String {
    let vocab: Vec<String> = (0..VOCAB_SIZE).map(word_of).collect();
    let mut text = String::new();
    let mut seed = 20251105i64;
    for _ in 0..TOKEN_COUNT {
        let s1 = next_seed(seed);
        let s2 = next_seed(s1);
        let s3 = next_seed(s2);
        let x = s1 % VOCAB_SIZE;
        let w = &vocab[(x * x / VOCAB_SIZE) as usize];
        match s2 % 8 {
            0 => text.push_str(&capitalize(w)),
            1 => text.push_str(&w.to_uppercase()),
            _ => text.push_str(w),
        }
        text.push_str(match s3 % 16 { 0 => ", ", 1 => ". ", 2 => "\n", _ => " " });
        seed = s3;
    }
    text
}

fn word_hash(w: &str) -> i64 {
    w.chars().fold(7, |h, c| (h * 31 + c as i64) % 1000003)
}

fn main() {
    let text = generate();
    let lowered: String = text.to_lowercase()
        .chars().map(|c| if c == ' ' || c == ',' || c == '.' || c == '\n' { ' ' } else { c }).collect();
    let ws: Vec<&str> = lowered.split_whitespace().collect();
    let mut dict = Dict::new();
    for w in &ws {
        if let Some(n) = dict.get_mut(w) { *n += 1; } else { dict.insert(w, 1); }
    }
    let mut sorted: Vec<(&str, i64)> = dict.iter().map(|(w, n)| (*w, *n)).collect();
    sorted.sort_by(|(a, na), (b, nb)| match nb.cmp(na) { Ordering::Equal => a.cmp(b), o => o });
    println!("text length: {}", text.chars().count());
    println!("words: {}", ws.len());
    println!("distinct: {}", dict.len());
    for (i, (w, n)) in sorted.iter().take(10).enumerate() { println!("  {}. {} {}", i + 1, w, n); }
    let mut acc = 0i64;
    for (i, (w, n)) in sorted.iter().enumerate() { acc = (acc + (i as i64 + 1) * n + word_hash(w)) % 1000000007; }
    println!("checksum: {}", acc);
    let least: Vec<String> = sorted.iter().rev().take(3).map(|(w, n)| format!("{} {}", w, n)).collect();
    println!("least frequent: {}", least.join(", "));
}

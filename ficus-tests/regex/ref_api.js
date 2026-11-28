// The model of the decided behaviour of the Regex API (L24, L30), written with node's RegExp: stdin is a JSON list of [flags, pattern, subject],
// stdout a JSON list of {line, quirk}. `line` is what the Elm program of run_diff.py prints for the case (same text format); `quirk` is true
// when Elm 0.19.3 itself is known to differ (an empty match or an empty capture, where Elm's find, replace and split are the bugs of
// regex#5, #6, #13, #18). BMP subjects only (JavaScript counts UTF-16 units; Ficus code points).
const fs = require('fs');
const cases = JSON.parse(fs.readFileSync(0, 'utf8'));

function esc(s) {
  let o = '';
  for (const ch of s) {
    const n = ch.codePointAt(0);
    o += (n >= 32 && n < 127 && ch !== '\\' && ch !== '"' && ch !== '~') ? ch : '~u{' + n + '}';
  }
  return o;
}
const showSub = (x) => x === undefined ? '-' : '+' + esc(x);
const showM = (m, number) => '(' + esc(m[0]) + ',' + m.index + ',' + number + ',' + m.slice(1).map(showSub).join(';') + ')';
const lst = (l) => '[' + l.join('|') + ']';

function findAll(re, s) { return [...s.matchAll(re)]; }

// String.prototype.split by the specification (SplitMatcher at each position q, sticky), with Elm's limit: at most n separators; captures ignored
function split(sticky, s, n) {
  if (n <= 0) return [s];
  if (s.length === 0) { sticky.lastIndex = 0; return sticky.exec(s) ? [] : [s]; }
  const out = [];
  let p = 0, q = 0, count = 0;
  while (q < s.length) {
    sticky.lastIndex = q;
    const m = sticky.exec(s);
    if (!m) { q++; continue; }
    const e = Math.min(sticky.lastIndex, s.length);
    if (e === p) { q++; continue; }
    out.push(s.slice(p, q)); count++;
    p = e; q = p;
    if (count >= n) break;
  }
  out.push(s.slice(p));
  return out;
}

function runCase([f, pat, s]) {
  const fl = ((f & 2) ? 'm' : '') + ((f & 1) ? 'i' : '');
  let re, sticky;
  try { re = new RegExp(pat, 'g' + fl); sticky = new RegExp(pat, 'y' + fl); } catch (e) { return { line: 'N', quirk: false }; }
  const ms = findAll(re, s);
  const quirk = ms.some(m => m[0] === '' || m.slice(1).some(x => x === '')) || (s.length === 0 && ms.length > 0);
  const find = (n) => ms.slice(0, n).map((m, i) => showM(m, i + 1));
  const rep = (n) => {
    let count = 0;
    return s.replace(re, function (...args) {
      count++;
      if (count > n) return args[0];
      let k = args.length - 1;
      if (typeof args[k] === 'object') k--;           // the named groups object (never here)
      const m = args.slice(0, k - 1);
      m.index = args[k - 1];
      return '<' + showM(m, count) + '>';
    });
  };
  const line = [
    s.search(re) >= 0 ? 'T' : 'F',
    lst(find(Infinity)),
    lst(find(2)),
    esc(rep(Infinity)),
    esc(rep(2)),
    lst(split(sticky, s, Infinity).map(esc)),
    lst(split(sticky, s, 2).map(esc)),
  ].join(' ');
  return { line, quirk };
}

process.stdout.write(JSON.stringify(cases.map(runCase)));

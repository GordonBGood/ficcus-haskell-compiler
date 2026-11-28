// Reference for the engine-level differential (run_diff.py): the matchAll iteration of node's RegExp (the rule of L24) printed in the
// format of re_driver.c. Input: the same lines as re_driver ("flags<TAB>pattern<TAB>subject", \n \t \\ escaped); BMP subjects only.
// "N" for a pattern that node rejects. Offsets: bytes of UTF-8 and code points (= UTF-16 units for a BMP subject).
const fs = require('fs');
function unesc(s) { return s.replace(/\\(.)/gs, (_, c) => c === 'n' ? '\n' : c === 't' ? '\t' : c); }
const out = [];
for (const line of fs.readFileSync(0, 'utf8').split('\n')) {
  if (line === '') continue;
  const [fl, pat0, sub0] = line.split('\t');
  const pat = unesc(pat0), sub = unesc(sub0 === undefined ? '' : sub0), f = +fl;
  let re;
  try { re = new RegExp(pat, 'gd' + ((f & 2) ? 'm' : '') + ((f & 1) ? 'i' : '')); } catch (e) { out.push('N'); continue; }
  const bytes = [0];
  for (let i = 0; i < sub.length; i++) bytes.push(bytes[i] + Buffer.byteLength(sub[i]));
  const ms = [];
  for (const m of sub.matchAll(re)) {
    let s = `${bytes[m.index]},${bytes[m.index + m[0].length]},${m.index}`;
    for (let g = 1; g < m.length; g++) { const ix = m.indices[g]; s += ix === undefined ? '|-1,-1' : `|${bytes[ix[0]]},${bytes[ix[1]]}`; }
    ms.push(s);
  }
  out.push(ms.join(';'));
}
process.stdout.write(out.join('\n') + '\n');

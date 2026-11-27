// Runs one compiled Elm worker under node and prints what it printed, in order: Debug.log lines (console.log) as they are, and each
// outgoing port message as `<port>: <JSON>`, a String on the port `output` as its text (workertests' format; the C runner's,
// runtime/fic_sched.h). Incoming port messages come from the file in
// FIC_PORTS_IN (lines `<port> <JSON>`), sent after init returns, as workertests/runner.js sends its INPUTS. Flags: none.
// Usage: node run.js <compiled.js> <Module>
const path = require("path");
const fs = require("fs");
const out = [];
console.log = (...a) => out.push(a.join(" "));
console.warn = () => {};
process.on("exit", () => { if (out.length) process.stdout.write(out.join("\n") + "\n"); });
// FIC_TIME (the C program's virtual clock): Date.now is that time, so Time.now and the seed of Random.generate equal the C program's.
// The timers of node still run in real time (the tests print nothing that depends on the clock but these).
if (process.env.FIC_TIME) { const t = Number(process.env.FIC_TIME); Date.now = () => t; }
// F2 (docs/T1A-REVIEW.md): C orders its timers by (virtual deadline, creation); node by real time, so two timers due at the same virtual
// time may fire in either order there. Each timer's virtual deadline is tracked (the virtual now is the deadline of the timer that is
// firing, 0 before the first; a delay as node takes it: below 1 or not a number is 1) and a timer armed for the deadline of a pending
// one is flagged on stderr (`FIC_JS_TIE: ...`): its output may differ from C's. A flag only; node still runs the timers in real time.
// Elm's outgoing port manager waits `Process.sleep 0` after each dispatch (Platform.js); the C runtime has no such timer, so the
// compiled text is loaded with that one call marked (`untracked`) and its timers are not tracked.
const untracked = { valueOf: () => 0 };
{
  const vt = { now: 0, pending: new Map() };
  const vdelay = (d) => { const a = Number(d); return a >= 1 && a <= 2147483647 ? a : 1; };
  const arm = (h, at) => {
    for (const t of vt.pending.values())
      if (t === at) { process.stderr.write("FIC_JS_TIE: two timers share the virtual deadline " + at + " ms (node may order them unlike C)\n"); break; }
    vt.pending.set(h, at);
  };
  const st = setTimeout, ct = clearTimeout, si = setInterval, ci = clearInterval;
  global.setTimeout = (f, d, ...args) => {
    if (d === untracked) return st(f, 0, ...args);
    const at = vt.now + vdelay(d);
    const h = st(() => { vt.pending.delete(h); vt.now = at; f(...args); }, d);
    arm(h, at);
    return h;
  };
  global.clearTimeout = (h) => { vt.pending.delete(h); ct(h); };
  global.setInterval = (f, d, ...args) => {
    const every = vdelay(d);
    let at = vt.now + every;
    const h = si(() => { vt.now = at; at += every; vt.pending.delete(h); arm(h, at); f(...args); }, d);
    arm(h, at);
    return h;
  };
  global.clearInterval = (h) => { vt.pending.delete(h); ci(h); };
}
const file = path.resolve(process.argv[2]);
const Module = require("module");
const mod = new Module(file, module);
mod.filename = file; mod.paths = Module._nodeModulePaths(path.dirname(file));
global.__ficUntracked = untracked;
mod._compile(fs.readFileSync(file, "utf8").replace(
  /(function _Platform_setupOutgoingPort\(name\)\s*\{[\s\S]*?var init = _Process_sleep\()0(\);)/, "$1global.__ficUntracked$2"), file);
const Elm = mod.exports.Elm || global.Elm;
const app = Elm[process.argv[3]].init({});
if (app.ports) {
  for (const name of Object.keys(app.ports).sort()) {
    if (app.ports[name].subscribe)
      app.ports[name].subscribe((v) => out.push(name === "output" && typeof v === "string" ? v : name + ": " + JSON.stringify(v)));
  }
  if (process.env.FIC_PORTS_IN) {
    for (const line of fs.readFileSync(process.env.FIC_PORTS_IN, "utf8").split("\n")) {
      if (!line.trim()) continue;
      const i = line.indexOf(" ");
      app.ports[line.slice(0, i)].send(JSON.parse(line.slice(i + 1)));
    }
  }
}

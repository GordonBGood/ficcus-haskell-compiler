// E3a/E3b: runs one compiled Elm worker under node as the Elm twin of a Ficus test; prints what it printed, in order (Debug.log lines,
// port lines and the driver's own lines on stdout; a failure's message on stderr, exit 1).
//
// Flags: FIC_FLAGS (JSON text) or FIC_FLAGS_FILE (a file of it), as the C program reads them; neither: init({}) (undefined flags).
// Both: the C program's refusal, so the harness agrees (that case's expected output is the decision D11's, not Elm's).
// Crash 4: Elm's debug mode prints the Json.Decode.Error value as `[object Object]`; the compiled JS is patched to print
// Json.Decode.errorToString of it, which is the text Ficus gives (fic_port_error, and the runner's second line).
//
// Two modes. Runner (no FIC_HOST_SCRIPT): as effects2/ref/run.js: a printer on every outgoing port (`<port>: <JSON>`, a String on
// `output` as its text), then the lines `<port> <JSON>` of FIC_PORTS_IN; a value that does not fit ends the program (stderr, exit 1).
// Host script (FIC_HOST_SCRIPT=<file>): the commands of ficus-tests/effects3/host/host3.c, line for line:
//   sub P | sub2 P          a printer on P (`P: <JSON>`, `P#2: <JSON>`)
//   unsub P | unsub2 P      unsubscribes that printer
//   echo P Q k              a callback on P: prints `echo P: <JSON>`, then sends value + 100 to Q at once while value < k
//   once P                  a callback on P: prints `once P: <JSON>`, then unsubscribes itself
//   adder P                 a callback on P: prints `adder P: <JSON>`, then subscribes the `sub2` printer of P (once)
//   send P <JSON>           sends; a failure prints `send P failed:` and the text; no such port prints `send P: no such port`
// Usage: node run3.js <compiled.js> <Module>
const path = require("path");
const fs = require("fs");
const out = [];
console.log = (...a) => out.push(a.join(" "));
console.warn = () => {};
const flush = () => { if (out.length) { process.stdout.write(out.join("\n") + "\n"); out.length = 0; } };
process.on("exit", flush);
const die = (msg) => { flush(); process.stderr.write(msg + "\n"); process.exit(1); };
if (process.env.FIC_TIME) { const t = Number(process.env.FIC_TIME); Date.now = () => t; }

let src = fs.readFileSync(path.resolve(process.argv[2]), "utf8");
const crash4 = "through port `' + portName + '`:\\n' + problem";
if (src.includes(crash4)) src = src.replace(crash4, "through port `' + portName + '`:\\n' + $elm$json$Json$Decode$errorToString(problem)");
const g = {};
new Function("scope", "(function() {" + src + "\n}).call(scope);")(g);
const Elm = g.Elm;

const ft = process.env.FIC_FLAGS, ff = process.env.FIC_FLAGS_FILE;
if (ft && ff) die("FIC_FLAGS and FIC_FLAGS_FILE are both set: give the flags in one of them");
const args = {};
if (ft) args.flags = JSON.parse(ft);
else if (ff) args.flags = JSON.parse(fs.readFileSync(ff, "utf8"));
let app;
try { app = Elm[process.argv[3]].init(args); } catch (e) { die(e.message); }
const ports = app.ports || {};

const printers = {};
const printer = (p, label) => printers[label] || (printers[label] = (v) => out.push(p === "output" && typeof v === "string" ? v : label + ": " + JSON.stringify(v)));
const send = (p, v, runner) => {
  if (!ports[p] || !ports[p].send) { if (runner) die("there is no incoming port `" + p + "`"); out.push("send " + p + ": no such port"); return; }
  try { ports[p].send(v); }
  catch (e) {
    if (runner) die(e.message);
    out.push("send " + p + " failed:"); out.push(e.message.slice(e.message.indexOf("\n") + 1));
  }
};

if (process.env.FIC_HOST_SCRIPT) {
  for (const line of fs.readFileSync(process.env.FIC_HOST_SCRIPT, "utf8").split("\n")) {
    if (!line.trim() || line.startsWith("#")) continue;
    const w = line.split(" ");
    const [cmd, p] = w;
    const has = ports[p] && ports[p].subscribe;
    if (cmd === "send") { send(p, JSON.parse(w.slice(2).join(" ")), false); continue; }
    if (!has) { out.push(cmd + " " + p + ": no such port"); continue; }
    if (cmd === "sub") ports[p].subscribe(printer(p, p));
    else if (cmd === "sub2") ports[p].subscribe(printer(p, p + "#2"));
    else if (cmd === "unsub") ports[p].unsubscribe(printer(p, p));
    else if (cmd === "unsub2") ports[p].unsubscribe(printer(p, p + "#2"));
    else if (cmd === "echo") {
      const q = w[2], k = Number(w[3]);
      ports[p].subscribe((v) => { out.push("echo " + p + ": " + JSON.stringify(v)); if (v < k) send(q, v + 100, false); });
    } else if (cmd === "once") {
      const f = (v) => { out.push("once " + p + ": " + JSON.stringify(v)); ports[p].unsubscribe(f); };
      ports[p].subscribe(f);
    } else if (cmd === "adder") {
      let done = false;
      ports[p].subscribe((v) => { out.push("adder " + p + ": " + JSON.stringify(v)); if (!done) { done = true; ports[p].subscribe(printer(p, p + "#2")); } });
    } else die("unknown command: " + line);
  }
} else {
  for (const name of Object.keys(ports).sort()) if (ports[name].subscribe) ports[name].subscribe(printer(name, name));
  if (process.env.FIC_PORTS_IN) {
    for (const line of fs.readFileSync(process.env.FIC_PORTS_IN, "utf8").split("\n")) {
      if (!line.trim()) continue;
      const i = line.indexOf(" ");
      send(line.slice(0, i), JSON.parse(line.slice(i + 1)), true);
    }
  }
}

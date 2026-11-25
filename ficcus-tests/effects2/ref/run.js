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
const mod = require(path.resolve(process.argv[2]));
const Elm = mod.Elm || global.Elm;
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

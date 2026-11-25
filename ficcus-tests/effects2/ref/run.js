// Runs one compiled Elm worker under node and prints what it printed, in order: Debug.log lines (console.log) as they are, and each
// outgoing port message as `<port>: <JSON>` (the C runner's format, runtime/fic_sched.h). Incoming port messages come from the file in
// FIC_PORTS_IN (lines `<port> <JSON>`), sent after init returns, as workertests/runner.js sends its INPUTS. Flags: none.
// Usage: node run.js <compiled.js> <Module>
const path = require("path");
const fs = require("fs");
const out = [];
console.log = (...a) => out.push(a.join(" "));
console.warn = () => {};
process.on("exit", () => { if (out.length) process.stdout.write(out.join("\n") + "\n"); });
const mod = require(path.resolve(process.argv[2]));
const Elm = mod.Elm || global.Elm;
const app = Elm[process.argv[3]].init({});
if (app.ports) {
  for (const name of Object.keys(app.ports).sort()) {
    if (app.ports[name].subscribe) app.ports[name].subscribe((v) => out.push(name + ": " + JSON.stringify(v)));
  }
  if (process.env.FIC_PORTS_IN) {
    for (const line of fs.readFileSync(process.env.FIC_PORTS_IN, "utf8").split("\n")) {
      if (!line.trim()) continue;
      const i = line.indexOf(" ");
      app.ports[line.slice(0, i)].send(JSON.parse(line.slice(i + 1)));
    }
  }
}

// E3a review: Elm's side of host/drive.c. node drive.js <compiled elm.js> <lines>: each line `<port> <JSON>` is sent with
// app.ports.<port>.send(JSON.parse(json)); a refusal prints Json.Decode.errorToString (crash 4 patched, as effects3/ref/run3.js)
const fs = require("fs"), path = require("path");
const out = [];
console.log = (...a) => out.push(a.join(" "));
console.warn = () => {};
process.on("exit", () => { if (out.length) process.stdout.write(out.join("\n") + "\n"); });
let src = fs.readFileSync(path.resolve(process.argv[2]), "utf8");
const crash4 = "through port `' + portName + '`:\\n' + problem";
if (!src.includes(crash4)) throw new Error("crash 4 text not found");
src = src.replace(crash4, "through port `' + portName + '`:\\n' + $elm$json$Json$Decode$errorToString(problem)");
const g = {};
new Function("scope", "(function() {" + src + "\n}).call(scope);")(g);
const app = Object.values(g.Elm)[0].init({});
if (app.ports.out) app.ports.out.subscribe((s) => console.log("out: " + s));
for (const line of fs.readFileSync(process.argv[3], "utf8").split("\n")) {
  if (line === "") continue;
  const sp = line.indexOf(" "), port = line.slice(0, sp);
  let v;
  try { v = JSON.parse(line.slice(sp + 1)); } catch (e) { console.log(port + ": not JSON"); continue; }
  try { app.ports[port].send(v); console.log(port + ": ok"); }
  catch (e) { console.log(port + ": FAIL " + String(e.message).replace(/^Trying to send an unexpected type of value through port `[^`]*`:\n/, "")); }
}

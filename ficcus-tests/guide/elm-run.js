// run.js <main.js>: load a compiled Elm worker program and start it; Debug.log writes to stdout (console.log).
const path = require("path");
const { Elm } = require(path.resolve(process.argv[2]));
Elm.Main.init();

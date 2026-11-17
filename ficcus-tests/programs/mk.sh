#!/bin/sh
# mk.sh NN-name : create the directory skeleton (elm.json) and print the path of src/Main.fic
d=$(dirname "$0")/$1; mkdir -p "$d/src"; cp "$(dirname "$0")/elm.json.template" "$d/elm.json"

#!/usr/bin/env python3
"""derive.py -- runs the A4a derive matrix (cases/ and expected.tsv, written by derivegen.py) with the machinery of
../attach/attach.py (same outcomes, options and private ELM_HOME).

  python3 ficus-tests/derive/derive.py --elm bin/elmficA4a [--only a,b] [-v]"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "attach"))
import attach

attach.HERE = HERE
attach.CASES = os.path.join(HERE, "cases")
_elm_json = attach.elm_json


def elm_json(deps):
    # a package listed in deps is a direct dependency only (attach.py also keeps elm/json among the indirect ones)
    j = _elm_json(deps)
    for name in j["dependencies"]["direct"]:
        j["dependencies"]["indirect"].pop(name, None)
    return j


attach.elm_json = elm_json

if __name__ == "__main__":
    sys.exit(attach.main())

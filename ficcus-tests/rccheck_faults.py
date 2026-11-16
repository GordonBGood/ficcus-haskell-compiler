#!/usr/bin/env python3
"""Tests of the independent checker of the Rc pass (Ficcus.Mono.RcCheck): fault injection.

  python3 ficcus-tests/rccheck_faults.py --elm bin/elmficNN --elm-home H [--only a,b] [--sample F --seed S]

Every `dup` and `drop` that the pass inserts is needed (the counts are exact), so removing any single one of them must be reported
by the checker. For each example the program is compiled with `--rc` and FICCUS_RC_MUTATE=n for n = 0, K, 2K, ... (--sample F --seed S: a random
fraction F of the sites, fixed seed); the compiler must fail with a message that starts with "rc check:". Exit status 1 when a mutated program is accepted.

S4: the same for the reset/reuse operations (FICCUS_RC_MUTATE=rK): removal of a drop specialization (MSpec), of the token of one, of a
reuse (MReuse) and of a token free (MFreeTok). There are few of them, so they are ALWAYS tested in full, also with --sample (the sample
covers only the dup/drop sites; STAGE4-PLAN 14: sample 0.05, seed 1).

S6 (FICCUS_RC_MUTATE=sK), also always in full: a take whose index is changed (the placeholder it leaves could be seen) and an owning call
of a function value turned into an ordinary call (the function is never consumed). The example `fbip` has them; `vec` (V1) has the
takes of `Vector.update` (elements with references)."""
import argparse, os, random, subprocess, sys, shutil, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT = ["fib", "lists", "acc", "clo", "dict", "letnum", "str2", "inl", "clos", "vecself"]      # inl: the output of Ficcus.Mono.Inline (S7); clos: the twins of Ficcus.Mono.Twin (S7 part 3)


def compile_mutant(elm, home, work, mod, n, prefix=""):
    env = dict(os.environ, ELM_HOME=home, FICCUS_RC_MUTATE=prefix + str(n))
    p = subprocess.run([elm, "make", "src/" + mod, "--output=x.c", "--rc"], cwd=work, env=env, capture_output=True, text=True, timeout=300)
    return p.returncode, p.stdout + p.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True)
    ap.add_argument("--only", default=",".join(DEFAULT)); ap.add_argument("--sample", type=float, default=1.0, help="fraction of the sites to test (1.0: all)"); ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    elm = os.path.abspath(a.elm)
    bad = total = 0
    for name in a.only.split(","):
        work = tempfile.mkdtemp()
        dst = os.path.join(work, name)
        shutil.copytree(os.path.join(HERE, name), dst, ignore=shutil.ignore_patterns("elm-stuff"))
        mod = sorted(f for f in os.listdir(os.path.join(dst, "src")) if f.endswith(".fic"))[0]
        caught = missed = 0
        n = 0
        rc0, text0 = compile_mutant(elm, a.elm_home, dst, mod, 10**9)      # no such site: only a program that compiles gets this far
        if "there is no dup or drop number" not in text0:
            print("%-8s skipped: does not compile with --rc (%s)" % (name, text0.strip().splitlines()[0][:80])); continue
        rng = random.Random(a.seed)
        reuse_n = 0
        for prefix in ("", "r", "s"):
            n = 0
            while True:
                if prefix == "" and a.sample < 1.0 and rng.random() >= a.sample: n += 1; continue
                rc, text = compile_mutant(elm, a.elm_home, dst, mod, n, prefix)
                if "there is no dup or drop number" in text or "there is no reset or reuse number" in text or "there is no S6 site number" in text: break
                if rc != 0 and "rc check:" in text: caught += 1
                else:
                    missed += 1; print("MISSED %s: removing %ssite %d was accepted (exit %d) %s" % (name, prefix, n, rc, text[-200:]))
                if prefix in ("r", "s"): reuse_n += 1
                n += 1
        total += caught + missed; bad += missed
        print("%-8s %d mutations (%d reset/reuse/S6): %d caught, %d missed" % (name, caught + missed, reuse_n, caught, missed), flush=True)
        shutil.rmtree(work, ignore_errors=True)
    print("total %d mutations, %d missed" % (total, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

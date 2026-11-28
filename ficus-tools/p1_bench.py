#!/usr/bin/env python3
"""P1: the JSON parsing benchmark (targets/p1, targets/rust/json_*.rs): Ficus A (combinators over a Vector Int), C (recursive descent),
the String variant of A and B (real elm/parser) on the 1 MB size, Rust (Rc<dyn Fn> combinators, impl Fn combinators, recursive
descent) and hand C (recursive descent).

  python3 ficus-tools/p1_bench.py --elm bin/elmficNN --elm-home H --out DIR [--sizes 7500,375000] [--runs 5] [--str-runs 1]
                                   [--only a,b] [--elm-check --elm0193 bin/elm0193 --shim ficus-tests/vecshim]

Every program builds the document itself (the C path cannot read a file) and takes the stage as a constant (Ficus) or an argument:
stage 0 generates the text, 1 also converts it to a byte vector, 2 also parses and prints the checksum. Generation time = stage 0,
conversion = stage 1 - stage 0, parse = stage 2 - stage 1. Serial, one process at a time under `ulimit -v` 6 GB, median wall time
of --runs runs, maximum resident set (GNU time) of one more run. Ficus: --rc, gcc -O2 -ffp-contract=off; counters from a second
build with -DFIC_STATS and a count of closure, partial application, string and vector allocations (the generated C is patched in
the work directory, no compiler change). Hand C: gcc/clang -O2/-O3 (best of the stage 2 times). Rust: -C opt-level=3, safe.
Every stage 2 output must equal the checksum of ficus-tools/gen_json.py (Python's json module). Writes DIR/p1_bench.json, keeps the
inputs DIR/json_1mb.json and json_50mb.json; the build directory is removed at the end of each step."""
import argparse, json, os, re, resource, shutil, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ROOT = os.path.dirname(REPO)
RT = os.path.join(ROOT, "targets", "c")
P1 = os.path.join(REPO, "targets", "p1")
RS = os.path.join(REPO, "targets", "rust")
SAFE = os.path.join(HERE, "safe")


def cap():
    resource.setrlimit(resource.RLIMIT_AS, (6 << 30, 6 << 30))


def sh(cmd, env=None, cwd=None):
    p = subprocess.run(cmd, capture_output=True, env=env, cwd=cwd)
    return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace")


def quiet():
    for _ in range(60):
        if os.getloadavg()[0] < 1.5: return True
        time.sleep(10)
    print("WARNING: machine not quiet (load %.2f)" % os.getloadavg()[0], flush=True)
    return False


def timed(cmd, runs):
    """median wall time (ms), max RSS (MB) of one more run, the output of the last run"""
    quiet()
    ts, out = [], ""
    for _ in range(runs):
        t0 = time.perf_counter()
        p = subprocess.run(cmd, capture_output=True, preexec_fn=cap)
        ts.append((time.perf_counter() - t0) * 1000)
        if p.returncode != 0: return None, None, "exit %d %s" % (p.returncode, p.stderr.decode()[-200:])
        out = (p.stdout + p.stderr).decode("utf-8", "replace")
    p = subprocess.run(["/usr/bin/time", "-f", "RSS %M"] + cmd, capture_output=True, preexec_fn=cap)
    rss = int(re.search(r"RSS (\d+)", p.stderr.decode()).group(1)) / 1024.0
    return statistics.median(ts), rss, out


def norm(out):
    for l in out.splitlines():
        if l.startswith(("nodes=", "text length", "vector length", "error")):
            return re.sub(r": \(\)$", "", l.strip())
    return out.strip()[-100:]


def counters(out):
    m = re.search(r"FIC_STATS: (.*)", out)
    d = {k: int(v) for k, v in re.findall(r"(\w+) (\d+)", m.group(1))} if m else {}
    m = re.search(r"TAGS: closure (\d+) pap (\d+) string (\d+) vector (\d+)", out)
    if m: d.update(closure=int(m.group(1)), pap=int(m.group(2)), string=int(m.group(3)), vector=int(m.group(4)))
    return d


PATCH_DECL = """
static size_t fic_tc_clo, fic_tc_pap, fic_tc_str, fic_tc_vec;
static void fic_tc_print(void) { fprintf(stderr, "TAGS: closure %zu pap %zu string %zu vector %zu\\n", fic_tc_clo, fic_tc_pap, fic_tc_str, fic_tc_vec); }
__attribute__((constructor)) static void fic_tc_init(void) { atexit(fic_tc_print); }
"""


def patch_tags(c):
    t = open(c).read()
    a = "static inline void *fic_alloc(size_t bytes, uint16_t tag, uint16_t nptr) {"
    b = "  fic_live_objects++; fic_total_allocs++;"
    assert a in t and b in t
    t = t.replace(a, PATCH_DECL + a, 1)
    t = t.replace(b, b + "\n  if (tag == FIC_TAG_CLOSURE) fic_tc_clo++; else if (tag == FIC_TAG_PAP) fic_tc_pap++; else if (tag == FIC_TAG_STRING) fic_tc_str++; else if (tag == FIC_TAG_VECTOR) fic_tc_vec++;", 1)
    open(c, "w").write(t)


def set_config(d, records, stage):
    p = os.path.join(d, "src", "JsonConfig.elm")
    t = open(p).read()
    t = re.sub(r"(records =\n    )\d+", r"\g<1>%d" % records, t)
    t = re.sub(r"(stage =\n    )\d+", r"\g<1>%d" % stage, t)
    open(p, "w").write(t)


class Ctx: pass


def build_ficus(x, mod, records, stage, stats, work):
    d = os.path.join(work, "fic_%s_%d_%d" % (mod, records, stage))
    if not os.path.isdir(d):
        shutil.copytree(P1, d); set_config(d, records, stage)
    c = os.path.join(d, "x.c")
    if not os.path.exists(c):
        env = dict(os.environ, ELM_HOME=os.path.abspath(x.elm_home))
        rc, msg = sh([SAFE, os.path.abspath(x.elm), "make", "src/%s.elm" % mod, "--output=x.c", "--rc"], env=env, cwd=d)
        if rc != 0: raise SystemExit("compile %s failed: %s" % (mod, msg[-500:]))
    exe = os.path.join(d, "stats" if stats else "run")
    src = c
    if stats:
        src = os.path.join(d, "xs.c"); shutil.copy(c, src); patch_tags(src)
    flags = ["-DFIC_STATS"] if stats else []
    rc, msg = sh(["gcc", "-std=c99", "-O2", "-ffp-contract=off", "-w"] + flags + ["-I", RT, src, "-o", exe, "-lm"])
    if rc != 0: raise SystemExit("gcc failed: " + msg[-500:])
    return exe


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elm", required=True); ap.add_argument("--elm-home", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--sizes", default="7500,375000"); ap.add_argument("--runs", type=int, default=5); ap.add_argument("--str-runs", type=int, default=1)
    ap.add_argument("--only", default=""); ap.add_argument("--work", default="")
    ap.add_argument("--elm-check", action="store_true"); ap.add_argument("--elm0193", default=os.path.join(ROOT, "bin", "elm0193"))
    ap.add_argument("--shim", default=os.path.join(REPO, "ficus-tests", "vecshim"))
    ap.add_argument("--str-sizes", default="125,250,500,1000,7500")
    a = ap.parse_args()
    x = Ctx(); x.elm, x.elm_home = a.elm, a.elm_home
    only = set(filter(None, a.only.split(",")))
    avail = [int(l.split()[1]) for l in open("/proc/meminfo") if l.startswith("MemAvailable:")][0] / 1048576.0
    if avail < 8: print("less than 8 GB available: not run"); return 1
    os.makedirs(a.out, exist_ok=True)
    work = a.work or os.path.join(a.out, "work")
    resfile = os.path.join(a.out, "p1_bench.json")
    res = json.load(open(resfile)) if os.path.exists(resfile) else {}

    def save(): json.dump(res, open(resfile, "w"), indent=1)

    for n in [int(s) for s in a.sizes.split(",")]:
        tag = "1mb" if n < 100000 else "50mb"
        inp = os.path.join(a.out, "json_%s.json" % tag)
        r = res.setdefault(tag, {"records": n})
        if "expected" not in r:
            rc, msg = sh([sys.executable, "-I", os.path.join(HERE, "gen_json.py"), str(n), inp])
            if rc != 0: print("gen_json failed", msg[-300:]); return 1
            m = re.match(r"N=\d+ bytes=(\d+) (.*)", msg.strip())
            r["bytes"], r["expected"] = int(m.group(1)), m.group(2)
            print(tag, "input", r["bytes"], "bytes;", r["expected"], flush=True); save()
        exp = r["expected"]
        os.makedirs(work, exist_ok=True)

        def measure(name, mk, stages=(0, 1, 2), runs=None):
            """mk(stage) -> command list"""
            if only and name not in only: return
            runs = runs or a.runs
            e = r.setdefault(name, {})
            for st in stages:
                cmd = mk(st)
                t, rss, out = timed(cmd, runs)
                if t is None: e["stage%d" % st] = {"error": out}; print(tag, name, st, "FAILED", out, flush=True); continue
                line = norm(out)
                ok = (line == exp) if st == 2 else (line.endswith(str(r["bytes"])) if st in (0, 1) else True)
                e["stage%d" % st] = {"ms": t, "rss_mb": rss, "ok": ok, "line": line}
                print(tag, name, "stage", st, "%.1f ms" % t, "%.1f MB" % rss, "OK" if ok else "MISMATCH " + line, flush=True)
            save()

        def rust(name, srcname):
            exe = os.path.join(work, name)
            rc, msg = sh(["rustc", "--edition", "2021", "-C", "opt-level=3", "-A", "warnings", os.path.join(RS, srcname), "-o", exe])
            if rc != 0: raise SystemExit("rustc " + srcname + ": " + msg[-500:])
            measure("rust_" + name, lambda st: [exe, str(n), str(st)])

        # Rust
        rust("rd", "json_rd.rs"); rust("comb_impl", "json_comb_impl.rs"); rust("comb_dyn", "json_comb_dyn.rs")
        # hand C: the four builds, the best at stage 2 gets all stages
        if not only or "hand_c" in only:
            best = None
            for cc in ("gcc", "clang"):
                for opt in ("-O2", "-O3"):
                    exe = os.path.join(work, "hand_%s%s" % (cc, opt))
                    rc, msg = sh([cc, "-std=c99", opt, "-ffp-contract=off", "-w", os.path.join(P1, "json_hand.c"), "-o", exe, "-lm"])
                    if rc != 0: raise SystemExit("hand C: " + msg[-300:])
                    t, rss, out = timed([exe, str(n), "2"], a.runs)
                    r.setdefault("hand_c_builds", {})["%s %s" % (cc, opt)] = {"ms": t, "rss_mb": rss, "ok": norm(out) == exp}
                    print(tag, "hand C", cc, opt, "%.1f ms" % t, "OK" if norm(out) == exp else "MISMATCH", flush=True)
                    if best is None or t < best[0]: best = (t, exe, "%s %s" % (cc, opt))
            r["hand_c_best"] = best[2]
            measure("hand_c", lambda st: [best[1], str(n), str(st)])
        # Ficus
        for mod, name in (("JsonComb", "ficus_A"), ("JsonHand", "ficus_C")):
            if only and name not in only: continue
            exes = {st: build_ficus(x, mod, n, st, False, work) for st in (0, 1, 2)}
            measure(name, lambda st: [exes[st]])
            if "counters" not in r.get(name, {}):
                cs = {}
                for st in (0, 1, 2):
                    p = subprocess.run([build_ficus(x, mod, n, st, True, work)], capture_output=True, preexec_fn=cap)
                    cs[st] = counters((p.stdout + p.stderr).decode("utf-8", "replace"))
                r[name]["counters"] = cs; save()
                print(tag, name, "counters stage 2:", cs[2], flush=True)
            shutil.rmtree(work, ignore_errors=True); os.makedirs(work, exist_ok=True)
        if n < 100000:
            # version B (real elm/parser) and the String variant of A: 1 MB only
            for mod, name, runs in (("JsonPkg", "ficus_B", a.runs),) + ((("JsonStrComb", "ficus_A_string", a.str_runs),) if "strfull" not in os.environ.get("P1_SKIP", "") else ()):
                if only and name not in only: continue
                try:
                    e0 = build_ficus(x, mod, n, 0, False, work); e2 = build_ficus(x, mod, n, 2, False, work)
                except SystemExit as ex:
                    r[name] = {"error": str(ex)}; print(name, "does not build:", ex); save(); continue
                measure(name, lambda st: [e0 if st == 0 else e2], stages=(0, 2), runs=runs)
                if "counters" not in r.get(name, {}):
                    cs = {}
                    for st in (0, 2):
                        if name == "ficus_A_string" and st == 2: continue
                        p = subprocess.run([build_ficus(x, mod, n, st, True, work)], capture_output=True, preexec_fn=cap)
                        cs[st] = counters((p.stdout + p.stderr).decode("utf-8", "replace"))
                    r[name]["counters"] = cs; save()
                shutil.rmtree(work, ignore_errors=True); os.makedirs(work, exist_ok=True)
            # the String variant on smaller documents: the cost grows with the square of the size (String.slice is O(offset))
            if not only or "ficus_A_string_scaling" in only:
                import importlib.util
                sp = importlib.util.spec_from_file_location("gen_json", os.path.join(HERE, "gen_json.py")); gj = importlib.util.module_from_spec(sp); sp.loader.exec_module(gj)
                sc = r.setdefault("ficus_A_string_scaling", {})
                for k in [int(s) for s in a.str_sizes.split(",") if int(s) < n]:
                    doc = gj.Gen().document(k)
                    want = re.sub(r"^N=\d+ bytes=\d+ ", "", "N=%d bytes=%d %s" % (k, len(doc), gj.checksum(doc)))
                    e2 = build_ficus(x, "JsonStrComb", k, 2, False, work)
                    t, rss, out = timed([e2], 1)
                    sc[str(k)] = {"bytes": len(doc), "ms": t, "rss_mb": rss, "ok": norm(out) == want}
                    print(tag, "A string", k, "records", len(doc), "bytes", "%.0f ms" % t, "OK" if norm(out) == want else "MISMATCH", flush=True); save()
                    shutil.rmtree(work, ignore_errors=True); os.makedirs(work, exist_ok=True)
        shutil.rmtree(work, ignore_errors=True)
    if a.elm_check:
        n = 7500; d = os.path.join(work, "elmcheck"); os.makedirs(work, exist_ok=True)
        shutil.copytree(P1, d); shutil.copytree(a.shim, os.path.join(d, "shim"))
        ej = open(os.path.join(d, "elm.json")).read().replace('"src"\n', '"src", "shim"\n'); open(os.path.join(d, "elm.json"), "w").write(ej)
        set_config(d, n, 2)
        env = dict(os.environ, ELM_HOME=os.path.abspath(x.elm_home)); out = {}
        for mod in ("JsonComb", "JsonHand"):
            rc, msg = sh([a.elm0193, "make", "src/%s.elm" % mod, "--output=%s.js" % mod], env=env, cwd=d)
            p = subprocess.run(["node", "--stack-size=50000", "-e", "const {Elm}=require('./%s.js'); Elm.%s.init();" % (mod, mod)], cwd=d, capture_output=True)
            out[mod] = norm((p.stdout + p.stderr).decode())
            print("Elm 0.19.3 under node", mod, out[mod], "OK" if out[mod] == res["1mb"]["expected"] else "MISMATCH", flush=True)
        res["elm_node_1mb"] = {k: {"line": v, "ok": v == res["1mb"]["expected"]} for k, v in out.items()}; save()
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

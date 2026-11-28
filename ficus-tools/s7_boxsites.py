import re,sys,subprocess,os
W="/home/gordon/Documents/HaskellWork/FiccusDevel"
S=os.path.dirname(os.path.abspath(__file__))
names=sys.argv[1:]
pat=re.compile(r'\(\((\w+) \*\)fic_alloc\(sizeof\((\w+)\), FIC_TAG_BOX, (\d+)\)')
for n in names:
    src=open(f"{S}/s7/{n}_fic.c").read().split("\n")
    out=[];sites=[]
    fn=None
    for i,l in enumerate(src):
        m=re.match(r'^(?:static )?[\w\* ]+? \**(\w+)\(.*\) \{$',l)
        if m: fn=m.group(1)
        pm=re.search(r'\((\w+) \*\)fic_alloc\(sizeof\((\w+)\), FIC_TAG_BOX, (\d+)\)',l)
        if pm:
            k=len(sites); vm=re.search(r"\*(\w+) = ",l); var=vm.group(1) if vm else "?"
            use=[x.strip() for x in src[i+1:i+40] if re.search(r"\b"+var+r"\b|a\d+ = \(&"+var+r"->h\)",x) and "->s" not in x.split("=")[0]][:3]
            # follow the alias a = (&o->h)
            al=None
            for x in src[i+1:i+8]:
                am=re.match(r"\s*fic_ref (\w+) = \(&"+var+r"->h\);",x)
                if am: al=am.group(1)
            if al: use+= [x.strip() for x in src[i+1:i+40] if re.search(r"\b"+al+r"\b",x)][1:3]
            sites.append((i+1,fn,pm.group(2),"\n".join(use+["","",""])))
            l=l.replace(pm.group(0),f"({pm.group(1)} *)(fic_boxsite[{k}]++,fic_alloc(sizeof({pm.group(2)}), FIC_TAG_BOX, {pm.group(3)}))")
        out.append(l)
    text="\n".join(out)
    # counters after fic_alloc definition: put before first function that uses; simplest: declare at top after includes via marker
    text=f"static unsigned long fic_boxsite[{len(sites)+1}];\n"+text
    # report at exit
    rep="static void fic_boxreport(void){ "+"".join(f'if(fic_boxsite[{k}]) fprintf(stderr,"BOXSITE {k} %lu\\n",fic_boxsite[{k}]);' for k in range(len(sites)))+"}\n"
    j=text.index("int main(void)")
    text=text[:j]+rep+text[j:]
    text=text.replace("int main(void) {","int main(void) { atexit(fic_boxreport);",1)
    open(f"{S}/box/{n}.c","w").write(text)
    r=subprocess.run(["gcc","-std=c99","-O2","-w","-DFIC_STATS","-ffp-contract=off","-I",f"{W}/targets/c",f"{S}/box/{n}.c","-o",f"{S}/box/{n}","-lm"],capture_output=True,text=True)
    if r.returncode: print(n,"BUILD FAIL",r.stderr[:300]); continue
    r=subprocess.run([f"{S}/box/{n}"],capture_output=True,text=True)
    tot=0; rows=[]
    allocs=re.search(r"allocs (\d+)",r.stderr)
    for m in re.finditer(r"BOXSITE (\d+) (\d+)",r.stderr):
        k,c=int(m.group(1)),int(m.group(2)); tot+=c; rows.append((c,k))
    def cls(ctx):
        u=ctx.split("\n")
        t=" ".join(u[:3])
        if re.search(r"->r\d+ = a\d+;|->r\d+ = o\d+",t) and not re.search(r"fic_ja|FIC_JA",t): return "cell/ctor field"
        if re.search(r"fic_ja_|FIC_JA_DATA|fic_vec",t): return "array element"
        if re.search(r"fic_ap\d|fic_pap|closure",t): return "closure/PAP"
        if re.search(r"\(fic_s_\w+\)\{",t): return "struct field (tuple/record)"
        if re.search(r"f\d+_\w+\(|entry\d+\(|return ",t): return "call argument/return"
        return "other"
    bycls={}
    for c,k in rows: bycls[cls(sites[k][3])]=bycls.get(cls(sites[k][3]),0)+c
    print(f"== {n}: box allocations {tot} of {allocs.group(1) if allocs else '?'}  by use: {bycls}")
    for c,k in sorted(rows,reverse=True)[:6]:
        ln,fn,ty,ctx=sites[k]; 
        print(f"  {c:>10}  line {ln} in {fn} {ty}")
        print("      "+ctx.split("\n")[0].strip()[:110]); print("      "+ctx.split("\n")[1].strip()[:110]); print("      "+ctx.split("\n")[2].strip()[:110])

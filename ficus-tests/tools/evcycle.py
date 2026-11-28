#!/usr/bin/env python3
# evcycle.py FILE... : for each eventlog, the threads whose last stop before the first deadlock GC is BlockedOnBlackHole, and their owners
import struct, sys
def events(path):
    d=open(path,"rb").read(); p=0
    def take(n):
        nonlocal p; b=d[p:p+n]; p+=n; return b
    take(8); sizes={}; names={}
    while True:
        tag=take(4)
        if tag==b"hete": break
        num,size=struct.unpack(">Hh",take(4)); dl,=struct.unpack(">I",take(4)); names[num]=take(dl).decode(); el,=struct.unpack(">I",take(4)); take(el); take(4); sizes[num]=size
    take(8); cap=None; ev=[]
    while p<len(d):
        num,=struct.unpack(">H",take(2))
        if num==0xffff: break
        t,=struct.unpack(">Q",take(8)); size=sizes[num]
        if size==-1: size,=struct.unpack(">H",take(2))
        b=take(size)
        if num==18: cap=struct.unpack(">IQH",b[:14])[2]; continue
        ev.append((t,cap,num,b,names[num]))
    ev.sort(key=lambda e:e[0]); return ev
for path in sys.argv[1:]:
    ev=events(path); t0=ev[0][0]; state={}
    # the deadlock GC: the last GC before the first "weak finalizer"-free burst; use: the GC after which blackhole-blocked threads run without a Wakeup
    for t,cap,num,b,n in ev:
        if num==2:
            tid,st,on=struct.unpack(">IHI",b[:10]); state[tid]=(st,on,(t-t0)/1e6)
        elif num==1:
            tid,=struct.unpack(">I",b[:4]); state[tid]=("run",0,(t-t0)/1e6)
        elif n=="Starting GC":
            bh={k:v for k,v in state.items() if v[0]==8}
            owners={k:v[1] for k,v in bh.items()}
            cyc=[k for k,o in owners.items() if owners.get(o)==k]
            if cyc:
                print("%s: GC at %.1f ms; blackhole cycle %s; blocked on blackholes %s" % (path.split("/")[-1], (t-t0)/1e6, sorted(cyc), {k:v[1] for k,v in bh.items()})); break
    else:
        print(path.split("/")[-1], ": no blackhole cycle found")

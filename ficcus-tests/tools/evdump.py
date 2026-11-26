#!/usr/bin/env python3
# evdump.py FILE [FROM_MS] : the raw thread, GC and label events of a GHC eventlog (+RTS -l), one line each, from
# FROM_MS milliseconds after the first event; needs evlog.py next to it.
import struct, sys
from evlog import STATUS
d=open(sys.argv[1],"rb").read(); p=0; lo=float(sys.argv[2]) if len(sys.argv)>2 else 0
def take(n):
    global p; b=d[p:p+n]; p+=n; return b
take(8); sizes={}; names={}
while True:
    tag=take(4)
    if tag==b"hete": break
    num,size=struct.unpack(">Hh",take(4)); dl,=struct.unpack(">I",take(4)); names[num]=take(dl).decode(); el,=struct.unpack(">I",take(4)); take(el); take(4); sizes[num]=size
take(8); cap=None; t0=None
while p<len(d):
    num,=struct.unpack(">H",take(2))
    if num==0xffff: break
    t,=struct.unpack(">Q",take(8)); size=sizes[num]
    if size==-1: size,=struct.unpack(">H",take(2))
    b=take(size)
    if num==18: cap=struct.unpack(">IQH",b[:14])[2]; continue
    if t0 is None: t0=t
    ms=(t-t0)/1e6
    if ms<lo: continue
    if num in (0,1,3,8,4):
        print("%9.3f cap%-2s %-14s thread %d" % (ms,cap,names[num][:14],struct.unpack(">I",b[:4])[0]) + (" -> cap %d" % struct.unpack(">IH",b[:6])[1] if num==8 else ""))
    elif num==2:
        tid,st,on=struct.unpack(">IHI",b[:10]); print("%9.3f cap%-2s stop thread %d %s%s"%(ms,cap,tid,STATUS.get(st,st),(" on %d"%on) if on else ""))
    elif num==44:
        print("%9.3f label %d %s"%(ms,struct.unpack(">I",b[:4])[0],b[4:].decode(errors="replace")))
    elif names[num].startswith(("Start GC","End GC","Request")) :
        print("%9.3f cap%-2s %s"%(ms,cap,names[num]))

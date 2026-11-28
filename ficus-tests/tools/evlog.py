#!/usr/bin/env python3
# evlog.py FILE : the thread events of a GHC eventlog (+RTS -l): for each thread, who created it (the thread
# running on that capability), its last stop status and what it was blocked on, and the thread labels.
import struct, sys

STATUS = {0: "NoStatus", 1: "HeapOverflow", 2: "StackOverflow", 3: "Yielding", 4: "Blocked", 5: "Finished",
          6: "ForeignCall", 7: "BlockedOnMVar", 8: "BlockedOnBlackHole", 9: "BlockedOnRead", 10: "BlockedOnWrite",
          11: "BlockedOnDelay", 12: "BlockedOnSTM", 13: "BlockedOnDoProc", 14: "BlockedOnCCall",
          15: "BlockedOnCCall_NoUnblockExc", 16: "BlockedOnMsgThrowTo", 17: "Migrating", 18: "BlockedOnMsgGlobalise",
          19: "BlockedOnBlackHoleOwnedBy", 20: "BlockedOnMVarRead"}


def main(path):
    d = open(path, "rb").read()
    p = 0
    def take(n):
        nonlocal p
        b = d[p:p + n]; p += n; return b
    assert take(4) == b"hdrb" and take(4) == b"hetb"
    sizes = {}
    while True:
        tag = take(4)
        if tag == b"hete": break
        assert tag == b"etb\0", tag
        num, size = struct.unpack(">Hh", take(4))
        dlen, = struct.unpack(">I", take(4)); take(dlen)
        elen, = struct.unpack(">I", take(4)); take(elen)
        assert take(4) == b"ete\0"
        sizes[num] = size
    assert take(4) == b"hdre" and take(4) == b"datb"
    cap = None
    running = {}          # capability -> thread
    threads = {}          # thread -> dict
    order = []
    while p < len(d):
        num, = struct.unpack(">H", take(2))
        if num == 0xffff: break
        t, = struct.unpack(">Q", take(8))
        size = sizes[num]
        if size == -1:
            size, = struct.unpack(">H", take(2))
        body = take(size)
        if num == 18:                               # EVENT_BLOCK_MARKER: size, end time, capability
            cap = struct.unpack(">IQH", body[:14])[2]; continue
        if num == 0:                                # CREATE_THREAD
            tid, = struct.unpack(">I", body[:4])
            threads[tid] = {"by": running.get(cap), "t0": t, "status": "created", "on": 0, "label": "", "t": t}
            order.append(tid)
        elif num == 1:                              # RUN_THREAD
            tid, = struct.unpack(">I", body[:4]); running[cap] = tid
            threads.setdefault(tid, {"by": None, "t0": t, "status": "?", "on": 0, "label": ""})
            if tid not in order: order.append(tid)
            threads[tid]["status"] = "running"; threads[tid]["t"] = t
        elif num == 2:                              # STOP_THREAD: thread, status, blocked on
            tid, st, on = struct.unpack(">IHI", body[:10]); running[cap] = None
            th = threads.setdefault(tid, {"by": None, "t0": t, "status": "?", "on": 0, "label": ""})
            th["status"] = STATUS.get(st, str(st)); th["on"] = on; th["t"] = t
        elif num == 44:                             # THREAD_LABEL
            tid, = struct.unpack(">I", body[:4]); threads.setdefault(tid, {"by": None, "t0": t, "status": "?", "on": 0, "label": ""})["label"] = body[4:].decode(errors="replace")
    t0 = min(th["t0"] for th in threads.values()) if threads else 0
    for tid in order:
        th = threads[tid]
        print("thread %-4d by %-5s created %8.3f ms  last %-22s %8.3f ms%s%s" % (
            tid, th["by"], (th["t0"] - t0) / 1e6, th["status"], (th.get("t", t0) - t0) / 1e6,
            (" on %d" % th["on"]) if th["on"] else "", ("  [%s]" % th["label"]) if th["label"] else ""))


if __name__ == "__main__":
    main(sys.argv[1])

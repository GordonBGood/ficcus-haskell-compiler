/* fic_conc.h -- Ficcus T1a: the kernels of the `Concurrent` module (overlay/Concurrent.elm; docs/attach/T1A-NOTES.md;
 * docs/T1-THREADING-DESIGN.md T1-D2 to T1-D6, T1-D13, T1-D14) on the E2 scheduler (runtime/fic_sched.h), one thread, green processes.
 * The JavaScript twin is runtime/fic_conc.js (same rules; the differential reference).
 * Emitted after fic_sched.h only by programs that reach a kernel of Concurrent; such a program gets fic_sched.h with three checked
 * text patches (Ficcus.Mono.Concurrent.patchSched): the run queue's pick is fic_conc_pick, the process being stepped is kept in
 * fic_conc_cur_p, and fic_platform_teardown starts with fic_conc_teardown. Every other program gets fic_sched.h unchanged.
 *
 * Objects. A Concurrent process is a record (fic_cproc) beside its E2 process (fic_proc): the handles Pid, Address and Mailbox are all
 * this record. Its mailbox is its own FIFO chain of fic_mail (kind SELF, `a` the message word), not the E2 process's mbox: a message to
 * an E2 process re-runs the binding it waits in (E2 = Elm's rawSend), which a sleeping Concurrent process must not see. The E2 mbox only
 * gets one wake mail per block. A Channel is a record of kind channel (no process): its queue holds the messages the effect manager has
 * not yet delivered; a send to it queues the message and sends the record to the manager as a self message (through the router that
 * the manager gave with `attach`). Only the owner of a mailbox may receive from it (O8), so at most one process waits on a mailbox.
 *
 * Blocking. `receive`, `receiveWithin` and `await` return the E2 receive task (FIC_TAG_TASK_RECEIVE) whose router is a fic_conc_router:
 * the step stops on it while the E2 mbox is empty; the wake mail makes fic_sched_receive call the onSelfMsg of the manager slot
 * FIC_CONC_MGR (a slot above every real manager; fic_nmgr never reaches it), fic_conc_on_self, which continues the process.
 * receiveWithin arms an E2 interval timer for the waiting process whose task (run as a process when it fires) wakes it with `nothing`;
 * a message first cancels the timer. The epoch makes a stale timeout a no-op.
 *
 * The operations that complete at once (spawn, send, kill, and receive, receiveWithin, await that need not wait) are a task
 * `andThen op (succeed ())` whose callback op does the work when the process reaches it: the process does not yield (rule R1).
 *
 * Registry (T1-D13): every record from its creation to the end of the program (ended ones are swept when nothing else holds them), so
 * cycles through handles in mailboxes, stacks and exit values are broken at the end: fic_conc_teardown kills what still runs, wakes
 * nobody, drops mailboxes, waiters and exit values, then the records and the router.
 *
 * FIC_SCHED_SEED=<n> (T1-D14, seeded shuffle): the run queue picks a random runnable domain instead of its head: the candidates are every
 * queued Concurrent process and the first queued other process (the app's domain keeps E2's FIFO order); xorshift64* from n. */
#ifndef FIC_CONC_H
#define FIC_CONC_H
#include <stddef.h>

#define FIC_TAG_CPROC       0xFFB0u   /* { proc, qhead, awaiters, exitv, killedv, wjust, wnothing } scalars */
#define FIC_TAG_CONC_ROUTER 0xFFB1u   /* { cproc } mgr kind: the router of a blocked receive or await (prefix = fic_router) */
#define FIC_CONC_MGR (FIC_MAX_MGR - 1)

enum { FIC_CONC_RUNNING, FIC_CONC_DONE, FIC_CONC_KILLED };
enum { FIC_CONC_WAIT_RECV = 1, FIC_CONC_WAIT_WITHIN, FIC_CONC_WAIT_AWAIT, FIC_CONC_WAIT_NEVER };
enum { FIC_CONC_PROCESS, FIC_CONC_CHANNEL };

typedef struct {
  fic_hdr h;
  fic_ref proc;        /* the E2 process while it runs, then none (a channel: none) */
  fic_ref qhead;       /* the mailbox (a channel: its undelivered messages): a chain of fic_mail, none when empty */
  fic_ref awaiters;    /* processes blocked in await of this process, oldest first (fic_sched_cell list) */
  fic_ref exitv;       /* the exit value once ended, none before */
  fic_ref killedv;     /* the value `Killed` given at spawn */
  fic_ref wjust;       /* receiveWithin pending: `Just` and `Nothing`, none otherwise */
  fic_ref wnothing;
  fic_hdr *qtail;
  int64_t id;          /* 1, 2, ... in creation order (processes and channels) */
  int64_t owner;       /* the E2 id of the process (the only one that may receive) */
  uint32_t state, kind, index;
  uint32_t waiting;    /* the owner waits: 0, FIC_CONC_WAIT_RECV or FIC_CONC_WAIT_WITHIN */
  uint32_t timed_out, epoch;
} fic_cproc;

typedef struct { fic_hdr h; fic_ref cproc; uint32_t mgr; uint32_t kind; } fic_conc_router;
/* F3: fic_sched_receive reads ((fic_router *)r)->mgr of a fic_conc_router: the two must start alike (a compile time check, C99) */
typedef char fic_conc_router_layout[(offsetof(fic_router, proc) == offsetof(fic_conc_router, cproc)
                                     && offsetof(fic_router, mgr) == offsetof(fic_conc_router, mgr)
                                     && sizeof(((fic_router *)0)->mgr) == sizeof(((fic_conc_router *)0)->mgr)) ? 1 : -1];

/* the operation closures: { code, a, b, w } with nptr = 2 + (w is a reference) */
typedef struct { fic_hdr h; const fic_code *code; fic_ref a; fic_ref b; fic_word w; } fic_conc_op;

static fic_ref *fic_conc_reg; static size_t fic_conc_nreg, fic_conc_capreg, fic_conc_sweep_at = 64;
static size_t fic_conc_n_spawned, fic_conc_n_sent, fic_conc_n_dropped;
static int64_t fic_conc_ids;
static int fic_conc_slot_ready;
static int fic_conc_ending;          /* in fic_conc_teardown: nothing is woken (a wake outside a drain would run the process now) */
static fic_ref fic_conc_router_ref;  /* the router of the Concurrent manager (attach), or NULL */
static fic_ref *fic_conc_held; static size_t fic_conc_nheld, fic_conc_capheld;   /* O9: channels whose oldest message waits (owned) */
static uint64_t fic_conc_rng; static int fic_conc_shuffle = -1;

/* ---- the run queue's pick (patched into fic_sched_enqueue) ---- */

static uint64_t fic_conc_next(void) {
  uint64_t x = fic_conc_rng;
  x ^= x >> 12; x ^= x << 25; x ^= x >> 27; fic_conc_rng = x;
  return x * 2685821657736338717ull;
}
static int fic_conc_is_cproc_proc(fic_ref p) { return ((fic_proc *)p)->id < 0; }   /* a Concurrent process's id is negated at spawn */

static fic_ref fic_conc_pick(void) {
  size_t i, n = 0, chosen, first_other = (size_t)-1, at;
  fic_ref q;
  if (fic_conc_shuffle < 0) {
    const char *s = getenv("FIC_SCHED_SEED");
    fic_conc_shuffle = s != NULL && *s != 0;
    if (fic_conc_shuffle) { fic_conc_rng = (uint64_t)strtoull(s, NULL, 10) * 0x9E3779B97F4A7C15ull + 1; if (fic_conc_rng == 0) fic_conc_rng = 1; }
  }
  if (!fic_conc_shuffle || fic_rq_len < 2) return fic_rq[fic_rq_head];
  for (i = 0; i < fic_rq_len; i++) {                                 /* the candidates: Concurrent entries and the first other one */
    fic_ref e = fic_rq[(fic_rq_head + i) % fic_rq_cap];
    if (fic_conc_is_cproc_proc(e)) n++;
    else if (first_other == (size_t)-1) { first_other = i; n++; }
  }
  chosen = (size_t)(fic_conc_next() % (uint64_t)n);
  for (i = 0, at = 0; i < fic_rq_len; i++) {
    fic_ref e = fic_rq[(fic_rq_head + i) % fic_rq_cap];
    if (fic_conc_is_cproc_proc(e) || i == first_other) { if (at == chosen) break; at++; }
  }
  /* move entry i to the head, the entries before it one place back (the others keep their order) */
  q = fic_rq[(fic_rq_head + i) % fic_rq_cap];
  for (; i > 0; i--) fic_rq[(fic_rq_head + i) % fic_rq_cap] = fic_rq[(fic_rq_head + i - 1) % fic_rq_cap];
  fic_rq[fic_rq_head] = q;
  return q;
}

/* ---- helpers ---- */

static fic_clo fic_conc_on_self_clo;
/* the manager slot of the blocks: only its onSelfMsg is read (fic_sched_receive); fic_nmgr stays below it */
static void fic_conc_slot(void) {
  fic_mgr *g = &fic_mgrs[FIC_CONC_MGR];
  if (fic_conc_slot_ready) return;
  if (fic_nmgr > FIC_CONC_MGR) { fprintf(stderr, "Concurrent: too many effect managers\n"); abort(); }
  memset(g, 0, sizeof *g);
  g->name = NULL; g->kind = FIC_MGR_ELM; g->state_ref = 0; g->on_self = &fic_conc_on_self_clo.h;
  g->init = FIC_NONE; g->on_effects = FIC_NONE; g->router = FIC_NONE; g->cmds = FIC_NONE; g->subs = FIC_NONE; g->port_subs = FIC_NONE;
  fic_conc_slot_ready = 1;
}

static fic_ref fic_conc_cur(void) {
  if (fic_conc_cur_p == NULL) { fprintf(stderr, "internal: a Concurrent operation outside a process\n"); abort(); }
  return (fic_ref)fic_conc_cur_p;
}

/* O8: a mailbox is private: a receive by any other process is the program's end with this message (as a crash: exit 1) */
static void fic_conc_owner_check(fic_cproc *c, const char *what) {
  if (c->kind != FIC_CONC_PROCESS || ((fic_proc *)fic_conc_cur())->id != c->owner) {
    fflush(stdout);
    fprintf(stderr, "Concurrent.%s: the mailbox belongs to another process (only the body given to spawnWith may receive from it)\n", what);
    exit(1);
  }
}

/* a list of processes, oldest first: append consumes p */
static void fic_conc_list_append(fic_ref *list, fic_ref p) {
  fic_ref *at = list;
  while (*at != FIC_NONE) at = &((fic_sched_cell *)*at)->tail;
  FIC_RC_DROP(*at);
  *at = fic_sched_cons(p, fic_none());
}
/* pop the oldest (owned), or NULL */
static fic_ref fic_conc_list_pop(fic_ref *list) {
  fic_sched_cell *c; fic_ref p;
  if (*list == FIC_NONE) return NULL;
  c = (fic_sched_cell *)*list;
  p = c->head; FIC_RC_DUP(p);
  *list = c->tail; FIC_RC_DUP(c->tail);
  FIC_RC_DROP(&c->h);
  return p;
}

/* wake a blocked process with a mail (consumed); its root is the receive of this block unless it was killed (then dropped) */
static void fic_conc_wake(fic_ref p, fic_word v, int isref) {
  fic_sched_raw_send(p, fic_mail_new(FIC_MAIL_SELF, v, FIC_W_UNIT, isref));
}

static fic_ref fic_conc_block(fic_ref cp, uint32_t kind) {         /* the receive task of a block (cp borrowed) */
  fic_conc_router *r = (fic_conc_router *)fic_alloc(sizeof(fic_conc_router), FIC_TAG_CONC_ROUTER, 1);
  fic_conc_slot();
  FIC_RC_DUP(cp); r->cproc = cp; r->mgr = FIC_CONC_MGR; r->kind = kind;
  return fic_task_receive(&r->h, FIC_W_UNIT, 0);
}

static void fic_conc_set(fic_ref *slot, fic_ref v) { fic_ref old = *slot; *slot = v; FIC_RC_DROP(old); }   /* consumes v */

static void fic_conc_drop_mail(fic_cproc *c) {
  fic_ref m = c->qhead;
  c->qhead = fic_none(); c->qtail = NULL;
  FIC_RC_DROP(m);
}

static void fic_conc_append(fic_cproc *c, fic_ref m) {               /* consumes the mail */
  if (c->qhead == FIC_NONE) { FIC_RC_DROP(c->qhead); c->qhead = m; } else { FIC_RC_DROP(((fic_mail *)c->qtail)->next); ((fic_mail *)c->qtail)->next = m; }
  c->qtail = m;
}

/* pop the head mail (owned) */
static fic_mail *fic_conc_pop(fic_cproc *c) {
  fic_mail *m = (fic_mail *)c->qhead;
  c->qhead = m->next; m->next = fic_none();
  if (c->qhead == FIC_NONE) c->qtail = NULL;
  return m;
}

/* the end of a process (done or killed): the exit value (consumed), the waiters woken in order, the mailbox and the process dropped */
static void fic_conc_end(fic_cproc *c, uint32_t state, fic_ref exitv) {
  fic_ref w, proc = c->proc;
  c->state = state; c->waiting = 0;
  fic_conc_set(&c->exitv, exitv);
  fic_conc_drop_mail(c);
  fic_conc_set(&c->wjust, fic_none()); fic_conc_set(&c->wnothing, fic_none());
  while ((w = fic_conc_list_pop(&c->awaiters)) != NULL) {
    if (!fic_conc_ending) { FIC_RC_DUP(c->exitv); fic_conc_wake(w, fic_w_p(c->exitv), 1); }
    FIC_RC_DROP(w);
  }
  c->proc = fic_none();
  FIC_RC_DROP(proc);
}

static void fic_conc_reg_remove(size_t i) {
  fic_ref last = fic_conc_reg[--fic_conc_nreg];
  if (i < fic_conc_nreg) { fic_conc_reg[i] = last; ((fic_cproc *)last)->index = (uint32_t)i; }
}

/* drop the records of ended processes (and of channels) that only the registry still holds */
static void fic_conc_sweep(void) {
#ifdef FIC_RC
  size_t i = 0;
  while (i < fic_conc_nreg) {
    fic_cproc *c = (fic_cproc *)fic_conc_reg[i];
    if ((c->state != FIC_CONC_RUNNING || c->kind == FIC_CONC_CHANNEL) && c->h.rc == 1) { fic_conc_reg_remove(i); FIC_RC_DROP(&c->h); }
    else i++;
  }
#endif
  fic_conc_sweep_at = fic_conc_nreg * 2 < 64 ? 64 : fic_conc_nreg * 2;
}

static void fic_conc_reg_add(fic_ref cp) {                          /* consumes a count */
  if (fic_conc_nreg >= fic_conc_sweep_at) fic_conc_sweep();
  if (fic_conc_nreg == fic_conc_capreg) {
    size_t cap = fic_conc_capreg == 0 ? 64 : fic_conc_capreg * 2;
    fic_ref *r = (fic_ref *)realloc(fic_conc_reg, cap * sizeof(fic_ref));
    if (r == NULL) abort();
    fic_conc_reg = r; fic_conc_capreg = cap;
  }
  ((fic_cproc *)cp)->index = (uint32_t)fic_conc_nreg;
  fic_conc_reg[fic_conc_nreg++] = cp;
}

static fic_cproc *fic_conc_record(uint32_t kind) {                  /* a new record (owned) in the registry */
  fic_cproc *c = (fic_cproc *)fic_alloc(sizeof(fic_cproc), FIC_TAG_CPROC, 7);
  c->proc = fic_none(); c->qhead = fic_none(); c->awaiters = fic_none(); c->exitv = fic_none(); c->killedv = fic_none();
  c->wjust = fic_none(); c->wnothing = fic_none();
  c->qtail = NULL; c->id = ++fic_conc_ids; c->owner = 0;
  c->state = FIC_CONC_RUNNING; c->kind = kind; c->waiting = 0; c->timed_out = 0; c->epoch = 0;
  FIC_RC_DUP(&c->h); fic_conc_reg_add(&c->h);
  return c;
}

/* ---- the operations ---- */

static fic_ref fic_conc_op_task(const fic_code *code, fic_ref a, fic_ref b, fic_word w, int wref) {   /* consumes a, b, w */
  fic_conc_op *o = (fic_conc_op *)fic_alloc(sizeof(fic_conc_op), FIC_TAG_CLOSURE, (uint16_t)(2 + (wref ? 1 : 0)));
  o->code = code; o->a = a; o->b = b; o->w = w;
  return fic_task_and_then(&o->h, fic_task_succeed(FIC_W_UNIT, 0));
}
#define FIC_CONC_OP(self) ((fic_conc_op *)(self))
#define FIC_CONC_UNIT_TASK fic_w_p(fic_task_succeed(FIC_W_UNIT, 0))

/* the end of the body: the exit value (a reference) */
static fic_word fic_conc_finish_entry(fic_ref self, fic_word v) {
  fic_cproc *c = (fic_cproc *)FIC_CONC_OP(self)->a;
  if (c->state == FIC_CONC_RUNNING) fic_conc_end(c, FIC_CONC_DONE, v.p); else FIC_RC_DROP(v.p);
  return FIC_CONC_UNIT_TASK;
}
static const fic_code fic_conc_finish_code = { (void (*)(void))fic_conc_finish_entry, 1u FIC_CODE_OWN0 };

/* spawnRaw killed body: a = killed, b = body (Mailbox msg -> Task Never exit) */
static fic_word fic_conc_spawn_entry(fic_ref self, fic_word u) {
  fic_conc_op *o = FIC_CONC_OP(self);
  fic_cproc *c = fic_conc_record(FIC_CONC_PROCESS);
  fic_ref root, p;
  fic_conc_op *fin;
  (void)u;
  FIC_RC_DUP(o->a); fic_conc_set(&c->killedv, o->a);
  fin = (fic_conc_op *)fic_alloc(sizeof(fic_conc_op), FIC_TAG_CLOSURE, 2);
  fin->code = &fic_conc_finish_code; FIC_RC_DUP(&c->h); fin->a = &c->h; fin->b = fic_none(); fin->w = FIC_W_UNIT;
  FIC_RC_DUP(o->b); FIC_RC_DUP(&c->h);
  root = fic_task_and_then(&fin->h, fic_task_and_then(o->b, fic_task_succeed(fic_w_p(&c->h), 1)));
  p = fic_proc_new(root);
  ((fic_proc *)p)->id = -((fic_proc *)p)->id - 1;
  c->owner = ((fic_proc *)p)->id;
  FIC_RC_DUP(p); fic_conc_set(&c->proc, p);
  fic_conc_n_spawned++;
  fic_sched_enqueue(p);                                              /* queued: the parent goes on (R2) */
  return fic_w_p(fic_task_succeed(fic_w_p(&c->h), 1));
}
static const fic_code fic_conc_spawn_code = { (void (*)(void))fic_conc_spawn_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_spawn(fic_ref killed, fic_ref body) {
  return fic_conc_op_task(&fic_conc_spawn_code, killed, body, FIC_W_UNIT, 0);
}

/* address, self, toAddress: the same record under another type */
static FIC_UNUSED fic_ref fic_conc_same(fic_ref x) { return x; }
/* channelId, chanRefId (borrowed) */
static FIC_UNUSED int64_t fic_conc_id(fic_ref x) { return ((fic_cproc *)x)->id; }

/* send addr msg: a = the record, w = the message */
static fic_word fic_conc_send_entry(fic_ref self, fic_word u) {
  fic_conc_op *o = FIC_CONC_OP(self);
  fic_cproc *c = (fic_cproc *)o->a;
  int isref = o->h.nptr == 3;
  (void)u;
  fic_conc_n_sent++;
  if (c->kind == FIC_CONC_CHANNEL) {                                 /* a channel: to the effect manager (T1-D6) */
    if (fic_conc_router_ref == NULL) { fic_conc_n_dropped++; return FIC_CONC_UNIT_TASK; }
    if (isref) FIC_RC_DUP(o->w.p);
    fic_conc_append(c, fic_mail_new(FIC_MAIL_SELF, o->w, FIC_W_UNIT, isref));
    FIC_RC_DUP(&c->h);
    fic_sched_raw_send(((fic_router *)fic_conc_router_ref)->proc, fic_mail_new(FIC_MAIL_SELF, fic_w_p(&c->h), FIC_W_UNIT, 1));
    return FIC_CONC_UNIT_TASK;
  }
  if (c->state != FIC_CONC_RUNNING) { fic_conc_n_dropped++; return FIC_CONC_UNIT_TASK; }
  if (isref) FIC_RC_DUP(o->w.p);
  fic_conc_append(c, fic_mail_new(FIC_MAIL_SELF, o->w, FIC_W_UNIT, isref));
  if (c->waiting != 0) {                                             /* the owner waits: queue it (R3) */
    fic_proc *p = (fic_proc *)c->proc;
    if (c->waiting == FIC_CONC_WAIT_WITHIN && p->timer >= 0) fic_sched_bind_async(p, NULL);   /* the message comes first: no timeout */
    c->waiting = 0; c->timed_out = 0;
    FIC_RC_DUP(&p->h);
    fic_conc_wake(&p->h, FIC_W_UNIT, 0);
    FIC_RC_DROP(&p->h);
  }
  return FIC_CONC_UNIT_TASK;
}
static const fic_code fic_conc_send_code = { (void (*)(void))fic_conc_send_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_send(fic_ref addr, fic_word msg, int isref) {
  return fic_conc_op_task(&fic_conc_send_code, addr, fic_none(), msg, isref);
}

/* the head of the mailbox as a succeed task (it is there) */
static fic_ref fic_conc_take_head(fic_cproc *c) {
  fic_mail *m = fic_conc_pop(c);
  int isref = m->h.nptr == 2;
  fic_word v = m->a;
  fic_ref t;
  if (isref) FIC_RC_DUP(v.p);
  t = fic_task_succeed(v, isref);
  FIC_RC_DROP(&m->h);
  return t;
}

/* receive (R4): the head at once, or wait */
static fic_word fic_conc_receive_entry(fic_ref self, fic_word u) {
  fic_cproc *c = (fic_cproc *)FIC_CONC_OP(self)->a;
  (void)u;
  fic_conc_owner_check(c, "receive");
  if (c->qhead != FIC_NONE) return fic_w_p(fic_conc_take_head(c));
  c->waiting = FIC_CONC_WAIT_RECV;
  return fic_w_p(fic_conc_block(&c->h, FIC_CONC_WAIT_RECV));
}
static const fic_code fic_conc_receive_code = { (void (*)(void))fic_conc_receive_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_receive(fic_ref box) { return fic_conc_op_task(&fic_conc_receive_code, box, fic_none(), FIC_W_UNIT, 0); }

/* receiveWithin: `just msg` (applied to the head) */
static fic_ref fic_conc_just_head(fic_cproc *c, fic_ref just) {
  fic_mail *m = fic_conc_pop(c);
  int isref = m->h.nptr == 2;
  fic_word v = m->a, r;
  if (isref) FIC_RC_DUP(v.p);
  r = fic_ap1(just, isref ? 1u : 0u, v);
  FIC_RC_DROP(&m->h);
  return fic_task_succeed(r, 1);
}

/* the timeout task of a receiveWithin (run as a process by the interval timer): a = the record, w = the epoch */
static fic_word fic_conc_timeout_entry(fic_ref self, fic_word u) {
  fic_conc_op *o = FIC_CONC_OP(self);
  fic_cproc *c = (fic_cproc *)o->a;
  (void)u;
  if (c->state == FIC_CONC_RUNNING && c->waiting == FIC_CONC_WAIT_WITHIN && (int64_t)c->epoch == o->w.i) {
    fic_proc *p = (fic_proc *)c->proc;
    if (p->timer >= 0) fic_sched_bind_async(p, NULL);               /* the interval ends */
    c->waiting = 0; c->timed_out = 1;
    FIC_RC_DUP(&p->h);
    fic_conc_wake(&p->h, FIC_W_UNIT, 0);
    FIC_RC_DROP(&p->h);
  }
  return FIC_CONC_UNIT_TASK;
}
static const fic_code fic_conc_timeout_code = { (void (*)(void))fic_conc_timeout_entry, 1u FIC_CODE_OWN0 };

/* receiveWithinRaw ms box just nothing: a = box, b = just, w = nothing (a reference); the delay is in the op of the call */
typedef struct { fic_hdr h; const fic_code *code; fic_ref box; fic_ref just; fic_ref nothing; double ms; } fic_conc_within_op;
static fic_word fic_conc_within_entry(fic_ref self, fic_word u) {
  fic_conc_within_op *o = (fic_conc_within_op *)self;
  fic_cproc *c = (fic_cproc *)o->box;
  fic_proc *p;
  double ms;
  (void)u;
  fic_conc_owner_check(c, "receiveWithin");
  if (c->qhead != FIC_NONE) return fic_w_p(fic_conc_just_head(c, o->just));
  p = (fic_proc *)c->proc;
  FIC_RC_DUP(o->just); fic_conc_set(&c->wjust, o->just);
  FIC_RC_DUP(o->nothing); fic_conc_set(&c->wnothing, o->nothing);
  c->waiting = FIC_CONC_WAIT_WITHIN; c->timed_out = 0; c->epoch++;
  ms = fic_timer_delay(o->ms);
  FIC_RC_DUP(&c->h);
  fic_tm_add(p, fic_conc_op_task(&fic_conc_timeout_code, &c->h, fic_none(), fic_w_i((int64_t)c->epoch), 0), ms, ms);
  return fic_w_p(fic_conc_block(&c->h, FIC_CONC_WAIT_WITHIN));
}
static const fic_code fic_conc_within_code = { (void (*)(void))fic_conc_within_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_receive_within(double ms, fic_ref box, fic_ref just, fic_ref nothing) {
  fic_conc_within_op *o = (fic_conc_within_op *)fic_alloc(sizeof(fic_conc_within_op), FIC_TAG_CLOSURE, 3);
  o->code = &fic_conc_within_code; o->box = box; o->just = just; o->nothing = nothing; o->ms = ms;
  return fic_task_and_then(&o->h, fic_task_succeed(FIC_W_UNIT, 0));
}

/* await pid (R5) */
static fic_word fic_conc_await_entry(fic_ref self, fic_word u) {
  fic_cproc *c = (fic_cproc *)FIC_CONC_OP(self)->a;
  fic_ref p;
  (void)u;
  if (c->state != FIC_CONC_RUNNING) { FIC_RC_DUP(c->exitv); return fic_w_p(fic_task_succeed(fic_w_p(c->exitv), 1)); }
  p = fic_conc_cur();
  FIC_RC_DUP(p);
  fic_conc_list_append(&c->awaiters, p);
  return fic_w_p(fic_conc_block(&c->h, FIC_CONC_WAIT_AWAIT));
}
static const fic_code fic_conc_await_code = { (void (*)(void))fic_conc_await_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_await(fic_ref pid) { return fic_conc_op_task(&fic_conc_await_code, pid, fic_none(), FIC_W_UNIT, 0); }

/* stop the E2 process of c now (E2's kill: the pending timer cancelled, root and stack dropped; a later resume is a no-op) */
static void fic_conc_stop(fic_cproc *c) {
  fic_proc *q = (fic_proc *)c->proc;
  fic_ref root, stack;
  if (&q->h == FIC_NONE) return;
  if (q->timer >= 0) fic_sched_bind_async(q, NULL);
  q->seq++;
  root = q->root; stack = q->stack;
  q->root = fic_none(); q->stack = fic_none();
  FIC_RC_DROP(root); FIC_RC_DROP(stack);
}

/* kill pid (R6): a self kill stops the process after this operation (its stack is being popped by the step: the result is a block
   that nothing wakes, and the process is released when the step ends) */
static fic_word fic_conc_kill_entry(fic_ref self, fic_word u) {
  fic_cproc *c = (fic_cproc *)FIC_CONC_OP(self)->a;
  int own;
  (void)u;
  if (c->state != FIC_CONC_RUNNING) return FIC_CONC_UNIT_TASK;
  own = c->proc == fic_conc_cur();
  if (!own) fic_conc_stop(c);
  FIC_RC_DUP(c->killedv);
  fic_conc_end(c, FIC_CONC_KILLED, c->killedv);
  if (own) return fic_w_p(fic_conc_block(&c->h, FIC_CONC_WAIT_NEVER));
  return FIC_CONC_UNIT_TASK;
}
static const fic_code fic_conc_kill_code = { (void (*)(void))fic_conc_kill_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_kill(fic_ref pid) { return fic_conc_op_task(&fic_conc_kill_code, pid, fic_none(), FIC_W_UNIT, 0); }

/* ---- channels and the effect manager (T1-D6) ---- */

static fic_word fic_conc_new_channel_entry(fic_ref self, fic_word u) {
  fic_cproc *c = fic_conc_record(FIC_CONC_CHANNEL);
  (void)self; (void)u;
  return fic_w_p(fic_task_succeed(fic_w_p(&c->h), 1));
}
static const fic_code fic_conc_new_channel_code = { (void (*)(void))fic_conc_new_channel_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_new_channel(void) { return fic_conc_op_task(&fic_conc_new_channel_code, fic_none(), fic_none(), FIC_W_UNIT, 0); }

/* current ch: the oldest undelivered message (it stays) */
static fic_word fic_conc_current_entry(fic_ref self, fic_word u) {
  fic_cproc *c = (fic_cproc *)FIC_CONC_OP(self)->a;
  fic_mail *m;
  int isref;
  (void)u;
  if (c->qhead == FIC_NONE) { fprintf(stderr, "internal: Concurrent: a channel without a message\n"); abort(); }
  m = (fic_mail *)c->qhead; isref = m->h.nptr == 2;
  if (isref) FIC_RC_DUP(m->a.p);
  return fic_w_p(fic_task_succeed(m->a, isref));
}
static const fic_code fic_conc_current_code = { (void (*)(void))fic_conc_current_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_current(fic_ref ch) { return fic_conc_op_task(&fic_conc_current_code, ch, fic_none(), FIC_W_UNIT, 0); }

/* O9: an effects dispatch for the Concurrent manager is under way: fic_platform_dispatch has gathered but not yet sent its FX mail (it
 * sets every manager's cmds to a list and back to none when it sends), or the FX mail waits in the manager's mailbox. A message that
 * finds no listen then is kept until that onEffects (the start-up race of R9: a message sent in the turn that subscribes). */
static int fic_conc_fx_pending(void) {
  fic_router *r = (fic_router *)fic_conc_router_ref;
  fic_ref q;
  if (fic_mgrs[r->mgr].cmds != FIC_NONE) return 1;
  for (q = ((fic_proc *)r->proc)->mbox; q != FIC_NONE; q = ((fic_mail *)q)->next)
    if (((fic_mail *)q)->kind == FIC_MAIL_FX) return 1;
  return 0;
}

/* advance ref listeners: the delivered (or, with no listener, dropped) message goes. listeners 0 (onSelfMsg): kept instead while a
 * dispatch is under way (O9); -1 (onEffects, a kept message that still has no listen): dropped. */
static fic_word fic_conc_advance_entry(fic_ref self, fic_word u) {
  fic_conc_op *o = FIC_CONC_OP(self);
  fic_cproc *c = (fic_cproc *)o->a;
  (void)u;
  if (o->w.i == 0 && fic_conc_fx_pending()) {                        /* O9: kept for the listens of the dispatch under way */
    if (fic_conc_nheld == fic_conc_capheld) {
      size_t cap = fic_conc_capheld == 0 ? 8 : fic_conc_capheld * 2;
      fic_ref *q = (fic_ref *)realloc(fic_conc_held, cap * sizeof(fic_ref));
      if (q == NULL) abort();
      fic_conc_held = q; fic_conc_capheld = cap;
    }
    FIC_RC_DUP(&c->h); fic_conc_held[fic_conc_nheld++] = &c->h;
    return FIC_CONC_UNIT_TASK;
  }
  if (c->qhead != FIC_NONE) { fic_mail *m = fic_conc_pop(c); FIC_RC_DROP(&m->h); }
  if (o->w.i <= 0) fic_conc_n_dropped++;
  return FIC_CONC_UNIT_TASK;
}
static const fic_code fic_conc_advance_code = { (void (*)(void))fic_conc_advance_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_advance(fic_ref ref, int64_t n) { return fic_conc_op_task(&fic_conc_advance_code, ref, fic_none(), fic_w_i(n), 0); }

/* held (): the kept channels, oldest first (O9; onEffects delivers them with the new subscriptions) */
typedef struct { fic_hdr h; fic_ref f0; fic_ref f1; } fic_conc_cell;
static fic_word fic_conc_held_entry(fic_ref self, fic_word u) {
  fic_ref list = fic_nil();
  (void)self; (void)u;
  while (fic_conc_nheld > 0) {
    fic_conc_cell *c = (fic_conc_cell *)fic_alloc(sizeof(fic_conc_cell), 1u, 2);
    c->f0 = fic_conc_held[--fic_conc_nheld]; c->f1 = list; list = &c->h;
  }
  return fic_w_p(fic_task_succeed(fic_w_p(list), 1));
}
static const fic_code fic_conc_held_code = { (void (*)(void))fic_conc_held_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_held_task(void) { return fic_conc_op_task(&fic_conc_held_code, fic_none(), fic_none(), FIC_W_UNIT, 0); }

/* attach router: the manager's router, kept from its first onEffects to the end */
static fic_word fic_conc_attach_entry(fic_ref self, fic_word u) {
  fic_ref r = FIC_CONC_OP(self)->a;
  (void)u;
  if (fic_conc_router_ref == NULL) { FIC_RC_DUP(r); fic_conc_router_ref = r; }
  return FIC_CONC_UNIT_TASK;
}
static const fic_code fic_conc_attach_code = { (void (*)(void))fic_conc_attach_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_attach(fic_ref router) { return fic_conc_op_task(&fic_conc_attach_code, router, fic_none(), FIC_W_UNIT, 0); }

/* ---- the continuation of a block ---- */

/* the onSelfMsg of the slot FIC_CONC_MGR: a blocked process continues (router owned, msg owned when a reference, state unit) */
static fic_word fic_conc_on_self_entry(fic_ref self, fic_word router, fic_word msg, fic_word state) {
  fic_conc_router *r = (fic_conc_router *)router.p;
  fic_cproc *c = (fic_cproc *)r->cproc;
  fic_ref t;
  (void)self; (void)state;
  switch (r->kind) {
  case FIC_CONC_WAIT_RECV: t = fic_conc_take_head(c); break;
  case FIC_CONC_WAIT_WITHIN:
    if (c->timed_out) { c->timed_out = 0; FIC_RC_DUP(c->wnothing); t = fic_task_succeed(fic_w_p(c->wnothing), 1); }
    else t = fic_conc_just_head(c, c->wjust);
    fic_conc_set(&c->wjust, fic_none()); fic_conc_set(&c->wnothing, fic_none());
    break;
  case FIC_CONC_WAIT_AWAIT: t = fic_task_succeed(msg, 1); break;          /* the exit value (owned) */
  default: fprintf(stderr, "internal: a wake of a stopped Concurrent process\n"); abort();
  }
  FIC_RC_DROP(router.p);
  return fic_w_p(t);
}
static const fic_code fic_conc_on_self_code = { (void (*)(void))fic_conc_on_self_entry, 3u FIC_CODE_OWN0 };
static fic_clo fic_conc_on_self_clo = { { FIC_IMMORTAL, FIC_TAG_CLOSURE, 0, 0 }, &fic_conc_on_self_code };

/* ---- the end of the program (patched into the start of fic_platform_teardown) ---- */

static void fic_conc_teardown(void) {
  size_t i, blocked = 0;
  fic_conc_ending = 1;
  for (i = 0; i < fic_conc_nreg; i++) {
    fic_cproc *c = (fic_cproc *)fic_conc_reg[i];
    if (c->kind == FIC_CONC_PROCESS && c->state == FIC_CONC_RUNNING) { blocked++; fic_conc_stop(c); FIC_RC_DUP(c->killedv); fic_conc_end(c, FIC_CONC_KILLED, c->killedv); }
    else fic_conc_drop_mail(c);
  }
  for (i = 0; i < fic_conc_nreg; i++) {                              /* the cycles through exit values and handles */
    fic_cproc *c = (fic_cproc *)fic_conc_reg[i];
    fic_conc_set(&c->exitv, fic_none()); fic_conc_set(&c->killedv, fic_none());
  }
#if defined(FIC_STATS) || defined(FIC_WARN_BLOCKED)
  fprintf(stderr, "FIC_STATS concurrent: spawned %zu sent %zu dropped %zu blocked_at_end %zu\n",
          fic_conc_n_spawned, fic_conc_n_sent, fic_conc_n_dropped, blocked);
#else
  (void)blocked;
#endif
  while (fic_conc_nheld > 0) FIC_RC_DROP(fic_conc_held[--fic_conc_nheld]);   /* O9: kept past the last dispatch: freed */
  free(fic_conc_held); fic_conc_held = NULL; fic_conc_capheld = 0;
  for (i = 0; i < fic_conc_nreg; i++) FIC_RC_DROP(fic_conc_reg[i]);
  free(fic_conc_reg); fic_conc_reg = NULL; fic_conc_nreg = fic_conc_capreg = 0;
  if (fic_conc_router_ref != NULL) { FIC_RC_DROP(fic_conc_router_ref); fic_conc_router_ref = NULL; }
  if (fic_conc_slot_ready) { memset(&fic_mgrs[FIC_CONC_MGR], 0, sizeof fic_mgrs[FIC_CONC_MGR]); fic_conc_slot_ready = 0; }
  fic_conc_ending = 0;
}

#endif /* FIC_CONC_H */

/* fic_conc.h -- Ficcus T1a-1: the kernels of the `Concurrent` module (overlay/Concurrent.elm; docs/attach/T1A-NOTES.md;
 * docs/T1-THREADING-DESIGN.md T1-D2 to T1-D5, T1-D13, T1-D14) on the E2 scheduler (runtime/fic_sched.h), one thread, green processes.
 * Emitted after fic_sched.h only by programs that reach a kernel of Concurrent; such a program gets fic_sched.h with three checked
 * text patches (Ficcus.Mono.Concurrent.patchSched): the run queue's pick is fic_conc_pick, the process being stepped is kept in
 * fic_conc_cur_p, and fic_platform_teardown starts with fic_conc_teardown. Every other program gets fic_sched.h unchanged.
 *
 * Objects. A Concurrent process is a record (fic_cproc) beside its E2 process (fic_proc): the handles Pid, Address and Mailbox are all
 * this record. Its mailbox is its own FIFO chain of fic_mail (kind SELF, `a` the message word), not the E2 process's mbox: a message to
 * an E2 process re-runs the binding it waits in (E2 = Elm's rawSend), which a sleeping Concurrent process must not see. The E2 mbox only
 * gets one wake mail per block, sent when the process blocked in `receive` or `await` may continue.
 *
 * Blocking. `receive` and `await` return the E2 receive task (FIC_TAG_TASK_RECEIVE) whose router is a fic_conc_router: the step stops on
 * it while the E2 mbox is empty; the wake mail makes fic_sched_receive call the onSelfMsg of the manager slot FIC_CONC_MGR (a slot above
 * every real manager; fic_nmgr never reaches it), fic_conc_on_self, which continues the process.
 *
 * The operations that complete at once (spawn, send, kill, receive and await that need not wait) are a task `andThen op (succeed ())`
 * whose callback op does the work when the process reaches it: the process does not yield (T1A-NOTES section 3, rule R1).
 *
 * Registry (T1-D13): every record from its spawn to the end of the program (finished ones are swept when nothing else holds them), so
 * cycles through handles in mailboxes, stacks and exit values are broken at the end: fic_conc_teardown kills what still runs, drops
 * mailboxes, waiters and exit values, then the records. A process blocked in receive or await does not keep the program alive.
 *
 * FIC_SCHED_SEED=<n> (T1-D14, seeded shuffle): the run queue picks a random runnable domain instead of its head: the candidates are every
 * queued Concurrent process and the first queued other process (the app's domain keeps E2's FIFO order); xorshift64* from n. */
#ifndef FIC_CONC_H
#define FIC_CONC_H

#define FIC_TAG_CPROC       0xFFB0u   /* { proc, qhead, rwait, awaiters, exitv, killedv } qtail state */
#define FIC_TAG_CONC_ROUTER 0xFFB1u   /* { cproc } mgr kind: the router of a blocked receive or await (prefix = fic_router) */
#define FIC_CONC_MGR (FIC_MAX_MGR - 1)

enum { FIC_CONC_RUNNING, FIC_CONC_DONE, FIC_CONC_KILLED };
enum { FIC_CONC_WAIT_RECV, FIC_CONC_WAIT_AWAIT, FIC_CONC_WAIT_NEVER };

typedef struct {
  fic_hdr h;
  fic_ref proc;        /* the E2 process while it runs, then none */
  fic_ref qhead;       /* the mailbox: a chain of fic_mail, none when empty */
  fic_ref rwait;       /* processes blocked in receive on this mailbox, oldest first (fic_sched_cell list, none at the end) */
  fic_ref awaiters;    /* processes blocked in await of this process, oldest first */
  fic_ref exitv;       /* the exit value once ended, none before */
  fic_ref killedv;     /* the value `Killed` given at spawn */
  fic_hdr *qtail;
  uint32_t state;
  uint32_t index;      /* the slot in the registry */
} fic_cproc;

typedef struct { fic_hdr h; fic_ref cproc; uint32_t mgr; uint32_t kind; } fic_conc_router;

/* the operation closures: { code, a, b, w } with nptr = 2 + (w is a reference) */
typedef struct { fic_hdr h; const fic_code *code; fic_ref a; fic_ref b; fic_word w; } fic_conc_op;

static fic_ref *fic_conc_reg; static size_t fic_conc_nreg, fic_conc_capreg, fic_conc_sweep_at = 64;
static size_t fic_conc_n_spawned, fic_conc_n_sent, fic_conc_n_dropped;
static int fic_conc_slot_ready;
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

static void fic_conc_drop_mail(fic_cproc *c) {
  fic_ref m = c->qhead;
  c->qhead = fic_none(); c->qtail = NULL;
  FIC_RC_DROP(m);
}

/* the end of a process (done or killed): the exit value (consumed), the waiters woken in order, the mailbox and the process dropped */
static void fic_conc_end(fic_cproc *c, uint32_t state, fic_ref exitv) {
  fic_ref w, proc = c->proc, ex;
  c->state = state;
  ex = c->exitv; c->exitv = exitv; FIC_RC_DROP(ex);
  fic_conc_drop_mail(c);
  while ((w = fic_conc_list_pop(&c->awaiters)) != NULL) {
    FIC_RC_DUP(c->exitv);
    fic_conc_wake(w, fic_w_p(c->exitv), 1);
    FIC_RC_DROP(w);
  }
  { fic_ref r = c->rwait; c->rwait = fic_none(); FIC_RC_DROP(r); }   /* its own receivers (only a leaked mailbox has others) */
  c->proc = fic_none();
  FIC_RC_DROP(proc);
}

static void fic_conc_reg_remove(size_t i) {
  fic_ref last = fic_conc_reg[--fic_conc_nreg];
  if (i < fic_conc_nreg) { fic_conc_reg[i] = last; ((fic_cproc *)last)->index = (uint32_t)i; }
}

/* drop the records of ended processes that only the registry still holds */
static void fic_conc_sweep(void) {
#ifdef FIC_RC
  size_t i = 0;
  while (i < fic_conc_nreg) {
    fic_cproc *c = (fic_cproc *)fic_conc_reg[i];
    if (c->state != FIC_CONC_RUNNING && c->h.rc == 1) { fic_conc_reg_remove(i); FIC_RC_DROP(&c->h); }
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

/* ---- the operations ---- */

static fic_ref fic_conc_op_task(const fic_code *code, fic_ref a, fic_ref b, fic_word w, int wref) {   /* consumes a, b, w */
  fic_conc_op *o = (fic_conc_op *)fic_alloc(sizeof(fic_conc_op), FIC_TAG_CLOSURE, (uint16_t)(2 + (wref ? 1 : 0)));
  o->code = code; o->a = a; o->b = b; o->w = w;
  return fic_task_and_then(&o->h, fic_task_succeed(FIC_W_UNIT, 0));
}
#define FIC_CONC_OP(self) ((fic_conc_op *)(self))

/* the end of the body: the exit value (a reference) */
static fic_word fic_conc_finish_entry(fic_ref self, fic_word v) {
  fic_cproc *c = (fic_cproc *)FIC_CONC_OP(self)->a;
  if (c->state == FIC_CONC_RUNNING) fic_conc_end(c, FIC_CONC_DONE, v.p); else FIC_RC_DROP(v.p);
  return fic_w_p(fic_task_succeed(FIC_W_UNIT, 0));
}
static const fic_code fic_conc_finish_code = { (void (*)(void))fic_conc_finish_entry, 1u FIC_CODE_OWN0 };

/* spawnRaw killed body: a = killed, b = body (Mailbox msg -> Task Never exit) */
static fic_word fic_conc_spawn_entry(fic_ref self, fic_word u) {
  fic_conc_op *o = FIC_CONC_OP(self);
  fic_cproc *c = (fic_cproc *)fic_alloc(sizeof(fic_cproc), FIC_TAG_CPROC, 6);
  fic_ref root, p;
  fic_conc_op *fin;
  (void)u;
  c->proc = fic_none(); c->qhead = fic_none(); c->rwait = fic_none(); c->awaiters = fic_none(); c->exitv = fic_none();
  FIC_RC_DUP(o->a); c->killedv = o->a;
  c->qtail = NULL; c->state = FIC_CONC_RUNNING;
  fin = (fic_conc_op *)fic_alloc(sizeof(fic_conc_op), FIC_TAG_CLOSURE, 2);
  fin->code = &fic_conc_finish_code; FIC_RC_DUP(&c->h); fin->a = &c->h; fin->b = fic_none(); fin->w = FIC_W_UNIT;
  FIC_RC_DUP(o->b); FIC_RC_DUP(&c->h);
  root = fic_task_and_then(&fin->h, fic_task_and_then(o->b, fic_task_succeed(fic_w_p(&c->h), 1)));
  p = fic_proc_new(root);
  ((fic_proc *)p)->id = -((fic_proc *)p)->id - 1;
  FIC_RC_DUP(p); FIC_RC_DROP(c->proc); c->proc = p;
  FIC_RC_DUP(&c->h); fic_conc_reg_add(&c->h);
  fic_conc_n_spawned++;
  fic_sched_enqueue(p);                                              /* queued: the parent goes on (R2) */
  return fic_w_p(fic_task_succeed(fic_w_p(&c->h), 1));
}
static const fic_code fic_conc_spawn_code = { (void (*)(void))fic_conc_spawn_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_spawn(fic_ref killed, fic_ref body) {
  return fic_conc_op_task(&fic_conc_spawn_code, killed, body, FIC_W_UNIT, 0);
}

/* address, self: the same record under another type */
static FIC_UNUSED fic_ref fic_conc_same(fic_ref x) { return x; }

/* send addr msg: a = the record, w = the message */
static fic_word fic_conc_send_entry(fic_ref self, fic_word u) {
  fic_conc_op *o = FIC_CONC_OP(self);
  fic_cproc *c = (fic_cproc *)o->a;
  int isref = o->h.nptr == 3;
  fic_ref w;
  (void)u;
  fic_conc_n_sent++;
  if (c->state != FIC_CONC_RUNNING) { fic_conc_n_dropped++; return fic_w_p(fic_task_succeed(FIC_W_UNIT, 0)); }
  if (isref) FIC_RC_DUP(o->w.p);
  {
    fic_ref m = fic_mail_new(FIC_MAIL_SELF, o->w, FIC_W_UNIT, isref);
    if (c->qhead == FIC_NONE) { FIC_RC_DROP(c->qhead); c->qhead = m; } else { FIC_RC_DROP(((fic_mail *)c->qtail)->next); ((fic_mail *)c->qtail)->next = m; }
    c->qtail = m;
  }
  while ((w = fic_conc_list_pop(&c->rwait)) != NULL) {               /* wake the oldest live receiver (R3) */
    int live = ((fic_proc *)w)->root != FIC_NONE;
    if (live) fic_conc_wake(w, FIC_W_UNIT, 0);
    FIC_RC_DROP(w);
    if (live) break;
  }
  return fic_w_p(fic_task_succeed(FIC_W_UNIT, 0));
}
static const fic_code fic_conc_send_code = { (void (*)(void))fic_conc_send_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_send(fic_ref addr, fic_word msg, int isref) {
  return fic_conc_op_task(&fic_conc_send_code, addr, fic_none(), msg, isref);
}

/* take the head of the mailbox as a succeed task, or block the current process (R4) */
static fic_ref fic_conc_take(fic_cproc *c) {
  if (c->qhead != FIC_NONE) {
    fic_mail *m = (fic_mail *)c->qhead;
    int isref = m->h.nptr == 2;
    fic_word v = m->a;
    fic_ref t;
    c->qhead = m->next; m->next = fic_none();
    if (c->qhead == FIC_NONE) c->qtail = NULL;
    if (isref) FIC_RC_DUP(v.p);
    t = fic_task_succeed(v, isref);
    FIC_RC_DROP(&m->h);
    return t;
  } else {
    fic_ref p = fic_conc_cur();
    FIC_RC_DUP(p);
    fic_conc_list_append(&c->rwait, p);
    return fic_conc_block(&c->h, FIC_CONC_WAIT_RECV);
  }
}

static fic_word fic_conc_receive_entry(fic_ref self, fic_word u) {
  (void)u;
  return fic_w_p(fic_conc_take((fic_cproc *)FIC_CONC_OP(self)->a));
}
static const fic_code fic_conc_receive_code = { (void (*)(void))fic_conc_receive_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_receive(fic_ref box) { return fic_conc_op_task(&fic_conc_receive_code, box, fic_none(), FIC_W_UNIT, 0); }

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
  if (c->state != FIC_CONC_RUNNING) return fic_w_p(fic_task_succeed(FIC_W_UNIT, 0));
  own = c->proc == fic_conc_cur();
  if (!own) fic_conc_stop(c);
  FIC_RC_DUP(c->killedv);
  fic_conc_end(c, FIC_CONC_KILLED, c->killedv);
  if (own) return fic_w_p(fic_conc_block(&c->h, FIC_CONC_WAIT_NEVER));
  return fic_w_p(fic_task_succeed(FIC_W_UNIT, 0));
}
static const fic_code fic_conc_kill_code = { (void (*)(void))fic_conc_kill_entry, 1u FIC_CODE_OWN0 };
static FIC_UNUSED fic_ref fic_conc_kill(fic_ref pid) { return fic_conc_op_task(&fic_conc_kill_code, pid, fic_none(), FIC_W_UNIT, 0); }

/* the onSelfMsg of the slot FIC_CONC_MGR: a blocked process continues (router owned, msg owned when a reference, state unit) */
static fic_word fic_conc_on_self_entry(fic_ref self, fic_word router, fic_word msg, fic_word state) {
  fic_conc_router *r = (fic_conc_router *)router.p;
  fic_ref t;
  (void)self; (void)state;
  switch (r->kind) {
  case FIC_CONC_WAIT_RECV: t = fic_conc_take((fic_cproc *)r->cproc); break;          /* the head, or block again */
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
  for (i = 0; i < fic_conc_nreg; i++) {
    fic_cproc *c = (fic_cproc *)fic_conc_reg[i];
    if (c->state == FIC_CONC_RUNNING) { blocked++; fic_conc_stop(c); FIC_RC_DUP(c->killedv); fic_conc_end(c, FIC_CONC_KILLED, c->killedv); }
  }
  for (i = 0; i < fic_conc_nreg; i++) {                              /* the cycles through exit values and handles */
    fic_cproc *c = (fic_cproc *)fic_conc_reg[i];
    fic_ref ex = c->exitv, kv = c->killedv;
    c->exitv = fic_none(); c->killedv = fic_none();
    FIC_RC_DROP(ex); FIC_RC_DROP(kv);
  }
#if defined(FIC_STATS) || defined(FIC_WARN_BLOCKED)
  fprintf(stderr, "FIC_STATS concurrent: spawned %zu sent %zu dropped %zu blocked_at_end %zu\n",
          fic_conc_n_spawned, fic_conc_n_sent, fic_conc_n_dropped, blocked);
#else
  (void)blocked;
#endif
  for (i = 0; i < fic_conc_nreg; i++) FIC_RC_DROP(fic_conc_reg[i]);
  free(fic_conc_reg); fic_conc_reg = NULL; fic_conc_nreg = fic_conc_capreg = 0;
  if (fic_conc_slot_ready) { memset(&fic_mgrs[FIC_CONC_MGR], 0, sizeof fic_mgrs[FIC_CONC_MGR]); fic_conc_slot_ready = 0; }
}

#endif /* FIC_CONC_H */

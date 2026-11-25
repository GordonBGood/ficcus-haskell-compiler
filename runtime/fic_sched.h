/* fic_sched.h -- Ficcus effects slice E2: the scheduler and the platform (docs/EFFECTS-CHECK.md section 5, steps 4 to 8;
 * docs/EFFECTS-DESIGN.md sections 1 and 3). A port of elm/core 1.0.5 `Elm/Kernel/Scheduler.js` and `Platform.js`, line for line where
 * the order of events is observable; the effect managers themselves (Task, Time, Random) are compiled from their Elm source.
 * Needs fic_rt.h and the closure runtime (fic_closure.h). Emitted only by programs that use a task, a bag or a manager.
 *
 * Values. Every value that crosses a task, a bag or a mailbox is a closure word (fic_word: a struct as its FIC_TAG_BOX). The objects
 * follow the header convention: the reference words first (`nptr` counts them), then the scalars, so the generic drop releases them.
 * Whether a word is a reference is known where it is made (the class at the kernel's call site) and kept as `nptr`: a SUCCEED of a
 * reference has nptr 1, of an Int nptr 0. "None" (JavaScript's null root, empty stack, empty mailbox) is the static object
 * `fic_sched_none`, so every reference field is an object and the generic drop needs no test.
 *
 * Ownership. As everywhere in the runtime (FIC_RC_DUP/DROP): a kernel consumes the references it stores, borrows the ones it only reads.
 * The run queue, a process's root, stack and mailbox, a router's process, the manager table and the timer heap each hold one count.
 * The protocol of the model (D-fx-3) is the generated stepper's (fic_app_step): this file never sees the model.
 *
 * Deviations from Elm, all decided (D-fx-6): a message to a process that waits in a binding does not run the binding again (Elm's
 * `_Scheduler_rawSend` + `_Scheduler_step` would); a resume after a kill is a no-op (a process killed while it sleeps stays dead). */
#ifndef FIC_SCHED_H
#define FIC_SCHED_H

#define FIC_TAG_TASK_SUCCEED 0xFFC0u   /* { value }                        nptr 1 when the value is a reference */
#define FIC_TAG_TASK_FAIL    0xFFC1u   /* { error }                        the same */
#define FIC_TAG_TASK_BIND    0xFFC2u   /* { a, b, ms, kind }               a binding of the runtime; nptr = the leading references of a, b */
#define FIC_TAG_TASK_ANDTHEN 0xFFC3u   /* { callback, task } */
#define FIC_TAG_TASK_ONERROR 0xFFC4u   /* { callback, task } */
#define FIC_TAG_TASK_RECEIVE 0xFFC5u   /* { router, state }                the receive of a manager's loop (only the runtime makes one) */
#define FIC_TAG_PROC         0xFFC6u   /* { root, stack, mailbox, tail, id, seq, timer } */
#define FIC_TAG_FRAME        0xFFC7u   /* { callback, rest, kind }         a frame of a process's stack */
#define FIC_TAG_MAIL         0xFFC8u   /* { next, a, b, kind }             a message in a mailbox: fx {cmds, subs} or SELF value */
#define FIC_TAG_ROUTER       0xFFC9u   /* { process, manager } */
#define FIC_TAG_SCHED_NONE   0xFFCFu
#define FIC_TAG_BAG_LEAF     0xFFD1u   /* { value, manager } */
#define FIC_TAG_BAG_NODE     0xFFD2u   /* { list of bags } */
#define FIC_TAG_BAG_MAP      0xFFD3u   /* { tagger, bag, pair } */

static fic_hdr fic_sched_none = { FIC_IMMORTAL, FIC_TAG_SCHED_NONE, 0, 0 };
#define FIC_NONE (&fic_sched_none)
/* an owned reference to "none" (it is counted like every static object, so the counts stay at FIC_IMMORTAL when the program ends) */
static fic_ref fic_none(void) { FIC_RC_DUP(FIC_NONE); return FIC_NONE; }

typedef struct { fic_hdr h; fic_word v; } fic_task_val;
typedef struct { fic_hdr h; fic_ref cb; fic_ref task; } fic_task_chain;
typedef struct { fic_hdr h; fic_word a; fic_word b; double ms; uint32_t kind; } fic_task_bind;
typedef struct { fic_hdr h; fic_ref router; fic_word state; } fic_task_recv;
typedef struct { fic_hdr h; fic_ref root; fic_ref stack; fic_ref mbox; fic_hdr *mtail; int64_t id; uint32_t seq; int32_t timer; } fic_proc;
typedef struct { fic_hdr h; fic_ref cb; fic_ref rest; uint32_t kind; } fic_frame;
typedef struct { fic_hdr h; fic_ref next; fic_word a; fic_word b; uint32_t kind; } fic_mail;
typedef struct { fic_hdr h; fic_ref proc; uint32_t mgr; } fic_router;
typedef struct { fic_hdr h; fic_word v; uint32_t mgr; } fic_bag_leaf_t;
typedef struct { fic_hdr h; fic_ref list; } fic_bag_node_t;
typedef struct { fic_hdr h; fic_ref f; fic_ref bag; uint32_t pair; } fic_bag_map_t;
/* a list cell of references (List.cons with a reference head: tag 1, head and tail) */
typedef struct { fic_hdr h; fic_ref head; fic_ref tail; } fic_sched_cell;

/* the kinds of a binding (the runtime's version of Elm's binding callbacks) */
enum { FIC_BIND_SPAWN, FIC_BIND_SPAWN_UNIT, FIC_BIND_SEND_SELF, FIC_BIND_KILL, FIC_BIND_SEND_TO_APP, FIC_BIND_SLEEP, FIC_BIND_NOW, FIC_BIND_INTERVAL,
       FIC_BIND_HERE, FIC_BIND_ZONE };
enum { FIC_MAIL_FX, FIC_MAIL_SELF };
enum { FIC_MGR_ELM, FIC_MGR_PORT_OUT, FIC_MGR_PORT_IN };

#define FIC_W_UNIT fic_w_b(0)

static FIC_UNUSED fic_ref fic_sched_dupw(fic_word w, int isref) { if (isref) FIC_RC_DUP(w.p); return isref ? w.p : NULL; }

static fic_ref fic_sched_cons(fic_ref head, fic_ref tail) {        /* consumes both */
  fic_sched_cell *c = (fic_sched_cell *)fic_alloc(sizeof(fic_sched_cell), 1u, 2);
  c->head = head; c->tail = tail;
  return &c->h;
}

/* ---- tasks (Scheduler.js: succeed, fail, binding, andThen, onError, receive) ---- */

static fic_ref fic_task_val_new(uint16_t tag, fic_word v, int isref) {
  fic_task_val *t = (fic_task_val *)fic_alloc(sizeof(fic_task_val), tag, isref ? 1 : 0);
  t->v = v;
  return &t->h;
}
static FIC_UNUSED fic_ref fic_task_succeed(fic_word v, int isref) { return fic_task_val_new(FIC_TAG_TASK_SUCCEED, v, isref); }
static FIC_UNUSED fic_ref fic_task_fail(fic_word v, int isref) { return fic_task_val_new(FIC_TAG_TASK_FAIL, v, isref); }

static fic_ref fic_task_chain_new(uint16_t tag, fic_ref cb, fic_ref task) {
  fic_task_chain *t = (fic_task_chain *)fic_alloc(sizeof(fic_task_chain), tag, 2);
  t->cb = cb; t->task = task;
  return &t->h;
}
static FIC_UNUSED fic_ref fic_task_and_then(fic_ref cb, fic_ref task) { return fic_task_chain_new(FIC_TAG_TASK_ANDTHEN, cb, task); }
static FIC_UNUSED fic_ref fic_task_on_error(fic_ref cb, fic_ref task) { return fic_task_chain_new(FIC_TAG_TASK_ONERROR, cb, task); }

/* a binding: a and b are stored (consumed); nref = how many of a, b (in this order) are references */
static fic_ref fic_task_bind_new(uint32_t kind, fic_word a, fic_word b, int nref, double ms) {
  fic_task_bind *t = (fic_task_bind *)fic_alloc(sizeof(fic_task_bind), FIC_TAG_TASK_BIND, (uint16_t)nref);
  t->a = a; t->b = b; t->ms = ms; t->kind = kind;
  return &t->h;
}
static FIC_UNUSED fic_ref fic_task_spawn(fic_ref task) { return fic_task_bind_new(FIC_BIND_SPAWN, fic_w_p(task), FIC_W_UNIT, 1, 0); }
/* `Elm.Kernel.Scheduler.spawn` in Task.spawnCmd, whose annotation says `Task x ()`: the same, but the result is () (in JavaScript the
   process is returned and never looked at; here a reference typed as () would never be released) */
static FIC_UNUSED fic_ref fic_task_spawn_unit(fic_ref task) { return fic_task_bind_new(FIC_BIND_SPAWN_UNIT, fic_w_p(task), FIC_W_UNIT, 1, 0); }
static FIC_UNUSED fic_ref fic_task_kill(fic_ref proc) { FIC_RC_DUP(proc); return fic_task_bind_new(FIC_BIND_KILL, fic_w_p(proc), FIC_W_UNIT, 1, 0); }
static FIC_UNUSED fic_ref fic_task_send_to_app(fic_ref router, fic_word msg, int isref) {
  FIC_RC_DUP(router); return fic_task_bind_new(FIC_BIND_SEND_TO_APP, fic_w_p(router), msg, isref ? 2 : 1, 0);
}
static FIC_UNUSED fic_ref fic_task_send_to_self(fic_ref router, fic_word msg, int isref) {
  FIC_RC_DUP(router); return fic_task_bind_new(FIC_BIND_SEND_SELF, fic_w_p(router), msg, isref ? 2 : 1, 0);
}

/* ---- processes and the run queue ---- */

static int64_t fic_sched_guid;
static int fic_sched_working;
static fic_ref *fic_rq; static size_t fic_rq_head, fic_rq_len, fic_rq_cap;

static fic_ref fic_proc_new(fic_ref root) {                         /* consumes root */
  fic_proc *p = (fic_proc *)fic_alloc(sizeof(fic_proc), FIC_TAG_PROC, 3);
  p->root = root; p->stack = fic_none(); p->mbox = fic_none(); p->mtail = NULL;
  p->id = fic_sched_guid++; p->seq = 0; p->timer = -1;
  return &p->h;
}

static void fic_rq_push(fic_ref p) {
  if (fic_rq_len == fic_rq_cap) {
    size_t cap = fic_rq_cap == 0 ? 64 : fic_rq_cap * 2, i;
    fic_ref *q = (fic_ref *)malloc(cap * sizeof(fic_ref));
    if (q == NULL) abort();
    for (i = 0; i < fic_rq_len; i++) q[i] = fic_rq[(fic_rq_head + i) % (fic_rq_cap ? fic_rq_cap : 1)];
    free(fic_rq); fic_rq = q; fic_rq_cap = cap; fic_rq_head = 0;
  }
  fic_rq[(fic_rq_head + fic_rq_len) % fic_rq_cap] = p; fic_rq_len++;
}

static void fic_sched_step(fic_proc *p);

/* _Scheduler_enqueue: consumes a count of p. A call from outside the scheduler runs everything that becomes runnable before it
   returns; a call from inside a step only queues. */
static void fic_sched_enqueue(fic_ref p) {
  fic_rq_push(p);
  if (fic_sched_working) return;
  fic_sched_working = 1;
  while (fic_rq_len != 0) {
    fic_ref q = fic_rq[fic_rq_head];
    fic_rq_head = (fic_rq_head + 1) % fic_rq_cap; fic_rq_len--;
    fic_sched_step((fic_proc *)q);
    FIC_RC_DROP(q);
  }
  fic_sched_working = 0;
}

/* _Scheduler_rawSpawn: a new process (the result holds a count; the queue holds another) */
static fic_ref fic_sched_raw_spawn(fic_ref task) {
  fic_ref p = fic_proc_new(task);
  FIC_RC_DUP(p);
  fic_sched_enqueue(p);
  return p;
}

/* _Scheduler_rawSend: consumes the message object; p borrowed. A dead process drops it (no observable difference). */
static void fic_sched_raw_send(fic_ref pr, fic_ref mail) {
  fic_proc *p = (fic_proc *)pr;
  if (p->root == FIC_NONE) { FIC_RC_DROP(mail); return; }
  if (p->mbox == FIC_NONE) { FIC_RC_DROP(p->mbox); p->mbox = mail; } else { FIC_RC_DROP(((fic_mail *)p->mtail)->next); ((fic_mail *)p->mtail)->next = mail; }
  p->mtail = mail;
  FIC_RC_DUP(pr);
  fic_sched_enqueue(pr);
}

static fic_ref fic_mail_new(uint32_t kind, fic_word a, fic_word b, int nref) {   /* nref: the references among a, b */
  fic_mail *m = (fic_mail *)fic_alloc(sizeof(fic_mail), FIC_TAG_MAIL, (uint16_t)(1 + nref));
  m->next = fic_none(); m->a = a; m->b = b; m->kind = kind;
  return &m->h;
}

/* the binding's callback(newRoot): the process continues with `task` when the queue reaches it (consumes task; p borrowed) */
static void fic_sched_resume(fic_proc *p, fic_ref task) {
  fic_ref old = p->root;
  p->root = task;
  FIC_RC_DROP(old);
  FIC_RC_DUP(&p->h);
  fic_sched_enqueue(&p->h);
}

static fic_ref fic_frame_new(fic_ref cb, fic_ref rest, uint32_t kind) {   /* consumes cb and rest */
  fic_frame *f = (fic_frame *)fic_alloc(sizeof(fic_frame), FIC_TAG_FRAME, 2);
  f->cb = cb; f->rest = rest; f->kind = kind;
  return &f->h;
}

static void fic_proc_pop(fic_proc *p) {
  fic_frame *f = (fic_frame *)p->stack;
  fic_ref rest = f->rest;
  FIC_RC_DUP(rest);
  p->stack = rest;
  FIC_RC_DROP(&f->h);
}

/* the runtime's own hooks, set by the generated program and by the later parts of this file */
static void (*fic_app_send_fn)(fic_word msg);                      /* sendToApp: update, stepper, enqueueEffects (generated) */
static void fic_sched_bind_async(fic_proc *p, fic_task_bind *b);   /* the bindings that wait: Process.sleep, Time.every (step 5) */
static fic_ref fic_sched_receive(fic_proc *p, fic_task_recv *r, fic_mail *m);   /* a manager's loop (below) */

/* the bindings that complete at once: their callback resumes the process (which then waits in the queue behind the others, as in
   Elm), or, for a spawn, the child first */
static void fic_sched_bind(fic_proc *p) {
  fic_task_bind *b = (fic_task_bind *)p->root;
  FIC_RC_DUP(&b->h);
  switch (b->kind) {
  case FIC_BIND_SPAWN: case FIC_BIND_SPAWN_UNIT: {
    fic_ref child;
    FIC_RC_DUP(b->a.p);
    child = fic_sched_raw_spawn(b->a.p);
    if (b->kind == FIC_BIND_SPAWN_UNIT) { FIC_RC_DROP(child); fic_sched_resume(p, fic_task_succeed(FIC_W_UNIT, 0)); }
    else fic_sched_resume(p, fic_task_succeed(fic_w_p(child), 1));
    break; }
  case FIC_BIND_SEND_SELF: {
    fic_router *r = (fic_router *)b->a.p;
    int isref = b->h.nptr == 2;
    if (isref) FIC_RC_DUP(b->b.p);
    fic_sched_raw_send(r->proc, fic_mail_new(FIC_MAIL_SELF, b->b, FIC_W_UNIT, isref));
    fic_sched_resume(p, fic_task_succeed(FIC_W_UNIT, 0));
    break; }
  case FIC_BIND_KILL: {
    fic_proc *q = (fic_proc *)b->a.p;
    fic_ref root = q->root, stack = q->stack;
    if (q->timer >= 0) fic_sched_bind_async(q, NULL);             /* cancels the pending timer */
    q->seq++;
    q->root = fic_none(); q->stack = fic_none();
    FIC_RC_DROP(root); FIC_RC_DROP(stack);
    fic_sched_resume(p, fic_task_succeed(FIC_W_UNIT, 0));
    break; }
  case FIC_BIND_SEND_TO_APP: {
    int isref = b->h.nptr == 2;
    if (isref) FIC_RC_DUP(b->b.p);
    fic_app_send_fn(b->b);
    fic_sched_resume(p, fic_task_succeed(FIC_W_UNIT, 0));
    break; }
  default:
    fic_sched_bind_async(p, b);
    break;
  }
  FIC_RC_DROP(&b->h);
}

/* _Scheduler_step */
static void fic_sched_step(fic_proc *p) {
  while (p->root != FIC_NONE) {
    fic_ref r = p->root;
    uint16_t tag = r->tag;
    if (tag == FIC_TAG_TASK_SUCCEED || tag == FIC_TAG_TASK_FAIL) {
      uint32_t want = tag == FIC_TAG_TASK_SUCCEED ? 0u : 1u;
      fic_word v, nr;
      int isref = r->nptr != 0;
      while (p->stack != FIC_NONE && ((fic_frame *)p->stack)->kind != want) fic_proc_pop(p);
      if (p->stack == FIC_NONE) return;                            /* done: a failure of a spawned task is silent */
      v = ((fic_task_val *)r)->v;
      if (isref) FIC_RC_DUP(v.p);
      nr = fic_ap1(((fic_frame *)p->stack)->cb, isref ? 1u : 0u, v);
      fic_proc_pop(p);
      p->root = nr.p;
      FIC_RC_DROP(r);
    } else if (tag == FIC_TAG_TASK_BIND) {
      fic_sched_bind(p);
      return;
    } else if (tag == FIC_TAG_TASK_RECEIVE) {
      fic_mail *m;
      if (p->mbox == FIC_NONE) return;
      m = (fic_mail *)p->mbox;
      p->mbox = m->next;                                          /* the count of `next` passes to the process */
      if (p->mbox == FIC_NONE) p->mtail = NULL;
      m->next = fic_none();
      p->root = fic_sched_receive(p, (fic_task_recv *)r, m);
      FIC_RC_DROP(&m->h);
      FIC_RC_DROP(r);
    } else {                                                        /* AND_THEN, ON_ERROR: push a frame, run the inner task */
      fic_task_chain *c = (fic_task_chain *)r;
      FIC_RC_DUP(c->cb); FIC_RC_DUP(c->task);
      p->stack = fic_frame_new(c->cb, p->stack, tag == FIC_TAG_TASK_ANDTHEN ? 0u : 1u);
      p->root = c->task;
      FIC_RC_DROP(r);
    }
  }
}

/* ---- bags (Platform.js: leaf, batch, map) ---- */

static FIC_UNUSED fic_ref fic_bag_leaf(uint32_t mgr, fic_word v, int isref) {
  fic_bag_leaf_t *b = (fic_bag_leaf_t *)fic_alloc(sizeof(fic_bag_leaf_t), FIC_TAG_BAG_LEAF, isref ? 1 : 0);
  b->v = v; b->mgr = mgr;
  return &b->h;
}
static FIC_UNUSED fic_ref fic_bag_batch(fic_ref list) {
  fic_bag_node_t *b = (fic_bag_node_t *)fic_alloc(sizeof(fic_bag_node_t), FIC_TAG_BAG_NODE, 1);
  b->list = list;
  return &b->h;
}
static FIC_UNUSED fic_ref fic_bag_map(fic_ref f, fic_ref bag, uint32_t pair) {
  fic_bag_map_t *b = (fic_bag_map_t *)fic_alloc(sizeof(fic_bag_map_t), FIC_TAG_BAG_MAP, 2);
  b->f = f; b->bag = bag; b->pair = pair;
  return &b->h;
}

/* ---- effect managers (Platform.js: createManager, instantiateManager, setupEffects) ---- */

typedef struct fic_mgr {
  const char *name;
  int kind, has_cmd, has_sub, state_ref;
  fic_ref init, on_effects, on_self;            /* a task and two closures (owned by the table) */
  const fic_ref *cmd_maps, *sub_maps;           /* cmdMap/subMap closures, one per map pair of the program (static) */
  fic_ref router;
  fic_ref cmds, subs;                           /* the lists being gathered by a dispatch */
  void (*port_out)(fic_word value);             /* an outgoing port: prints the value (step 7) */
  fic_ref port_subs;                            /* an incoming port: the current subscriptions (step 7) */
} fic_mgr;

#ifndef FIC_MAX_MGR
#  define FIC_MAX_MGR 64
#endif
static fic_mgr fic_mgrs[FIC_MAX_MGR];
static int fic_nmgr;

/* the table entry of a manager compiled from Elm (generated code, in Elm's order of _Platform_effectManagers); consumes init */
static FIC_UNUSED void fic_mgr_def(const char *name, fic_ref init, fic_ref on_effects, fic_ref on_self, const fic_ref *cmd_maps,
                                   const fic_ref *sub_maps, int has_cmd, int has_sub, int state_ref) {
  fic_mgr *m;
  if (fic_nmgr == FIC_MAX_MGR) { fprintf(stderr, "too many effect managers\n"); abort(); }
  m = &fic_mgrs[fic_nmgr++];
  memset(m, 0, sizeof *m);
  m->name = name; m->kind = FIC_MGR_ELM; m->init = init; m->on_effects = on_effects; m->on_self = on_self;
  m->cmd_maps = cmd_maps; m->sub_maps = sub_maps; m->has_cmd = has_cmd; m->has_sub = has_sub; m->state_ref = state_ref;
  m->router = FIC_NONE; m->cmds = FIC_NONE; m->subs = FIC_NONE; m->port_subs = fic_none();
}

/* the loop of a manager: loop state = andThen loop (receive (\msg -> ...)); the closure captures the router */
typedef struct { fic_hdr h; const fic_code *code; fic_ref router; } fic_mgr_loop_clo;
static fic_word fic_mgr_loop_entry(fic_ref self, fic_word state);
static const fic_code fic_mgr_loop_code = { (void (*)(void))fic_mgr_loop_entry, 1u FIC_CODE_OWN0 };

static fic_ref fic_task_receive(fic_ref router, fic_word state, int isref) {    /* consumes both */
  fic_task_recv *t = (fic_task_recv *)fic_alloc(sizeof(fic_task_recv), FIC_TAG_TASK_RECEIVE, isref ? 2 : 1);
  t->router = router; t->state = state;
  return &t->h;
}

static fic_word fic_mgr_loop_entry(fic_ref self, fic_word state) {
  fic_ref router = ((fic_mgr_loop_clo *)self)->router;
  int isref = fic_mgrs[((fic_router *)router)->mgr].state_ref;
  FIC_RC_DUP(self); FIC_RC_DUP(router);
  return fic_w_p(fic_task_and_then(self, fic_task_receive(router, state, isref)));
}

/* the receive callback of the loop: SELF -> onSelfMsg router value state; fx -> onEffects router cmds (subs) state */
static fic_ref fic_sched_receive(fic_proc *p, fic_task_recv *r, fic_mail *m) {
  fic_mgr *g = &fic_mgrs[((fic_router *)r->router)->mgr];
  fic_word state = r->state, res;
  uint32_t sbit = g->state_ref ? 1u : 0u;
  (void)p;
  if (g->state_ref) FIC_RC_DUP(state.p);
  FIC_RC_DUP(r->router);
  if (m->kind == FIC_MAIL_SELF) {
    int vref = m->h.nptr == 2;
    if (vref) FIC_RC_DUP(m->a.p);
    res = fic_ap3(g->on_self, 1u | (vref ? 2u : 0u) | (sbit << 2), fic_w_p(r->router), m->a, state);
  } else if (g->has_cmd && g->has_sub) {
    FIC_RC_DUP(m->a.p); FIC_RC_DUP(m->b.p);
    res = fic_ap4(g->on_effects, 7u | (sbit << 3), fic_w_p(r->router), m->a, m->b, state);
  } else {
    fic_ref list = g->has_cmd ? m->a.p : m->b.p;
    FIC_RC_DUP(list);
    res = fic_ap3(g->on_effects, 3u | (sbit << 2), fic_w_p(r->router), fic_w_p(list), state);
  }
  return res.p;
}

/* _Platform_setupEffects: every manager gets its router and process, in table order; each process runs its init at once */
static FIC_UNUSED void fic_platform_setup(void) {
  int i;
  for (i = 0; i < fic_nmgr; i++) {
    fic_mgr *g = &fic_mgrs[i];
    fic_router *r = (fic_router *)fic_alloc(sizeof(fic_router), FIC_TAG_ROUTER, 1);
    fic_mgr_loop_clo *loop = (fic_mgr_loop_clo *)fic_alloc(sizeof(fic_mgr_loop_clo), FIC_TAG_CLOSURE, 1);
    fic_ref proc;
    r->mgr = (uint32_t)i;
    g->router = &r->h;
    loop->code = &fic_mgr_loop_code; loop->router = &r->h; FIC_RC_DUP(&r->h);
    FIC_RC_DUP(g->init);
    proc = fic_proc_new(fic_task_and_then(&loop->h, g->init));
    r->proc = proc;                                                 /* the router's count */
    FIC_RC_DUP(proc);
    fic_sched_enqueue(proc);
  }
}

/* ---- dispatch (Platform.js: enqueueEffects, dispatchEffects, gatherEffects, toEffect, insert) ---- */

typedef struct fic_taggers { fic_ref f; uint32_t pair; const struct fic_taggers *rest; } fic_taggers;
static fic_word fic_port_in_compose(fic_ref outer, fic_ref inner);  /* step 7 */

static void fic_gather(int is_cmd, fic_ref bag, const fic_taggers *tg) {
  switch (bag->tag) {
  case FIC_TAG_BAG_LEAF: {
    fic_bag_leaf_t *l = (fic_bag_leaf_t *)bag;
    fic_mgr *g = &fic_mgrs[l->mgr];
    fic_word v = l->v;
    const fic_taggers *t;
    FIC_RC_DUP(v.p);
    for (t = tg; t != NULL; t = t->rest) {                         /* the innermost tagger first */
      FIC_RC_DUP(t->f);
      if (g->kind == FIC_MGR_ELM) v = fic_ap2(is_cmd ? g->cmd_maps[t->pair] : g->sub_maps[t->pair], 3u, fic_w_p(t->f), v);
      else if (g->kind == FIC_MGR_PORT_IN) v = fic_port_in_compose(t->f, v.p);
      else FIC_RC_DROP(t->f);                                      /* an outgoing port's cmdMap ignores the tagger */
    }
    if (is_cmd) g->cmds = fic_sched_cons(v.p, g->cmds); else g->subs = fic_sched_cons(v.p, g->subs);
    return; }
  case FIC_TAG_BAG_NODE: {
    fic_ref l;
    for (l = ((fic_bag_node_t *)bag)->list; l->tag == 1u; l = ((fic_sched_cell *)l)->tail) fic_gather(is_cmd, ((fic_sched_cell *)l)->head, tg);
    return; }
  case FIC_TAG_BAG_MAP: {
    fic_bag_map_t *m = (fic_bag_map_t *)bag;
    fic_taggers n;
    n.f = m->f; n.pair = m->pair; n.rest = tg;
    fic_gather(is_cmd, m->bag, &n);
    return; }
  default:                                                          /* Cmd.none, Sub.none */
    return;
  }
}

static void fic_platform_dispatch(fic_ref cmd, fic_ref sub) {
  int i;
  for (i = 0; i < fic_nmgr; i++) { fic_mgrs[i].cmds = fic_nil(); fic_mgrs[i].subs = fic_nil(); }
  fic_gather(1, cmd, NULL);
  fic_gather(0, sub, NULL);
  for (i = 0; i < fic_nmgr; i++) {
    fic_mgr *g = &fic_mgrs[i];
    fic_ref cmds = g->cmds, subs = g->subs;
    g->cmds = FIC_NONE; g->subs = FIC_NONE;
    fic_sched_raw_send(((fic_router *)g->router)->proc, fic_mail_new(FIC_MAIL_FX, fic_w_p(cmds), fic_w_p(subs), 2));
  }
}

/* _Platform_enqueueEffects: consumes both bags. Effects of a synchronous command run inside a dispatch wait for the batch in progress. */
static fic_ref *fic_fxq; static size_t fic_fxq_head, fic_fxq_len, fic_fxq_cap;
static int fic_fx_active;

static FIC_UNUSED void fic_platform_enqueue(fic_ref cmd, fic_ref sub) {
  if (fic_fxq_head + fic_fxq_len + 2 > fic_fxq_cap) {
    size_t cap = fic_fxq_cap == 0 ? 64 : fic_fxq_cap * 2;
    fic_ref *q;
    if (fic_fxq_head > 0) { memmove(fic_fxq, fic_fxq + fic_fxq_head, fic_fxq_len * sizeof(fic_ref)); fic_fxq_head = 0; }
    if (fic_fxq_len + 2 > fic_fxq_cap) {
      q = (fic_ref *)realloc(fic_fxq, cap * sizeof(fic_ref));
      if (q == NULL) abort();
      fic_fxq = q; fic_fxq_cap = cap;
    }
  }
  fic_fxq[fic_fxq_head + fic_fxq_len++] = cmd;
  fic_fxq[fic_fxq_head + fic_fxq_len++] = sub;
  if (fic_fx_active) return;
  fic_fx_active = 1;
  while (fic_fxq_len != 0) {
    fic_ref c = fic_fxq[fic_fxq_head], s = fic_fxq[fic_fxq_head + 1];
    fic_fxq_head += 2; fic_fxq_len -= 2;
    if (fic_fxq_len == 0) fic_fxq_head = 0;
    fic_platform_dispatch(c, s);
    FIC_RC_DROP(c); FIC_RC_DROP(s);
  }
  fic_fx_active = 0;
}

/* ---- the event loop (step 5) and the ports (step 7) ---- */

static void fic_sched_bind_async(fic_proc *p, fic_task_bind *b) {
  (void)p; (void)b;
  fprintf(stderr, "internal: a binding that waits needs the event loop\n"); abort();
}
static fic_word fic_port_in_compose(fic_ref outer, fic_ref inner) { (void)outer; (void)inner; abort(); }
static FIC_UNUSED void fic_sched_run(void) { }

/* ---- the end of the program (step 8): the effect state is released, so a counted program ends with nothing live ---- */

static FIC_UNUSED void fic_platform_teardown(void) {
  int i;
  for (i = 0; i < fic_nmgr; i++) {
    fic_mgr *g = &fic_mgrs[i];
    fic_router *r = (fic_router *)g->router;
    if (g->router != FIC_NONE) {
      fic_proc *p = (fic_proc *)r->proc;
      fic_ref root = p->root, stack = p->stack, mbox = p->mbox;
      p->root = fic_none(); p->stack = fic_none(); p->mbox = fic_none(); p->mtail = NULL;
      FIC_RC_DROP(root); FIC_RC_DROP(stack); FIC_RC_DROP(mbox);     /* the loop closure and the receive release the router */
      r->proc = fic_none();
      FIC_RC_DROP(&p->h);
      FIC_RC_DROP(g->router);
    }
    FIC_RC_DROP(g->init); FIC_RC_DROP(g->on_effects); FIC_RC_DROP(g->on_self); FIC_RC_DROP(g->port_subs);
  }
  fic_nmgr = 0;
  free(fic_rq); fic_rq = NULL; fic_rq_cap = fic_rq_len = fic_rq_head = 0;
  free(fic_fxq); fic_fxq = NULL; fic_fxq_cap = fic_fxq_len = fic_fxq_head = 0;
}

#endif /* FIC_SCHED_H */

#define _POSIX_C_SOURCE 200809L
/* Standalone tests of the scheduler (fic_sched.h, effects slice E2): the order of the run queue, spawn order (the child runs first,
   up to its first wait; then the parent), andThen/onError frames (a failure skips andThen frames, a success skips onError frames), the
   silent end of a failed spawned task, kill of a finished process, sendToApp through the program's hook; with the event loop (step 5):
   sleep 0 yields to the loop, a timer order (deadline, then creation), kill of a sleeping process (its timer is cancelled and a late
   resume is a no-op), Time.every-like intervals. Counted (-DFIC_RC -DFIC_STATS): everything is freed at the end. Build and run: runtime/test.sh */
#include "fic_rt.h"
#include "fic_base.h"
#include "fic_string.h"
#include "fic_closure.h"
#include "fic_sched.h"

/* a closure that logs its tag and the Int it gets, then continues with a task made by `next` */
typedef fic_ref (*next_fn)(int64_t v);
typedef struct { fic_hdr h; const fic_code *code; const char *tag; next_fn next; } logger;
static fic_word logger_entry(fic_ref self, fic_word a) {
  logger *l = (logger *)self;
  printf("%s %lld\n", l->tag, (long long)a.i);
  return fic_w_p(l->next(a.i));
}
static const fic_code logger_code = { (void (*)(void))logger_entry, 1u FIC_CODE_OWN0 };
static fic_ref log_then(const char *tag, next_fn next) {
  logger *l = (logger *)fic_alloc(sizeof(logger), FIC_TAG_CLOSURE, 0);
  l->code = &logger_code; l->tag = tag; l->next = next;
  return &l->h;
}
static fic_ref succ_plus1(int64_t v) { return fic_task_succeed(fic_w_i(v + 1), 0); }
static fic_ref fail_100(int64_t v) { (void)v; return fic_task_fail(fic_w_i(100), 0); }

/* the process the interval test kills: `woke` continues with `kill stop_target` */
static fic_ref stop_target;
static fic_ref fic_task_kill_of(int64_t v) { (void)v; return fic_task_kill(stop_target); }

/* sendToApp hook */
static void app_send(fic_word m) { printf("app %lld\n", (long long)m.i); }

static void run(fic_ref task) { fic_ref p = fic_sched_raw_spawn(task); FIC_RC_DROP(p); }

int main(void) {
  fic_app_send_fn = app_send;

  printf("-- chain\n");             /* succeed 1 |> andThen log a |> andThen log b */
  run(fic_task_and_then(log_then("b", succ_plus1), fic_task_and_then(log_then("a", succ_plus1), fic_task_succeed(fic_w_i(1), 0))));

  printf("-- failure skips andThen, onError catches\n");
  run(fic_task_on_error(log_then("caught", succ_plus1),
        fic_task_and_then(log_then("never", succ_plus1), fic_task_and_then(log_then("x", fail_100), fic_task_succeed(fic_w_i(5), 0)))));

  printf("-- success skips onError\n");
  run(fic_task_and_then(log_then("ok", succ_plus1), fic_task_on_error(log_then("never", succ_plus1), fic_task_succeed(fic_w_i(7), 0))));

  printf("-- a failed spawned task is silent\n");
  run(fic_task_and_then(log_then("never", succ_plus1), fic_task_fail(fic_w_i(9), 0)));

  printf("-- spawn order: the child first, then the parent\n");
  {
    fic_ref child = fic_task_and_then(log_then("child2", succ_plus1), fic_task_and_then(log_then("child1", succ_plus1), fic_task_succeed(fic_w_i(10), 0)));
    run(fic_task_and_then(log_then("parent", succ_plus1), fic_task_spawn_unit(child)));
  }

  printf("-- kill of a finished process, then sendToApp\n");
  {
    fic_ref done = fic_sched_raw_spawn(fic_task_succeed(fic_w_i(1), 0));
    run(fic_task_and_then(log_then("after kill", succ_plus1), fic_task_kill(done)));
    FIC_RC_DROP(done);
    run(fic_task_send_to_app(FIC_NONE, fic_w_i(42), 0));
  }

  /* the event loop on the virtual clock (as FIC_TIME) */
  fic_clock_virtual = 1; fic_clock_base = 1000; fic_clock_vnow = 0;

  printf("-- timers: deadline order, equal deadlines in creation order, a delay below 1 is 1, sleep 0 yields\n");
  run(fic_task_and_then(log_then("t30", succ_plus1), fic_task_sleep(30)));
  run(fic_task_and_then(log_then("t0", succ_plus1), fic_task_sleep(0)));
  run(fic_task_and_then(log_then("t1", succ_plus1), fic_task_sleep(1)));
  run(fic_task_and_then(log_then("t10", succ_plus1), fic_task_sleep(10)));
  run(fic_task_and_then(log_then("sync", succ_plus1), fic_task_succeed(fic_w_i(3), 0)));
  fic_sched_run();
  printf("clock %g\n", fic_loop_now());

  printf("-- kill of a sleeping process: its timer is gone, the loop ends at once\n");
  {
    fic_ref sleeper = fic_sched_raw_spawn(fic_task_and_then(log_then("never", succ_plus1), fic_task_sleep(1000)));
    run(fic_task_and_then(log_then("killed", succ_plus1), fic_task_kill(sleeper)));
    FIC_RC_DROP(sleeper);
    printf("timers %zu\n", fic_tm_len);
    fic_sched_run();
    printf("clock %g\n", fic_loop_now());
  }

  printf("-- an interval spawns its task every period until it is killed\n");
  {
    fic_ref ticker = fic_sched_raw_spawn(fic_task_interval(25, fic_task_and_then(log_then("tick", succ_plus1), fic_task_succeed(fic_w_i(0), 0))));
    run(fic_task_and_then(log_then("stop", succ_plus1), fic_task_and_then(log_then("woke", fic_task_kill_of), fic_task_sleep(80))));
    stop_target = ticker;
    fic_sched_run();
    FIC_RC_DROP(ticker);
    printf("clock %g timers %zu\n", fic_loop_now(), fic_tm_len);
  }

  fic_platform_teardown();
  return fic_shutdown();
}

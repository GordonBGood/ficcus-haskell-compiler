/* host_life.c -- E3c review, item 1: the lifetime of raw vectors at the host interface, with E3crLife (src/E3crLife.fic).
 * FIC_LIFE=<case> picks one case; each prints its steps. Build: ../build.sh E3crLife host/host_life.c OUT (ASan + UBSan, --rc).
 *
 * Within the contract (must be clean under ASan/UBSan and end with live 0):
 *   retain_in    the host retains an incoming Int vector, sends it, the program writes element 0 in place: the host still reads
 *                its own values (the node's count forces the copy)
 *   retain_out   a viOut callback retains the outgoing raw value, asks the program to write in place and then to drop the vector:
 *                the retained value keeps its values and stays readable
 *   twice        one retained raw Int vector sent twice; then an in place write; counts balanced
 *   echo         a viOut callback retains its value and sends it back to viIn (the documented re-send rule)
 *   list         [raw, raw] into a List (Vector Int) port
 *   narrow_out   a vbOut copy retained after the program drops its Vector Word8
 * Host errors (outside the contract; they show what a host that keeps the data pointer sees):
 *   write_after  writes element 0 through the fic_hv_vector_alloc pointer after the send: the program's immutable value changes
 *   read_after_drop   reads through that pointer after the program dropped the vector: use after free (8 byte kind)
 *   read_after_send8  reads a narrow kind's staging buffer after the send: use after free at once
 *   borrow_kept  (in the contract) a viOut callback reads its borrowed pointer after the program dropped the vector during the call:
 *                the delivery still holds the node, so the memory is live
 *   reuse        (no sanitizer) a narrow staging buffer's address handed out again: a host comparing addresses is misled */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../../runtime/fic_ports_api.h"

static const char *mode;
static fic_hv kept;
static const int64_t *keptp;
static int stage;

static void out_printer(void *env, fic_hv v) {
  size_t n; char *j = fic_hv_to_json(v, &n); (void)env;
  printf("  program: %s\n", j); free(j);
}

static int64_t *alloc_i64(size_t n, fic_hv *v) {
  void *d; size_t i;
  *v = fic_hv_vector_alloc(FIC_EL_I64, n, &d);
  for (i = 0; i < n; i++) ((int64_t *)d)[i] = (int64_t)(10 + i);
  return (int64_t *)d;
}

static void rc(const char *what, int r) { printf("%s: %s\n", what, r == FIC_OK ? "ok" : fic_port_error()); }
static void op(int k) { char b[16]; snprintf(b, sizeof b, "op %d", k); rc(b, fic_port_send("opIn", fic_hv_int(k))); }

static void vi_out(void *env, fic_hv v) {
  size_t n; enum fic_el k;
  const int64_t *p = (const int64_t *)fic_hv_vector(v, &k, &n);
  (void)env;
  printf("  viOut: n=%zu first %lld\n", n, n > 0 ? (long long)p[0] : -1LL);
  if (strcmp(mode, "retain_out") == 0 && stage == 0) {
    stage = 1;
    kept = fic_hv_retain(v);
    op(1);                                              /* the program writes element 0 (the node holds a count: a copy) */
    p = (const int64_t *)fic_hv_vector(kept, &k, &n);
    printf("  retained after in place write: first %lld (want 10)\n", (long long)p[0]);
    op(0);                                              /* the program drops its vector */
    p = (const int64_t *)fic_hv_vector(kept, &k, &n);
    printf("  retained after drop: first %lld last %lld\n", (long long)p[0], (long long)p[n - 1]);
    fic_hv_release(kept);
  } else if (strcmp(mode, "echo") == 0 && stage == 0) {
    stage = 1;
    rc("echo send", fic_port_send("viIn", fic_hv_retain(v)));
    op(1); op(3);
  } else if (strcmp(mode, "borrow_kept") == 0 && stage == 0) {
    stage = 1;
    keptp = p;                                          /* no retain: borrowed for this call only */
    op(0);
    printf("  borrowed pointer after drop: %lld\n", (long long)keptp[0]);
  }
}

static void vb_out(void *env, fic_hv v) {
  size_t n; enum fic_el k; (void)env;
  if (strcmp(mode, "narrow_out") == 0) {
    kept = fic_hv_retain(v);
    op(0);
    { const uint8_t *p = (const uint8_t *)fic_hv_vector(kept, &k, &n); printf("  vbOut retained after drop: n=%zu %u %u\n", n, p[0], p[n - 1]); }
    fic_hv_release(kept);
  }
}

int life_main(void) {
  fic_hv v, w;
  int64_t *p;
  mode = getenv("FIC_LIFE");
  if (mode == NULL) { printf("no FIC_LIFE\n"); return 1; }
  if (fic_app_start(NULL) != FIC_OK) { printf("start: %s\n", fic_port_error()); return 1; }
  fic_port_subscribe("output", out_printer, NULL);
  fic_port_subscribe("viOut", vi_out, NULL);
  fic_port_subscribe("vbOut", vb_out, NULL);
  printf("case %s\n", mode);
  if (strcmp(mode, "retain_in") == 0) {
    p = alloc_i64(4, &v);
    fic_hv_retain(v);
    rc("send", fic_port_send("viIn", v));
    op(1); op(3);
    { size_t n; enum fic_el k; const int64_t *q = (const int64_t *)fic_hv_vector(v, &k, &n);
      printf("host's retained vector: first %lld (want 10), same memory as alloc: %s\n", (long long)q[0], q == p ? "yes" : "no"); }
    fic_hv_release(v);
    op(0);
  } else if (strcmp(mode, "retain_out") == 0 || strcmp(mode, "echo") == 0 || strcmp(mode, "borrow_kept") == 0) {
    p = alloc_i64(4, &v);
    rc("send", fic_port_send("viIn", v));
    op(2);                                              /* viOut: the callback runs from the loop, after this function */
  } else if (strcmp(mode, "twice") == 0) {
    p = alloc_i64(3, &v);
    fic_hv_retain(v);
    rc("send 1", fic_port_send("viIn", v));
    rc("send 2", fic_port_send("viIn", v));
    op(1); op(3); op(0);
  } else if (strcmp(mode, "list") == 0) {
    fic_hv a = fic_hv_array(2);
    p = alloc_i64(2, &v); alloc_i64(3, &w);
    fic_hv_array_set(a, 0, v); fic_hv_array_set(a, 1, w);
    rc("send", fic_port_send("vlIn", fic_hv_finish(a)));
    op(1); op(3); op(0);
  } else if (strcmp(mode, "narrow_out") == 0) {
    void *d; v = fic_hv_vector_alloc(FIC_EL_U8, 5, &d); memset(d, 7, 5);
    rc("send", fic_port_send("vbIn", v));
    op(4);
  } else if (strcmp(mode, "write_after") == 0) {
    p = alloc_i64(4, &v);
    rc("send", fic_port_send("viIn", v));
    p[0] = 77;                                          /* host error */
    op(3);
    op(0);
  } else if (strcmp(mode, "read_after_drop") == 0) {
    p = alloc_i64(4, &v);
    rc("send", fic_port_send("viIn", v));
    op(0);
    printf("host reads after drop: %lld\n", (long long)p[0]);   /* host error: use after free */
  } else if (strcmp(mode, "read_after_send8") == 0) {
    void *d; v = fic_hv_vector_alloc(FIC_EL_U8, 4, &d); memset(d, 5, 4);
    rc("send", fic_port_send("vbIn", v));
    printf("host reads staging after send: %u\n", ((uint8_t *)d)[0]);   /* host error: use after free */
  } else if (strcmp(mode, "reuse") == 0) {
    void *d, *e; int i, same = 0;
    for (i = 0; i < 100; i++) {
      v = fic_hv_vector_alloc(FIC_EL_U8, 16, &d); memset(d, 1, 16);
      rc("send", fic_port_send("vbIn", v));
      w = fic_hv_vector_alloc(FIC_EL_U8, 16, &e);
      if (e == d) same++;
      fic_hv_release(w);
    }
    printf("staging address handed out again: %d of 100\n", same);
  } else printf("unknown case\n");
  return 0;
}

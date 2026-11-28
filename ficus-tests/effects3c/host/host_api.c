/* host_api.c -- effects slices E3c and E3d: a host that drives a program through runtime/fic_ports_api.h from a script
 * (FIC_HOST_SCRIPT), one command per line; every result is printed, so a case compares the whole output with its expected file.
 *
 *   sub P                      subscribe the printer to the outgoing port P (`P: <JSON>`, a raw vector as `P: raw KIND n=N [same]
 *                              <JSON>`, where `same` says the elements are the memory of the last fic_hv_vector_alloc; a long text as
 *                              its length, head and tail)
 *   json P TEXT                fic_port_send_json
 *   int P I / uint P U / float P D      fic_hv_int / fic_hv_uint / fic_hv_float (D may be nan, inf, -inf) and fic_port_send
 *   vec P KIND N A B           a raw vector of N elements A + i * B (KIND i8 .. f64) from fic_hv_vector_alloc, sent
 *   veccopy P KIND N A B       the same through fic_hv_vector_copy
 *   bytes P N                  a Vector Word8 round trip of N bytes (i * 7 + 3) mod 256 through P, the echo checked byte for byte
 *   deep P DEPTH LEAF          [[..[LEAF]..]] of DEPTH arrays built with the API and sent (LEAF: 1, or u for 2^64 - 1, or v for a
 *                              raw vector of 3 Int)
 *   deeptext P DEPTH           the same text ([[..[1]..]]) through fic_port_send_json
 *   deepjson DEPTH             fic_hv_to_json and fic_hv_from_json of a DEPTH deep array (length, head; parsed back, printed again)
 *   api                        the reads of a JUINT and of raw vectors (kind, len, get_uint, get_float, get_int)
 * Linked with the generated program, -DFIC_HOST_MAIN=api_main.  Timing (bytes): printed only when FIC_TIMING is set (informational). */
#define _POSIX_C_SOURCE 200809L
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../../../runtime/fic_ports_api.h"

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (double)t.tv_sec + (double)t.tv_nsec * 1e-9; }
static void *allocs[256];                             /* the data pointers of the 8 byte vectors allocated here (`same`: zero copy;
                                                         a narrow kind's staging buffer is freed when it is sent, and its address
                                                         may come back for another object) */
static int nallocs;
static double t_send;                                 /* bytes: when its send began */
static char *names[64];                               /* the subscribed port names (freed at the end) */
static int nnames;
static const char *kinds[] = { "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64" };
static const char *knames[] = { "INT8", "INT16", "INT32", "INT64", "WORD8", "WORD16", "WORD32", "WORD64", "FLOAT32", "FLOAT64" };
static const size_t ksize[] = { 1, 2, 4, 8, 1, 2, 4, 8, 4, 8 };

static void show_text(const char *t, size_t n) {
  if (n <= 400) { fwrite(t, 1, n, stdout); return; }
  printf("<%zu bytes> ", n); fwrite(t, 1, 60, stdout); printf(" ... "); fwrite(t + n - 20, 1, 20, stdout);
}

static void printer(void *env, fic_hv v) {
  const char *port = (const char *)env;
  size_t n;
  char *j;
  printf("%s: ", port);
  if (fic_hv_kind(v) == FIC_HV_VECTOR) {
    enum fic_el k;
    size_t len;
    const void *p = fic_hv_vector(v, &k, &len);
    int i, same = 0;
    for (i = 0; i < nallocs; i++) if (p == allocs[i] && len > 0) same = 1;
    printf("raw %s n=%zu%s ", knames[k], len, same ? " same" : "");
  }
  j = fic_hv_to_json(v, &n);
  if (j == NULL) printf("(to_json NULL)"); else show_text(j, n);
  printf("\n");
  free(j);
}

static void result(const char *what, int rc) {
  if (rc == FIC_OK) { printf("%s: ok\n", what); return; }
  printf("%s: rc %d\n", what, rc);
  { const char *e = fic_port_error(); printf("error: "); show_text(e, strlen(e)); printf("\n"); }
}

static int kind_of(const char *s) {
  int i;
  for (i = 0; i < 10; i++) if (strcmp(s, kinds[i]) == 0) return i;
  return -1;
}

static void fill(int k, void *d, size_t n, double a, double b) {
  size_t i;
  for (i = 0; i < n; i++) {
    double x = a + (double)i * b;
    switch (k) {
    case FIC_EL_I8: ((int8_t *)d)[i] = (int8_t)x; break;
    case FIC_EL_I16: ((int16_t *)d)[i] = (int16_t)x; break;
    case FIC_EL_I32: ((int32_t *)d)[i] = (int32_t)x; break;
    case FIC_EL_I64: ((int64_t *)d)[i] = (int64_t)x; break;
    case FIC_EL_U8: ((uint8_t *)d)[i] = (uint8_t)x; break;
    case FIC_EL_U16: ((uint16_t *)d)[i] = (uint16_t)x; break;
    case FIC_EL_U32: ((uint32_t *)d)[i] = (uint32_t)x; break;
    case FIC_EL_U64: ((uint64_t *)d)[i] = x >= 0 ? (uint64_t)x : 0; break;
    case FIC_EL_F32: ((float *)d)[i] = (float)x; break;
    default: ((double *)d)[i] = x; break;
    }
  }
}

/* bytes: the echo is checked in the callback */
static size_t bytes_n;
static int bytes_ok;
static void bytes_check(void *env, fic_hv v) {
  enum fic_el k;
  size_t n, i;
  const uint8_t *p = (const uint8_t *)fic_hv_vector(v, &k, &n);
  (void)env;
  if (p == NULL || n != bytes_n) return;               /* an earlier vbOut of the script */
  bytes_ok = k == FIC_EL_U8;
  for (i = 0; bytes_ok && i < n; i++) if (p[i] != (uint8_t)(i * 7 + 3)) bytes_ok = 0;
  printf("bytes %zu: echo %s\n", bytes_n, bytes_ok ? "checked" : "WRONG");
  if (getenv("FIC_TIMING") != NULL)
    fprintf(stderr, "timing: Vector Word8 round trip of %zu bytes (fill, send, widen, update, dispatch, narrow, check): %.3f ms\n", n,
            (now() - t_send) * 1e3);
}

static void free_names(void) { while (nnames > 0) free(names[--nnames]); }

static fic_hv deep_value(long depth, const char *leaf) {
  fic_hv v;
  long i;
  if (strcmp(leaf, "u") == 0) v = fic_hv_uint(UINT64_MAX);
  else if (strcmp(leaf, "v") == 0) { void *d; v = fic_hv_vector_alloc(FIC_EL_I64, 3, &d); fill(FIC_EL_I64, d, 3, 1, 1); }
  else v = fic_hv_int(1);
  for (i = 0; i < depth; i++) { fic_hv a = fic_hv_array(1); fic_hv_array_set(a, 0, v); v = fic_hv_finish(a); }
  return v;
}

static char *deep_text(long depth, size_t *n) {
  char *t = (char *)malloc((size_t)depth * 2 + 2);
  long i;
  for (i = 0; i < depth; i++) t[i] = '[';
  t[depth] = '1';
  for (i = 0; i < depth; i++) t[depth + 1 + i] = ']';
  *n = (size_t)depth * 2 + 1;
  t[*n] = 0;
  return t;
}

static void api_reads(void) {
  uint64_t u; int64_t i; double d; size_t n; enum fic_el k; void *p;
  fic_hv v = fic_hv_uint(UINT64_MAX), w = fic_hv_uint(5), x;
  { int ru = fic_hv_get_uint(v, &u), ri = fic_hv_get_int(v, &i), rf = fic_hv_get_float(v, &d);
    printf("uint max: kind %d, get_uint %d %llu, get_int %d, get_float %d %.17g\n", (int)fic_hv_kind(v), ru, (unsigned long long)u, ri, rf, d); }
  { int ri = fic_hv_get_int(w, &i); printf("uint 5: kind %d, get_int %d %lld\n", (int)fic_hv_kind(w), ri, (long long)i); }
  x = fic_hv_float(-1.0);
  printf("float -1: get_uint %d; float 2^64: ", fic_hv_get_uint(x, &u));
  fic_hv_release(x); x = fic_hv_float(18446744073709551616.0);
  printf("get_uint %d; int -1: ", fic_hv_get_uint(x, &u));
  fic_hv_release(x); x = fic_hv_int(-1);
  printf("get_uint %d\n", fic_hv_get_uint(x, &u));
  fic_hv_release(x); fic_hv_release(v); fic_hv_release(w);
  v = fic_hv_vector_alloc(FIC_EL_U16, 4, &p);
  fill(FIC_EL_U16, p, 4, 65533, 1);
  printf("vector u16: kind %d len %zu at0 %s get_int %d data %s\n", (int)fic_hv_kind(v), fic_hv_len(v), fic_hv_at(v, 0) == NULL ? "NULL" : "?",
         fic_hv_get_int(v, &i), fic_hv_vector(v, &k, &n) == p && k == FIC_EL_U16 && n == 4 ? "ok" : "BAD");
  { size_t m; char *j = fic_hv_to_json(v, &m); printf("  to_json %s\n", j); free(j); }
  x = fic_hv_array(2);
  printf("  array_set raw %d, ", fic_hv_array_set(x, 0, v));
  printf("array_set juint %d, ", fic_hv_array_set(x, 1, fic_hv_uint(9223372036854775808ull)));
  x = fic_hv_finish(x);
  { size_t m; char *j = fic_hv_to_json(x, &m); printf("to_json %s\n", j); free(j); }
  fic_hv_release(x);
  printf("bad kind: %s; n too large: %s; copy NULL data: %s\n", fic_hv_vector_alloc((enum fic_el)10, 1, &p) == NULL ? "NULL" : "?",
         fic_hv_vector_alloc(FIC_EL_U8, (size_t)-1, &p) == NULL ? "NULL" : "?", fic_hv_vector_copy(FIC_EL_U8, NULL, 3) == NULL ? "NULL" : "?");
  x = fic_hv_vector_copy(FIC_EL_F32, NULL, 0);
  { size_t m; char *j = fic_hv_to_json(x, &m); printf("empty f32 vector: kind %d len %zu json %s\n", (int)fic_hv_kind(x), fic_hv_len(x), j); free(j); }
  fic_hv_release(x);
  { const char *t = "[18446744073709551615, 18446744073709551616, 9223372036854775807, 9223372036854775808, -9223372036854775809, 1e19, 0.5]";
    v = fic_hv_from_json(t, strlen(t)); }
  { size_t m; char *j = fic_hv_to_json(v, &m); printf("parsed: %s\n", j); free(j); }
  printf("  kinds:");
  for (n = 0; n < fic_hv_len(v); n++) printf(" %d", (int)fic_hv_kind(fic_hv_at(v, n)));
  printf("\n");
  fic_hv_release(v);
}

int api_main(void) {
  const char *path = getenv("FIC_HOST_SCRIPT");
  FILE *f = path != NULL ? fopen(path, "r") : NULL;
  char line[4096];
  int rc = fic_app_start(NULL);
  if (rc != FIC_OK) { printf("start: rc %d %s\n", rc, fic_port_error()); return 1; }
  if (f == NULL) { printf("no FIC_HOST_SCRIPT\n"); return 1; }
  while (fgets(line, sizeof line, f) != NULL) {
    char cmd[32], port[64], a1[64];
    size_t len = strlen(line);
    int k;
    while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) line[--len] = 0;
    if (len == 0 || line[0] == '#') continue;
    if (sscanf(line, "%31s", cmd) != 1) continue;
    printf("> %s\n", line);
    if (strcmp(cmd, "sub") == 0 && sscanf(line, "%*s %63s", port) == 1) {
      char *name = strdup(port);
      if (nnames < 64) names[nnames++] = name;
      result("subscribe", fic_port_subscribe(name, printer, name));
    } else if (strcmp(cmd, "json") == 0 && sscanf(line, "%*s %63s", port) == 1) {
      const char *t = strstr(line + 5, port) + strlen(port) + 1;
      result("send_json", fic_port_send_json(port, t, strlen(t)));
    } else if (strcmp(cmd, "int") == 0 && sscanf(line, "%*s %63s %63s", port, a1) == 2) {
      result("send", fic_port_send(port, fic_hv_int(strtoll(a1, NULL, 10))));
    } else if (strcmp(cmd, "uint") == 0 && sscanf(line, "%*s %63s %63s", port, a1) == 2) {
      result("send", fic_port_send(port, fic_hv_uint(strtoull(a1, NULL, 10))));
    } else if (strcmp(cmd, "float") == 0 && sscanf(line, "%*s %63s %63s", port, a1) == 2) {
      result("send", fic_port_send(port, fic_hv_float(strcmp(a1, "nan") == 0 ? NAN : strtod(a1, NULL))));
    } else if ((strcmp(cmd, "vec") == 0 || strcmp(cmd, "veccopy") == 0)) {
      char ks[8]; long n; double a, b; void *d;
      fic_hv v;
      if (sscanf(line, "%*s %63s %7s %ld %lf %lf", port, ks, &n, &a, &b) != 5 || (k = kind_of(ks)) < 0) { printf("bad line\n"); continue; }
      if (strcmp(cmd, "vec") == 0) { v = fic_hv_vector_alloc((enum fic_el)k, (size_t)n, &d); fill(k, d, (size_t)n, a, b); if (ksize[k] == 8 && nallocs < 256) allocs[nallocs++] = d; }
      else { void *tmp = malloc((size_t)n * ksize[k] + 1); fill(k, tmp, (size_t)n, a, b); v = fic_hv_vector_copy((enum fic_el)k, tmp, (size_t)n); free(tmp); }
      result("send", fic_port_send(port, v));
    } else if (strcmp(cmd, "bytes") == 0) {
      long n, i; void *d;
      if (sscanf(line, "%*s %63s %ld", port, &n) != 2) { printf("bad line\n"); continue; }
      fic_port_subscribe("vbOut", bytes_check, NULL);    /* the last command of its script: the echo is checked when it is delivered */
      bytes_n = (size_t)n; bytes_ok = 0;
      t_send = now();
      { fic_hv v = fic_hv_vector_alloc(FIC_EL_U8, (size_t)n, &d);
        for (i = 0; i < n; i++) ((uint8_t *)d)[i] = (uint8_t)(i * 7 + 3);
        result("send", fic_port_send(port, v)); }
    } else if (strcmp(cmd, "deep") == 0) {
      long depth; char leaf[8];
      if (sscanf(line, "%*s %63s %ld %7s", port, &depth, leaf) != 3) { printf("bad line\n"); continue; }
      result("send", fic_port_send(port, deep_value(depth, leaf)));
    } else if (strcmp(cmd, "deeptext") == 0) {
      long depth; size_t n; char *t;
      if (sscanf(line, "%*s %63s %ld", port, &depth) != 2) { printf("bad line\n"); continue; }
      t = deep_text(depth, &n);
      result("send_json", fic_port_send_json(port, t, n));
      free(t);
    } else if (strcmp(cmd, "deepjson") == 0) {
      long depth; size_t n, m; char *t, *u; fic_hv v, w;
      if (sscanf(line, "%*s %ld", &depth) != 1) { printf("bad line\n"); continue; }
      v = deep_value(depth, "1");
      t = fic_hv_to_json(v, &n);
      printf("to_json: "); show_text(t, n); printf("\n");
      w = fic_hv_from_json(t, n);
      u = w != NULL ? fic_hv_to_json(w, &m) : NULL;
      printf("from_json: %s, again equal: %s\n", w != NULL ? "ok" : "NULL", u != NULL && m == n && memcmp(t, u, n) == 0 ? "yes" : "no");
      free(t); free(u); fic_hv_release(v); fic_hv_release(w);
    } else if (strcmp(cmd, "api") == 0) {
      api_reads();
    } else printf("unknown command\n");
    fflush(stdout);
  }
  fclose(f);
  atexit(free_names);                                  /* the deliveries come after this function returns (the event loop) */
  return 0;
}

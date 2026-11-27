/* E3a/E3b: a C host for the effects3 tests, linked with a generated program compiled with -DFIC_HOST_MAIN=fic_test_host_main. It uses
 * only the public interface (runtime/fic_ports_api.h) and does what ficcus-tests/effects3/ref/run3.js does with Elm's `app.ports`, so
 * the two outputs compare line for line: the flags (FIC_FLAGS, FIC_FLAGS_FILE) to fic_app_start, then the commands of FIC_HOST_SCRIPT
 * (see run3.js), before the event loop starts. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fic_ports_api.h"

typedef struct { char port[64]; char label[80]; char q[64]; long k; int done; int kind; } cb_env;
static cb_env envs[256];
static int nenv;

static void print_value(const char *label, const char *what, fic_hv v) {
  size_t n;
  char *j = fic_hv_to_json(v, &n);
  printf("%s%s: %.*s\n", what, label, (int)n, j != NULL ? j : "?");
  free(j);
}

static void cb_print(void *env, fic_hv v) {
  cb_env *e = (cb_env *)env;
  size_t n;
  const char *s = fic_hv_get_string(v, &n);
  if (strcmp(e->port, "output") == 0 && s != NULL) printf("%.*s\n", (int)n, s);
  else print_value(e->label, "", v);
}

static void send_text(const char *p, const char *json, size_t n) {
  int rc = fic_port_send_json(p, json, n);
  if (rc == FIC_E_NO_PORT) printf("send %s: no such port\n", p);
  else if (rc == FIC_E_DECODE) printf("send %s failed:\n%s\n", p, fic_port_error());
  else if (rc != FIC_OK) printf("send %s: error %d: %s\n", p, rc, fic_port_error());
}

static void cb_echo(void *env, fic_hv v) {
  cb_env *e = (cb_env *)env;
  int64_t x;
  print_value(e->port, "echo ", v);
  if (fic_hv_get_int(v, &x) == FIC_OK && x < e->k) {
    int rc = fic_port_send(e->q, fic_hv_int(x + 100));
    if (rc == FIC_E_NO_PORT) printf("send %s: no such port\n", e->q);
    else if (rc != FIC_OK) printf("send %s failed:\n%s\n", e->q, fic_port_error());
  }
}

static void cb_once(void *env, fic_hv v) {
  cb_env *e = (cb_env *)env;
  print_value(e->port, "once ", v);
  fic_port_unsubscribe(e->port, cb_once, env);
}

static cb_env *printer(const char *p, const char *label) {
  int i;
  for (i = 0; i < nenv; i++) if (envs[i].kind == 1 && strcmp(envs[i].label, label) == 0) return &envs[i];
  snprintf(envs[nenv].port, sizeof envs[nenv].port, "%s", p);
  snprintf(envs[nenv].label, sizeof envs[nenv].label, "%s", label);
  envs[nenv].kind = 1;
  return &envs[nenv++];
}

static void cb_adder(void *env, fic_hv v) {
  cb_env *e = (cb_env *)env;
  print_value(e->port, "adder ", v);
  if (!e->done) {
    char label[80];
    e->done = 1;
    snprintf(label, sizeof label, "%s#2", e->port);
    fic_port_subscribe(e->port, cb_print, printer(e->port, label));
  }
}

static char *read_file(const char *path, size_t *n) {
  FILE *f = fopen(path, "rb");
  char *b = NULL;
  size_t cap = 0, k;
  *n = 0;
  if (f == NULL) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
  do {
    if (*n == cap) { cap = cap ? cap * 2 : 4096; b = (char *)realloc(b, cap + 1); if (b == NULL) abort(); }
    k = fread(b + *n, 1, cap - *n, f);
    *n += k;
  } while (k > 0);
  fclose(f);
  b[*n] = 0;
  return b;
}

int fic_test_host_main(void) {
  const char *ft = getenv("FIC_FLAGS"), *ff = getenv("FIC_FLAGS_FILE"), *script = getenv("FIC_HOST_SCRIPT");
  fic_hv flags = NULL;
  int rc;
  if (ft != NULL && *ft && ff != NULL && *ff) { fprintf(stderr, "FIC_FLAGS and FIC_FLAGS_FILE are both set: give the flags in one of them\n"); return 1; }
  if (ft != NULL && *ft) flags = fic_hv_from_json(ft, strlen(ft));
  else if (ff != NULL && *ff) { size_t n; char *t = read_file(ff, &n); flags = fic_hv_from_json(t, n); free(t); }
  rc = fic_app_start(flags);
  if (rc != FIC_OK) { fflush(stdout); fprintf(stderr, "%s\n", fic_port_error()); return 1; }
  if (script != NULL && *script) {
    size_t n;
    char *text = read_file(script, &n), *line = text;
    while (line != NULL && *line) {
      char *nl = strchr(line, '\n'), cmd[16], p[64];
      if (nl != NULL) *nl = 0;
      if (*line && *line != '#' && sscanf(line, "%15s %63s", cmd, p) == 2) {
        if (strcmp(cmd, "send") == 0) {
          const char *json = strchr(strchr(line, ' ') + 1, ' ');
          json = json != NULL ? json + 1 : "";
          send_text(p, json, strlen(json));
        } else {
          char label[80];
          int r = FIC_OK;
          if (strcmp(cmd, "sub") == 0) r = fic_port_subscribe(p, cb_print, printer(p, p));
          else if (strcmp(cmd, "sub2") == 0) { snprintf(label, sizeof label, "%s#2", p); r = fic_port_subscribe(p, cb_print, printer(p, label)); }
          else if (strcmp(cmd, "unsub") == 0) r = fic_port_unsubscribe(p, cb_print, printer(p, p));
          else if (strcmp(cmd, "unsub2") == 0) { snprintf(label, sizeof label, "%s#2", p); r = fic_port_unsubscribe(p, cb_print, printer(p, label)); }
          else if (strcmp(cmd, "echo") == 0) {
            cb_env *e = &envs[nenv++];
            snprintf(e->port, sizeof e->port, "%s", p);
            if (sscanf(line, "%*s %*s %63s %ld", e->q, &e->k) != 2) { fprintf(stderr, "bad line: %s\n", line); return 2; }
            r = fic_port_subscribe(p, cb_echo, e);
          } else if (strcmp(cmd, "once") == 0) {
            cb_env *e = &envs[nenv++];
            snprintf(e->port, sizeof e->port, "%s", p);
            r = fic_port_subscribe(p, cb_once, e);
          } else if (strcmp(cmd, "adder") == 0) {
            cb_env *e = &envs[nenv++];
            snprintf(e->port, sizeof e->port, "%s", p);
            r = fic_port_subscribe(p, cb_adder, e);
          } else { fprintf(stderr, "unknown command: %s\n", line); return 2; }
          if (r == FIC_E_NO_PORT) printf("%s %s: no such port\n", cmd, p);
          else if (r != FIC_OK) printf("%s %s: error %d\n", cmd, p, r);
        }
      }
      line = nl != NULL ? nl + 1 : NULL;
    }
    free(text);
  }
  return 0;
}

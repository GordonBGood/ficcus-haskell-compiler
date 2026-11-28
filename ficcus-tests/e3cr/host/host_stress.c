/* host_stress.c -- E3c review, item 5: the host's JSON parser and writer (runtime/fic_ports_fic.h) under stress.  The program runs
 * on its own thread of FIC_STACK_MB megabytes, so the build uses -DFIC_STACK_MB=1 (ulimit -s does not reach that thread).
 * FIC_STRESS=<case>; programs: E3cDeep (deep, big) or E3crLife (text) -- both have jsonIn, jsonOut and output.
 *   deep    1,000,000 levels: arrays and objects as text through fic_port_send_json; fic_hv_to_json/from_json of them; a refused
 *           deep value (listIn of E3cDeep: its error text stops at the budget)
 *   big     large strings (64 MB of ASCII, 8M x "\u00e9", 1M escaped surrogate pairs) and long numbers (1 MB of digits, exponents),
 *           through jsonIn and back out (the printer shows the length, head and tail)
 *   text    invalid UTF-8, surrogate escapes, duplicate keys, bad escapes: rc and error text per input (small values)
 * Build: ../build.sh <Prog> host/host_stress.c OUT -DFIC_STACK_MB=1 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../../runtime/fic_ports_api.h"

static void show(const char *t, size_t n) {
  if (n <= 300) { fwrite(t, 1, n, stdout); return; }
  printf("<%zu bytes> ", n); fwrite(t, 1, 40, stdout); printf(" ... "); fwrite(t + n - 30, 1, 30, stdout);
}

static void printer(void *env, fic_hv v) {
  size_t n; char *j = fic_hv_to_json(v, &n);
  printf("  %s: ", (const char *)env); show(j, n); printf("\n"); free(j);
}

static void send(const char *what, const char *port, const char *t, size_t n) {
  int rc = fic_port_send_json(port, t, n);
  printf("%s: ", what);
  if (rc == FIC_OK) printf("ok\n");
  else { const char *e = fic_port_error(); printf("rc %d: ", rc); show(e, strlen(e)); printf("\n"); }
  fflush(stdout);
}

static char *rep(const char *open, const char *mid, const char *close, long depth, size_t *n) {
  size_t lo = strlen(open), lm = strlen(mid), lc = strlen(close), k = 0;
  char *t = (char *)malloc((size_t)depth * (lo + lc) + lm + 1);
  long i;
  for (i = 0; i < depth; i++) { memcpy(t + k, open, lo); k += lo; }
  memcpy(t + k, mid, lm); k += lm;
  for (i = 0; i < depth; i++) { memcpy(t + k, close, lc); k += lc; }
  t[k] = 0; *n = k;
  return t;
}

static void roundtrip(const char *what, const char *t, size_t n) {
  fic_hv v = fic_hv_from_json(t, n);
  size_t m; char *u = v != NULL ? fic_hv_to_json(v, &m) : NULL;
  printf("%s: from_json %s, to_json equal to the text: %s\n", what, v != NULL ? "ok" : "NULL", u != NULL && m == n && memcmp(t, u, n) == 0 ? "yes" : "no");
  free(u); fic_hv_release(v);
}

static void deep(void) {
  size_t n; char *t;
  t = rep("[", "1", "]", 1000000, &n); send("array 1e6 text", "jsonIn", t, n); roundtrip("array 1e6", t, n); free(t);
  t = rep("{\"a\":", "null", "}", 1000000, &n); send("object 1e6 text", "jsonIn", t, n); roundtrip("object 1e6", t, n); free(t);
  t = rep("[{\"k\":", "\"x\"", "}]", 500000, &n); send("mixed 1e6 text", "jsonIn", t, n); free(t);
  t = rep("[", "1", "]", 1000000, &n); t[n - 1] = 0; send("unclosed 1e6", "jsonIn", t, n - 1); free(t);
  t = rep("[", "1", "]", 1000000, &n); send("refused 1e6 (listIn)", "listIn", t, n); free(t);
  t = rep("[", "", "", 3000000, &n); send("only opens 3e6", "jsonIn", t, n); free(t);
}

static void big(void) {
  size_t n = 64u << 20, i; char *t = (char *)malloc(n + 3);
  t[0] = '"'; memset(t + 1, 'a', n); t[n + 1] = '"'; t[n + 2] = 0;
  send("string 64 MB", "jsonIn", t, n + 2); free(t);
  n = 8u << 20; t = (char *)malloc(n * 6 + 3); t[0] = '"';
  for (i = 0; i < n; i++) memcpy(t + 1 + i * 6, "\\u00e9", 6);
  t[n * 6 + 1] = '"'; send("8M escaped e-acute", "jsonIn", t, n * 6 + 2); free(t);
  n = 1u << 20; t = (char *)malloc(n * 12 + 3); t[0] = '"';
  for (i = 0; i < n; i++) memcpy(t + 1 + i * 12, "\\ud83d\\ude00", 12);
  t[n * 12 + 1] = '"'; send("1M escaped pairs", "jsonIn", t, n * 12 + 2); free(t);
  { static const char *forms[] = { "%s", "-%s", "0.%s", "1e%s", "1e-%s", "%se-1048576", "[%s]", "[18446744073709551615%s]" };
    size_t d = 1u << 20, k;
    char *digits = (char *)malloc(d + 1);
    memset(digits, '0', d); digits[0] = '1'; digits[d] = 0;
    for (k = 0; k < sizeof forms / sizeof forms[0]; k++) {
      char *u = (char *)malloc(d + 64); char what[64];
      snprintf(u, d + 64, forms[k], digits);
      snprintf(what, sizeof what, "number form %s, 1 MB of digits", forms[k]);
      send(what, "jsonIn", u, strlen(u)); free(u);
    }
    free(digits); }
}

static void text(void) {
  static const char *cases[] = {
    "\"\xff\"", "\"\xc0\x80\"", "\"\xed\xa0\x80\"", "\"a\xe2\x82\"", "\"\xf4\x90\x80\x80\"", "\"\xe2\x82\xac\"",
    "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800\\u0041\"", "\"\\ud800\\ud800\"", "\"\\ud83d\\ude00\"", "\"\\u12\"", "\"\\uZZZZ\"",
    "\"\\x41\"", "\"\t\"", "\"\\/\"", "{\"a\":1,\"a\":2}", "{\"a\":1,\"b\":{\"a\":3},\"a\":[18446744073709551615]}",
    "{\"\":1,\"\":2}", "{\"a\\u0000\":1}", "[1,]", "[,1]", "{\"a\":1,}", "{\"a\" 1}", "\xef\xbb\xbf[1]", " [1] ", "[1] x",
    "\"\xed\xb0\x80\"", "\"\xf0\x9f\x98\x80\"", "\"\xf0\x9f\x98\"" };
  size_t k;
  for (k = 0; k < sizeof cases / sizeof cases[0]; k++) {
    char what[32]; snprintf(what, sizeof what, "text %zu", k);
    send(what, "jsonIn", cases[k], strlen(cases[k]));
  }
}

int stress_main(void) {
  const char *c = getenv("FIC_STRESS");
  if (c == NULL || fic_app_start(NULL) != FIC_OK) { printf("no FIC_STRESS or start failed\n"); return 1; }
  fic_port_subscribe("output", printer, "output");
  fic_port_subscribe("jsonOut", printer, "jsonOut");
  printf("case %s\n", c);
  if (strcmp(c, "deep") == 0) deep();
  else if (strcmp(c, "big") == 0) big();
  else if (strcmp(c, "text") == 0) text();
  return 0;
}

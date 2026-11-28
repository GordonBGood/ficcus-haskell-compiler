/* E3a review: deep host values (built with the API, so no parser limit applies). DEEP_MODE picks one step:
   tojson  fic_hv_to_json of a value nested DEEP levels
   refuse  fic_port_send of it to pInt (refused: the error text encodes it)
   release build it and release it (a recursive free?)
   accept  fic_port_send of it to pVal (the program encodes it with E.encode 0) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fic_ports_api.h"

static void cb(void *env, fic_hv v) { size_t n; const char *s = fic_hv_get_string(v, &n); (void)env; printf("out: %zu bytes %.20s\n", n, s); }

static fic_hv nest(long d) {
  fic_hv v = fic_hv_int(1);
  long i;
  for (i = 0; i < d; i++) { fic_hv a = fic_hv_array(1); fic_hv_array_set(a, 0, v); v = fic_hv_finish(a); }
  return v;
}

int deep_main(void) {
  const char *mode = getenv("DEEP_MODE");
  long d = atol(getenv("DEEP"));
  fic_hv v;
  int rc;
  if (fic_app_start(NULL) != FIC_OK) return 2;
  fic_port_subscribe("out", cb, NULL);
  v = nest(d);
  printf("built %ld\n", d); fflush(stdout);
  if (strcmp(mode, "tojson") == 0) { size_t n; char *j = fic_hv_to_json(v, &n); printf("to_json: %zu bytes\n", n); free(j); fic_hv_release(v); }
  else if (strcmp(mode, "refuse") == 0) { rc = fic_port_send("pInt", v); printf("send pInt: %d, %zu bytes of text\n", rc, strlen(fic_port_error())); }
  else if (strcmp(mode, "release") == 0) { fic_hv_release(v); printf("released\n"); }
  else { rc = fic_port_send("pVal", v); printf("send pVal: %d\n", rc); }
  fflush(stdout);
  return 0;
}

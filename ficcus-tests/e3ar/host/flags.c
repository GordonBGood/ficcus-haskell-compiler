/* E3b review: fic_app_start from a host. FLAGS_MODE:
   retry   a failing start (after partial work), then a good one
   failret a failing start, then return 0 (the program never started: what does the loop do?)
   unsealed  an unsealed builder as flags */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fic_ports_api.h"

static void cb(void *env, fic_hv v) { size_t n; const char *s = fic_hv_get_string(v, &n); (void)env; printf("out: %.*s\n", (int)n, s); }
static fic_hv json(const char *s) { return fic_hv_from_json(s, strlen(s)); }

int flags_main(void) {
  const char *mode = getenv("FLAGS_MODE");
  int rc;
  if (strcmp(mode, "unsealed") == 0) {
    fic_hv a = fic_hv_object(1);
    rc = fic_app_start(a);
    printf("start unsealed: %d %s\n", rc, fic_port_error());
  } else {
    rc = fic_app_start(json("{\"a\":\"x\",\"b\":[\"y\",\"z\"],\"c\":\"no\",\"d\":{\"k\":[1]}}"));
    printf("start bad: %d\n%s\n", rc, fic_port_error());
    if (strcmp(mode, "failret") == 0) { fflush(stdout); return 0; }
  }
  rc = fic_app_start(json("{\"a\":\"x\",\"b\":[\"y\",\"z\"],\"c\":3,\"d\":{\"k\":[1]}}"));
  printf("start good: %d %s\n", rc, rc ? fic_port_error() : "");
  printf("subscribe: %d\n", fic_port_subscribe("out", cb, NULL));
  fflush(stdout);
  return rc == 0 ? 0 : 3;
}

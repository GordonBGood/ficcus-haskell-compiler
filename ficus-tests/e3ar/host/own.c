/* E3a review: ownership at the boundary and re-entrancy (D3, D12), driven through the public API only.
   Linked with a generated R1Own.c (-DFIC_HOST_MAIN=own_main); run --rc under ASan + UBSan: must end with live 0 and no reports. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "R1Own_ports.h"

static void say(const char *what, int rc) {
  printf("%s: %d%s%s\n", what, rc, rc != 0 ? " | " : "", rc != 0 ? fic_port_error() : "");
}
static fic_hv str(const char *s) { return fic_hv_string(s, strlen(s)); }
static fic_hv json(const char *s) { return fic_hv_from_json(s, strlen(s)); }
static void show(const char *who, fic_hv v) { size_t n; char *j = fic_hv_to_json(v, &n); printf("%s %s\n", who, j ? j : "(not a value)"); free(j); }

static fic_hv kept = NULL;          /* retained from a callback, released by a later one */
static int ncallsV = 0, ncallsS = 0, ncallsX = 0;

static void cbX(void *env, fic_hv v) { (void)env; ncallsX++; show("  X got", v); }

static void cbV(void *env, fic_hv v) {
  (void)env;
  ncallsV++;
  show("  V got", v);
  if (ncallsV == 1) {
    kept = fic_hv_retain(v);                              /* keep it beyond the call */
    say("  V: send pStr from inside the callback", fic_port_send("pStr", str("nested")));
    say("  V: subscribe X during the delivery", fic_port_subscribe("outV", cbX, NULL));
    say("  V: unsubscribe myself during the delivery", fic_port_unsubscribe("outV", cbV, NULL));
    say("  V: send the kept value back (retained again first)", fic_port_send("pVal", fic_hv_retain(kept)));
  }
}

static void cbS(void *env, fic_hv v) {
  (void)env;
  ncallsS++;
  show("  S got", v);
  if (kept != NULL && ncallsS >= 4) { show("  S: the kept value is still", kept); fic_hv_release(kept); kept = NULL; }
  if (ncallsS == 6) {
    say("  S: unsubscribe X", fic_port_unsubscribe("outV", cbX, NULL));
    say("  S: unsubscribe a callback that is not there", fic_port_unsubscribe("outV", cbV, (void *)1));
  }
}

int own_main(void) {
  fic_hv a, b, s, o;
  char *p;
  int i;
  say("subscribe before start", fic_port_subscribe("outS", cbS, NULL));
  say("send before start", fic_port_send("pStr", str("early")));
  say("start", fic_app_start(NULL));
  say("start again", fic_app_start(NULL));
  say("subscribe S", fic_port_subscribe("outS", cbS, NULL));
  say("subscribe V", fic_port_subscribe("outV", cbV, NULL));
  /* decode failures after partial work: the parts decoded first must be released */
  say("pRec, second string of xs is a number", fic_port_send("pRec", json("{\"name\":\"nm\",\"xs\":[\"a\",\"b\",1]}")));
  say("pRec, name ok, xs missing", fic_port_send("pRec", json("{\"name\":\"nm\"}")));
  say("pTup, 2nd fails late", fic_port_send("pTup", json("[\"s\",[\"a\",null]]")));
  {
    char buf[64];
    a = fic_hv_array(40);
    for (i = 0; i < 40; i++) { snprintf(buf, sizeof buf, "e%d", i); fic_hv_array_set(a, (size_t)i, i == 39 ? fic_hv_int(5) : str(buf)); }
    say("pArr, element 39 of 40 is a number", fic_port_send("pArr", fic_hv_finish(a)));
    a = fic_hv_array(1057);
    for (i = 0; i < 1057; i++) { snprintf(buf, sizeof buf, "e%d", i); fic_hv_array_set(a, (size_t)i, str(buf)); }
    say("pArr, 1057 strings", fic_port_send("pArr", fic_hv_finish(a)));
  }
  /* builder misuse */
  a = fic_hv_array(2);
  say("set slot 0", fic_hv_array_set(a, 0, str("x")));
  say("set slot 0 again", fic_hv_array_set(a, 0, str("y")));
  say("set slot 2 (out of range)", fic_hv_array_set(a, 2, str("z")));
  say("send the unsealed builder", fic_port_send("pVal", fic_hv_retain(a)));
  printf("finish with slot 1 unset: %s\n", fic_hv_finish(a) == NULL ? "NULL" : "a value");
  a = fic_hv_array(1);
  fic_hv_array_set(a, 0, str("x"));
  b = fic_hv_retain(a);
  { fic_hv r = fic_hv_finish(a); printf("finish a retained builder: %s | %s\n", r == NULL ? "NULL" : "a value", fic_port_error()); }
  fic_hv_release(b);
  o = fic_hv_object(2);
  say("object key not UTF-8", fic_hv_object_set(o, 0, "\xff", 1, str("v")));
  fic_hv_object_set(o, 0, "k", 1, str("v1"));
  fic_hv_object_set(o, 1, "k", 1, str("v2"));
  o = fic_hv_finish(o);
  show("object with a duplicate key", o);
  say("pVal with it", fic_port_send("pVal", o));
  s = fic_hv_string_alloc(3, &p);
  memcpy(p, "abc", 3);
  say("send an unsealed string", fic_port_send("pStr", fic_hv_retain(s)));
  s = fic_hv_string_seal(s);
  b = fic_hv_retain(s);
  say("pStr with a retained string", fic_port_send("pStr", s));
  show("the host's string after the update appended to it", b);
  fic_hv_release(b);
  s = fic_hv_string_alloc(2, &p);
  memcpy(p, "\xc0\x80", 2);
  printf("seal an overlong NUL: %s\n", fic_hv_string_seal(s) == NULL ? "NULL" : "a value");
  say("pMV null", fic_port_send("pMV", fic_hv_null()));
  say("pMV object", fic_port_send("pMV", json("{\"q\":[1,2.5,\"\\u00e9\"]}")));
  say("send_json not JSON", fic_port_send_json("pStr", "[1,", 3));
  say("send NULL", fic_port_send("pStr", NULL));
  say("send to a missing port", fic_port_send("nope", str("x")));
  say("send to an outgoing port", fic_port_send("outS", str("x")));
  say("pVal, a value that the updates keep and echo", fic_port_send("pVal", json("{\"keep\":true}")));
  return 0;
}

/* E3a: the host value API and the port calls of runtime/fic_ports_api.h, against the program effects3/src/E3Api.fic, compiled with
 * -DFIC_HOST_MAIN=api_main. It includes the generated E3Api_ports.h (the API text and the FIC_PORT_ names), so it also checks that
 * a host compiles against that header alone. No Elm twin: the expected output (expected/e3_api.out) follows the rules of
 * docs/E3-PORTS-DESIGN.md D2 to D4, D7, D8, D12 and D15. Under --rc the program must end with live 0: every value consumed by a
 * setter or a send (also a failed one) and every value retained and released by the host is freed. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "E3Api_ports.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("CHECK FAILED line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static void show(const char *what, fic_hv v) {
  size_t n;
  char *j = fic_hv_to_json(v, &n);
  printf("%s: %s\n", what, j != NULL ? j : "(null)");
  free(j);
}

static fic_hv kept;                                  /* a value an outgoing callback retained */
static int calls;

static void on_val(void *env, fic_hv v) {
  (void)env;
  show("valOut", v);
  calls++;
  if (calls == 1) kept = fic_hv_retain(v);          /* keep the first value beyond the call ... */
  else if (kept != NULL) {                           /* ... and read it at the next call, then release it */
    show("kept", kept);
    fic_hv_release(kept);
    kept = NULL;
  }
}

static void on_str(void *env, fic_hv v) {
  size_t n;
  const char *s = fic_hv_get_string(v, &n);
  printf("strOut (%s): %.*s (%zu bytes)\n", (const char *)env, (int)n, s != NULL ? s : "?", n);
}

static void at_end(void) {
  int rc = fic_port_subscribe(FIC_PORT_valOut, on_val, NULL);
  printf("after the end: subscribe %d, send %d\n", rc, fic_port_send(FIC_PORT_strIn, fic_hv_string("x", 1)));
  if (kept != NULL) printf("a value is still retained\n");
}

int api_main(void) {
  fic_hv a, o, s, v, b;
  int64_t i;
  double d;
  int bo, rc;
  size_t n;
  char *p;

  /* scalars and kinds */
  CHECK(fic_hv_kind(NULL) == FIC_HV_INVALID);
  v = fic_hv_null(); CHECK(fic_hv_kind(v) == FIC_HV_NULL); fic_hv_release(v);
  v = fic_hv_bool(7); CHECK(fic_hv_get_bool(v, &bo) == FIC_OK && bo == 1); CHECK(fic_hv_get_int(v, &i) == FIC_E_INVALID); fic_hv_release(v);
  v = fic_hv_int(-9007199254740993LL); CHECK(fic_hv_get_int(v, &i) == FIC_OK && i == -9007199254740993LL); show("int", v); fic_hv_release(v);
  v = fic_hv_float(1e3); CHECK(fic_hv_kind(v) == FIC_HV_FLOAT); CHECK(fic_hv_get_int(v, &i) == FIC_OK && i == 1000); fic_hv_release(v);
  v = fic_hv_float(1.5); CHECK(fic_hv_get_int(v, &i) == FIC_E_INVALID); CHECK(fic_hv_get_float(v, &d) == FIC_OK && d == 1.5); fic_hv_release(v);
  v = fic_hv_float(0.0 / 0.0); show("nan", v); fic_hv_release(v);

  /* strings (D4) */
  v = fic_hv_string("h\xc3\xa9 \xf0\x9f\x98\x80", 8); CHECK(v != NULL); show("string", v); fic_hv_release(v);
  CHECK(fic_hv_string("\xc0\x80", 2) == NULL);              /* overlong */
  CHECK(fic_hv_string("\xed\xa0\x80", 3) == NULL);          /* a surrogate */
  CHECK(fic_hv_string("\xf4\x90\x80\x80", 4) == NULL);      /* above U+10FFFF */
  CHECK(fic_hv_string("\xe2\x82", 2) == NULL);              /* truncated */
  CHECK(fic_hv_string("\xff", 1) == NULL);
  v = fic_hv_string("", 0); CHECK(v != NULL && fic_hv_get_string(v, &n) != NULL && n == 0); fic_hv_release(v);
  s = fic_hv_string_alloc(12, &p); memcpy(p, "hello w\xc3\xb6rld", 12); s = fic_hv_string_seal(s);
  CHECK(s != NULL && fic_hv_kind(s) == FIC_HV_STRING); show("sealed", s); fic_hv_release(s);
  s = fic_hv_string_alloc(3, &p); memcpy(p, "a\xc3x", 3); CHECK(fic_hv_string_seal(s) == NULL);

  /* arrays and objects: L35 order, the last duplicate wins at the place of the first, unset slots, wrong values */
  o = fic_hv_object(5);
  CHECK(fic_hv_object_set(o, 0, "b", 1, fic_hv_int(1)) == FIC_OK);
  CHECK(fic_hv_object_set(o, 1, "a", 1, fic_hv_int(2)) == FIC_OK);
  CHECK(fic_hv_object_set(o, 2, "2", 1, fic_hv_bool(1)) == FIC_OK);
  CHECK(fic_hv_object_set(o, 3, "1", 1, fic_hv_null()) == FIC_OK);
  CHECK(fic_hv_object_set(o, 4, "b", 1, fic_hv_string("last", 4)) == FIC_OK);
  CHECK(fic_hv_object_set(o, 5, "c", 1, fic_hv_int(9)) == FIC_E_INVALID);     /* out of range: the value is consumed */
  CHECK(fic_hv_object_set(o, 0, "\xff", 1, fic_hv_int(9)) == FIC_E_INVALID);  /* a key that is not UTF-8 */
  CHECK(fic_hv_kind(o) == FIC_HV_INVALID);                                  /* unsealed */
  o = fic_hv_finish(o);
  CHECK(fic_hv_kind(o) == FIC_HV_OBJECT && fic_hv_len(o) == 4);
  show("object", o);
  CHECK(fic_hv_field(o, "b") != NULL && fic_hv_get_string(fic_hv_field(o, "b"), &n) != NULL && n == 4);
  CHECK(fic_hv_field(o, "zz") == NULL);
  CHECK(fic_hv_key(o, 0, &n) != NULL && n == 1 && fic_hv_key(o, 0, &n)[0] == '1');
  a = fic_hv_array(3);
  CHECK(fic_hv_array_set(a, 0, fic_hv_float(2.5)) == FIC_OK);
  CHECK(fic_hv_array_set(a, 1, o) == FIC_OK);                             /* o is consumed */
  CHECK(fic_hv_array_set(a, 3, fic_hv_int(1)) == FIC_E_INVALID);
  b = fic_hv_array(1);
  CHECK(fic_hv_array_set(a, 2, b) == FIC_E_INVALID);                      /* an unsealed array: consumed, refused */
  printf("error: %s\n", fic_port_error());
#ifdef FIC_RC
  CHECK(fic_hv_finish(fic_hv_retain(a)) == NULL);                          /* a shared builder is refused (and the count released) */
#endif
  CHECK(fic_hv_array_set(a, 2, fic_hv_string("z", 1)) == FIC_OK);
  CHECK(fic_hv_array_set(a, 2, fic_hv_string("y", 1)) == FIC_OK);         /* a slot set again */
  a = fic_hv_finish(a);
  CHECK(fic_hv_kind(a) == FIC_HV_ARRAY && fic_hv_len(a) == 3 && fic_hv_kind(fic_hv_at(a, 1)) == FIC_HV_OBJECT && fic_hv_at(a, 3) == NULL);
  show("array", a);
  fic_hv_release(a);
  b = fic_hv_array(2);
  CHECK(fic_hv_array_set(b, 1, fic_hv_int(1)) == FIC_OK);
  CHECK(fic_hv_finish(b) == NULL);                                         /* slot 0 never set */
  printf("error: %s\n", fic_port_error());
  v = fic_hv_finish(fic_hv_object(0)); CHECK(v != NULL); show("empty", v); fic_hv_release(v);

  /* JSON text (D8) */
  { const char *t = " [1, 2.5, \"x\\u00e9\", null, true, {\"k\": -0, \"2\": 1e400}] "; v = fic_hv_from_json(t, strlen(t)); }
  CHECK(v != NULL); show("parsed", v);
  p = fic_hv_to_json(v, &n); CHECK(p != NULL && n == strlen(p)); free(p);
  fic_hv_release(v);
  CHECK(fic_hv_from_json("[1,", 3) == NULL);
  CHECK(fic_hv_from_json("\"\xff\"", 3) == NULL);
  CHECK(fic_hv_to_json(NULL, &n) == NULL);

  /* the program (D11: () flags are never read; a second start is refused) */
  CHECK(fic_port_send(FIC_PORT_strIn, fic_hv_string("early", 5)) == FIC_E_NO_PORT);   /* before the start: no ports yet */
  rc = fic_app_start(fic_hv_int(5));
  CHECK(rc == FIC_OK);
  CHECK(fic_app_start(NULL) == FIC_E_INVALID);
  printf("error: %s\n", fic_port_error());

  /* ports */
  CHECK(fic_port_subscribe(FIC_PORT_valOut, on_val, NULL) == FIC_OK);
  CHECK(fic_port_subscribe(FIC_PORT_strOut, on_str, "first") == FIC_OK);
  CHECK(fic_port_subscribe(FIC_PORT_strOut, on_str, "second") == FIC_OK);
  CHECK(fic_port_unsubscribe(FIC_PORT_strOut, on_str, "second") == FIC_OK);
  CHECK(fic_port_unsubscribe(FIC_PORT_strOut, on_str, "never") == FIC_OK);  /* not subscribed: nothing happens, as Elm */
  CHECK(fic_port_subscribe(FIC_PORT_strIn, on_str, NULL) == FIC_E_NO_PORT);  /* an incoming port has no subscribe */
  printf("error: %s\n", fic_port_error());
  CHECK(fic_port_subscribe(FIC_PORT_strOut, NULL, NULL) == FIC_E_INVALID);
  CHECK(fic_port_send(FIC_PORT_valOut, fic_hv_null()) == FIC_E_NO_PORT);     /* an outgoing port has no send */
  printf("error: %s\n", fic_port_error());
  CHECK(fic_port_send("nope", fic_hv_null()) == FIC_E_NO_PORT);
  CHECK(fic_port_send(FIC_PORT_strIn, NULL) == FIC_E_INVALID);
  CHECK(fic_port_send(FIC_PORT_strIn, fic_hv_object(1)) == FIC_E_INVALID);    /* unsealed */
  CHECK(fic_port_send(FIC_PORT_strIn, fic_hv_int(3)) == FIC_E_DECODE);
  printf("error: %s\n", fic_port_error());
  CHECK(fic_port_send_json(FIC_PORT_valIn, "{bad", 4) == FIC_E_DECODE);
  printf("error: %s\n", fic_port_error());
  CHECK(fic_port_send_json(FIC_PORT_valIn, "\"\xff\"", 3) == FIC_E_INVALID);
  CHECK(fic_port_send(FIC_PORT_strIn, fic_hv_string("h\xc3\xa9\xf0\x9f\x98\x80", 7)) == FIC_OK);   /* String.length: UTF-16 units */
  v = fic_hv_object(2);
  fic_hv_object_set(v, 0, "z", 1, fic_hv_int(1));
  fic_hv_object_set(v, 1, "a", 1, fic_hv_from_json("[1,{\"q\":null}]", strlen("[1,{\"q\":null}]")));
  v = fic_hv_finish(v);
  CHECK(fic_port_send(FIC_PORT_valIn, fic_hv_retain(v)) == FIC_OK);         /* the host keeps its count: the program shares the value */
  show("still held", v);
  fic_hv_release(v);
  CHECK(fic_port_send_json(FIC_PORT_valIn, "[3]", 3) == FIC_OK);
  atexit(at_end);
  printf("checks failed: %d\n", fails);
  return 0;
}

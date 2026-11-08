/* Standalone tests of the runtime fragments (strings, Int/Float helpers, the Float formatter, Debug printers).
   The fragments have no include guards: they are one text, included in this order, as in a generated file.
   Build and run: runtime/test.sh */
#include "fic_base.h"
#include "fic_string.h"
#include "fic_num.h"
#include "fic_format.h"
#include "fic_debug.h"

static int failures = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); failures++; } } while (0)

static int is_str(fic_ref s, const char *want) {
  return FIC_STR(s)->len == (int64_t)strlen(want) && memcmp(FIC_STR(s)->data, want, strlen(want)) == 0;
}
static int fmt_is(double x, const char *want) { char b[64]; fic_fmt_float(x, b); return strcmp(b, want) == 0; }

int main(void) {
  /* strings */
  fic_ref a = fic_str_new("ab", 2), b = fic_str_new("cd", 2), e = fic_str_new("", 0);
  CHECK(is_str(fic_str_append(a, b), "abcd"));
  CHECK(is_str(fic_str_append(e, b), "cd"));
  CHECK(fic_str_eq(a, fic_str_new("ab", 2)) && !fic_str_eq(a, b) && !fic_str_eq(a, e));
  /* Int helpers */
  CHECK(fic_idiv(7, 2) == 3 && fic_idiv(-7, 2) == -3 && fic_idiv(5, 0) == 0);
  CHECK(fic_idiv(INT64_MIN, -1) == INT64_MIN);
  CHECK(fic_ipow(2, 10) == 1024 && fic_ipow(3, 0) == 1 && fic_ipow(2, -1) == 0 && fic_ipow(2, 64) == 0);
  CHECK(FIC_SUB64(INT64_MIN, 1) == INT64_MAX && FIC_NEG64(INT64_MIN) == INT64_MIN);
  /* Float comparisons: NaN compares as GT, as Elm's kernel does */
  { double n = NAN;
    CHECK(!fic_f_lt(n, 1) && !fic_f_le(n, 1) && fic_f_gt(n, 1) && fic_f_ge(n, 1));
    CHECK(fic_f_le(1, 1) && !fic_f_gt(1, 1) && fic_f_ge(1, 1) && fic_f_lt(1, 2)); }
  /* Int and Float to String */
  CHECK(is_str(fic_str_from_int(-42), "-42") && is_str(fic_str_from_int(INT64_MIN), "-9223372036854775808"));
  CHECK(fmt_is(0.1, "0.1") && fmt_is(1, "1") && fmt_is(-1.5, "-1.5") && fmt_is(100, "100") && fmt_is(0, "0"));
  CHECK(fmt_is(1e21, "1e+21") && fmt_is(1e20, "100000000000000000000") && fmt_is(1.5e-7, "1.5e-7"));
  CHECK(fmt_is(0.000001, "0.000001") && fmt_is(123456789.125, "123456789.125"));
  CHECK(fmt_is(5e-324, "5e-324") && fmt_is(1.7976931348623157e308, "1.7976931348623157e+308"));
  CHECK(fmt_is(NAN, "NaN") && fmt_is(INFINITY, "Infinity") && fmt_is(-INFINITY, "-Infinity"));
  CHECK(fmt_is(7.120236347223045e-307, "7.120236347223045e-307"));   /* a power of two: the neighbour digit */
  CHECK(is_str(fic_str_from_float(3.25), "3.25"));
  /* Debug.toString of a String */
  CHECK(is_str(fic_show_string(fic_str_new("a\"b\\c\n\t", 7)), "\"a\\\"b\\\\c\\n\\t\""));
  CHECK(is_str(fic_show_string(e), "\"\""));
  /* Debug.log (the output is checked by test.sh against runtime/test_runtime.expected) */
  fic_log(fic_str_new("tag", 3), fic_str_from_int(7));
  fic_log_unit(fic_str_new("u", 1));
  if (failures) { printf("%d failure(s)\n", failures); return 1; }
  printf("runtime tests ok\n");
  return 0;
}

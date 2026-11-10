/* Standalone test of fic_fdlibm.h (decision L18): the results of node (V8's Math.*) for 47 edge values and 60 generated inputs per
   function (test_fdlibm_cases.h, written by gen_fdlibm_test.js), compared bit for bit.
   The large differential test is fdlibm_diff.sh. Build and run: runtime/test.sh */
#include <stdio.h>
#include <string.h>
#include "fic_fdlibm.h"
#include "test_fdlibm_cases.h"

static double fromhex(unsigned long long b) { double d; memcpy(&d, &b, 8); return d; }
static int same(double a, double b) { return (a != a && b != b) || memcmp(&a, &b, 8) == 0; }
static int failures = 0, total = 0;
#define CASES1(name, fn) do { unsigned i; for (i = 0; i < sizeof fdc_##name / sizeof fdc_##name[0]; i++) { double x = fromhex(fdc_##name[i][0]), want = fromhex(fdc_##name[i][1]), got = fn(x); total++; \
  if (!same(got, want)) { if (failures++ < 20) printf("FAIL " #name "(%.17g) = %.17g, node %.17g\n", x, got, want); } } } while (0)
#define CASES2(name, fn, ok) do { unsigned i; for (i = 0; i < sizeof fdc_##name / sizeof fdc_##name[0]; i++) { double x = fromhex(fdc_##name[i][0]), y = fromhex(fdc_##name[i][1]), want = fromhex(fdc_##name[i][2]), got = fn(x, y); total++; \
  if (!ok(got, want)) { if (failures++ < 20) printf("FAIL " #name "(%.17g, %.17g) = %.17g, node %.17g\n", x, y, got, want); } } } while (0)

int main(void) {
  CASES1(sin, fic_fd_sin); CASES1(cos, fic_fd_cos); CASES1(tan, fic_fd_tan); CASES1(asin, fic_fd_asin); CASES1(acos, fic_fd_acos); CASES1(atan, fic_fd_atan);
  CASES1(exp, fic_fd_exp); CASES1(log, fic_fd_log); CASES1(log2, fic_fd_log2); CASES1(log10, fic_fd_log10); CASES1(log1p, fic_fd_log1p); CASES1(expm1, fic_fd_expm1);
  CASES1(sinh, fic_fd_sinh); CASES1(cosh, fic_fd_cosh); CASES1(tanh, fic_fd_tanh); CASES1(asinh, fic_fd_asinh); CASES1(acosh, fic_fd_acosh); CASES1(atanh, fic_fd_atanh);
  CASES1(cbrt, fic_fd_cbrt);
  CASES2(atan2, fic_fd_atan2, same); CASES2(pow, fic_fd_pow, same);
  if (fic_fd_logbase(10.0, 1000.0) != 3.0 || fic_fd_logbase(2.0, 8.0) != 3.0) { printf("FAIL logbase\n"); failures++; }
  if (failures) { printf("%d failure(s) of %d\n", failures, total); return 1; }
  printf("fdlibm tests ok (%d cases)\n", total);
  return 0;
}

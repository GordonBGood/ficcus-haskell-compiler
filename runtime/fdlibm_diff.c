/* fdlibm_diff.c DIR [function]: the functions of fic_fdlibm.h against node's results (files written by gen_fdlibm_test.js bin);
   prints the number of differing results per function (bit patterns; any NaN equals any NaN); exit status 1 if any differs.
   Run through fdlibm_diff.sh. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fic_fdlibm.h"
typedef double (*F1)(double);
typedef double (*F2)(double, double);
static int same(double a, double b) { return (a != a && b != b) || memcmp(&a, &b, 8) == 0; }
int main(int argc, char **argv) {
  struct { const char *n; F1 f; } t1[] = { {"sin", fic_fd_sin}, {"cos", fic_fd_cos}, {"tan", fic_fd_tan}, {"asin", fic_fd_asin}, {"acos", fic_fd_acos}, {"atan", fic_fd_atan},
    {"exp", fic_fd_exp}, {"log", fic_fd_log}, {"log2", fic_fd_log2}, {"log10", fic_fd_log10}, {"log1p", fic_fd_log1p}, {"expm1", fic_fd_expm1},
    {"sinh", fic_fd_sinh}, {"cosh", fic_fd_cosh}, {"tanh", fic_fd_tanh}, {"asinh", fic_fd_asinh}, {"acosh", fic_fd_acosh}, {"atanh", fic_fd_atanh}, {"cbrt", fic_fd_cbrt} };
  struct { const char *n; F2 f; } t2[] = { {"atan2", fic_fd_atan2}, {"pow", fic_fd_pow} };
  int bad_total = 0; char fn[512];
  for (unsigned i = 0; i < sizeof t1 / sizeof *t1; i++) {
    FILE *f; double p[2]; long n = 0, bad = 0; double bx = 0, bg = 0, be = 0;
    if (argc > 2 && strcmp(argv[2], t1[i].n)) continue;
    snprintf(fn, sizeof fn, "%s/%s.bin", argv[1], t1[i].n); f = fopen(fn, "rb"); if (!f) { printf("missing %s\n", fn); return 2; }
    while (fread(p, 8, 2, f) == 2) { double g = t1[i].f(p[0]); n++; if (!same(g, p[1])) { if (!bad) { bx = p[0]; bg = g; be = p[1]; } bad++; } }
    fclose(f); printf("%-6s %ld cases, %ld differ", t1[i].n, n, bad); if (bad) printf(" (first: x=%.17g got %.17g node %.17g)", bx, bg, be); printf("\n"); bad_total += bad != 0;
  }
  for (unsigned i = 0; i < sizeof t2 / sizeof *t2; i++) {
    FILE *f; double p[3]; long n = 0, bad = 0; double bx = 0, by = 0, bg = 0, be = 0;
    if (argc > 2 && strcmp(argv[2], t2[i].n)) continue;
    snprintf(fn, sizeof fn, "%s/%s.bin", argv[1], t2[i].n); f = fopen(fn, "rb"); if (!f) { printf("missing %s\n", fn); return 2; }
    while (fread(p, 8, 3, f) == 3) { double g = t2[i].f(p[0], p[1]); n++; if (!same(g, p[2])) { if (!bad) { bx = p[0]; by = p[1]; bg = g; be = p[2]; } bad++; } }
    fclose(f); printf("%-6s %ld cases, %ld differ", t2[i].n, n, bad); if (bad) printf(" (first: x=%.17g y=%.17g got %.17g node %.17g)", bx, by, bg, be); printf("\n"); bad_total += bad != 0;
  }
  return bad_total != 0;
}

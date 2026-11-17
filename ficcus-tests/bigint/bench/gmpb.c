/* GMP reference for the BigInt benchmarks (same output lines as ref.c).   cc -O2 gmpb.c -lgmp */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <gmp.h>
static void summary(const char *what, char *s) { int n = strlen(s); printf("%s: \"len=%d head=%.20s tail=%s\"\n", what, n, s, s + (n > 20 ? n - 20 : 0)); }
int main(int argc, char **argv) {
    const char *w = argc > 1 ? argv[1] : "fact";
    mpz_t a, b, c, d; mpz_inits(a, b, c, d, NULL);
    if (!strcmp(w, "fact")) { mpz_set_ui(a, 1); for (unsigned i = 2; i <= 10000; i++) mpz_mul_ui(a, a, i); summary("fact10000", mpz_get_str(NULL, 10, a)); }
    else if (!strcmp(w, "fib")) { mpz_set_ui(a, 0); mpz_set_ui(b, 1); for (int i = 0; i < 100000; i++) { mpz_add(c, a, b); mpz_swap(a, b); mpz_swap(b, c); } summary("fib100000", mpz_get_str(NULL, 10, a)); }
    else if (!strcmp(w, "pow3")) { mpz_ui_pow_ui(a, 3, 200000); summary("pow3_200000", mpz_get_str(NULL, 10, a)); }
    else if (!strcmp(w, "build")) { mpz_ui_pow_ui(a, 3, 209589); printf("build: \"%s\"\n", mpz_sgn(a) > 0 ? "positive" : "zero"); }
    else if (!strcmp(w, "tostr")) { mpz_ui_pow_ui(a, 3, 209589); summary("tostr", mpz_get_str(NULL, 10, a)); }
    else if (!strcmp(w, "fromstr")) { char *s = malloc(100001); for (int i = 0; i < 100000; i++) s[i] = "1234567890"[i % 10]; s[100000] = 0; mpz_set_str(a, s, 10); printf("fromstr: \"odd %s\"\n", mpz_odd_p(a) ? "True" : "False"); }
    else if (!strcmp(w, "mulbig")) { mpz_ui_pow_ui(a, 3, 150000); mpz_ui_pow_ui(b, 7, 90000); mpz_set_ui(d, 0);
        for (int i = 0; i < 5; i++) { mpz_add_ui(c, a, i); mpz_mul(c, c, b); mpz_mod_ui(c, c, 1000000007); mpz_add(d, d, c); }
        printf("mulbig: \"%s\"\n", mpz_get_str(NULL, 10, d)); }
    else if (!strcmp(w, "divmod")) { mpz_ui_pow_ui(a, 3, 209589); mpz_ui_pow_ui(b, 7, 59200); mpz_set_ui(d, 0);
        for (int i = 0; i < 10; i++) { mpz_add_ui(c, a, i); mpz_t q, r; mpz_inits(q, r, NULL); mpz_tdiv_qr(q, r, c, b); mpz_add(d, d, q); mpz_add(d, d, r); mpz_clears(q, r, NULL); }
        summary("divmod", mpz_get_str(NULL, 10, d)); }
    return 0;
}

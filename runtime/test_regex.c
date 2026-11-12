/* Standalone test of fic_regex.h (decision L24): every kernel (compile, valid, groups, exec, found, cap, slice, size, advance) with a
   shared and a unique Regex, an invalid pattern and a search without a match; the count of live objects is compared before and after
   each group of calls (a leak or a double free shows under ASan); the two resource limits (steps and stack) are reached with the hook
   of fic_re_exhausted. Built with -DFIC_RC -DFIC_RE_BUDGET=3000000ull -DFIC_RE_MAX_STACK=65536 (see test.sh). The correctness of the matcher
   itself is tested against node's RegExp (ficcus-tests/regex). */
#include <stdio.h>
#include "fic_rt.h"
#include "fic_base.h"
#include "fic_string.h"
#include "fic_num.h"
#include "fic_format.h"
#include "fic_closure.h"
#include "fic_case.h"
#include "fic_ustring.h"
#include "fic_regex.h"

static int bad = 0;
static const char *last_limit = NULL;
static void hook(const char *what) { last_limit = what; }

static fic_ref S(const char *s) { return fic_str_new(s, (int64_t)strlen(s)); }

static void check_live(const char *what, size_t before) {
  if (fic_live_objects != before) { printf("LEAK %s: %zu live objects, %zu before\n", what, fic_live_objects, before); bad = 1; }
}

/* all the matches of re in text with the matchAll rule, printed as start-end@cp and the groups */
static void all(fic_ref re, const char *text, int flags_unused) {
  fic_ref s = S(text);
  int64_t from = 0, fromcp = 0, g, n = fic_re_groups(re);
  (void)flags_unused;
  printf("  /%s/ ", text);
  while (from <= fic_re_size(s)) {
    fic_ref c = fic_re_exec(re, s, from, fromcp), t;
    if (!fic_re_found(c)) { fic_drop(c); break; }
    t = fic_re_slice(s, fic_re_cap(c, 0), fic_re_cap(c, 1));
    printf("[%lld-%lld@%lld '%s'", (long long)fic_re_cap(c, 0), (long long)fic_re_cap(c, 1), (long long)fic_re_cap(c, 2), FIC_STR(t)->data);
    fic_drop(t);
    for (g = 1; g <= n; g++) {
      if (fic_re_cap(c, 2 + 2 * g) < 0) printf(" -");
      else { t = fic_re_slice(s, fic_re_cap(c, 2 + 2 * g), fic_re_cap(c, 3 + 2 * g)); printf(" '%s'", FIC_STR(t)->data); fic_drop(t); }
    }
    printf("]");
    if (fic_re_cap(c, 1) == fic_re_cap(c, 0)) { from = fic_re_advance(s, fic_re_cap(c, 1)); fromcp = fic_re_cap(c, 3) + 1; }
    else { from = fic_re_cap(c, 1); fromcp = fic_re_cap(c, 3); }
    fic_drop(c);
  }
  printf("\n");
  fic_drop(s);
}

static fic_ref comp(const char *pat, int flags) { fic_ref p = S(pat), r = fic_re_compile(flags, p); fic_drop(p); return r; }

int main(void) {
  size_t before = fic_live_objects;
  fic_ref re, bad_re, text, c, t;
  fic_re_exhausted_hook = hook;

  printf("compile and valid\n");
  re = comp("(a)(b)?", 0);
  printf("  valid %d groups %lld\n", fic_re_valid(re), (long long)fic_re_groups(re));
  { const char *invalid[] = { "(", ")", "[", "a{2,1}", "*", "a**", "(?<n>x)(?<n>y)", "(?<n>x)\\k<m>", "(?<1>x)", "(?<n>x)\\k", "\\p{L}", "(?i)a", "x{1}{2}", "^*", "\\", "[z-a]", "(?<=a)*" };
    size_t i;
    for (i = 0; i < sizeof invalid / sizeof *invalid; i++) {
      bad_re = comp(invalid[i], 0);
      printf("  %-9s valid %d\n", invalid[i], fic_re_valid(bad_re));
      c = fic_re_exec(bad_re, text = S("abc"), 0, 0);                  /* an invalid Regex finds nothing */
      if (fic_re_found(c)) { printf("  invalid regex found something\n"); bad = 1; }
      fic_drop(c); fic_drop(text); fic_drop(bad_re);
    } }
  check_live("compile", before + 1);

  printf("exec, found, cap, slice, size, advance\n");
  all(re, "a ab b", 0);
  all(re, "", 0);
  all(re, "xyz", 0);
  { fic_ref u = comp("[a-z]*", 0); all(u, "ab 12 c", 0); all(u, "é😣z", 0); fic_drop(u); }
  { fic_ref u = comp("", 0); all(u, "aé😣", 0); fic_drop(u); }
  { fic_ref u = comp("(?<=(\\d+))x|(?=(a))\\2?", 0); all(u, "12x a", 0); fic_drop(u); }
  { fic_ref u = comp("(?<q>a)(?<r>b)?\\k<q>|\\k<q>x", 0); printf("  named valid %d groups %lld\n", fic_re_valid(u), (long long)fic_re_groups(u)); all(u, "aba aa x", 0); fic_drop(u); }
  { fic_ref u = comp("\\k<n>", 0); all(u, "k<n>", 0); fic_drop(u); }
  { fic_ref u = comp("(a)|\\1b", 1); all(u, "Ab B", 0); fic_drop(u); }
  { fic_ref u = comp("^a|b$", 2); all(u, "a\nb\na\nb", 0); fic_drop(u); }
  { fic_ref u = comp("(?:(a)|b)+?c", 0); all(u, "abc", 0); fic_drop(u); }
  { fic_ref u = comp("(z)((a+)?(b+)?(c))*", 0); all(u, "zaacbbbcac", 0); fic_drop(u); }
  text = S("a😣b");
  printf("  size %lld cps %lld advance %lld %lld %lld %lld %lld\n", (long long)fic_re_size(text), (long long)FIC_STR(text)->cps, (long long)fic_re_advance(text, 0),
         (long long)fic_re_advance(text, 1), (long long)fic_re_advance(text, 5), (long long)fic_re_advance(text, 6), (long long)fic_re_advance(text, 99));
  t = fic_re_slice(text, 1, 5); printf("  slice 1 5 '%s'\n", FIC_STR(t)->data); fic_drop(t);
  t = fic_re_slice(text, 5, -1); printf("  slice 5 end '%s'\n", FIC_STR(t)->data); fic_drop(t);
  t = fic_re_slice(text, 7, 2); printf("  slice 7 2 '%s' (%lld)\n", FIC_STR(t)->data, (long long)FIC_STR(t)->len); fic_drop(t);
  c = fic_re_exec(re, text, 99, 0); printf("  from beyond the end: found %d\n", fic_re_found(c)); fic_drop(c);
  c = fic_re_exec(re, text, -1, 0); printf("  from negative: found %d\n", fic_re_found(c)); fic_drop(c);
  fic_drop(text);
  check_live("matching", before + 1);

  printf("equality\n");
  { fic_ref x = comp("a+", 0), y = comp("a+", 0), z = comp("a+", 1), w = comp("(", 0), v = comp("[", 0);
    printf("  same %d different flags %d different pattern %d two invalid %d\n", fic_re_eq(x, y), fic_re_eq(x, z), fic_re_eq(x, re), fic_re_eq(w, v));
    fic_drop(x); fic_drop(y); fic_drop(z); fic_drop(w); fic_drop(v); }

  printf("resource limits\n");
  { fic_ref u = comp("(a*)*b", 0), s = S("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac");
    last_limit = NULL; c = fic_re_exec(u, s, 0, 0); printf("  catastrophic: %s, found %d\n", last_limit ? last_limit : "no limit", fic_re_found(c)); fic_drop(c);
    fic_drop(u); fic_drop(s); }
  { fic_ref u = comp("(?:a|b)*c", 0), s;
    char *big = (char *)malloc(200001);
    size_t i;
    for (i = 0; i < 200000; i++) big[i] = (i & 1) ? 'b' : 'a';
    big[200000] = 0;
    s = S(big);
    last_limit = NULL; c = fic_re_exec(u, s, 0, 0); printf("  deep stack: %s, found %d\n", last_limit ? last_limit : "no limit", fic_re_found(c)); fic_drop(c);
    fic_drop(u); fic_drop(s); free(big); }
  { fic_ref u = comp("[ab]*c", 0), s;                 /* one backtrack record for the whole run: no limit, however long the text */
    char *big = (char *)malloc(1000001);
    size_t i;
    for (i = 0; i < 1000000; i++) big[i] = (i & 1) ? 'b' : 'a';
    big[999999] = 'c'; big[1000000] = 0;
    s = S(big);
    last_limit = NULL; c = fic_re_exec(u, s, 0, 0); printf("  long run: %s, found %d\n", last_limit ? last_limit : "no limit", fic_re_found(c)); fic_drop(c);
    fic_drop(u); fic_drop(s); free(big); }
  check_live("limits", before + 1);

  fic_drop(re);
  check_live("end", before);
  printf("live objects at the end: %zu\n", fic_live_objects - before);
  return bad;
}

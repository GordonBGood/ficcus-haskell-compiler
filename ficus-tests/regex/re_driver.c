/* Engine-level driver for the differential test (ficus-tests/regex/run_diff.py): reads cases from stdin, one per line,
   "flags<TAB>pattern<TAB>subject" (\n, \t and \\ escaped), prints the matches of the matchAll iteration (the rule of L24):
   "N" for an invalid pattern, else the list of "start,end,startcp|g1s,g1e|..." joined by ";". Build: see run_diff.py. */
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

static size_t unesc(char *s) {
  char *o = s, *p = s;
  while (*p) {
    if (*p == '\\' && p[1]) { p++; *o++ = *p == 'n' ? '\n' : *p == 't' ? '\t' : *p; p++; } else *o++ = *p++;
  }
  *o = 0;
  return (size_t)(o - s);
}

int main(void) {
  static char line[1 << 20];
  while (fgets(line, sizeof line, stdin)) {
    char *t1, *t2, *nl;
    fic_ref re, pat, sub;
    int64_t from = 0, fromcp = 0, len;
    int first = 1;
    nl = strchr(line, '\n'); if (nl) *nl = 0;
    t1 = strchr(line, '\t'); if (!t1) continue; *t1++ = 0;
    t2 = strchr(t1, '\t'); if (!t2) continue; *t2++ = 0;
    { size_t lp = unesc(t1), ls = unesc(t2);
      pat = fic_str_new(t1, (int64_t)lp); sub = fic_str_new(t2, (int64_t)ls); }
    re = fic_re_compile(atoi(line), pat);
    if (!fic_re_valid(re)) { printf("N\n"); fic_drop(re); fic_drop(pat); fic_drop(sub); continue; }
    len = FIC_STR(sub)->len;
    while (from <= len) {
      fic_ref c = fic_re_exec(re, sub, from, fromcp);
      int64_t g, n = fic_re_groups(re);
      if (!fic_re_found(c)) { fic_drop(c); break; }
      printf("%s%lld,%lld,%lld", first ? "" : ";", (long long)fic_re_cap(c, 0), (long long)fic_re_cap(c, 1), (long long)fic_re_cap(c, 2));
      for (g = 1; g <= n; g++) printf("|%lld,%lld", (long long)fic_re_cap(c, 2 + 2 * g), (long long)fic_re_cap(c, 3 + 2 * g));
      first = 0;
      if (fic_re_cap(c, 1) == fic_re_cap(c, 0)) { from = fic_re_advance(sub, fic_re_cap(c, 1)); fromcp = fic_re_cap(c, 3) + 1; }
      else { from = fic_re_cap(c, 1); fromcp = fic_re_cap(c, 3); }
      fic_drop(c);
    }
    printf("\n");
    fic_drop(re); fic_drop(pat); fic_drop(sub);
  }
  return 0;
}

/* Standalone test of fic_ustring.h against node (test_ustring.expected is made by gen_ustring_test.js). */
#include <stdio.h>
#include "fic_rt.h"
#include "fic_base.h"
#include "fic_string.h"
#include "fic_num.h"
#include "fic_format.h"
#include "fic_closure.h"
#include "fic_case.h"
#include "fic_ustring.h"
#include "test_ustring_cases.h"

static void hexs(fic_ref s) {
  int64_t i;
  for (i = 0; i < FIC_STR(s)->len; i++) printf("%02x", (unsigned char)FIC_STR(s)->data[i]);
}

int main(void) {
  int i, k;
  static const int64_t sl[][2] = { {0, 1}, {1, 3}, {-2, 100}, {2, -1}, {3, 2}, {-100, 2}, {0, 0} };
  for (i = 0; i < FIC_UT_N; i++) {
    fic_ref s = fic_str_new(fic_ut_cases[i], (int64_t)strlen(fic_ut_cases[i])), w;
    printf("%d len %lld up ", i, (long long)fic_us_length(s)); hexs(fic_us_upper(s));
    printf(" lo "); hexs(fic_us_lower(s));
    printf(" words ");
    for (w = fic_us_words(s); w->tag != 0u; w = ((fic_us_cell *)w)->f1) { hexs(((fic_us_cell *)w)->f0); if (((fic_us_cell *)w)->f1->tag != 0u) printf(","); }
    printf("\n");
    for (k = 0; k < 7; k++) { printf("%d slice %lld %lld ", i, (long long)sl[k][0], (long long)sl[k][1]); hexs(fic_us_slice(sl[k][0], sl[k][1], s)); printf("\n"); }
    printf("%d rev ", i); hexs(fic_us_reverse(s)); printf(" trim "); hexs(fic_us_trim(s)); printf(" tl "); hexs(fic_us_trim_left(s)); printf(" tr "); hexs(fic_us_trim_right(s));
    printf(" lines ");
    for (w = fic_us_lines(s); w->tag != 0u; w = ((fic_us_cell *)w)->f1) { hexs(((fic_us_cell *)w)->f0); if (((fic_us_cell *)w)->f1->tag != 0u) printf(","); }
    printf("\n");
    for (k = 0; k < FIC_UT_P; k++) {
      fic_ref p = fic_str_new(fic_ut_pats[k], (int64_t)strlen(fic_ut_pats[k]));
      printf("%d pat %d has %d sw %d ew %d idx ", i, k, fic_us_contains(p, s), fic_us_starts_with(p, s), fic_us_ends_with(p, s));
      for (w = fic_us_indexes(p, s); w->tag != 0u; w = ((fic_us_icell *)w)->f1) { printf("%lld", (long long)((fic_us_icell *)w)->f0); if (((fic_us_icell *)w)->f1->tag != 0u) printf(","); }
      printf(" split ");
      for (w = fic_us_split(p, s); w->tag != 0u; w = ((fic_us_cell *)w)->f1) { hexs(((fic_us_cell *)w)->f0); if (((fic_us_cell *)w)->f1->tag != 0u) printf(","); }
      printf("\n");
    }
  }
  for (i = 0; i < FIC_UT_M; i++) {
    fic_ref s = fic_str_new(fic_ut_nums[i], (int64_t)strlen(fic_ut_nums[i]));
    int64_t iv; double dv;
    printf("num %d int ", i);
    if (fic_us_to_int(s, &iv)) printf("%lld", (long long)iv); else printf("N");
    printf(" float ");
    if (fic_us_to_float(s, &dv)) { if (dv == 0 && signbit(dv)) printf("-0"); else { fic_ref f = fic_str_from_float(dv); fwrite(FIC_STR(f)->data, 1, (size_t)FIC_STR(f)->len, stdout); } } else printf("N");
    printf("\n");
  }
  return 0;
}

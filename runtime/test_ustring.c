/* Standalone test of fic_ustring.h against node (test_ustring.expected is made by gen_ustring_test.js). */
#include <stdio.h>
#include "fic_base.h"
#include "fic_string.h"
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
  }
  return 0;
}

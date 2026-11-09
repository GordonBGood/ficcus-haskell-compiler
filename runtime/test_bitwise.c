/* Bitwise and Bitwise64 against node (test_bitwise.expected comes from gen_bitwise_test.js) */
#include <stdio.h>
#include <stdint.h>
#include "fic_base.h"
#include "fic_num.h"

static const int64_t A32[] = { 0, 1, -1, 5, -5, 255, 2147483647LL, 2147483648LL, -2147483648LL, -2147483649LL, 4294967295LL,
  4294967296LL, 4294967297LL, 8589934591LL, 1099511627779LL, -1099511627779LL, 123456789LL, -123456789LL };
static const int64_t A64[] = { 0, 1, -1, 5, -5, 255, 2147483647LL, 2147483648LL, -2147483648LL, 4294967295LL, 4294967296LL,
  81985529216486895LL, -81985529216486895LL, 9223372036854775807LL, (-9223372036854775807LL - 1), 6148914691236517205LL };
static const int64_t N[] = { 0, 1, 2, 31, 32, 33, 63, 64, 65, -1, -32 };
#define LEN(x) (int)(sizeof(x) / sizeof((x)[0]))

int main(void) {
  int i, j;
  for (i = 0; i < LEN(A32); i++) {
    int64_t a = A32[i];
    printf("32 not %lld = %lld\n", (long long)a, (long long)fic_bw_not(a));
    for (j = 0; j < LEN(A32); j++) {
      int64_t b = A32[j];
      printf("32 and %lld %lld = %lld\n", (long long)a, (long long)b, (long long)fic_bw_and(a, b));
      printf("32 or %lld %lld = %lld\n", (long long)a, (long long)b, (long long)fic_bw_or(a, b));
      printf("32 xor %lld %lld = %lld\n", (long long)a, (long long)b, (long long)fic_bw_xor(a, b));
    }
    for (j = 0; j < LEN(N); j++) {
      printf("32 shl %lld %lld = %lld\n", (long long)N[j], (long long)a, (long long)fic_bw_shl(N[j], a));
      printf("32 shr %lld %lld = %lld\n", (long long)N[j], (long long)a, (long long)fic_bw_shr(N[j], a));
      printf("32 shrz %lld %lld = %lld\n", (long long)N[j], (long long)a, (long long)fic_bw_shrz(N[j], a));
    }
  }
  for (i = 0; i < LEN(A64); i++) {
    int64_t a = A64[i];
    printf("64 not %lld = %lld\n", (long long)a, (long long)fic_bw64_not(a));
    for (j = 0; j < LEN(A64); j++) {
      int64_t b = A64[j];
      printf("64 and %lld %lld = %lld\n", (long long)a, (long long)b, (long long)fic_bw64_and(a, b));
      printf("64 or %lld %lld = %lld\n", (long long)a, (long long)b, (long long)fic_bw64_or(a, b));
      printf("64 xor %lld %lld = %lld\n", (long long)a, (long long)b, (long long)fic_bw64_xor(a, b));
    }
    for (j = 0; j < LEN(N); j++) {
      printf("64 shl %lld %lld = %lld\n", (long long)N[j], (long long)a, (long long)fic_bw64_shl(N[j], a));
      printf("64 shr %lld %lld = %lld\n", (long long)N[j], (long long)a, (long long)fic_bw64_shr(N[j], a));
      printf("64 shrz %lld %lld = %lld\n", (long long)N[j], (long long)a, (long long)fic_bw64_shrz(N[j], a));
    }
  }
  return 0;
}

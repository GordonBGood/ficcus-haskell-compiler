#include <stdio.h>
#include <math.h>
#include <stdint.h>

#define FIC_UNREACHABLE() abort()         /* a case of Elm is exhaustive */
typedef struct fic_string { fic_hdr h; int64_t len; int64_t cps; char data[]; } fic_string;   /* byte length, code point length (cached) */
#define FIC_STR(r) ((fic_string *)(r))

#define FIC_SUB64(a, b) ((int64_t)((uint64_t)(a) - (uint64_t)(b)))
#define FIC_NEG64(a) ((int64_t)(0u - (uint64_t)(a)))


/* the number of code points of n bytes of UTF-8: the bytes that are not continuation bytes */
static int64_t fic_str_cps_of(const char *p, int64_t n) {
  int64_t i, c = 0;
  for (i = 0; i < n; i++) if (((unsigned char)p[i] & 0xC0u) != 0x80u) c++;
  return c;
}

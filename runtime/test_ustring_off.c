/* Standalone test of the offset functions of fic_ustring.h (FIX2 step 3): fic_us_slice and fic_us_indexes against a plain scan from the
   start (the model below, which is the code of before the position cache), on random UTF-8 strings (ASCII, two, three and four byte
   characters), with the indices in random order (so every seek direction of the cache is used: from the start, from the cache forwards
   and backwards, from the end), in and out of range, negative, for ASCII and for non ASCII strings. As a counted program (-DFIC_RC
   -DFIC_STATS) the cache holds a count and no object is live at the end (this test is built only that way: every object is dropped). */
#include <stdio.h>
#include "fic_rt.h"
#include "fic_base.h"
#include "fic_string.h"
#include "fic_num.h"
#include "fic_format.h"
#include "fic_closure.h"
#include "fic_case.h"
#include "fic_ustring.h"


static uint64_t rng = 88172645463325252ull;
static uint64_t next(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

/* the model: slice by a scan from the start */
static fic_ref model_slice(int64_t from, int64_t to, fic_ref s) {
  int64_t n = FIC_STR(s)->cps, i = 0, bf = 0, bt = 0, len = FIC_STR(s)->len;
  const unsigned char *d = (const unsigned char *)FIC_STR(s)->data;
  if (from < 0) { from += n; if (from < 0) from = 0; } else if (from > n) from = n;
  if (to < 0) { to += n; if (to < 0) to = 0; } else if (to > n) to = n;
  if (from >= to) return fic_str_new("", 0);
  { int64_t b = 0;
    while (b < len && i < to) { if (i == from) bf = b; b++; while (b < len && (d[b] & 0xC0u) == 0x80u) b++; i++; }
    bt = b;
    if (from == 0) bf = 0;
  }
  return fic_str_new(FIC_STR(s)->data + bf, bt - bf);
}

static fic_ref random_string(int64_t n, int kind) {      /* kind 0: ASCII, 1: mixed, 2: only multi byte */
  char *buf = (char *)malloc((size_t)n * 4 + 1), *o = buf;
  int64_t i;
  fic_ref r;
  for (i = 0; i < n; i++) {
    uint32_t c;
    int k = kind == 0 ? 0 : kind == 2 ? 1 + (int)(next() % 3) : (int)(next() % 4);
    if (k == 0) c = 0x61u + (uint32_t)(next() % 3);                                            /* a b c: matches are frequent */
    else if (k == 1) c = 0xE0u + (uint32_t)(next() % 0x20u);                                  /* two bytes */
    else if (k == 2) c = 0x4E00u + (uint32_t)(next() % 0x40u);                                /* three bytes */
    else c = 0x1F600u + (uint32_t)(next() % 0x20u);                                           /* four bytes */
    o += fic_us_put(o, c);
  }
  r = fic_str_new(buf, (int64_t)(o - buf));
  free(buf);
  return r;
}

static int same(fic_ref a, fic_ref b) { return FIC_STR(a)->len == FIC_STR(b)->len && FIC_STR(a)->cps == FIC_STR(b)->cps && memcmp(FIC_STR(a)->data, FIC_STR(b)->data, (size_t)FIC_STR(a)->len) == 0; }

static fic_ref model_indexes(fic_ref sub, fic_ref s) {      /* the plain version: a code point index per match by a scan from the start */
  int64_t sl = FIC_STR(sub)->len, hl = FIC_STR(s)->len, i = 0, n = 0, k;
  int64_t *at = (int64_t *)malloc((size_t)(hl + 1) * sizeof(int64_t));
  fic_ref list = fic_nil();
  const char *p;
  if (sl < 1) { free(at); return list; }
  while ((p = fic_us_memmem(FIC_STR(s)->data, hl, FIC_STR(sub)->data, sl, i)) != NULL) { at[n++] = (int64_t)(p - FIC_STR(s)->data); i = at[n - 1] + sl; }
  for (k = n - 1; k >= 0; k--) {
    fic_us_icell *c = (fic_us_icell *)fic_alloc(sizeof(fic_us_icell), 1u, 1);
    c->f0 = fic_us_cp_index(FIC_STR(s)->data, at[k]); c->f1 = list; list = &c->h;
  }
  free(at);
  return list;
}
static int same_list(fic_ref a, fic_ref b) {
  while (a->tag != 0u && b->tag != 0u) { if (((fic_us_icell *)a)->f0 != ((fic_us_icell *)b)->f0) return 0; a = ((fic_us_icell *)a)->f1; b = ((fic_us_icell *)b)->f1; }
  return a->tag == 0u && b->tag == 0u;
}

int main(void) {
  int kind, round, bad = 0;
  for (kind = 0; kind < 3; kind++) {
    int64_t sizes[] = { 0, 1, 2, 3, 7, 40, 300 };
    int si;
    for (si = 0; si < 7; si++) {
      fic_ref s = random_string(sizes[si], kind);
      int64_t n = FIC_STR(s)->cps;
      for (round = 0; round < 400; round++) {
        int64_t from = (int64_t)(next() % (uint64_t)(2 * n + 5)) - n - 2, to;
        fic_ref a, b;
        to = (int64_t)(next() % (uint64_t)(2 * n + 5)) - n - 2;
        if (round % 4 == 0) { from = (int64_t)(next() % (uint64_t)(n + 1)); to = from + (int64_t)(next() % 4); }       /* short slices: the left to right walk */
        a = fic_us_slice(from, to, s); b = model_slice(from, to, s);
        if (!same(a, b)) { bad++; printf("FAIL slice kind %d size %lld from %lld to %lld\n", kind, (long long)sizes[si], (long long)from, (long long)to); }
        fic_drop(a); fic_drop(b);
      }
      /* a left to right walk with a cache, then a jump back and a jump to the end */
      { int64_t i; for (i = 0; i + 1 <= n; i += 1) { fic_ref a = fic_us_slice(i, i + 1, s), b = model_slice(i, i + 1, s); if (!same(a, b)) { bad++; printf("FAIL walk %lld\n", (long long)i); } fic_drop(a); fic_drop(b); } }
      { int64_t i; for (i = n; i > 0; i--) { fic_ref a = fic_us_slice(i - 1, i, s), b = model_slice(i - 1, i, s); if (!same(a, b)) { bad++; printf("FAIL back walk %lld\n", (long long)i); } fic_drop(a); fic_drop(b); } }
      /* the offsets themselves: the byte offset of each index is a character boundary and increases */
      { int64_t i, last = -1; for (i = 0; i <= n; i++) { int64_t b = fic_us_off(s, i); if (b <= last && i > 0) { bad++; printf("FAIL off order\n"); } last = b; } }
      { int pi; for (pi = 0; pi < 6; pi++) {
          int64_t sublen = (int64_t)(next() % 3) + (pi == 0 ? 0 : 1);       /* (the order of evaluation of arguments is not defined: one call each) */
          int subkind = kind == 0 ? 0 : (int)(next() % 3);
          fic_ref sub = random_string(sublen, subkind);
          fic_ref x = fic_us_indexes(sub, s), y = model_indexes(sub, s);
          if (!same_list(x, y)) { bad++; printf("FAIL indexes kind %d size %lld\n", kind, (long long)sizes[si]); }
          fic_drop(x); fic_drop(y); fic_drop(sub);
        } }
      fic_drop(s);
    }
  }
  fic_us_release();
  printf("%s\n", bad == 0 ? "ok   ustring offsets against the plain scan" : "FAIL ustring offsets");
  printf("%s\n", fic_us_cs == NULL ? "ok   cache released" : "FAIL cache not released");
  printf("%d bad\n", bad);
  return bad != 0 || fic_shutdown() != 0;
}

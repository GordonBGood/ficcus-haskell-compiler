/* The kernel functions of elm/parser (Parser.Advanced.isSubString, isSubChar, isAsciiCode, chompBase10, consumeBase,
   consumeBase16, findSubString) on UTF-8 strings. Decision L22: the offsets, the row and the column that the Elm code sees
   count code points (as String.slice and String.length do); the kernel converts to byte offsets inside. The cache of fic_us_off
   makes the usual left to right parse linear, and an ASCII source needs no conversion at all. Elm's JavaScript counts UTF-16 units,
   so the two agree for text of the basic multilingual plane only. Needs fic_ustring.h and the closure runtime. */

/* the cache of the byte offsets is the one of fic_ustring.h (fic_us_off, shared with String.slice); fic_pk_release stays as the name the
   generated main calls */
static void fic_pk_release(void) { fic_us_release(); }

/* the byte offset of the code point `cp` of s (the length of s when cp is the number of code points), or -1 beyond the end */
static int64_t fic_pk_off(fic_ref s, int64_t cp) {
  if (cp < 0 || cp > FIC_STR(s)->cps) return -1;
  return fic_us_off(s, cp);
}

static int64_t fic_pk_len_of(fic_ref s) { return fic_us_length(s); }

/* the code point at byte offset b */
static uint32_t fic_pk_at(fic_ref s, int64_t b) {
  const unsigned char *p = (const unsigned char *)FIC_STR(s)->data + b;
  return fic_us_get(&p);
}

/* isSubString small offset row col big: the offset after small when it is at `offset` of big, else -1; row and column advance as
   far as the text matched (a line feed starts a new row at column 1) */
static int64_t fic_pk_is_sub(fic_ref small, int64_t offset, int64_t *row, int64_t *col, fic_ref big) {
  int64_t sn = fic_us_length(small), bn, b, i, sb = 0;     /* (the cache is for the big string only) */
  bn = fic_pk_len_of(big);
  if (offset < 0 || offset + sn > bn) { return -1; }
  b = fic_pk_off(big, offset);
  for (i = 0; i < sn; i++) {
    uint32_t cs = fic_pk_at(small, sb), cb = fic_pk_at(big, b);
    const unsigned char *p;
    if (cs != cb) return -1;
    if (cs == 10u) { (*row)++; *col = 1; } else (*col)++;
    p = (const unsigned char *)FIC_STR(small)->data + sb; fic_us_get(&p); sb = (int64_t)(p - (const unsigned char *)FIC_STR(small)->data);
    p = (const unsigned char *)FIC_STR(big)->data + b; fic_us_get(&p); b = (int64_t)(p - (const unsigned char *)FIC_STR(big)->data);
  }
  return offset + sn;
}

/* isSubChar predicate offset string: offset + 1 when the predicate holds for the code point there, -2 for a line feed, -1 otherwise */
static int64_t fic_pk_is_sub_char(fic_ref pred, int64_t offset, fic_ref s) {
  int64_t n = fic_pk_len_of(s), b;
  uint32_t c;
  if (n <= offset || offset < 0) return -1;
  b = fic_pk_off(s, offset);
  c = fic_pk_at(s, b);
  if (!fic_ap1(pred, 0u, fic_w_c(c)).b) return -1;
  return c == 10u ? -2 : offset + 1;
}

static uint8_t fic_pk_is_ascii(int64_t code, int64_t offset, fic_ref s) {
  int64_t n = fic_pk_len_of(s), b;
  if (offset < 0 || n <= offset) return 0;
  b = fic_pk_off(s, offset);
  return (int64_t)fic_pk_at(s, b) == code;
}

static int64_t fic_pk_chomp10(int64_t offset, fic_ref s) {
  int64_t n = fic_pk_len_of(s), b;
  if (offset < 0 || offset >= n) return offset;
  b = fic_pk_off(s, offset);
  while (offset < n) {
    unsigned char c = (unsigned char)FIC_STR(s)->data[b];
    if (c < '0' || c > '9') return offset;
    b++; offset++;                               /* digits are single bytes */
  }
  return offset;
}

/* consumeBase base offset string: the offset after the digits (below the base) and their value */
static int64_t fic_pk_consume(int64_t base, int64_t offset, fic_ref s, int64_t *total) {
  int64_t n = fic_pk_len_of(s), b, t = 0;
  if (offset >= 0 && offset < n) {
    b = fic_pk_off(s, offset);
    while (offset < n) {
      int64_t digit = (int64_t)(unsigned char)FIC_STR(s)->data[b] - 0x30;
      if (digit < 0 || base <= digit) break;
      t = FIC_ADD64(FIC_MUL64(base, t), digit);
      b++; offset++;
    }
  }
  *total = t;
  return offset;
}

static int64_t fic_pk_consume16(int64_t offset, fic_ref s, int64_t *total) {
  int64_t n = fic_pk_len_of(s), b, t = 0;
  if (offset >= 0 && offset < n) {
    b = fic_pk_off(s, offset);
    while (offset < n) {
      unsigned char c = (unsigned char)FIC_STR(s)->data[b];
      int64_t d;
      if (c >= '0' && c <= '9') d = c - 0x30;
      else if (c >= 'A' && c <= 'F') d = c - 55;
      else if (c >= 'a' && c <= 'f') d = c - 87;
      else break;
      t = FIC_ADD64(FIC_MUL64(16, t), d);
      b++; offset++;
    }
  }
  *total = t;
  return offset;
}

/* findSubString small offset row col big: the offset of the first match at or after offset (-1 when there is none); the row and column
   are those of the END of the match (the end of big when there is none): Elm's actual behaviour, kept (decision L33) */
static int64_t fic_pk_find(fic_ref small, int64_t offset, int64_t *row, int64_t *col, fic_ref big) {
  int64_t sn = fic_us_length(small), bn = fic_pk_len_of(big), start, found = -1, target, i;
  int64_t sb;
  const char *p;
  if (offset < 0) offset = 0;
  if (offset > bn) offset = bn;
  start = fic_pk_off(big, offset);
  p = fic_us_memmem(FIC_STR(big)->data, FIC_STR(big)->len, FIC_STR(small)->data, FIC_STR(small)->len, start);
  if (p != NULL) found = offset + fic_us_cp_index(FIC_STR(big)->data + start, (int64_t)(p - FIC_STR(big)->data) - start);
  target = found < 0 ? bn : found + sn;
  sb = start;
  for (i = offset; i < target; i++) {
    uint32_t c = fic_pk_at(big, sb);
    const unsigned char *q = (const unsigned char *)FIC_STR(big)->data + sb;
    fic_us_get(&q); sb = (int64_t)(q - (const unsigned char *)FIC_STR(big)->data);
    if (c == 10u) { *col = 1; (*row)++; } else (*col)++;
  }
  return found;
}

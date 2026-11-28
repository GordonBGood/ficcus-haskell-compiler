/* P1, hand written C: the recursive descent parser of targets/p1/src/JsonHand.elm over a byte buffer, same generator, same tree
 * (malloc, freed at the end like the other versions), same checksum.
 * Build: cc -std=c99 -O2 -ffp-contract=off json_hand.c -o json_hand -lm ; run: json_hand RECORDS STAGE
 * (STAGE 0: generate, 1: also take the bytes (nothing to do: the text is the buffer), 2: also parse and print the checksum). */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- the generator (specification: ficus-tools/gen_json.py) ---- */
typedef struct { char *p; size_t n, cap; } buf;
static void put(buf *b, const char *s, size_t k) {
  if (b->n + k + 1 > b->cap) { b->cap = (b->n + k + 1) * 2; b->p = realloc(b->p, b->cap); if (!b->p) abort(); }
  memcpy(b->p + b->n, s, k); b->n += k; b->p[b->n] = 0;
}
static void puts_(buf *b, const char *s) { put(b, s, strlen(s)); }
static int64_t seed = 12345;
static int64_t draw(void) { seed = seed * 48271 % 2147483647; return seed; }
static const char ALPHA[] = "abcdefghijklmnopqrstuvwxyz0123456789 _";
static const char *ESC[8] = { "\\\"", "\\\\", "\\/", "\\n", "\\t", "\\b", "\\u00e9", "\\u0041" };

static void gen_string(buf *b, int64_t lo, int64_t span) {
  int64_t n = lo + draw() % span, i;
  put(b, "\"", 1);
  for (i = 0; i < n; i++) {
    int64_t r = draw(), p = (r / 20) % 38;
    if (r % 20 < 14) put(b, &ALPHA[p], 1); else puts_(b, ESC[p % 8]);
  }
  put(b, "\"", 1);
}

static void gen_value(buf *b, int d) {
  int64_t r = draw(), k = r % 20, n, i;
  char t[64];
  if (d >= 12 && k < 10) k += 10;
  if (k < 5) {
    n = draw() % 5; put(b, "[", 1);
    for (i = 0; i < n; i++) { if (i) puts_(b, ", "); gen_value(b, d + 1); }
    put(b, "]", 1);
  } else if (k < 10) {
    n = draw() % 5; put(b, "{", 1);
    for (i = 0; i < n; i++) { if (i) puts_(b, ", "); gen_string(b, 1, 8); puts_(b, ": "); gen_value(b, d + 1); }
    put(b, "}", 1);
  } else if (k == 10) puts_(b, "null");
  else if (k == 11) puts_(b, "true");
  else if (k == 12) puts_(b, "false");
  else if (k < 16) {
    if (draw() % 4 == 0) put(b, "-", 1);
    snprintf(t, sizeof t, "%lld", (long long)(draw() % 1000000)); puts_(b, t);
  } else if (k < 18) {
    int64_t ip, fr;
    if (draw() % 4 == 0) put(b, "-", 1);
    ip = draw() % 10000; fr = (draw() % 64) * 15625;
    snprintf(t, sizeof t, "%lld.%06lld", (long long)ip, (long long)fr); puts_(b, t);
    if (draw() % 8 == 0) { static const char *sfx[3] = { "e1", "E+2", "e0" }; puts_(b, sfx[draw() % 3]); }
  } else gen_string(b, 0, 12);
}

/* ---- the tree ---- */
enum { JNULL, JBOOL, JNUM, JSTR, JARR, JOBJ };
typedef struct node {
  int tag; double num; char *str; int64_t cps;        /* JNUM; JSTR: decoded bytes, length in code points */
  int64_t n; struct node *items; char **keys; int64_t *kcps;   /* JARR, JOBJ: items (and keys) */
} node;

static void free_node(node *v) {
  int64_t i;
  if (v->tag == JSTR) free(v->str);
  if (v->tag == JARR || v->tag == JOBJ) {
    for (i = 0; i < v->n; i++) { free_node(&v->items[i]); if (v->tag == JOBJ) free(v->keys[i]); }
    free(v->items); free(v->keys); free(v->kcps);
  }
}

/* ---- the parser: recursive descent over bytes; a syntax error sets *bad ---- */
static const unsigned char *S; static int64_t LEN;
static int at(int64_t i) { return i < LEN ? S[i] : -1; }
static int64_t skip(int64_t i) { int b; while ((b = at(i)) == 32 || b == 10 || b == 13 || b == 9) i++; return i; }
static int hexv(int c) { return c >= 97 ? c - 87 : c >= 65 ? c - 55 : c - 48; }

static char *unescape(int64_t from, int64_t to, int64_t *cps) {
  char *o = malloc((size_t)(to - from) * 2 + 1), *q = o; int64_t i = from, n = 0;
  while (i < to) {
    int c = S[i];
    if (c != '\\') { *q++ = (char)c; i++; n++; continue; }
    c = S[i + 1]; i += 2; n++;
    switch (c) {
      case 'n': *q++ = '\n'; break; case 't': *q++ = '\t'; break; case 'b': *q++ = 8; break;
      case 'f': *q++ = 12; break; case 'r': *q++ = 13; break;
      case 'u': { unsigned v = (unsigned)(hexv(S[i]) * 4096 + hexv(S[i + 1]) * 256 + hexv(S[i + 2]) * 16 + hexv(S[i + 3])); i += 4;
        if (v < 0x80) *q++ = (char)v; else if (v < 0x800) { *q++ = (char)(0xC0 | (v >> 6)); *q++ = (char)(0x80 | (v & 63)); }
        else { *q++ = (char)(0xE0 | (v >> 12)); *q++ = (char)(0x80 | ((v >> 6) & 63)); *q++ = (char)(0x80 | (v & 63)); } break; }
      default: *q++ = (char)c;
    }
  }
  *q = 0; *cps = n; return o;
}

static int64_t parse_string(int64_t i, char **s, int64_t *cps) {   /* i after the opening quote */
  int64_t e = i;
  for (;;) { int b = at(e); if (b == 34) break; if (b < 0) return -1; e += b == 92 ? 2 : 1; }
  *s = unescape(i, e, cps);
  return skip(e + 1);
}

static int64_t digits_end(int64_t i) { while (at(i) >= 48 && at(i) <= 57) i++; return i; }
static int64_t digits_value(int64_t i, int64_t e) { int64_t v = 0; for (; i < e; i++) v = v * 10 + (S[i] - 48); return v; }
static double pow10i(int64_t n) { double x = 1; while (n-- > 0) x *= 10; return x; }

static int64_t parse_number(int64_t i, double *out) {
  int neg = at(i) == 45; int64_t i1 = neg ? i + 1 : i, i2 = digits_end(i1), i3, i4, ip; double fr = 0, ex = 1, x; int b;
  if (i2 == i1) return -1;
  ip = digits_value(i1, i2);
  i3 = i2;
  if (at(i2) == 46) { int64_t j = digits_end(i2 + 1); fr = (double)digits_value(i2 + 1, j) / pow10i(j - i2 - 1); i3 = j; }
  i4 = i3; b = at(i3);
  if (b == 101 || b == 69) {
    int s = at(i3 + 1); int64_t j1 = (s == 43 || s == 45) ? i3 + 2 : i3 + 1, j2 = digits_end(j1), e = digits_value(j1, j2);
    ex = s == 45 ? 1 / pow10i(e) : pow10i(e); i4 = j2;
  }
  x = ((double)ip + fr) * ex; *out = neg ? -x : x; return i4;
}

static int64_t parse_value(int64_t i, node *v);

static int64_t parse_list(int64_t i, node *v, int obj) {   /* i after the opening bracket and spaces */
  int64_t cap = 0; int close = obj ? 125 : 93;
  v->tag = obj ? JOBJ : JARR; v->n = 0; v->items = NULL; v->keys = NULL; v->kcps = NULL;
  if (at(i) == close) return skip(i + 1);
  for (;;) {
    int b; int64_t j;
    if (v->n == cap) {
      cap = cap ? cap * 2 : 4; v->items = realloc(v->items, (size_t)cap * sizeof(node));
      if (obj) { v->keys = realloc(v->keys, (size_t)cap * sizeof(char *)); v->kcps = realloc(v->kcps, (size_t)cap * sizeof(int64_t)); }
    }
    if (obj) {
      if (at(i) != 34) return -1;
      j = parse_string(i + 1, &v->keys[v->n], &v->kcps[v->n]);
      if (j < 0 || at(j) != 58) return -1;
      i = skip(j + 1);
    }
    j = parse_value(i, &v->items[v->n]);
    if (j < 0) return -1;
    v->n++;
    b = at(j);
    if (b == 44) i = skip(j + 1); else if (b == close) return skip(j + 1); else return -1;
  }
}

static int64_t parse_value(int64_t i, node *v) {
  int b = at(i); int64_t j; memset(v, 0, sizeof *v);
  if (b == 91) return parse_list(skip(i + 1), v, 0);
  if (b == 123) return parse_list(skip(i + 1), v, 1);
  if (b == 34) { v->tag = JSTR; j = parse_string(i + 1, &v->str, &v->cps); return j; }
  if (b == 116) { v->tag = JBOOL; return skip(i + 4); }
  if (b == 102) { v->tag = JBOOL; return skip(i + 5); }
  if (b == 110) { v->tag = JNULL; return skip(i + 4); }
  v->tag = JNUM; j = parse_number(i, &v->num);
  return j < 0 ? -1 : skip(j);
}

/* ---- the checksum ---- */
static int64_t nodes, strlen_, depth; static double sum;
static void fold(int d, const node *v) {
  int64_t i;
  nodes++; if (d > depth) depth = d;
  switch (v->tag) {
    case JNUM: sum += v->num; break;
    case JSTR: strlen_ += v->cps; break;
    case JARR: for (i = 0; i < v->n; i++) fold(d + 1, &v->items[i]); break;
    case JOBJ: for (i = 0; i < v->n; i++) { strlen_ += v->kcps[i]; fold(d + 1, &v->items[i]); } break;
    default: break;
  }
}

int main(int argc, char **argv) {
  long long records = argc > 1 ? atoll(argv[1]) : 7500; int stage = argc > 2 ? atoi(argv[2]) : 2;
  buf b = { 0, 0, 0 }; node root; long long i; int64_t j;
  puts_(&b, "[\n");
  for (i = 0; i < records; i++) { if (i) puts_(&b, ",\n"); gen_value(&b, 2); }
  puts_(&b, "\n]\n");
  if (stage == 0) { printf("text length %zu\n", b.n); free(b.p); return 0; }
  S = (const unsigned char *)b.p; LEN = (int64_t)b.n;
  if (stage == 1) { printf("vector length %zu\n", b.n); free(b.p); return 0; }
  j = parse_value(skip(0), &root);
  if (j != LEN) { printf("error\n"); return 1; }
  fold(1, &root);
  printf("nodes=%lld sum64=%lld strlen=%lld depth=%lld\n", (long long)nodes, (long long)floor(sum * 64), (long long)strlen_, (long long)depth);
  free_node(&root); free(b.p);
  return 0;
}

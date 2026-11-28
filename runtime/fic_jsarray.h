/* The primitives of Elm.JsArray (elm/core's Elm.Kernel.JsArray): the arrays that the Elm code of Array.elm builds
   its tree of. Every element is a fic_word (the class of the element is the caller's business: the generator
   converts with fic_w_* and the word selectors); the object is the vector of ficrt.h with 8 byte elements,
   tag FIC_TAG_VEC_REF when the elements are references and FIC_TAG_VEC_RAW otherwise (the generic drop and the
   later reference counting find the references by that tag).
   Arrays are values. Without counts (no -DFIC_RC) every operation that changes an array makes a copy, like the JavaScript kernel;
   in a counted program `set` and `push` update a unique array in place (S6, see fic_ja_set below).
   Ownership in a counted program (-DFIC_RC; the signatures are in Ficus.Mono.Kernel): an array is BORROWED unless the signature
   says it is consumed (`set` and `push` consume their array and the element they store, `singleton` its element); the result is
   owned; the elements of a REF vector each hold a count, so a copy dups them, a function that gets an element from a borrowed array
   gives the callee its own count, and `get` returns a borrowed element (the generated code adds the count).
   Emitted after the closure runtime, only into programs that use it. */

static void fic_ja_dup_elems(fic_ref a, int64_t from, int64_t to) {
#ifdef FIC_RC
  int64_t i;
  if (a->tag == FIC_TAG_VEC_REF) for (i = from; i < to; i++) fic_dup(((fic_word *)FIC_VEC(a)->data)[i].p);
#else
  (void)a; (void)from; (void)to;
#endif
}

static fic_word *fic_ja_data(fic_ref a) { return (fic_word *)FIC_VEC(a)->data; }
static int64_t fic_ja_length(fic_ref a) { return FIC_VEC(a)->len; }

static fic_ref fic_ja_new(int64_t n, uint16_t tag) {
  fic_ref v = fic_vec_new(n < 1 ? 1 : n, sizeof(fic_word), tag);
  FIC_VEC(v)->len = n;
  return v;
}

static fic_ref fic_ja_empty(uint16_t tag) { return fic_ja_new(0, tag); }

static fic_ref fic_ja_singleton(uint16_t tag, fic_word x) {
  fic_ref r = fic_ja_new(1, tag);
  fic_ja_data(r)[0] = x;
  return r;
}

/* initialize size offset f: f is Int -> a (no reference argument) */
static fic_ref fic_ja_initialize(uint16_t tag, int64_t size, int64_t offset, fic_ref f) {
  int64_t i;
  fic_ref r = fic_ja_new(size < 0 ? 0 : size, tag);
  for (i = 0; i < FIC_VEC(r)->len; i++) fic_ja_data(r)[i] = fic_ap1(f, 0u, fic_w_i(offset + i));
  return r;
}

/* out of range reads give a zero word (JavaScript: undefined; Array.elm never asks) */
static fic_word fic_ja_get(int64_t i, fic_ref a) {
  fic_word z;
  if (i >= 0 && i < FIC_VEC(a)->len) return fic_ja_data(a)[i];
  z.i = 0;
  return z;
}

/* S6, take (Ficus.Mono.Rc `takeCall`): the element at i as an OWNED value; the array is borrowed. The compiler uses it only where the
   one later use of the array is `set` at the same index. A unique array gives up its element (no count is touched) and holds a
   placeholder there, the static empty list with a count, which the set overwrites and drops; a shared array gives a counted copy. */
static fic_word fic_ja_take(int64_t i, fic_ref a) {
  fic_word w;
  if (i < 0 || i >= FIC_VEC(a)->len) { w.p = fic_nil(); return w; }      /* unreachable from Array.elm */
  w = fic_ja_data(a)[i];
#ifdef FIC_RC
  if (a->rc == 1) fic_ja_data(a)[i].p = fic_nil();
  else fic_dup(w.p);
#endif
  return w;
}

/* S6 (STAGE4-PLAN 5.4, docs/STAGE4-S6.md): in a counted program `set` and `push` update the array IN PLACE when it is unique (count 1:
   the caller gave up the only reference), and copy otherwise. For `set` the generated code has the test and the write inline
   (FIC_JA_SET_RAW, FIC_JA_SET_REF below: the checked update) and calls fic_ja_set only when the array is shared or the index is out of
   range; the function repeats the test, so it is correct for every caller. Without -DFIC_RC nothing is counted and every update copies. */
#define FIC_JA_DATA(a) ((fic_word *)FIC_VEC(a)->data)
/* the fast path of the checked update: the array is unique and the index is in range */
#define FIC_JA_UNIQUE_AT(a, i) ((a)->rc == 1 && (uint64_t)(i) < (uint64_t)FIC_VEC(a)->len)
/* the same when the compiler knows that the array is unique (the elisions of docs/STAGE4-S6.md; not generated yet) */
#define FIC_JA_IN_RANGE(a, i) ((uint64_t)(i) < (uint64_t)FIC_VEC(a)->len)

static fic_ref fic_ja_set(int64_t i, fic_word x, fic_ref a) {
  int64_t n = FIC_VEC(a)->len;
  fic_ref r;
  if (i < 0 || i >= n) { if (a->tag == FIC_TAG_VEC_REF) FIC_RC_DROP(x.p); return a; }   /* unreachable from Array.elm */
#ifdef FIC_RC
  if (a->rc == 1) {                                 /* unique: in place; the element that was there loses its count */
    fic_word old = fic_ja_data(a)[i];
    fic_ja_data(a)[i] = x;
    if (a->tag == FIC_TAG_VEC_REF) fic_drop(old.p);
    FIC_STAT(fic_n_inplace++);
    return a;
  }
#endif
  FIC_STAT(fic_n_copied++);
  r = fic_ja_new(n, a->tag);
  memcpy(fic_ja_data(r), fic_ja_data(a), (size_t)n * sizeof(fic_word));
  fic_ja_dup_elems(r, 0, i);
  fic_ja_dup_elems(r, i + 1, n);
  fic_ja_data(r)[i] = x;
  FIC_RC_DROP(a);
  return r;
}

/* push: in place when the array is unique and has room; a unique array without room moves into a larger one (capacity doubles, at
   least 4: an Array.elm tail goes 4, 8, 16, 32); a shared array is copied with room for exactly one more */
static fic_ref fic_ja_push(fic_word x, fic_ref a) {
  int64_t n = FIC_VEC(a)->len;
  fic_ref r;
#ifdef FIC_RC
  if (a->rc == 1) {
    if (n < FIC_VEC(a)->cap) { fic_ja_data(a)[n] = x; FIC_VEC(a)->len = n + 1; FIC_STAT(fic_n_inplace++); return a; }
    r = fic_vec_new(n < 4 ? 4 : 2 * n, sizeof(fic_word), a->tag);
    memcpy(fic_ja_data(r), fic_ja_data(a), (size_t)n * sizeof(fic_word));
    fic_ja_data(r)[n] = x;
    FIC_VEC(r)->len = n + 1;
    fic_free_obj(a);                               /* the elements moved: only the shell is freed */
    FIC_STAT(fic_n_copied++);
    return r;
  }
#endif
  FIC_STAT(fic_n_copied++);
  r = fic_ja_new(n + 1, a->tag);
  memcpy(fic_ja_data(r), fic_ja_data(a), (size_t)n * sizeof(fic_word));
  fic_ja_dup_elems(r, 0, n);
  fic_ja_data(r)[n] = x;
  FIC_RC_DROP(a);
  return r;
}

/* the function of foldl and foldr is a -> b -> b; fmask has bit 0 set when a is a reference and bit 1 when b is */
static fic_word fic_ja_foldl(fic_ref f, unsigned fmask, fic_word acc, fic_ref a) {
  int64_t i;
  for (i = 0; i < FIC_VEC(a)->len; i++) { if (fmask & 1u) FIC_RC_DUP(fic_ja_data(a)[i].p); acc = fic_ap2(f, fmask, fic_ja_data(a)[i], acc); }
  return acc;
}

static fic_word fic_ja_foldr(fic_ref f, unsigned fmask, fic_word acc, fic_ref a) {
  int64_t i;
  for (i = FIC_VEC(a)->len - 1; i >= 0; i--) { if (fmask & 1u) FIC_RC_DUP(fic_ja_data(a)[i].p); acc = fic_ap2(f, fmask, fic_ja_data(a)[i], acc); }
  return acc;
}

/* map: f is a -> b, fmask bit 0 set when a is a reference; tag is the tag of the result */
static fic_ref fic_ja_map(uint16_t tag, fic_ref f, unsigned fmask, fic_ref a) {
  int64_t i, n = FIC_VEC(a)->len;
  fic_ref r = fic_ja_new(n, tag);
  for (i = 0; i < n; i++) { if (fmask & 1u) FIC_RC_DUP(fic_ja_data(a)[i].p); fic_ja_data(r)[i] = fic_ap1(f, fmask, fic_ja_data(a)[i]); }
  return r;
}

/* indexedMap: f is Int -> a -> b, fmask bit 1 set when a is a reference */
static fic_ref fic_ja_indexedmap(uint16_t tag, fic_ref f, unsigned fmask, int64_t offset, fic_ref a) {
  int64_t i, n = FIC_VEC(a)->len;
  fic_ref r = fic_ja_new(n, tag);
  for (i = 0; i < n; i++) { if (fmask & 2u) FIC_RC_DUP(fic_ja_data(a)[i].p); fic_ja_data(r)[i] = fic_ap2(f, fmask, fic_w_i(offset + i), fic_ja_data(a)[i]); }
  return r;
}

/* JavaScript's array.slice(from, to): negative indices count from the end, both are clamped */
static fic_ref fic_ja_slice(int64_t from, int64_t to, fic_ref a) {
  int64_t n = FIC_VEC(a)->len;
  fic_ref r;
  if (from < 0) { from += n; if (from < 0) from = 0; } else if (from > n) from = n;
  if (to < 0) { to += n; if (to < 0) to = 0; } else if (to > n) to = n;
  if (to < from) to = from;
  r = fic_ja_new(to - from, a->tag);
  if (to > from) memcpy(fic_ja_data(r), fic_ja_data(a) + from, (size_t)(to - from) * sizeof(fic_word));
  fic_ja_dup_elems(r, 0, to - from);
  return r;
}

/* appendN n dest source: dest followed by as many elements of source as fit below n */
static fic_ref fic_ja_appendn(int64_t n, fic_ref dest, fic_ref source) {
  int64_t dl = FIC_VEC(dest)->len, sl = FIC_VEC(source)->len, k = n - dl;
  fic_ref r;
  if (k > sl) k = sl;
  if (k < 0) k = 0;                              /* (JavaScript would make a shorter array: not reachable from Array.elm) */
  r = fic_ja_new(dl + k, dest->tag);
  memcpy(fic_ja_data(r), fic_ja_data(dest), (size_t)dl * sizeof(fic_word));
  if (k > 0) memcpy(fic_ja_data(r) + dl, fic_ja_data(source), (size_t)k * sizeof(fic_word));
  fic_ja_dup_elems(r, 0, dl + k);
  return r;
}

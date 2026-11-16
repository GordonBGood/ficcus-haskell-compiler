/* fic_vector.h -- the Vector of the language (V1; decisions D1 to D8 of 12 Nov; docs/STAGE4-V1.md). Needs fic_rt.h, which defines
   the object (fic_vector), its descriptor (fic_vdesc), the tag FIC_TAG_VECTOR and the drop. Emitted only into programs that use it.

   The object: { header, esize, len, cap, desc, elements }. The elements are stored FLAT, `esize` bytes each, in the C type of the
   element's class (decision D4):
     RAW   Int, Float, Char, Bool (one byte for now) and structs of those: desc is NULL, nothing is counted per element;
     REF   a single reference: desc lists the one offset 0 (fic_vd_ref below);
     MAP   a struct (record or tuple) that contains references: desc lists the offsets of its reference words (the pointer map; the
           generator makes one static descriptor per struct type), and the drop and the copy walk exactly those.
   A vector is an immutable VALUE (D3). In a counted program (-DFIC_RC) an update is done IN PLACE when the vector is unique (count 1)
   and copies the whole vector otherwise; `push` on a unique vector without room moves into one of twice the capacity (amortized
   constant time). Without counts every update copies (the oracle build).

   The generated code has the fast paths INLINE (Ficcus.Mono.CGen, `vectorCall`): a read is `FIC_VECTOR_AT(v, T, i)`, and the checked
   update is `if (FIC_VECTOR_UNIQUE_AT(v, i)) <write> else v = fic_vector_set(...)`. The functions below are the slow paths; each
   repeats every test, so it is correct for any caller. The two planned elisions of the count test (docs/STAGE4-S6.md section 2) only
   replace FIC_VECTOR_UNIQUE_AT by FIC_VECTOR_IN_RANGE(FIC_CHECK_UNIQUE(v), i) in the generated code: nothing here changes.

   Ownership (the signatures are in Ficcus.Mono.Kernel): `set`, `swap`, `push` consume their vector, `set` and `push` also the element
   they store (passed by address; the references in it are moved); `append` consumes its first vector and borrows the second; `slice`
   consumes its vector (in place when it is unique); a read gives a borrowed element (the generated code adds the counts), a take moves the element out of a unique vector.

   Diagnostic (decision D3): every update that copies because the vector is shared counts in `vec_copy` of the FIC_STATS line, and
   with the environment variable FIC_WARN_COPY=1 the first such copy prints one line on stderr with the operation and the function
   that made it. Growth of a unique vector is not such a copy. */
#ifndef FIC_VECTOR_H
#define FIC_VECTOR_H

#include <stddef.h>

#define FIC_VECTOR_LEN(v)            (FIC_VECTOR(v)->len)
#define FIC_VECTOR_AT(v, T, i)       (((T *)(void *)FIC_VECTOR(v)->data)[i])
#define FIC_VECTOR_IN_RANGE(v, i)    ((uint64_t)(i) < (uint64_t)FIC_VECTOR(v)->len)
/* the fast path of the checked update: the vector is unique and the index is in range */
#define FIC_VECTOR_UNIQUE_AT(v, i)   ((v)->rc == 1 && FIC_VECTOR_IN_RANGE(v, i))
/* the fast path of push: unique and room for one more */
#define FIC_VECTOR_ROOM(v)           (FIC_VECTOR(v)->len < FIC_VECTOR(v)->cap)
#define FIC_VECTOR_UNIQUE_ROOM(v)    ((v)->rc == 1 && FIC_VECTOR_ROOM(v))

/* a read at an index that the Elm code has tested (`Vector.get`); with -DFIC_CHECK the runtime tests it again */
#ifdef FIC_CHECK
static inline int64_t fic_vector_checked(fic_ref v, int64_t i) {
  if (!FIC_VECTOR_IN_RANGE(v, i)) { fprintf(stderr, "FIC_CHECK: vector index %lld out of range (length %lld)\n", (long long)i, (long long)FIC_VECTOR(v)->len); abort(); }
  return i;
}
#  define FIC_VECTOR_GET(v, T, i)    FIC_VECTOR_AT(v, T, fic_vector_checked((v), (i)))
#else
#  define FIC_VECTOR_GET(v, T, i)    FIC_VECTOR_AT(v, T, i)
#endif

/* the descriptor of a vector of single references */
static const uint16_t fic_vd_ref_off[1] = { 0 };
static const fic_vdesc fic_vd_ref FIC_UNUSED = { 1u, fic_vd_ref_off };

/* a new vector with room for `cap` elements and none in it */
static fic_ref fic_vector_new(int64_t cap, uint32_t esize, const fic_vdesc *desc) {
  fic_vector *v;
  if (cap < 0) cap = 0;
  if (esize == 0 || (uint64_t)cap > (uint64_t)(SIZE_MAX / 2 - sizeof(fic_vector)) / esize) abort();
  v = (fic_vector *)fic_alloc(sizeof(fic_vector) + (size_t)cap * esize, FIC_TAG_VECTOR, desc != NULL ? 1 : 0);
  v->esize = esize; v->spare = 0; v->len = 0; v->cap = cap; v->desc = desc;
  return &v->h;
}

static inline unsigned char *fic_vector_elem(fic_ref v, int64_t i) { return FIC_VECTOR(v)->data + (size_t)i * FIC_VECTOR(v)->esize; }

/* a count for every reference of the elements from..to-1 (they are now held twice) */
static void fic_vector_dup_range(fic_ref v, int64_t from, int64_t to) {
#ifdef FIC_RC
  const fic_vdesc *d = FIC_VECTOR(v)->desc;
  if (d != NULL) {
    unsigned char *e = fic_vector_elem(v, from);
    int64_t i;
    uint32_t k;
    for (i = from; i < to; i++, e += FIC_VECTOR(v)->esize)
      for (k = 0; k < d->nref; k++) fic_dup(*(fic_ref *)(void *)(e + d->off[k]));
  }
#else
  (void)v; (void)from; (void)to;
#endif
}

/* the references of one element (at `e`) lose their counts */
static void fic_vector_drop_elem(const fic_vdesc *d, const unsigned char *e) {
#ifdef FIC_RC
  if (d != NULL) { uint32_t k; for (k = 0; k < d->nref; k++) fic_drop(*(fic_ref const *)(const void *)(e + d->off[k])); }
#else
  (void)d; (void)e;
#endif
}

/* a copy of the BORROWED vector v with room for `cap` elements (at least its length); the copy holds its own counts */
static fic_ref fic_vector_copy(fic_ref v, int64_t cap) {
  int64_t n = FIC_VECTOR(v)->len;
  fic_ref r = fic_vector_new(cap < n ? n : cap, FIC_VECTOR(v)->esize, FIC_VECTOR(v)->desc);
  if (n > 0) memcpy(FIC_VECTOR(r)->data, FIC_VECTOR(v)->data, (size_t)n * FIC_VECTOR(v)->esize);
  FIC_VECTOR(r)->len = n;
  fic_vector_dup_range(r, 0, n);
  return r;
}

#ifdef FIC_RC
/* decision D3: an update copies because its vector is shared */
static int fic_warn_copy_state;                         /* 0 not asked yet, 1 report the next one, 2 nothing (more) to report */
static void fic_vector_shared(const char *op, fic_ref v, const char *where) {
  FIC_STAT(fic_n_vcopy++);
  if (fic_warn_copy_state == 0) {
    const char *e = getenv("FIC_WARN_COPY");
    fic_warn_copy_state = (e != NULL && e[0] == '1' && e[1] == 0) ? 1 : 2;
  }
  if (fic_warn_copy_state == 1) {
    fic_warn_copy_state = 2;
    fprintf(stderr, "FIC_WARN_COPY: Vector.%s copies a shared vector of %lld elements (%u references to it) in %s; later copies are not reported\n",
            op, (long long)FIC_VECTOR(v)->len, (unsigned)v->rc, where != NULL ? where : "?");
  }
}
#endif

/* the capacity a vector of n elements grows to */
static inline int64_t fic_vector_grown(int64_t n) { return n < 4 ? 4 : 2 * n; }

/* a unique vector moves into a new one with room for `cap` (the elements are moved: no counts; the old shell is freed) */
#ifdef FIC_RC
static fic_ref fic_vector_move(fic_ref v, int64_t cap) {
  int64_t n = FIC_VECTOR(v)->len;
  fic_ref r = fic_vector_new(cap, FIC_VECTOR(v)->esize, FIC_VECTOR(v)->desc);
  if (n > 0) memcpy(FIC_VECTOR(r)->data, FIC_VECTOR(v)->data, (size_t)n * FIC_VECTOR(v)->esize);
  FIC_VECTOR(r)->len = n;
  fic_free_obj(v);
  return r;
}
#endif

/* set i x v: out of range the vector comes back unchanged (and the element is released) */
static fic_ref fic_vector_set(int64_t i, const void *x, fic_ref v, const char *where) {
  fic_ref r;
  (void)where;
  if (!FIC_VECTOR_IN_RANGE(v, i)) { fic_vector_drop_elem(FIC_VECTOR(v)->desc, (const unsigned char *)x); return v; }
#ifdef FIC_RC
  if (v->rc == 1) {
    fic_vector_drop_elem(FIC_VECTOR(v)->desc, fic_vector_elem(v, i));
    memcpy(fic_vector_elem(v, i), x, FIC_VECTOR(v)->esize);
    FIC_STAT(fic_n_inplace++);
    return v;
  }
  fic_vector_shared("set", v, where);
#endif
  FIC_STAT(fic_n_copied++);
  r = fic_vector_new(FIC_VECTOR(v)->len, FIC_VECTOR(v)->esize, FIC_VECTOR(v)->desc);
  memcpy(FIC_VECTOR(r)->data, FIC_VECTOR(v)->data, (size_t)FIC_VECTOR(v)->len * FIC_VECTOR(v)->esize);
  FIC_VECTOR(r)->len = FIC_VECTOR(v)->len;
  memcpy(fic_vector_elem(r, i), x, FIC_VECTOR(v)->esize);
  fic_vector_dup_range(r, 0, i);
  fic_vector_dup_range(r, i + 1, FIC_VECTOR(r)->len);
  FIC_RC_DROP(v);
  return r;
}

/* swap i j v: when either index is out of range the vector comes back unchanged */
static fic_ref fic_vector_swap(int64_t i, int64_t j, fic_ref v, const char *where) {
  size_t es = FIC_VECTOR(v)->esize, k;
  unsigned char *a, *b;
  (void)where;
  if (!FIC_VECTOR_IN_RANGE(v, i) || !FIC_VECTOR_IN_RANGE(v, j) || i == j) return v;
#ifdef FIC_RC
  if (v->rc != 1) {
    fic_ref r;
    fic_vector_shared("swap", v, where);
    FIC_STAT(fic_n_copied++);
    r = fic_vector_copy(v, 0);
    fic_drop(v);
    v = r;
  } else FIC_STAT(fic_n_inplace++);
#else
  FIC_STAT(fic_n_copied++);
  v = fic_vector_copy(v, 0);
#endif
  a = fic_vector_elem(v, i); b = fic_vector_elem(v, j);
  for (k = 0; k < es; k++) { unsigned char t = a[k]; a[k] = b[k]; b[k] = t; }
  return v;
}

/* push x v */
static fic_ref fic_vector_push(const void *x, fic_ref v, const char *where) {
  int64_t n = FIC_VECTOR(v)->len;
  fic_ref r;
  (void)where;
#ifdef FIC_RC
  if (v->rc == 1) {
    if (n < FIC_VECTOR(v)->cap) { r = v; FIC_STAT(fic_n_inplace++); }
    else { r = fic_vector_move(v, fic_vector_grown(n)); FIC_STAT(fic_n_copied++); }      /* growth: not a copy of a shared vector */
  } else {
    fic_vector_shared("push", v, where);
    FIC_STAT(fic_n_copied++);
    r = fic_vector_copy(v, fic_vector_grown(n));
    fic_drop(v);
  }
#else
  FIC_STAT(fic_n_copied++);
  r = fic_vector_copy(v, n + 1);
#endif
  memcpy(fic_vector_elem(r, n), x, FIC_VECTOR(r)->esize);
  FIC_VECTOR(r)->len = n + 1;
  return r;
}

/* the index rule of Array.slice: a negative index counts from the end, both ends are clamped */
static int64_t fic_vector_index(int64_t i, int64_t len) {
  if (i < 0) { i += len; return i < 0 ? 0 : i; }
  return i > len ? len : i;
}

/* slice from to v: v is CONSUMED (V4 step 4). A unique vector is cut in place: the elements outside the range lose their counts, the
   live part moves down to index 0 and the capacity stays, so a trim followed by pushes does not copy again; when the length falls far
   below the capacity (len * 4 < cap, cap > 64) the live part moves into a smaller block, one copy. A shared vector gives a new
   vector (as before) and loses one count. Without counts (the oracle) v is only borrowed: a new vector. */
static fic_ref fic_vector_slice(int64_t from, int64_t to, fic_ref v) {
  int64_t n = FIC_VECTOR(v)->len, a = fic_vector_index(from, n), b = fic_vector_index(to, n);
  fic_ref r;
  if (b < a) b = a;
#ifdef FIC_RC
  if (v->rc == 1) {
    fic_vector *p = FIC_VECTOR(v);
    int64_t len = b - a, i;
    if (p->desc != NULL) {
      for (i = 0; i < a; i++) fic_vector_drop_elem(p->desc, fic_vector_elem(v, i));
      for (i = b; i < n; i++) fic_vector_drop_elem(p->desc, fic_vector_elem(v, i));
    }
    if (a > 0 && len > 0) memmove(p->data, fic_vector_elem(v, a), (size_t)len * p->esize);
    p->len = len;
    FIC_STAT(fic_n_inplace++);
    if (p->cap > 64 && len * 4 < p->cap) { r = fic_vector_move(v, fic_vector_grown(len)); FIC_STAT(fic_n_copied++); return r; }
    return v;
  }
#endif
  r = fic_vector_new(b - a, FIC_VECTOR(v)->esize, FIC_VECTOR(v)->desc);
  if (b > a) memcpy(FIC_VECTOR(r)->data, fic_vector_elem(v, a), (size_t)(b - a) * FIC_VECTOR(v)->esize);
  FIC_VECTOR(r)->len = b - a;
  fic_vector_dup_range(r, 0, b - a);
  FIC_RC_DROP(v);
  return r;
}

/* append a b: a is consumed (extended in place when it is unique and has room; a unique one without room moves), b is borrowed */
static fic_ref fic_vector_append(fic_ref a, fic_ref b, const char *where) {
  int64_t la = FIC_VECTOR(a)->len, lb = FIC_VECTOR(b)->len, n = la + lb;
  fic_ref r;
  (void)where;
  if (lb == 0) return a;
#ifdef FIC_RC
  if (a == b && a->rc == 1) { FIC_RC_DUP(a); r = fic_vector_append(a, b, where); FIC_RC_DROP(b); return r; }      /* the same unique vector twice (the Rc pass never does this): do not free b under the copy */
  if (a->rc == 1) {
    if (FIC_VECTOR(a)->cap >= n) { r = a; FIC_STAT(fic_n_inplace++); }
    else { int64_t g = fic_vector_grown(la); r = fic_vector_move(a, g < n ? n : g); FIC_STAT(fic_n_copied++); }
  } else {
    if (la > 0) fic_vector_shared("append", a, where);
    FIC_STAT(fic_n_copied++);
    r = fic_vector_copy(a, n);
    fic_drop(a);
  }
#else
  FIC_STAT(fic_n_copied++);
  r = fic_vector_copy(a, n);
#endif
  memcpy(fic_vector_elem(r, la), FIC_VECTOR(b)->data, (size_t)lb * FIC_VECTOR(b)->esize);
  FIC_VECTOR(r)->len = n;
  fic_vector_dup_range(r, la, n);
  return r;
}

/* take i v out (v borrowed, the index in range): the element is MOVED out of a unique vector, whose reference words then hold a
   placeholder (the static empty list, counted) that the following set at the same index overwrites and drops; a shared vector gives a
   counted copy. The generated code does this inline for the element's type (CGen `vectorCall`, "unsafeTake"); this is the same for
   any element, used by the runtime test. */
static void fic_vector_take(int64_t i, fic_ref v, void *out) {
  const fic_vdesc *d = FIC_VECTOR(v)->desc;
  unsigned char *e;
  if (!FIC_VECTOR_IN_RANGE(v, i)) { fprintf(stderr, "fic_vector_take: index %lld out of range\n", (long long)i); abort(); }
  e = fic_vector_elem(v, i);
  memcpy(out, e, FIC_VECTOR(v)->esize);
#ifdef FIC_RC
  if (d != NULL) {
    uint32_t k;
    for (k = 0; k < d->nref; k++) {
      if (v->rc == 1) *(fic_ref *)(void *)(e + d->off[k]) = fic_nil();
      else fic_dup(*(fic_ref *)(void *)(e + d->off[k]));
    }
  }
#else
  (void)d;
#endif
}

#endif

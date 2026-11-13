/* fic_rt.h -- the runtime core of generated Ficcus programs: header, allocator, reference counts, the generic drop,
 * vectors (STAGE4-PLAN slices S0 and S1). Derived from targets/c/ficrt.h (the sketch the 16 hand written target programs
 * use; that file is not changed). Standard library only, C99. Emitted first by CRuntime.prelude.
 *
 * Value model (decisions file, 5 Nov and rev 113):
 *   - records and tuples are C structs (value semantics); inside a heap object or a closure they are flattened;
 *   - custom types, vectors, strings and closures are heap objects with the 8 byte header {rc, tag, nptr, cls}; the
 *     `nptr` reference words follow the fixed part of the object (the header; for a closure also the code pointer),
 *     then the scalar words. So the drop of an object needs no type information;
 *   - nullary constructors are static immortal objects (one per tag, `fic_nul<tag>`), never scalars;
 *   - counts are not atomic (single thread). Static objects start at FIC_IMMORTAL and are counted like any other, so
 *     dup and drop have no branch for them and a static object is never "unique";
 *   - FIC_STATS prints counters at fic_shutdown, FIC_DROP_ALL registers every object and, at fic_shutdown, checks the
 *     layout of every one (every reference word is an object) and frees them all; FIC_CHECK aborts on count overflow
 *     and on a failed uniqueness check.
 */
#ifndef FIC_RT_H
#define FIC_RT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* cls: allocation size class in 8 byte units (0 = plain malloc), so a free needs no size */
typedef struct fic_hdr { uint32_t rc; uint16_t tag; uint8_t nptr; uint8_t cls; } fic_hdr;
typedef fic_hdr *fic_ref;

#define FIC_IMMORTAL        0x40000000u
#define FIC_TAG_VEC_REF     0xFFFFu   /* a vector (fic_vec) whose elements are references */
#define FIC_TAG_VEC_RAW     0xFFFEu   /* a vector without references */
#define FIC_TAG_CLOSURE     0xFFFDu   /* header, code pointer, nptr captured references, captured scalars */
#define FIC_TAG_PAP         0xFFFCu   /* header, code, fun, mask, nargs, args (words): released through the mask */
#define FIC_TAG_STRING      0xFFF0u   /* header, byte length, code point length, bytes, NUL */
#define FIC_TAG_BOX         0xFFF1u   /* a struct held where a single word is needed (an object with the struct flattened) */

/* Int is 64 bit two's complement and wraps: do the arithmetic unsigned. */
#define FIC_ADD64(a, b) ((int64_t)((uint64_t)(a) + (uint64_t)(b)))
#define FIC_MUL64(a, b) ((int64_t)((uint64_t)(a) * (uint64_t)(b)))

#if defined(__GNUC__)
#  define FIC_UNUSED __attribute__((unused))
#else
#  define FIC_UNUSED
#endif

static size_t fic_live_objects, fic_total_allocs;
#ifdef FIC_STATS
static size_t fic_n_dup, fic_n_drop, fic_n_free_slow, fic_n_reuse_hit, fic_n_reuse_miss, fic_peak_live;
static size_t fic_n_inplace, fic_n_copied, fic_n_pap_steal, fic_n_clo_steal;   /* S6: array updates in place and copied, partial applications taken apart */
#  define FIC_STAT(x) (x)
#else
#  define FIC_STAT(x) ((void)0)
#endif

/* ---- the words of a closure, shared by the closure runtime and the generic drop ---- */
typedef union fic_word { int64_t i; double d; uint32_t c; uint8_t b; fic_ref p; } fic_word;
/* `own` (counted programs only, S7 part 3): the entry of a call that consumes a closure object nobody else holds (it takes the
   captured values out of the object and frees it), or 0 */
#ifdef FIC_RC
typedef struct fic_code { void (*fn)(void); unsigned arity; void (*own)(void); } fic_code;
#define FIC_CODE_OWN0 , 0
#else
typedef struct fic_code { void (*fn)(void); unsigned arity; } fic_code;
#define FIC_CODE_OWN0
#endif
typedef struct fic_clo { fic_hdr h; const fic_code *code; } fic_clo;
typedef struct fic_pap { fic_hdr h; const fic_code *code; fic_ref fun; uint32_t mask; uint32_t nargs; fic_word args[]; } fic_pap;

/* A case on a value that gcc knows is a static nullary object (8 bytes) contains the field reads of the other constructors
   behind a tag test that is false: dead code, but -Warray-bounds sees the read. */
#if defined(__GNUC__) && !defined(__clang__)
#  pragma GCC diagnostic ignored "-Warray-bounds"
#endif

/* the static nullary objects that runtime C code needs: [] and Nothing-like tags 0 and 1 (generated code defines the others) */
static fic_hdr fic_nul0 FIC_UNUSED = { FIC_IMMORTAL, 0u, 0, 0 };
static fic_hdr fic_nul1 FIC_UNUSED = { FIC_IMMORTAL, 1u, 0, 0 };

/* ---- allocator: size classes with free lists (compile with -DFIC_NO_POOL for plain malloc) ----
   Objects up to 256 bytes come from per-size free lists (classes of 8 byte steps, 16..256),
   carved from 1 MB slabs; a freed object goes on the list of its class (the class is in the
   header), so alloc and free are a few instructions and nothing is returned to the system
   until fic_pool_release(). Larger objects use malloc/free. Under AddressSanitizer the
   free objects are poisoned, so a use after free is still reported.
   Reuse tokens (drop-reuse) are unaffected: a token is a live object of the right class. */
#if defined(__SANITIZE_ADDRESS__)
#  define FIC_HAVE_ASAN 1
#elif defined(__has_feature)
#  if __has_feature(address_sanitizer)
#    define FIC_HAVE_ASAN 1
#  endif
#endif
#ifdef FIC_HAVE_ASAN
#  include <sanitizer/asan_interface.h>
#  define FIC_POISON(p, n)   ASAN_POISON_MEMORY_REGION((p), (n))
#  define FIC_UNPOISON(p, n) ASAN_UNPOISON_MEMORY_REGION((p), (n))
#else
#  define FIC_POISON(p, n)   ((void)0)
#  define FIC_UNPOISON(p, n) ((void)0)
#endif

#define FIC_MAX_CLASS  32                       /* the largest pooled object: 32 units of 8 bytes (also the limit of a reuse token, with or without the pool) */
#ifndef FIC_NO_POOL
#define FIC_SLAB_BYTES ((size_t)1 << 20)
static void *fic_free_list[FIC_MAX_CLASS + 1];
static unsigned char *fic_bump, *fic_bump_end;
static void *fic_slabs;                         /* chain of slabs: the first word links to the next */
static size_t fic_slab_count;

static void *fic_bump_alloc(size_t n) {
  unsigned char *p;
  if ((size_t)(fic_bump_end - fic_bump) < n) {
    unsigned char *slab = (unsigned char *)malloc(FIC_SLAB_BYTES);
    if (slab == NULL) abort();
    *(void **)slab = fic_slabs; fic_slabs = slab; fic_slab_count++;
    fic_bump = slab + 16; fic_bump_end = slab + FIC_SLAB_BYTES;
    FIC_POISON(fic_bump, (size_t)(fic_bump_end - fic_bump));
  }
  p = fic_bump; fic_bump += n;
  return p;
}
static void fic_pool_release(void) {            /* give every slab back (all objects must be dead) */
  while (fic_slabs != NULL) { void *next = *(void **)fic_slabs; free(fic_slabs); fic_slabs = next; }
  memset(fic_free_list, 0, sizeof fic_free_list);
  fic_bump = fic_bump_end = NULL; fic_slab_count = 0;
}
#endif

/* ---- FIC_DROP_ALL: a set of the live objects (open addressing, tombstones) ---- */
#ifdef FIC_DROP_ALL
static uintptr_t *fic_reg_tab; static size_t fic_reg_cap, fic_reg_used, fic_reg_count;   /* used = entries and tombstones */
#define FIC_REG_DEAD ((uintptr_t)1)
static size_t fic_reg_hash(uintptr_t p) { p >>= 3; p *= (uintptr_t)0x9E3779B97F4A7C15ull; return (size_t)(p >> 20); }
static void fic_reg_grow(void) {
  uintptr_t *old = fic_reg_tab; size_t oc = fic_reg_cap, i;
  fic_reg_cap = oc == 0 ? 1024 : (fic_reg_count * 2 >= oc ? oc * 2 : oc);   /* only tombstones: rehash at the same size */
  fic_reg_tab = (uintptr_t *)calloc(fic_reg_cap, sizeof(uintptr_t));
  if (fic_reg_tab == NULL) abort();
  fic_reg_used = 0;
  for (i = 0; i < oc; i++) {
    uintptr_t p = old[i];
    if (p > FIC_REG_DEAD) {
      size_t h = fic_reg_hash(p) & (fic_reg_cap - 1);
      while (fic_reg_tab[h] != 0) h = (h + 1) & (fic_reg_cap - 1);
      fic_reg_tab[h] = p; fic_reg_used++;
    }
  }
  free(old);
}
static void fic_reg_add(void *o) {
  size_t h;
  if ((fic_reg_used + 1) * 2 > fic_reg_cap) fic_reg_grow();
  h = fic_reg_hash((uintptr_t)o) & (fic_reg_cap - 1);
  while (fic_reg_tab[h] > FIC_REG_DEAD) h = (h + 1) & (fic_reg_cap - 1);
  if (fic_reg_tab[h] == 0) fic_reg_used++;
  fic_reg_tab[h] = (uintptr_t)o; fic_reg_count++;
}
static int fic_reg_has(const void *o) {
  size_t h;
  if (fic_reg_cap == 0) return 0;
  h = fic_reg_hash((uintptr_t)o) & (fic_reg_cap - 1);
  while (fic_reg_tab[h] != 0) { if (fic_reg_tab[h] == (uintptr_t)o) return 1; h = (h + 1) & (fic_reg_cap - 1); }
  return 0;
}
static void fic_reg_del(void *o) {
  size_t h = fic_reg_hash((uintptr_t)o) & (fic_reg_cap - 1);
  while (fic_reg_tab[h] != 0) {
    if (fic_reg_tab[h] == (uintptr_t)o) { fic_reg_tab[h] = FIC_REG_DEAD; fic_reg_count--; return; }
    h = (h + 1) & (fic_reg_cap - 1);
  }
  fprintf(stderr, "FIC_DROP_ALL: free of an object that is not live (double free) %p\n", o); abort();
}
#endif

static inline void *fic_alloc(size_t bytes, uint16_t tag, uint16_t nptr) {
  fic_hdr *h;
  if (nptr > 255) abort();
#ifndef FIC_NO_POOL
  {
    size_t c = (bytes + 7) >> 3;
    if (c < 2) c = 2;
    if (c <= FIC_MAX_CLASS) {
      h = (fic_hdr *)fic_free_list[c];
      if (h != NULL) { fic_free_list[c] = *(void **)h; FIC_UNPOISON((char *)h + 8, c * 8 - 8); }
      else { h = (fic_hdr *)fic_bump_alloc(c * 8); FIC_UNPOISON(h, c * 8); }
      h->cls = (uint8_t)c;
    } else { h = (fic_hdr *)malloc(bytes); if (h == NULL) abort(); h->cls = 0; }
  }
#else
  {                                   /* no pool (ASan): malloc, but the size class is kept so that a reuse token can be checked (S4) */
    size_t c = (bytes + 7) >> 3;
    if (c < 2) c = 2;
    h = (fic_hdr *)malloc(c * 8);
    if (h == NULL) abort();
    h->cls = c <= FIC_MAX_CLASS ? (uint8_t)c : 0;
  }
#endif
  h->rc = 1; h->tag = tag; h->nptr = (uint8_t)nptr;
  fic_live_objects++; fic_total_allocs++;
#ifdef FIC_STATS
  if (fic_live_objects > fic_peak_live) fic_peak_live = fic_live_objects;
#endif
#ifdef FIC_DROP_ALL
  fic_reg_add(h);
#endif
  return h;
}

/* S4 reuse: an object built in the cell of a token (the cell of a unique object that was taken apart, of the same size class), or a fresh
   one when the token is NULL (the cell was shared). The class check makes a wrong pairing a miss, never a heap overflow. */
static inline void fic_free_obj(void *o);
static inline void *fic_reuse(void *tok, size_t bytes, uint16_t tag, uint16_t nptr) {
  if (tok != NULL) {
    size_t c = (bytes + 7) >> 3;
    fic_hdr *h = (fic_hdr *)tok;
    if (c < 2) c = 2;
    if (h->cls == c) {
      h->rc = 1; h->tag = tag; h->nptr = (uint8_t)nptr;
      FIC_STAT(fic_n_reuse_hit++);
      return h;
    }
    fic_free_obj(tok);                                  /* a pairing the generator got wrong: not a reuse */
  }
  FIC_STAT(fic_n_reuse_miss++);
  return fic_alloc(bytes, tag, nptr);
}

/* free an object whose count is zero or that was moved out (a reuse token not reused) */
static inline void fic_free_obj(void *o) {
  fic_live_objects--;
#ifdef FIC_DROP_ALL
  fic_reg_del(o);
#endif
#ifndef FIC_NO_POOL
  {
    unsigned c = ((fic_hdr *)o)->cls;
    if (c != 0) {
      *(void **)o = fic_free_list[c]; fic_free_list[c] = o;
      FIC_POISON((char *)o + 8, (size_t)c * 8 - 8);
      return;
    }
  }
#endif
  free(o);
}

/* ---- counts, the generic drop ---- */
typedef struct fic_vec { fic_hdr h; int64_t len; int64_t cap; size_t esize; unsigned char data[]; } fic_vec;
#define FIC_VEC(r) ((fic_vec *)(r))

static void fic_free_slow(fic_ref o);

/* a new reference to o: o is not consumed */
static inline fic_ref fic_dup(fic_ref p) {
  FIC_STAT(fic_n_dup++);
#ifdef FIC_CHECK
  if (p->rc >= 0xF0000000u) { fprintf(stderr, "FIC_CHECK: reference count overflow\n"); abort(); }
#endif
  p->rc++;
  return p;
}
/* give up one reference: frees the object (and what only it holds) when it was the last */
static inline void fic_drop(fic_ref p) {
  FIC_STAT(fic_n_drop++);
  if (--p->rc == 0) fic_free_slow(p);
}
/* a shared object (count above 1) loses one count: it cannot die (drop specialization, S4) */
static inline void fic_drop_shared(fic_ref p) { FIC_STAT(fic_n_drop++); p->rc--; }
/* uniqueness: the one owner may update in place */
static inline int fic_is_unique(fic_ref p) { return p->rc == 1; }
/* free the memory of an object whose fields were moved out (nothing below it is released) */
static inline void fic_free_shell(fic_ref p) { fic_free_obj(p); }

/* Kernel macros (STAGE4-PLAN section 8). FIC_DUP and FIC_DROP count; FIC_MOVE documents that ownership of x passes on
   (no code); FIC_CHECK_UNIQUE(x) is x, and under FIC_CHECK aborts when x is shared. */
/* The kernels of the runtime (fic_closure.h, fic_jsarray.h, ...) follow the ownership convention of STAGE4-PLAN section 8 only in a
   counted program (-DFIC_RC, which the generator defines for `--rc`): without counts nothing may be freed, because a value can be held
   by several owners that do not count. FIC_RC_DUP/FIC_RC_DROP are the counts a kernel adds for itself. */
#ifdef FIC_RC
#  define FIC_RC_DUP(x)  ((void)fic_dup(x))
#  define FIC_RC_DROP(x) fic_drop(x)
#else
#  define FIC_RC_DUP(x)  ((void)0)
#  define FIC_RC_DROP(x) ((void)0)
#endif
/* an owned reference to the empty list (a kernel that builds a list ends it with this) */
static inline fic_ref fic_nil(void) { FIC_RC_DUP((fic_ref)&fic_nul0); return (fic_ref)&fic_nul0; }
#define FIC_DUP(x)  fic_dup(x)
#define FIC_DROP(x) fic_drop(x)
#define FIC_MOVE(x) (x)
#ifdef FIC_CHECK
static inline fic_ref fic_check_unique(fic_ref p, const char *where) {
  if (p->rc != 1) { fprintf(stderr, "FIC_CHECK: %s: object with count %u is not unique\n", where, (unsigned)p->rc); abort(); }
  return p;
}
#  define FIC_CHECK_UNIQUE(x) fic_check_unique((x), __FILE__)
#else
#  define FIC_CHECK_UNIQUE(x) (x)
#endif

/* A child whose count reaches zero is freed next; the explicit stack holds the earlier dying siblings, so a list of
   lists or a degenerate tree needs no C recursion (STAGE4-PLAN 7.2). The stack grows by realloc and is never shrunk;
   `base` marks the part that belongs to one running drop, so a drop started while another runs is safe. */
static fic_ref *fic_dstack; static size_t fic_dtop, fic_dcap;

static void fic_dpush(fic_ref o) {
  if (fic_dtop == fic_dcap) {
    size_t cap = fic_dcap == 0 ? 256 : fic_dcap * 2;
    fic_ref *s = (fic_ref *)realloc(fic_dstack, cap * sizeof(fic_ref));
    if (s == NULL) abort();
    fic_dstack = s; fic_dcap = cap;
  }
  fic_dstack[fic_dtop++] = o;
}

/* an object without references to release: freed at once when it dies */
static inline int fic_is_leaf(const fic_hdr *k) {
  return k->tag == FIC_TAG_STRING || k->tag == FIC_TAG_VEC_RAW || (k->nptr == 0 && k->tag != FIC_TAG_VEC_REF && k->tag != FIC_TAG_PAP);
}

#define FIC_RELEASE_CHILD(kexpr) do { \
    fic_ref k_ = (kexpr); \
    if (--k_->rc == 0) { \
      if (fic_is_leaf(k_)) fic_free_obj(k_); \
      else { if (next != NULL) fic_dpush(next); next = k_; } \
    } \
  } while (0)

static void fic_free_slow(fic_ref o) {            /* o->rc has just reached 0 */
  size_t base = fic_dtop;
  FIC_STAT(fic_n_free_slow++);
  for (;;) {
    fic_ref next = NULL;                           /* continue with the last child that dies */
    switch (o->tag) {
    case FIC_TAG_VEC_REF: {
      fic_vec *v = FIC_VEC(o);
      fic_ref *items = (fic_ref *)v->data;
      int64_t i;
      for (i = 0; i < v->len; i++) FIC_RELEASE_CHILD(items[i]);
      break; }
    case FIC_TAG_VEC_RAW: case FIC_TAG_STRING:
      break;
    case FIC_TAG_PAP: {
      fic_pap *p = (fic_pap *)o;
      uint32_t i;
      FIC_RELEASE_CHILD(p->fun);
      for (i = 0; i < p->nargs; i++) if ((p->mask >> i) & 1u) FIC_RELEASE_CHILD(p->args[i].p);
      break; }
    default: {
      fic_ref *kid = (fic_ref *)(o + 1);
      unsigned i, n = o->nptr;
      if (o->tag == FIC_TAG_CLOSURE) kid = (fic_ref *)((char *)kid + sizeof(void *));   /* skip the code pointer */
      for (i = 0; i < n; i++) FIC_RELEASE_CHILD(kid[i]);
      break; }
    }
    fic_free_obj(o);
    if (next != NULL) o = next;
    else if (fic_dtop > base) o = fic_dstack[--fic_dtop];
    else break;
  }
}

/* ---- the end of a program: FIC_DROP_ALL check, FIC_STATS report ---- */
#ifdef FIC_DROP_ALL
static size_t fic_check_child(const fic_hdr *o, const void *k, size_t idx) {
  uintptr_t u = (uintptr_t)k;
  if (k != NULL && fic_reg_has(k)) return 0;
  /* a static object is not registered: recognised by its count, but only a 4-byte aligned address of a plausible size is read */
  if (u >= 65536u && (u & 3u) == 0 && u < ((uintptr_t)1 << 47) && ((const fic_hdr *)k)->rc >= FIC_IMMORTAL / 2) return 0;
  fprintf(stderr, "FIC_DROP_ALL: object %p tag %u: reference word %zu is %p, not an object\n", (const void *)o, (unsigned)o->tag, idx, k);
  return 1;
}
static size_t fic_check_object(const fic_hdr *o) {
  size_t bad = 0, i;
  switch (o->tag) {
  case FIC_TAG_VEC_REF: {
    const fic_vec *v = (const fic_vec *)o;
    for (i = 0; i < (size_t)v->len; i++) bad += fic_check_child(o, ((fic_ref const *)v->data)[i], i);
    break; }
  case FIC_TAG_VEC_RAW: break;
  case FIC_TAG_STRING: {
    const fic_hdr *s = o;
    const int64_t *len = (const int64_t *)(s + 1);
    const char *d = (const char *)(len + 2);
    int64_t cps = 0, j;
    for (j = 0; j < len[0]; j++) if (((unsigned char)d[j] & 0xC0u) != 0x80u) cps++;
    if (cps != len[1] || d[len[0]] != 0) { fprintf(stderr, "FIC_DROP_ALL: string %p: code points %lld cached %lld\n", (const void *)o, (long long)cps, (long long)len[1]); bad++; }
    break; }
  case FIC_TAG_PAP: {
    const fic_pap *p = (const fic_pap *)o;
    bad += fic_check_child(o, p->fun, 0);
    for (i = 0; i < p->nargs; i++) if ((p->mask >> i) & 1u) bad += fic_check_child(o, p->args[i].p, i + 1);
    break; }
  default: {
    fic_ref const *kid = (fic_ref const *)(o + 1);
    if (o->tag == FIC_TAG_CLOSURE) kid = (fic_ref const *)((const char *)kid + sizeof(void *));
    for (i = 0; i < o->nptr; i++) bad += fic_check_child(o, kid[i], i);
    break; }
  }
  return bad;
}
#endif

/* Call at the end of main (generated code does it under FIC_DROP_ALL and FIC_STATS). Returns 0 when everything is fine.
   FIC_DROP_ALL: checks the layout of every live object and frees them all (a leak test of the layout before, or in
   addition to, the counting); a nonzero result means a bad reference word or objects that could not be freed. */
static int fic_shutdown(void) {
  int bad = 0;
#ifdef FIC_DROP_ALL
  {
    size_t i, checked = 0, errors = 0;
    for (i = 0; i < fic_reg_cap; i++) if (fic_reg_tab[i] > FIC_REG_DEAD) { errors += fic_check_object((const fic_hdr *)fic_reg_tab[i]); checked++; }
    for (i = 0; i < fic_reg_cap; i++) if (fic_reg_tab[i] > FIC_REG_DEAD) { void *o = (void *)fic_reg_tab[i]; fic_reg_tab[i] = FIC_REG_DEAD; fic_reg_count--; fic_live_objects--;
#ifndef FIC_NO_POOL
      { unsigned c = ((fic_hdr *)o)->cls; if (c != 0) { *(void **)o = fic_free_list[c]; fic_free_list[c] = o; FIC_POISON((char *)o + 8, (size_t)c * 8 - 8); continue; } }
#endif
      free(o); }
    fprintf(stderr, "FIC_DROP_ALL: %zu objects checked, %zu bad, %zu live after the free\n", checked, errors, fic_live_objects);
    if (errors != 0 || fic_live_objects != 0) bad = 1;
    free(fic_reg_tab); fic_reg_tab = NULL; fic_reg_cap = fic_reg_used = fic_reg_count = 0;
  }
#endif
#ifdef FIC_STATS
  fprintf(stderr, "FIC_STATS: allocs %zu live %zu peak %zu dup %zu drop %zu free_slow %zu reuse_hit %zu reuse_miss %zu inplace %zu copied %zu pap_steal %zu clo_steal %zu\n",
          fic_total_allocs, fic_live_objects, fic_peak_live, fic_n_dup, fic_n_drop, fic_n_free_slow, fic_n_reuse_hit, fic_n_reuse_miss,
          fic_n_inplace, fic_n_copied, fic_n_pap_steal, fic_n_clo_steal);
#ifdef FIC_RC
  if (fic_live_objects != 0) bad = 1;          /* a counted program must have freed everything by now (the globals are dropped first) */
#endif
#endif
  free(fic_dstack); fic_dstack = NULL; fic_dtop = fic_dcap = 0;
  return bad;
}

/* ---- main on a big stack (STAGE4-PLAN 9.3, S6) -----------------------------------------
   A deep recursion that is not a tail call (a fold over a long list written by hand, a deep tree) needs C stack. The generated
   `main` runs the program (`fic_main`) on a thread with a stack of FIC_STACK_MB megabytes (default 1024; address space only, the
   pages are used on demand), where POSIX threads are available; if the thread cannot be made, and on other systems, or with
   -DFIC_NO_BIG_STACK, the program runs on the stack of `main`. Counts stay non-atomic: there is still one thread that runs Ficcus
   code. (Windows: not done yet, `CreateThread` with a stack size is the same idea.) */
#ifndef FIC_STACK_MB
#  define FIC_STACK_MB 1024
#endif
#if !defined(FIC_NO_BIG_STACK) && (defined(__unix__) || defined(__APPLE__))
#include <pthread.h>
static int (*fic_main_fn)(void);
static int fic_main_status;
static void *fic_main_thread(void *arg) { (void)arg; fic_main_status = fic_main_fn(); return NULL; }
static int fic_run_main(int (*f)(void)) {
  pthread_attr_t attr;
  pthread_t thread;
  fic_main_fn = f;
  if (pthread_attr_init(&attr) != 0) return f();
  if (pthread_attr_setstacksize(&attr, (size_t)FIC_STACK_MB << 20) != 0 || pthread_create(&thread, &attr, fic_main_thread, NULL) != 0) {
    pthread_attr_destroy(&attr);
    return f();
  }
  pthread_attr_destroy(&attr);
  if (pthread_join(thread, NULL) != 0) return 70;
  return fic_main_status;
}
#else
static int fic_run_main(int (*f)(void)) { return f(); }
#endif

/* ---- vectors (the Array standard library as a Vector) --------------------------------
   Parameters are owned (consumed) unless marked borrowed. An element is passed as a
   pointer to its bytes; for REF vectors the element is a fic_ref and ownership of that
   reference passes to the vector. */

static unsigned char *fic_vec_at(fic_ref v, int64_t i) { return FIC_VEC(v)->data + (size_t)i * FIC_VEC(v)->esize; }

static fic_ref fic_vec_new(int64_t cap, size_t esize, uint16_t tag) {
  fic_vec *v = (fic_vec *)fic_alloc(sizeof(fic_vec) + (size_t)cap * esize, tag, 0);
  v->len = 0; v->cap = cap; v->esize = esize;
  return &v->h;
}

static void fic_vec_dup_elems(fic_ref v, int64_t from, int64_t n) { /* count the copies of references */
  if (v->tag == FIC_TAG_VEC_REF) {
    int64_t i;
    for (i = 0; i < n; i++) fic_dup(((fic_ref *)FIC_VEC(v)->data)[from + i]);
  }
}

static fic_ref fic_vec_repeat(int64_t n, const void *x, size_t esize, uint16_t tag) {
  fic_ref v;
  int64_t i;
  if (n <= 0) { if (tag == FIC_TAG_VEC_REF) fic_drop(*(const fic_ref *)x); return fic_vec_new(0, esize, tag); }
  v = fic_vec_new(n, esize, tag);
  for (i = 0; i < n; i++) memcpy(fic_vec_at(v, i), x, esize);
  if (tag == FIC_TAG_VEC_REF) (*(const fic_ref *)x)->rc += (uint32_t)(n - 1);
  FIC_VEC(v)->len = n;
  return v;
}

static void *fic_vec_get(fic_ref v, int64_t i) {                /* borrowed in, borrowed out; NULL = Nothing */
  return (i >= 0 && i < FIC_VEC(v)->len) ? fic_vec_at(v, i) : NULL;
}

static fic_ref fic_vec_copy(fic_ref v) {                        /* v borrowed */
  fic_vec *p = FIC_VEC(v);
  fic_ref c = fic_vec_new(p->len, p->esize, v->tag);
  memcpy(FIC_VEC(c)->data, p->data, (size_t)p->len * p->esize);
  FIC_VEC(c)->len = p->len;
  fic_vec_dup_elems(c, 0, p->len);
  return c;
}

static fic_ref fic_vec_push(fic_ref v, const void *x) {         /* append one element; in place when unique with room */
  fic_vec *p = FIC_VEC(v);
  int64_t n = p->len + 1;
  if (v->rc != 1 || p->cap < n) {                               /* grow (amortized doubling) or copy */
    int64_t cap = p->len < 4 ? 4 : 2 * p->len;
    fic_ref r = fic_vec_new(cap, p->esize, v->tag);
    memcpy(FIC_VEC(r)->data, p->data, (size_t)p->len * p->esize);
    FIC_VEC(r)->len = p->len;
    if (v->rc == 1) fic_free_obj(v);                            /* moved: free the shell only */
    else { fic_vec_dup_elems(r, 0, p->len); v->rc--; }
    v = r; p = FIC_VEC(v);
  }
  memcpy(fic_vec_at(v, p->len), x, p->esize);
  p->len = n;
  return v;
}

static fic_ref fic_vec_unique(fic_ref v) {                      /* make v safe to update in place */
  if (v->rc == 1) return v;
  { fic_ref c = fic_vec_copy(v); v->rc--; return c; }
}

static fic_ref fic_vec_set(fic_ref v, int64_t i, const void *x) { /* in place when v is unique */
  if (i < 0 || i >= FIC_VEC(v)->len) { if (v->tag == FIC_TAG_VEC_REF) fic_drop(*(const fic_ref *)x); return v; }
  if (v->rc != 1) { fic_ref c = fic_vec_copy(v); v->rc--; v = c; }
  if (v->tag == FIC_TAG_VEC_REF) fic_drop(*(fic_ref *)fic_vec_at(v, i));
  memcpy(fic_vec_at(v, i), x, FIC_VEC(v)->esize);
  return v;
}

static int64_t fic_vec_index(int64_t i, int64_t len) {          /* Array.slice index rule */
  int64_t p = i < 0 ? len + i : i;
  return p < 0 ? 0 : (p > len ? len : p);
}

static fic_ref fic_vec_slice(fic_ref v, int64_t from, int64_t to) { /* v borrowed */
  fic_vec *p = FIC_VEC(v);
  int64_t a = fic_vec_index(from, p->len), b = fic_vec_index(to, p->len);
  fic_ref r;
  if (a > b) a = b;
  r = fic_vec_new(b - a, p->esize, v->tag);
  memcpy(FIC_VEC(r)->data, fic_vec_at(v, a), (size_t)(b - a) * p->esize);
  FIC_VEC(r)->len = b - a;
  fic_vec_dup_elems(r, 0, b - a);
  return r;
}

static fic_ref fic_vec_append(fic_ref a, fic_ref b) {           /* consumes both */
  fic_vec *pa = FIC_VEC(a), *pb = FIC_VEC(b);
  int64_t la = pa->len, n = pa->len + pb->len;
  fic_ref r;
  if (a->rc == 1 && pa->cap >= n) {
    r = a;                                                      /* room to grow in place */
  } else {
    r = fic_vec_new(n, pa->esize, a->tag);
    memcpy(FIC_VEC(r)->data, pa->data, (size_t)la * pa->esize);
    if (a->rc == 1) fic_free_obj(a);                            /* moved: free the shell only */
    else { fic_vec_dup_elems(r, 0, la); a->rc--; }
    FIC_VEC(r)->len = la;
  }
  memcpy(fic_vec_at(r, la), pb->data, (size_t)pb->len * pb->esize);
  fic_vec_dup_elems(r, la, pb->len);
  FIC_VEC(r)->len = n;
  fic_drop(b);
  return r;
}

#endif

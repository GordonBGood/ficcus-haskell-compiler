/* Standalone test of fic_jsarray.h (no closures: initialize, map, indexedMap, foldl and foldr are tested through the
   Elm examples against Elm itself). */
#include <stdio.h>
#include "fic_base.h"
#include "fic_closure.h"
#include "fic_jsarray.h"

static void show(const char *name, fic_ref a) {
  int64_t i;
  printf("%s [", name);
  for (i = 0; i < fic_ja_length(a); i++) printf(i ? " %lld" : "%lld", (long long)fic_ja_data(a)[i].i);
  printf("] tag %s\n", a->tag == FIC_TAG_VEC_RAW ? "raw" : "ref");
}

int main(void) {
  fic_ref e = fic_ja_empty(FIC_TAG_VEC_RAW), a = e;
  int64_t i;
  show("empty", e);
  for (i = 1; i <= 6; i++) a = fic_ja_push(fic_w_i(i * 10), a);
  show("pushed", a);
  show("empty unchanged", e);
  show("set 2", fic_ja_set(2, fic_w_i(99), a));
  show("original", a);
  show("singleton", fic_ja_singleton(FIC_TAG_VEC_RAW, fic_w_i(7)));
  show("slice 1 4", fic_ja_slice(1, 4, a));
  show("slice 0 100", fic_ja_slice(0, 100, a));
  show("slice -2 6", fic_ja_slice(-2, 6, a));
  show("slice 2 -1", fic_ja_slice(2, -1, a));
  show("slice 4 2", fic_ja_slice(4, 2, a));
  show("slice -100 2", fic_ja_slice(-100, 2, a));
  show("appendN 8", fic_ja_appendn(8, fic_ja_slice(0, 3, a), a));
  show("appendN 4", fic_ja_appendn(4, fic_ja_slice(0, 3, a), a));
  show("appendN 2", fic_ja_appendn(2, fic_ja_slice(0, 3, a), a));
  printf("get %lld %lld %lld\n", (long long)fic_ja_get(0, a).i, (long long)fic_ja_get(5, a).i, (long long)fic_ja_get(6, a).i);
  return 0;
}

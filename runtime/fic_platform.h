/* Ficcus effects (docs/EFFECTS-CHECK.md, slice E1): the platform objects that exist before the scheduler (E2, fic_sched.h).
 *
 * Cmd and Sub are one structure (Elm's Platform.js): a leaf (manager home, value), a batch (a list of bags) or a map (tagger, bag).
 * They are counted heap objects with the header convention (references first, nptr counts them). E1 only needs the empty batch:
 * `Cmd.none` and `Sub.none` (`batch []` in Elm) are one static immortal object, handed out as an owned reference (like the
 * primitive decoders of fic_json.h): a dup on the way out, so a drop by the receiver keeps the count at FIC_IMMORTAL. */
#ifndef FIC_PLATFORM_H
#define FIC_PLATFORM_H

#define FIC_TAG_BAG_NONE    0xFFD0u   /* the empty batch: no fields */

static fic_hdr fic_bag_none = { FIC_IMMORTAL, FIC_TAG_BAG_NONE, 0, 0 };

static FIC_UNUSED fic_ref fic_bag_none_ref(void) { fic_ref r = &fic_bag_none; FIC_RC_DUP(r); return r; }

/* E1 step 3, FIC_STATS: the counters of the runtime (fic_rt.h, fic_jsarray.h, fic_vector.h) between the entry and the exit of the typed
 * stepper (fic_app_step, generated): what the program's `update` and `subscriptions` did to the model. "copies" = copied + vec_copy:
 * an array or vector that was updated while shared. The D-fx-3 contract (G17): 0 for a model that nothing else holds. */
#ifdef FIC_STATS
static size_t fic_model_steps, fic_model_inplace, fic_model_copied, fic_model_vcopy, fic_model_reuse_miss;
static size_t fic_model_at[4];
static FIC_UNUSED void fic_model_enter(void) {
  fic_model_at[0] = fic_n_inplace; fic_model_at[1] = fic_n_copied; fic_model_at[2] = fic_n_vcopy; fic_model_at[3] = fic_n_reuse_miss;
}
static FIC_UNUSED void fic_model_leave(void) {
  fic_model_steps++;
  fic_model_inplace += fic_n_inplace - fic_model_at[0]; fic_model_copied += fic_n_copied - fic_model_at[1];
  fic_model_vcopy += fic_n_vcopy - fic_model_at[2]; fic_model_reuse_miss += fic_n_reuse_miss - fic_model_at[3];
}
static FIC_UNUSED void fic_model_report(void) {
  fprintf(stderr, "FIC_STATS model: steps %zu inplace %zu copied %zu vec_copy %zu reuse_miss %zu model_copies %zu\n",
          fic_model_steps, fic_model_inplace, fic_model_copied, fic_model_vcopy, fic_model_reuse_miss, fic_model_copied + fic_model_vcopy);
}
#endif

#endif

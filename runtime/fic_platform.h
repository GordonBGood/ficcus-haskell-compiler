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

#endif

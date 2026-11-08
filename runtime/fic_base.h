#include "ficrt.h"
#include <stdio.h>
#include <math.h>
#include <stdint.h>

#define FIC_TAG_STRING 0xFFF0u
#define FIC_TAG_BOX 0xFFF1u               /* a struct held where an unconstrained variable stands for it */
#define FIC_UNREACHABLE() abort()         /* a case of Elm is exhaustive */
typedef struct fic_string { fic_hdr h; int64_t len; char data[]; } fic_string;
#define FIC_STR(r) ((fic_string *)(r))

#define FIC_SUB64(a, b) ((int64_t)((uint64_t)(a) - (uint64_t)(b)))
#define FIC_NEG64(a) ((int64_t)(0u - (uint64_t)(a)))


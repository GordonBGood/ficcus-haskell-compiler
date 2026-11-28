/* fic_ports_api.h -- the C host interface of a Ficus program: its ports and its flags (effects slices E3a and E3b;
 * docs/E3-PORTS-DESIGN.md D1 to D4, D7, D8, D11, D12).
 *
 * This text is in two places: inside every generated program that has ports or flags (before runtime/fic_ports.h, which defines the
 * functions), and at the top of the generated `<Module>_ports.h`, which a host includes. Everything here is for the loop thread only
 * (the thread that runs the program); the thread safe entries come with E3e.
 *
 * Values (D1). A host value `fic_hv` is a Json.Value of the program (runtime/fic_json.h) behind an opaque handle: null, a Bool, an
 * Int (64 bit, exact: decision L21), a Float, a String (UTF-8), an array, an object (keys in JavaScript's order, L35). A Json.Value
 * payload crosses unchanged; every other payload is converted by the type directed code of the compiler, as Elm's ports do.
 * A .fic program's ports also carry the sized integers (range checked when they come in: a value outside the type's range does not
 * fit, it is never wrapped), Word64 up to 2^64 - 1 (fic_hv_uint), Float32 (any number, rounded), and Vector (E3c, E3d, D5, D6, D9).
 *
 * Ownership (D3). A function that returns a fic_hv returns an OWNED value (one count), except fic_hv_at and fic_hv_field, which
 * BORROW from their container. fic_port_send and the builders' setters CONSUME the value they are given (also when they fail);
 * fic_hv_finish consumes its argument and returns the sealed value. An outgoing callback BORROWS its value for the duration of the
 * call: to keep it, fic_hv_retain it, and fic_hv_release it later (on the loop thread). While a host holds a count, the program cannot
 * write that object in place: the host's view never changes.
 * Two host errors that nothing here can detect (E3a review N2):
 *   - do not write through the pointer of fic_hv_string_alloc after fic_hv_string_seal: the sealed string moves into the program
 *     when it is sent, and a late write changes a value of the program;
 *   - a callback must fic_hv_retain its borrowed value before it passes that value to fic_port_send (which consumes it): without
 *     the retain it gives away a count it does not own, and the value is freed twice later.
 *
 * Errors (D7). Each int result is FIC_OK or a negative code; nothing here exits the program. After a failure fic_port_error() gives
 * the text: for FIC_E_DECODE it is Elm's Json.Decode.errorToString of the error Elm's decoder would give (for flags, after Elm's
 * "Problem with the flags given to your Elm program on initialization." line). The text stays valid until the next failure.
 *
 * Re-entrancy (D12), as Elm: an outgoing callback may call fic_port_send (the update runs at once, nested, and its effects wait for
 * the dispatch in progress), and may subscribe or unsubscribe (a delivery works on the list of its moment; a callback added to the
 * port being delivered is called for the same value, as Elm's subscribe pushes onto the array being read).
 */
#ifndef FIC_PORTS_API_H
#define FIC_PORTS_API_H

#include <stddef.h>
#include <stdint.h>

typedef struct fic_hdr *fic_hv;                    /* opaque; NULL never denotes a value */

enum fic_hv_kind { FIC_HV_NULL, FIC_HV_BOOL, FIC_HV_INT, FIC_HV_FLOAT, FIC_HV_STRING, FIC_HV_ARRAY, FIC_HV_OBJECT,
                   FIC_HV_VECTOR,                  /* a raw vector of numbers (E3d; fic_hv_vector) */
                   FIC_HV_INVALID };               /* NULL, an unsealed builder, or not a host value */

enum { FIC_OK = 0,
       FIC_E_NO_PORT = -1,                         /* no reachable port of that name and direction */
       FIC_E_DECODE = -2,                          /* the value does not fit the port's (or the flags') type */
       FIC_E_INVALID = -3,                         /* a bad handle, an unsealed array or object, an index out of range, bad UTF-8 */
       FIC_E_STOPPED = -4,                         /* the program has ended (its effect state is released) */
       FIC_E_THREAD = -5 };                        /* reserved (E3e: a call from another thread) */

/* the element kinds of a raw vector (E3d, D9): a Vector of Int, Float or a sized type crosses as one, never as an array of nodes */
enum fic_el { FIC_EL_I8, FIC_EL_I16, FIC_EL_I32, FIC_EL_I64, FIC_EL_U8, FIC_EL_U16, FIC_EL_U32, FIC_EL_U64, FIC_EL_F32, FIC_EL_F64 };

/* build (each returns an OWNED value; NULL on bad input) */
fic_hv fic_hv_null(void);
fic_hv fic_hv_bool(int b);
fic_hv fic_hv_int(int64_t i);
fic_hv fic_hv_uint(uint64_t u);                                       /* E3c: above 2^63 - 1 a node that only Word64 and Float take */
fic_hv fic_hv_float(double d);
fic_hv fic_hv_string(const char *utf8, size_t n);                     /* copies; NULL if not valid UTF-8 (D4) */
fic_hv fic_hv_string_alloc(size_t n, char **p);                       /* a string of n bytes to fill at *p, then seal */
fic_hv fic_hv_string_seal(fic_hv s);                                  /* validates; NULL (and released) if not valid UTF-8 */
fic_hv fic_hv_array(size_t n);                                        /* n slots, each to set once before fic_hv_finish */
int    fic_hv_array_set(fic_hv a, size_t i, fic_hv v);                /* consumes v */
fic_hv fic_hv_object(size_t n);
int    fic_hv_object_set(fic_hv o, size_t i, const char *key, size_t kn, fic_hv v);   /* copies key, consumes v */
fic_hv fic_hv_finish(fic_hv v);   /* seals an array or object (object: L35 key order, a later duplicate key replaces the value at the
                                     place of the first); NULL (and released) if a slot was never set; other values pass through */

/* read (borrowed results, valid while the value is held) */
enum fic_hv_kind fic_hv_kind(fic_hv v);
int fic_hv_get_bool(fic_hv v, int *out);
int fic_hv_get_int(fic_hv v, int64_t *out);                           /* an Int, or a Float that is a whole number in range */
int fic_hv_get_uint(fic_hv v, uint64_t *out);                         /* E3c: a whole number from 0 to 2^64 - 1 */
int fic_hv_get_float(fic_hv v, double *out);                          /* any number */
const char *fic_hv_get_string(fic_hv v, size_t *n);                   /* UTF-8, NUL terminated; NULL if not a string */
size_t fic_hv_len(fic_hv v);                                          /* array, object or raw vector; 0 otherwise */
fic_hv fic_hv_at(fic_hv v, size_t i);                                 /* array element or object value; NULL if out of range (and
                                                                         for a raw vector: read it with fic_hv_vector) */
const char *fic_hv_key(fic_hv o, size_t i, size_t *n);
fic_hv fic_hv_field(fic_hv o, const char *key);                       /* NULL if absent */

/* raw vectors (E3d; D9, D10). Outgoing, a Vector of Int, Float or a sized type arrives as a FIC_HV_VECTOR value: fic_hv_vector gives
   its elements at their natural C width (int8_t .. uint64_t, float, double), borrowed like any read (retain the value to keep them).
   Int, Word64 and Float vectors are the program's own memory (zero copy); the narrow kinds are a copy made once by the encoder (D10,
   until G30). Incoming, fic_hv_vector_alloc returns a vector of n elements to fill at *data (all n, before the value is sent; do not
   write after sending), and a Vector port takes it when the element kind is the port's (zero copy for the 8 byte kinds, one widening
   pass for the others); a Vector port also takes a JSON array. Inside a Json.Value payload a raw vector becomes an array of numbers.
   WARNING: the *data pointer of fic_hv_vector_alloc is valid only until the value is sent. Reading it after fic_port_send is a use
   after free for the narrow kinds (the send frees the staging node); for the 8 byte kinds (zero copy) the memory becomes the
   program's, so a read is a use after free once the program drops the Vector, and a write silently changes the program's
   (immutable) value, unseen by any sanitizer. To keep reading, fic_hv_retain the value before sending and read through
   fic_hv_vector. */
fic_hv fic_hv_vector_alloc(enum fic_el elem, size_t n, void **data);
fic_hv fic_hv_vector_copy(enum fic_el elem, const void *data, size_t n);   /* fic_hv_vector_alloc and one memcpy */
const void *fic_hv_vector(fic_hv v, enum fic_el *elem, size_t *n);    /* NULL if v is not a raw vector */

/* counts */
fic_hv fic_hv_retain(fic_hv v);
void   fic_hv_release(fic_hv v);

/* JSON text (D8): JSON.parse and JSON.stringify */
fic_hv fic_hv_from_json(const char *text, size_t n);                  /* NULL if not valid JSON or not valid UTF-8; any depth; an
                                                                         integer literal above 2^63 - 1 as fic_hv_uint gives it */
char  *fic_hv_to_json(fic_hv v, size_t *n);                           /* malloc'd, NUL terminated; the host frees it; any depth */

/* ports (only in a program that has ports) */
typedef void (*fic_port_fn)(void *env, fic_hv v);                     /* v borrowed for the duration of the call */
int fic_port_subscribe(const char *port, fic_port_fn fn, void *env);  /* an outgoing port */
int fic_port_unsubscribe(const char *port, fic_port_fn fn, void *env);/* removes the first equal (fn, env) */
int fic_port_send(const char *port, fic_hv v);                        /* an incoming port; consumes v; runs the updates at once */
int fic_port_send_json(const char *port, const char *text, size_t n); /* fic_hv_from_json, then fic_port_send */
const char *fic_port_error(void);                                     /* the text of the last failure */

/* the program: decodes the flags (consumed; NULL = none given, JavaScript's undefined), runs init and the first dispatch, and
   returns; FIC_E_DECODE with Elm's crash 2 text when the flags do not fit (init does not run) */
int fic_app_start(fic_hv flags);

#endif /* FIC_PORTS_API_H */

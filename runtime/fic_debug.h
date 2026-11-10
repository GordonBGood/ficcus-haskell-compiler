/* Debug.toString of a String: quoted, with Elm's escapes */
static fic_ref fic_show_string(fic_ref s) {
  int64_t i, n = FIC_STR(s)->len, o = 0;
  char *buf = (char *)malloc((size_t)(n * 2 + 3));
  fic_ref r;
  buf[o++] = '"';
  for (i = 0; i < n; i++) {
    char c = FIC_STR(s)->data[i];
    if (c == '"' || c == '\\') { buf[o++] = '\\'; buf[o++] = c; }
    else if (c == '\n') { buf[o++] = '\\'; buf[o++] = 'n'; }
    else if (c == '\t') { buf[o++] = '\\'; buf[o++] = 't'; }
    else if (c == '\r') { buf[o++] = '\\'; buf[o++] = 'r'; }
    else if (c == '\v') { buf[o++] = '\\'; buf[o++] = 'v'; }
    else if (c == 0) { buf[o++] = '\\'; buf[o++] = '0'; }
    else buf[o++] = c;
  }
  buf[o++] = '"';
  r = fic_str_new(buf, o);
  free(buf);
  return r;
}

/* Debug.log: `tag: value` on its own line */
static void fic_log(fic_ref tag, fic_ref shown) {
  fwrite(FIC_STR(tag)->data, 1, (size_t)FIC_STR(tag)->len, stdout);
  fputs(": ", stdout);
  fwrite(FIC_STR(shown)->data, 1, (size_t)FIC_STR(shown)->len, stdout);
  fputc('\n', stdout);
}
/* a log of () prints `tag: ()` as Elm does (run_all.py strips the trailing `: ()` on both sides) */
static void fic_log_unit(fic_ref tag) {
  fwrite(FIC_STR(tag)->data, 1, (size_t)FIC_STR(tag)->len, stdout);
  fputs(": ()\n", stdout);
}

/* ---- Debug.toString for every type: a growing buffer, filled by generated per type functions (CGen HShow) ---- */
typedef struct fic_sb { char *p; int64_t n, cap; } fic_sb;

static void fic_sb_init(fic_sb *b) { b->cap = 64; b->n = 0; b->p = (char *)malloc((size_t)b->cap); if (b->p == NULL) abort(); }
static void fic_sb_putn(fic_sb *b, const char *s, int64_t k) {
  if (b->n + k > b->cap) {
    while (b->n + k > b->cap) b->cap *= 2;
    b->p = (char *)realloc(b->p, (size_t)b->cap);
    if (b->p == NULL) abort();
  }
  memcpy(b->p + b->n, s, (size_t)k);
  b->n += k;
}
static void fic_sb_puts(fic_sb *b, const char *s) { fic_sb_putn(b, s, (int64_t)strlen(s)); }
static fic_ref fic_sb_str(fic_sb *b) { fic_ref r = fic_str_new(b->p, b->n); free(b->p); b->p = NULL; return r; }

static void fic_sb_int(fic_sb *b, int64_t v) { fic_ref s = fic_str_from_int(v); fic_sb_putn(b, FIC_STR(s)->data, FIC_STR(s)->len); FIC_RC_DROP(s); }
static void fic_sb_float(fic_sb *b, double v) { fic_ref s = fic_str_from_float(v); fic_sb_putn(b, FIC_STR(s)->data, FIC_STR(s)->len); FIC_RC_DROP(s); }
static void fic_sb_string(fic_sb *b, fic_ref s) { fic_ref q = fic_show_string(s); fic_sb_putn(b, FIC_STR(q)->data, FIC_STR(q)->len); FIC_RC_DROP(q); }

/* a Char: 'x' with the escapes of Elm's addSlashes (backslash, \n \t \r \v \0 and the single quote) */
static void fic_sb_char(fic_sb *b, uint32_t c) {
  char u[4];
  int k;
  fic_sb_puts(b, "'");
  if (c == '\\') fic_sb_puts(b, "\\\\");
  else if (c == '\n') fic_sb_puts(b, "\\n");
  else if (c == '\t') fic_sb_puts(b, "\\t");
  else if (c == '\r') fic_sb_puts(b, "\\r");
  else if (c == '\v') fic_sb_puts(b, "\\v");
  else if (c == 0u) fic_sb_puts(b, "\\0");
  else if (c == '\'') fic_sb_puts(b, "\\'");
  else {
    if (c < 0x80u) { u[0] = (char)c; k = 1; }
    else if (c < 0x800u) { u[0] = (char)(0xC0u | (c >> 6)); u[1] = (char)(0x80u | (c & 0x3Fu)); k = 2; }
    else if (c < 0x10000u) { u[0] = (char)(0xE0u | (c >> 12)); u[1] = (char)(0x80u | ((c >> 6) & 0x3Fu)); u[2] = (char)(0x80u | (c & 0x3Fu)); k = 3; }
    else { u[0] = (char)(0xF0u | (c >> 18)); u[1] = (char)(0x80u | ((c >> 12) & 0x3Fu)); u[2] = (char)(0x80u | ((c >> 6) & 0x3Fu)); u[3] = (char)(0x80u | (c & 0x3Fu)); k = 4; }
    fic_sb_putn(b, u, k);
  }
  fic_sb_puts(b, "'");
}

/* the argument of a constructor that was written from `start`: in parentheses unless it starts with { ( [ < or " or has no space (Elm) */
static void fic_sb_wrap_arg(fic_sb *b, int64_t start) {
  char c0 = b->p[start];
  int64_t i;
  int plain = c0 == '{' || c0 == '(' || c0 == '[' || c0 == '<' || c0 == '"';
  if (!plain) { plain = 1; for (i = start; i < b->n; i++) if (b->p[i] == ' ') { plain = 0; break; } }
  if (plain) return;
  fic_sb_putn(b, "))", 2);                     /* room for both parentheses: the opening one overwrites a copy of the first byte */
  memmove(b->p + start + 1, b->p + start, (size_t)(b->n - 2 - start));
  b->p[start] = '(';
}

/* Debug.todo: Elm's kernel throws an Error with the module, the region and the message; here the message on stderr and exit 1
   (the module and the line are not known to the runtime yet) */
static void fic_todo(fic_ref msg) {
  fputs("TODO\n\n", stderr);
  fwrite(FIC_STR(msg)->data, 1, (size_t)FIC_STR(msg)->len, stderr);
  fputc('\n', stderr);
  exit(1);
}

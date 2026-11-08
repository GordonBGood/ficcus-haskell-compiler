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

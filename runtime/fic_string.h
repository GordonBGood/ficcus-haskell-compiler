static fic_ref fic_str_new(const char *p, int64_t n) {
  fic_string *s = (fic_string *)fic_alloc(sizeof(fic_string) + (size_t)n + 1, FIC_TAG_STRING, 0);
  s->len = n;
  if (n > 0) memcpy(s->data, p, (size_t)n);
  s->data[n] = 0;
  return &s->h;
}

static fic_ref fic_str_append(fic_ref a, fic_ref b) {
  int64_t la = FIC_STR(a)->len, lb = FIC_STR(b)->len;
  fic_string *s = (fic_string *)fic_alloc(sizeof(fic_string) + (size_t)(la + lb) + 1, FIC_TAG_STRING, 0);
  s->len = la + lb;
  memcpy(s->data, FIC_STR(a)->data, (size_t)la);
  memcpy(s->data + la, FIC_STR(b)->data, (size_t)lb);
  s->data[la + lb] = 0;
  return &s->h;
}

static uint8_t fic_str_eq(fic_ref a, fic_ref b) {
  return FIC_STR(a)->len == FIC_STR(b)->len && memcmp(FIC_STR(a)->data, FIC_STR(b)->data, (size_t)FIC_STR(a)->len) == 0;
}


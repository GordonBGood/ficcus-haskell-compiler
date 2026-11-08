static fic_ref fic_str_from_int(int64_t v) {
  char buf[32];
  int n = snprintf(buf, sizeof buf, "%lld", (long long)v);
  return fic_str_new(buf, n);
}

/* a Float as JavaScript's Number.prototype.toString: the shortest digits that read back exactly */
static int fic_fmt_float(double x, char *out) {
  char e[40], t[48], digits[32];
  int p, k = 0, n, exp10 = 0, o = 0, i;
  if (x != x) return sprintf(out, "NaN");
  if (x == 0) return sprintf(out, "0");
  if (x > 1.7976931348623157e308) return sprintf(out, "Infinity");
  if (x < -1.7976931348623157e308) return sprintf(out, "-Infinity");
  if (x < 0) { out[o++] = '-'; x = -x; }
  /* the fewest digits that read back as x; at p+1 digits the nearest decimal may not read back while its
     neighbour does (x a power of two: the gap below is half the gap above), and JavaScript takes that one */
  for (p = 0; p < 17; p++) {
    unsigned long long d; int ex, dl, delta, found = 0;
    snprintf(e, sizeof e, "%.*e", p, x);
    for (i = 0, d = 0; e[i] != 'e'; i++) if (e[i] != '.') d = d * 10 + (unsigned long long)(e[i] - '0');
    ex = atoi(e + i + 1);
    for (delta = 0; delta != 2 && !found; delta = (delta == 0 ? -1 : delta == -1 ? 1 : 2)) {
      unsigned long long d2 = d + (unsigned long long)(long long)delta;
      if (d2 == 0) continue;
      snprintf(t, sizeof t, "%llue%d", d2, ex - p);
      if (strtod(t, NULL) == x) {
        dl = snprintf(digits, sizeof digits, "%llu", d2);
        k = dl; exp10 = ex + (dl - (p + 1)); found = 1;
      }
    }
    if (found) break;
  }
  while (k > 1 && digits[k - 1] == '0') k--;
  n = exp10 + 1;
  if (k <= n && n <= 21) {
    memcpy(out + o, digits, (size_t)k); o += k;
    for (i = 0; i < n - k; i++) out[o++] = '0';
  } else if (0 < n && n <= 21) {
    memcpy(out + o, digits, (size_t)n); o += n; out[o++] = '.';
    memcpy(out + o, digits + n, (size_t)(k - n)); o += k - n;
  } else if (-6 < n && n <= 0) {
    out[o++] = '0'; out[o++] = '.';
    for (i = 0; i < -n; i++) out[o++] = '0';
    memcpy(out + o, digits, (size_t)k); o += k;
  } else {
    out[o++] = digits[0];
    if (k > 1) { out[o++] = '.'; memcpy(out + o, digits + 1, (size_t)(k - 1)); o += k - 1; }
    o += sprintf(out + o, "e%c%d", n - 1 < 0 ? '-' : '+', n - 1 < 0 ? 1 - n : n - 1);
  }
  out[o] = 0;
  return o;
}

static fic_ref fic_str_from_float(double x) {
  char buf[64];
  int n = fic_fmt_float(x, buf);
  return fic_str_new(buf, n);
}


/* E3a review: the C side of ref/drive.js. FIC_SCRIPT names a file of lines `<port> <JSON>`, each sent with fic_port_send_json;
   a refusal prints fic_port_error(). Outgoing `out` is printed as `out: <text>`. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fic_ports_api.h"

static void cb(void *env, fic_hv v) { size_t n; const char *s = fic_hv_get_string(v, &n); (void)env; fputs("out: ", stdout); fwrite(s, 1, n, stdout); fputc(10, stdout); }

int drive_main(void) {
  FILE *f = fopen(getenv("FIC_SCRIPT"), "r");
  char *line = NULL;
  size_t cap = 0;
  ssize_t got;
  if (f == NULL || fic_app_start(NULL) != FIC_OK) return 2;
  fic_port_subscribe("out", cb, NULL);
  while ((got = getline(&line, &cap, f)) > 0) {
    char *sp;
    int rc;
    if (line[got - 1] == '\n') line[--got] = 0;
    if (got == 0) continue;
    sp = strchr(line, ' ');
    *sp = 0;
    rc = fic_port_send_json(line, sp + 1, strlen(sp + 1));
    if (rc == FIC_OK) printf("%s: ok\n", line);
    else if (rc == FIC_E_DECODE && strncmp(fic_port_error(), "Problem with the given value:\n\n\"", 31) == 0 && strstr(fic_port_error(), "This is not valid JSON") != NULL) printf("%s: not JSON\n", line);
    else printf("%s: FAIL %s\n", line, fic_port_error());
  }
  free(line);
  fclose(f);
  return 0;
}

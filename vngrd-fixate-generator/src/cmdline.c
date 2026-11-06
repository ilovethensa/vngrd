/* cmdline.c — token comparison, split from main for tests. The token cap bounds
 * memory on untrusted input.
 */

#define _GNU_SOURCE

#include "cmdline.h"

#include "diagnose.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CMDLINE_MAX_TOKENS 4096

struct tokens {
        char *v[CMDLINE_MAX_TOKENS];
        size_t n;
};

static int split_tokens(char *buf, struct tokens *t) {
        char *p = buf;

        t->n = 0;
        while (*p) {
                while (*p && isspace((unsigned char) *p))
                        p++;
                if (!*p)
                        break;
                if (t->n == CMDLINE_MAX_TOKENS) {
                        diagnose("vngrd-cmdline-guard: more than %d command line tokens, refusing.",
                                 CMDLINE_MAX_TOKENS);
                        return -1;
                }
                t->v[t->n++] = p;
                while (*p && !isspace((unsigned char) *p))
                        p++;
                if (*p)
                        *p++ = '\0';
        }
        return 0;
}

static int cmp_str(const void *a, const void *b) {
        return strcmp(*(char *const *) a, *(char *const *) b);
}

/* Non-console tokens must match in count. console= may repeat: the stub appends
 * them only when the signed line has none, which this image never does. */
static int compare_lists(struct tokens *signed_tokens, struct tokens *live_tokens, const char **first_difference) {
        size_t s = 0, l = 0;

        while (s < signed_tokens->n || l < live_tokens->n) {
                const char *t;

                if (l >= live_tokens->n || (s < signed_tokens->n
                                            && strcmp(signed_tokens->v[s], live_tokens->v[l]) <= 0))
                        t = signed_tokens->v[s];
                else
                        t = live_tokens->v[l];

                size_t cs = 0, cl = 0;
                while (s + cs < signed_tokens->n && strcmp(signed_tokens->v[s + cs], t) == 0)
                        cs++;
                while (l + cl < live_tokens->n && strcmp(live_tokens->v[l + cl], t) == 0)
                        cl++;

                if (strncmp(t, "console=", 8) == 0) {
                        /* Missing console= is still a modification. */
                        if (cl < cs) {
                                *first_difference = t;
                                return -1;
                        }
                } else if (cs != cl) {
                        *first_difference = t;
                        return -1;
                }

                s += cs;
                l += cl;
        }
        return 0;
}

/* /proc files report st_size 0, so read until EOF. */
static char *read_whole_file(const char *path, int *absent) {
        FILE *f;
        char *buf = NULL;
        size_t size = 0, len = 0;
        int saved;

        *absent = 0;
        f = fopen(path, "r");
        if (!f) {
                if (errno == ENOENT)
                        *absent = 1;
                return NULL;
        }

        for (;;) {
                size_t n;

                if (len + 512 > size) {
                        char *grown;
                        size_t want = size ? size * 2 : 1024;

                        grown = realloc(buf, want);
                        if (!grown) {
                                saved = errno;
                                free(buf);
                                fclose(f);
                                errno = saved;
                                return NULL;
                        }
                        buf = grown;
                        size = want;
                }
                n = fread(buf + len, 1, size - len - 1, f);
                if (n == 0)
                        break;
                len += n;
        }
        if (ferror(f)) {
                saved = errno;
                free(buf);
                fclose(f);
                errno = saved;
                return NULL;
        }
        fclose(f);

        if (!buf) {
                /* Empty is a real answer, not an error. */
                buf = malloc(1);
                if (!buf)
                        return NULL;
        }
        buf[len] = '\0';
        return buf;
}

int cmdline_verify(const char *signed_path, const char *live_path, const char **first_difference) {
        char *signed_buf = NULL, *live_buf = NULL;
        struct tokens signed_tokens, live_tokens;
        int absent = 0, r, ret;

        if (first_difference)
                *first_difference = NULL;

        signed_buf = read_whole_file(signed_path, &absent);
        if (!signed_buf) {
                diagnose("vngrd-cmdline-guard: cannot read %s: %s", signed_path,
                         absent ? "the signed UKI carries no command line" : strerror(errno));
                return 2;
        }

        live_buf = read_whole_file(live_path, &absent);
        if (!live_buf) {
                diagnose("vngrd-cmdline-guard: cannot read %s: %s", live_path,
                         absent ? "no such file" : strerror(errno));
                free(signed_buf);
                return 2;
        }

        r = split_tokens(signed_buf, &signed_tokens);
        if (r == 0)
                r = split_tokens(live_buf, &live_tokens);
        if (r < 0) {
                free(signed_buf);
                free(live_buf);
                return 2;
        }

        qsort(signed_tokens.v, signed_tokens.n, sizeof(char *), cmp_str);
        qsort(live_tokens.v, live_tokens.n, sizeof(char *), cmp_str);

        /* Empty signed line is a malformed UKI, not a pass. */
        if (signed_tokens.n == 0) {
                diagnose("vngrd-cmdline-guard: %s is empty; the signed UKI carries no command line",
                         signed_path);
                free(signed_buf);
                free(live_buf);
                return 2;
        }

        r = compare_lists(&signed_tokens, &live_tokens, first_difference);
        ret = r < 0 ? 1 : 0;

        free(signed_buf);
        free(live_buf);
        return ret;

}

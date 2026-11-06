/* passphrase-main.c — prompt, then exec systemd-cryptenroll.
 *
 * Usage:
 *   vngrd-passphrase --new [--min-length=N] -- PROGRAM [ARGS...]
 *   vngrd-passphrase --current -- PROGRAM [ARGS...]
 *
 * --new sets NEWPASSWORD (cryptenroll --password), --current sets PASSWORD (the
 * unlock passphrase). Never in argv, stdout or a file; cryptenroll erases the
 * environment value with getenv_steal_erase().
 */

#define _GNU_SOURCE

#include "passphrase.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void usage(const char *argv0) {
        fprintf(stderr,
                "usage: %s --new [--min-length=N] -- PROGRAM [ARGS...]\n"
                "       %s --current -- PROGRAM [ARGS...]\n"
                "\n"
                "Prompts on the ask-password console, validates the value, and execs\n"
                "PROGRAM with NEWPASSWORD (--new) or PASSWORD (--current) set.\n",
                argv0, argv0);
}

int main(int argc, char **argv) {
        enum { MODE_NONE, MODE_NEW, MODE_CURRENT } mode = MODE_NONE;
        size_t min_len = VNGRD_PASSPHRASE_MIN;
        int separator = -1;

        for (int i = 1; i < argc; i++) {
                const char *a = argv[i];

                if (strcmp(a, "--") == 0) {
                        separator = i;
                        break;
                }
                if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
                        usage(argv[0]);
                        return 0;
                }
                if (strcmp(a, "--new") == 0) {
                        if (mode != MODE_NONE) {
                                fprintf(stderr, "vngrd-passphrase: choose one of --new/--current\n");
                                return 2;
                        }
                        mode = MODE_NEW;
                } else if (strcmp(a, "--current") == 0) {
                        if (mode != MODE_NONE) {
                                fprintf(stderr, "vngrd-passphrase: choose one of --new/--current\n");
                                return 2;
                        }
                        mode = MODE_CURRENT;
                } else if (strncmp(a, "--min-length=", 13) == 0) {
                        char *end = NULL;
                        errno = 0;
                        unsigned long v = strtoul(a + 13, &end, 10);
                        if (errno != 0 || end == a + 13 || *end != '\0' ||
                            v < 1 || v >= VNGRD_PASSPHRASE_MAX) {
                                fprintf(stderr, "vngrd-passphrase: invalid --min-length\n");
                                return 2;
                        }
                        min_len = (size_t) v;
                } else {
                        fprintf(stderr, "vngrd-passphrase: unknown argument '%s'\n", a);
                        usage(argv[0]);
                        return 2;
                }
        }

        if (mode == MODE_NONE || separator < 0 || separator + 1 >= argc) {
                usage(argv[0]);
                return 2;
        }

        char **program_argv = &argv[separator + 1];
        const char *program = program_argv[0];
        if (program[0] != '/') {
                fprintf(stderr,
                        "vngrd-passphrase: PROGRAM must be an absolute path (got '%s')\n",
                        program);
                return 2;
        }

        char *pass = NULL;
        int r = mode == MODE_NEW ? passphrase_prompt_new(&pass, min_len)
                                 : passphrase_prompt_current(&pass);
        if (r < 0)
                return 1;

        const char *variable = mode == MODE_NEW ? "NEWPASSWORD" : "PASSWORD";
        if (setenv(variable, pass, 1) < 0) {
                fprintf(stderr, "vngrd-passphrase: setenv: %s\n", strerror(errno));
                passphrase_free(pass);
                return 1;
        }

        /* setenv() copied it; erase our copy. On exec failure also unset the
         * environment entry. */
        passphrase_free(pass);

        execv(program, program_argv);
        int saved = errno;
        unsetenv(variable);
        fprintf(stderr, "vngrd-passphrase: exec %s: %s\n", program, strerror(saved));
        return 1;
}

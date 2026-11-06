/* cmdline-main.c — compare the booted command line with the signed one.
 *
 * systemd-stub appends io.systemd.stub.kernel-cmdline-extra= from SMBIOS Type 11
 * after the signed .cmdline, so a second usrhash= can win (last occurrence
 * wins). The stub is patched to drop those under Secure Boot and to expose the
 * signed line as /.extra/signed-cmdline; this is the independent check.
 *
 * Exit: 0 match, 1 differ, 2 unreadable/empty. 2 must not mean "skip": a stripped
 * UKI would otherwise bypass the check. Mismatch is printed via diagnose() and
 * the unit's FailureAction=reboot-force acts on it.
 */

#define _GNU_SOURCE

#include "cmdline.h"
#include "diagnose.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define VNGRD_SIGNED_CMDLINE "/.extra/signed-cmdline"
#define VNGRD_LIVE_CMDLINE   "/proc/cmdline"

static void usage(FILE *out) {
        fprintf(out, "vngrd-cmdline-guard [SIGNED-CMDLINE-FILE [LIVE-CMDLINE-FILE]]\n"
                     "  defaults: %s and %s\n"
                     "  exit 0: the live command line is the signed one\n"
                     "  exit 1: they differ\n"
                     "  exit 2: a file could not be read, or the signed command line\n"
                     "           is absent or empty\n",
                VNGRD_SIGNED_CMDLINE, VNGRD_LIVE_CMDLINE);
}

int main(int argc, char **argv) {
        const char *signed_path = VNGRD_SIGNED_CMDLINE;
        const char *live_path = VNGRD_LIVE_CMDLINE;
        const char *difference = NULL;
        int positional = 0, r;

        for (int i = 1; i < argc; i++) {
                if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                        usage(stdout);
                        return 0;
                } else if (argv[i][0] != '-') {
                        positional++;
                        if (positional == 1)
                                signed_path = argv[i];
                        else if (positional == 2)
                                live_path = argv[i];
                        else {
                                fprintf(stderr, "vngrd-cmdline-guard: unexpected argument: %s\n", argv[i]);
                                usage(stderr);
                                return 2;
                        }
                } else {
                        fprintf(stderr, "vngrd-cmdline-guard: unknown argument: %s\n", argv[i]);
                        usage(stderr);
                        return 2;
                }
        }

        r = cmdline_verify(signed_path, live_path, &difference);
        if (r == 1) {
                diagnose("vngrd-cmdline-guard: the kernel command line is not the one the signed UKI carries.");
                diagnose("vngrd-cmdline-guard: first disagreeing parameter: %s", difference);
                diagnose("vngrd-cmdline-guard: signed: %s", signed_path);
                diagnose("vngrd-cmdline-guard: live:   %s", live_path);
        }
        return r;
}

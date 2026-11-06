/* test-cmdline.c — check the command line comparison, case by case.
 *
 * This runs on every boot of every machine as vngrd-cmdline-guard.service, and a
 * wrong answer in either direction is expensive: a false mismatch turns every
 * machine into a reboot loop (FailureAction=reboot-force), and a false match is
 * the exact hole the check exists for -- an SMBIOS Type 11 cmdline-extra appending
 * a second usrhash= to a signed command line, which the kernel and
 * systemd-veritysetup-generator both resolve as the last one winning.
 *
 * The cases below are the ones that matter, including the two that are easy to
 * get backwards:
 *
 *   - the attack itself: the same signed line with an extra usrhash= appended,
 *     which is what a host-injected SMBIOS string produces. Must be 1.
 *   - the only difference that is NOT an attack: a surplus console= token, which
 *     is what the stub itself appends when the signed command line has none
 *     (cmdline_append_console(), src/boot/console.c). Must be 0.
 *
 * Build: make test
 */

#define _GNU_SOURCE

#include "cmdline.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;

static void write_file(const char *path, const char *content) {
        FILE *f = fopen(path, "we");
        if (f == NULL) {
                perror(path);
                exit(1);
        }
        fputs(content, f);
        fclose(f);
}

static void check_case(const char *what, const char *signed_cmdline, const char *live_cmdline, int want) {
        const char *signed_path = "/tmp/vngrd-test-signed-cmdline";
        const char *live_path = "/tmp/vngrd-test-live-cmdline";
        const char *difference = NULL;
        int got;

        write_file(signed_path, signed_cmdline ? signed_cmdline : "");
        write_file(live_path, live_cmdline ? live_cmdline : "");

        got = cmdline_verify(signed_path, live_path, &difference);
        if (got == want) {
                printf("  ok   %s\n", what);
                return;
        }
        printf("  FAIL %s\n    want: %d\n    got:  %d (first difference: %s)\n",
               what, want, got, difference ? difference : "(none)");
        failures++;
}

int main(void) {
        /* This image's signed command line, verbatim from mkosi.conf. */
        static const char *signed_line =
                "usrhash=3d198fee1595ecaffc94d0f0cd6148b723730f1f9fbbe52f4e0bdcaa64f26d57 "
                "root=/dev/mapper/vngrd-root rw fstab=0 systemd.verity=yes "
                "lockdown=integrity console=tty0 console=ttyS0,115200";

        printf("test-cmdline: command line comparison\n");

        check_case("identical", signed_line, signed_line, 0);

        /* The attack. Same line, an SMBIOS-injected usrhash= appended last: the
         * last occurrence is the one every consumer takes. */
        check_case("appended usrhash (the SMBIOS attack)",
                   signed_line,
                   "usrhash=3d198fee1595ecaffc94d0f0cd6148b723730f1f9fbbe52f4e0bdcaa64f26d57 "
                   "root=/dev/mapper/vngrd-root rw fstab=0 systemd.verity=yes "
                   "lockdown=integrity console=tty0 console=ttyS0,115200 "
                   "usrhash=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                   1);

        /* Same parameter, different value. */
        check_case("different usrhash",
                   signed_line,
                   "usrhash=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff "
                   "root=/dev/mapper/vngrd-root rw fstab=0 systemd.verity=yes "
                   "lockdown=integrity console=tty0 console=ttyS0,115200",
                   1);

        /* A token that is not on the signed line at all. */
        check_case("unexpected init=",
                   signed_line,
                   "usrhash=3d198fee1595ecaffc94d0f0cd6148b723730f1f9fbbe52f4e0bdcaa64f26d57 "
                   "root=/dev/mapper/vngrd-root rw fstab=0 systemd.verity=yes "
                   "lockdown=integrity console=tty0 console=ttyS0,115200 init=/bin/sh",
                   1);

        /* A signed token missing from the live line. */
        check_case("lockdown dropped",
                   signed_line,
                   "usrhash=3d198fee1595ecaffc94d0f0cd6148b723730f1f9fbbe52f4e0bdcaa64f26d57 "
                   "root=/dev/mapper/vngrd-root rw fstab=0 systemd.verity=yes "
                   "console=tty0 console=ttyS0,115200",
                   1);

        /* console= is the one token the stub adds by itself, so surplus is not a
         * modification. */
        check_case("surplus console= tolerated",
                   signed_line,
                   "usrhash=3d198fee1595ecaffc94d0f0cd6148b723730f1f9fbbe52f4e0bdcaa64f26d57 "
                   "root=/dev/mapper/vngrd-root rw fstab=0 systemd.verity=yes "
                   "lockdown=integrity console=tty0 console=ttyS0,115200 console=hvc0",
                   0);

        /* ...but losing a console= token is. */
        check_case("console= token removed",
                   signed_line,
                   "usrhash=3d198fee1595ecaffc94d0f0cd6148b723730f1f9fbbe52f4e0bdcaa64f26d57 "
                   "root=/dev/mapper/vngrd-root rw fstab=0 systemd.verity=yes "
                   "lockdown=integrity console=ttyS0,115200",
                   1);

        /* Order is not meaning. The kernel resolves parameters by last
         * occurrence, and none of these repeat, so a reordered line is the same
         * line. */
        check_case("tokens reordered",
                   signed_line,
                   "console=tty0 console=ttyS0,115200 lockdown=integrity systemd.verity=yes "
                   "rw fstab=0 root=/dev/mapper/vngrd-root "
                   "usrhash=3d198fee1595ecaffc94d0f0cd6148b723730f1f9fbbe52f4e0bdcaa64f26d57",
                   0);

        /* Whitespace is not meaning either: the stub's mangle_stub_cmdline()
         * normalises runs of it into single spaces. */
        check_case("whitespace normalised",
                   "usrhash=aaa root=/dev/mapper/vngrd-root",
                   "  usrhash=aaa   root=/dev/mapper/vngrd-root\n",
                   0);

        /* An empty signed command line is a malformed UKI, not a pass. This image
         * always carries a .cmdline section, so there is no supported boot with
         * nothing signed. */
        check_case("signed line is empty (no .cmdline section)",
                   "",
                   "usrhash=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff "
                   "root=/dev/mapper/vngrd-root",
                   2);

        check_case("both empty", "", "", 2);

        /* The signed file is absent entirely: same answer, and the case the unit
         * used to skip with ConditionPathExists=. */
        {
                const char *difference = NULL;
                int got;

                unlink("/tmp/vngrd-test-signed-cmdline-absent");
                write_file("/tmp/vngrd-test-live-cmdline", signed_line);
                got = cmdline_verify("/tmp/vngrd-test-signed-cmdline-absent",
                                     "/tmp/vngrd-test-live-cmdline",
                                     &difference);
                if (got == 2) {
                        printf("  ok   missing signed command line is not a pass\n");
                } else {
                        printf("  FAIL missing signed command line is not a pass (got %d)\n", got);
                        failures++;
                }
        }

        /* A /proc/cmdline that cannot be read is not a match. */
        {
                const char *difference = NULL;
                int got = cmdline_verify("/tmp/vngrd-test-signed-cmdline",
                                         "/tmp/vngrd-test-live-cmdline-does-not-exist",
                                         &difference);
                if (got == 2) {
                        printf("  ok   missing live command line is not a match\n");
                } else {
                        printf("  FAIL missing live command line is not a match (got %d)\n", got);
                        failures++;
                }
        }

        if (failures == 0) {
                printf("test-cmdline: all cases pass\n");
                return 0;
        }
        printf("test-cmdline: %d failure(s)\n", failures);
        return 1;
}

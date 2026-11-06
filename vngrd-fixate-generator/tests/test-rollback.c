/* test-rollback.c — the version -> rollback index encoding.
 *
 * Pure arithmetic, but it is the arithmetic that decides whether a boot proceeds,
 * so the cases that must be refused are as important as the ones that must work.
 * The one worth naming: 0.10 and 1.0 both pack to 100, so 0.10 is REFUSED rather
 * than silently treated as 1.0. A guard that accepted it would let a machine that
 * had run 1.0 go back to 0.10 while believing it had gone forward.
 *
 * rollback.o reaches nvindex.o and nvwrite.o through its other two functions, so
 * those are linked, but nothing here calls them and no TPM is touched.
 *
 * Build: make test
 */

#define _GNU_SOURCE

#include "rollback.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;

static void expect_index(const char *version, int want_ok, uint32_t want) {
        uint32_t got = 0xdeadbeefu;
        int rc = rollback_index_from_version(version, &got);

        if (want_ok && rc == 0 && got == want) {
                printf("  ok   '%s' -> %u\n", version, want);
                return;
        }
        if (!want_ok && rc != 0) {
                printf("  ok   '%s' refused\n", version);
                return;
        }
        printf("  FAIL '%s' (want_ok=%d want=%u, got rc=%d value=%u)\n",
               version, want_ok, want, rc, got);
        failures++;
}

static void write_file(const char *path, const char *content) {
        FILE *f = fopen(path, "we");
        if (f == NULL) {
                perror(path);
                exit(1);
        }
        fputs(content, f);
        fclose(f);
}

static void expect_osrelease(const char *content, int want_ok, uint32_t want) {
        const char *path = "/tmp/vngrd-test-os-release";
        uint32_t got = 0xdeadbeefu;
        int rc;

        write_file(path, content);
        rc = rollback_index_from_os_release(path, &got);

        if (want_ok && rc == 0 && got == want) {
                printf("  ok   os-release -> %u\n", want);
                return;
        }
        if (!want_ok && rc != 0) {
                printf("  ok   os-release refused\n");
                return;
        }
        printf("  FAIL os-release (want_ok=%d want=%u, got rc=%d value=%u)\n",
               want_ok, want, rc, got);
        failures++;
}

int main(void) {
        printf("test-rollback: version encoding\n");

        /* The releases this project actually ships, in order. */
        expect_index("0.1", 1, 10);
        expect_index("0.2", 1, 20);
        expect_index("0.9", 1, 90);
        expect_index("1.0", 1, 100);
        expect_index("1.1", 1, 110);
        expect_index("2.3", 1, 230);
        expect_index("2.3.4", 1, 234);
        expect_index("10.0", 1, 1000);

        /* The collision the encoding exists to refuse: 0.10 would equal 1.0. */
        expect_index("0.10", 0, 0);
        expect_index("0.1.10", 0, 0);
        expect_index("0.0.10", 0, 0);

        /* Version 0 packs to the "no floor" sentinel and must be refused. */
        expect_index("0", 0, 0);
        expect_index("0.0", 0, 0);
        expect_index("0.0.0", 0, 0);

        /* Grammar. */
        expect_index("", 0, 0);
        expect_index(".1", 0, 0);
        expect_index("1.", 0, 0);
        expect_index("1..2", 0, 0);
        expect_index("1.2.3.4", 0, 0);
        expect_index("0.1-rc1", 0, 0);
        expect_index("v0.1", 0, 0);
        expect_index("-1", 0, 0);
        expect_index(" 0.1", 0, 0);

        /* Monotonic over the shipping sequence, which is the whole property. */
        {
                static const char *seq[] = { "0.1", "0.2", "0.3", "0.9", "1.0", "1.1", "2.0" };
                uint32_t prev = 0;
                int monotonic = 1;
                for (size_t i = 0; i < sizeof(seq) / sizeof(seq[0]); i++) {
                        uint32_t v = 0;
                        if (rollback_index_from_version(seq[i], &v) != 0 || v <= prev)
                                monotonic = 0;
                        prev = v;
                }
                if (monotonic)
                        printf("  ok   strictly increasing over the release sequence\n");
                else {
                        printf("  FAIL not strictly increasing\n");
                        failures++;
                }
        }

        /* os-release parsing, including the quoting and the missing key. */
        expect_osrelease("NAME=vngrd\nIMAGE_VERSION=0.1\nVERSION_ID=0.1\n", 1, 10);
        expect_osrelease("IMAGE_VERSION=\"0.2\"\n", 1, 20);
        expect_osrelease("NAME=vngrd\n", 0, 0);
        expect_osrelease("IMAGE_VERSION=garbage\n", 0, 0);

        if (failures != 0) {
                printf("test-rollback: %d FAILED\n", failures);
                return 1;
        }
        printf("test-rollback: all cases pass\n");
        return 0;
}

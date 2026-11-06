/* test-passphrase.c — the checks that stand between an operator and a weak
 * recovery keyslot.
 *
 * The prompt itself is an ask-password agent and is exercised by the boot tier;
 * this test covers the decisions, which are the part that can silently regress.
 */

#include "passphrase.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void expect(int condition, const char *what) {
        if (condition)
                return;
        fprintf(stderr, "test-passphrase: FAIL: %s\n", what);
        failures++;
}

int main(void) {
        /* The harness's fixed test passphrase. It is 43 characters and must keep
         * passing; a minimum that rejects it would break provisioning before any
         * boot assertion ran. */
        const char *good = "vngrd-test-recovery-passphrase-0123456789";
        expect(passphrase_quality_reason(good, VNGRD_PASSPHRASE_MIN) == NULL,
               "the test recovery passphrase must pass");

        expect(passphrase_quality_reason("short", VNGRD_PASSPHRASE_MIN) != NULL,
               "a short passphrase must be refused");
        expect(passphrase_quality_reason("", VNGRD_PASSPHRASE_MIN) != NULL,
               "an empty passphrase must be refused");
        expect(passphrase_quality_reason(NULL, VNGRD_PASSPHRASE_MIN) != NULL,
               "a NULL passphrase must be refused");

        /* Exactly the floor is accepted; one below it is not. */
        expect(passphrase_quality_reason("abcdEFGH1234wxyz", 16) == NULL,
               "exactly 16 distinct characters must pass");
        expect(passphrase_quality_reason("abcdEFGH1234wxy", 16) != NULL,
               "15 characters must fail a 16-character floor");

        expect(passphrase_quality_reason("                ", VNGRD_PASSPHRASE_MIN) != NULL,
               "whitespace-only must be refused");
        expect(passphrase_quality_reason("aaaaaaaaaaaaaaaa", VNGRD_PASSPHRASE_MIN) != NULL,
               "a low-diversity passphrase must be refused");
        expect(passphrase_quality_reason("abcdabcdabcdabcd", VNGRD_PASSPHRASE_MIN) == NULL,
               "four distinct characters meet the distinct-count floor");

        expect(passphrase_quality_reason("valid passphrase\nwith newline", VNGRD_PASSPHRASE_MIN) != NULL,
               "control characters must be refused");
        expect(passphrase_quality_reason("valid passphrase\twith tab", VNGRD_PASSPHRASE_MIN) != NULL,
               "a tab is a control character and must be refused");

        /* A trailing/leading space is part of the secret, not something to trim. */
        expect(passphrase_quality_reason(" vngrd-test-recovery-passphrase-0123 ",
                                         VNGRD_PASSPHRASE_MIN) == NULL,
               "spaces inside or around a long passphrase are allowed");

        if (failures != 0) {
                fprintf(stderr, "test-passphrase: %d failure(s)\n", failures);
                return 1;
        }
        printf("test-passphrase: ok\n");
        return 0;
}

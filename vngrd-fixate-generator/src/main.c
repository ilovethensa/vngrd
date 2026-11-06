/* main.c — vngrd-fixate-generator.
 *
 * A systemd generator: if a fixate digest is frozen in TPM NV, make
 * systemd-cryptsetup check the volume key against it. The digest is
 * hex(HMAC-SHA256(volume_key, "cryptsetup:<name>:<uuid>")), so it binds the
 * volume name, UUID and key; cryptsetup compares it before activating
 * (cryptsetup.c:1109-1127).
 *
 * The check is written as a unit drop-in because the crypttab options are the
 * only input and /etc is read-only to generators. Alternatives are rejected in
 * fixate.h.
 *
 * No index means no expected value: stay silent and write nothing. A present
 * index that cannot be honoured is reported, and vngrd-fixate-guard refuses the
 * absent-register case on a provisioned machine.
 */

#define _GNU_SOURCE

#include "fixate.h"
#include "diagnose.h"
#include "nvindex.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Matches the crypttab and EncryptedVolume= name. The digest covers the name,
 * so changing it invalidates every stored value; base-files/build asserts they
 * still agree. */
#define VNGRD_VOLUME "vngrd-root"

#define VNGRD_CRYPTTAB "/etc/crypttab"
#define VNGRD_DROPIN_DIR "/run/systemd/generator"
#define VNGRD_TCTI "device:/dev/tpmrm0"

/* Generators also run on the host, where the root is already mounted and a
 * drop-in would never start. /etc/initrd-release is the conventional test. */
static bool in_initrd(void) {
        return access("/etc/initrd-release", F_OK) == 0;
}

static void usage(const char *argv0) {
        fprintf(stderr,
                "usage: %s [OPTIONS] [OUTPUT-DIRECTORY]...\n"
                "\n"
                "A systemd generator. systemd invokes it as\n"
                "    %s NORMAL-DIR [EARLY-DIR [LATE-DIR]]\n"
                "and those directories are where the unit drop-in is written; see\n"
                "DEFINE_MAIN_GENERATOR_FUNCTION (generator.h:107), which is the\n"
                "convention this implements. The options exist so the crypttab handling\n"
                "can be exercised without a TPM; supplying one also means \"run here,\n"
                "now\", which is what lets the program be tested outside an initrd.\n"
                "\n"
                "  --crypttab PATH     crypttab to read (default %s)\n"
                "  --volume NAME        volume to look for (default %s)\n"
                "  --tcti CONF          TPM TCTI, or a path that cannot exist (default %s)\n"
                "  --verbose            say what it is doing\n",
                argv0, argv0, VNGRD_CRYPTTAB, VNGRD_VOLUME, VNGRD_TCTI);
}

int main(int argc, char **argv) {

	/* The first boot has no index. libtss2-esys logs that probe as an error
	 * before the caller sees the rc, so silence esys/tcti unless TSS2_LOG is
	 * already set. */
	setenv("TSS2_LOG", "esys+none,tcti+none", 0);
        const char *crypttab = VNGRD_CRYPTTAB;
        const char *volume = VNGRD_VOLUME;
        const char *tcti = VNGRD_TCTI;
        bool verbose = false;
        bool forced = false;

        /* systemd passes one to three output directories; argc is 2..4
         * (generator.h:107). Accepting only zero arguments breaks every boot. */
        const char *out_dirs[4] = { NULL, NULL, NULL, NULL };
        size_t n_out_dirs = 0;

        for (int i = 1; i < argc; i++) {
                const char *a = argv[i];

                /* Accept --opt=value as well as --opt value. */
                if (strncmp(a, "--crypttab=", 11) == 0) {
                        crypttab = a + 11;
                        forced = true;
                } else if (strncmp(a, "--volume=", 9) == 0) {
                        volume = a + 9;
                        forced = true;
                } else if (strncmp(a, "--tcti=", 7) == 0) {
                        tcti = a + 7;
                        forced = true;
                } else if (strcmp(a, "--crypttab") == 0 && i + 1 < argc) {
                        crypttab = argv[++i];
                        forced = true;
                } else if (strcmp(a, "--volume") == 0 && i + 1 < argc) {
                        volume = argv[++i];
                        forced = true;
                } else if (strcmp(a, "--tcti") == 0 && i + 1 < argc) {
                        tcti = argv[++i];
                        forced = true;
                } else if (strcmp(a, "--verbose") == 0) {
                        verbose = true;
                } else if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
                        usage(argv[0]);
                        return 0;
                } else if (a[0] == '-') {
                        diagnose("vngrd-fixate-generator: unknown option: %s\n", a);
                        usage(argv[0]);
                        return 1;
                } else {
                        /* A directory systemd wants output in. An unknown option
                         * is still an error: a silently ignored typo can make a
                         * test pass for the wrong reason. */
                        if (n_out_dirs < sizeof(out_dirs) / sizeof(out_dirs[0]))
                                out_dirs[n_out_dirs++] = a;
                }
        }

        if (n_out_dirs == 0) {
                out_dirs[n_out_dirs++] = VNGRD_DROPIN_DIR;
        }

        /* Nothing to do on the host. Supplying any option means "run here", so
         * tests can exercise this outside an initrd. */
        if (!in_initrd() && !forced) {
                if (verbose)
                        diagnose("vngrd-fixate-generator: not in the initrd and not asked to do "
                                 "anything, doing nothing\n");
                return 0;
        }

        char hex[2 * VNGRD_FIXATE_DIGEST_LEN + 1];
        NvReadResult r = nvindex_read_fixate(tcti, hex, sizeof(hex));

        if (r == NV_READ_ABSENT) {
                /* Normal case before provisioning: silent on purpose. */
                if (verbose)
                        diagnose("vngrd-fixate-generator: no fixate digest in NV, no drop-in\n");
                return 0;
        }
        if (r != NV_READ_OK) {
                /* Already reported. A generator's exit status is ignored by
                 * systemd, but the truth is failure. */
                return 1;
        }

        /* One line when the check is active: a refusal and a success both leave
         * the root closed, so otherwise there is no sign the control ran. */
        diagnose("vngrd-fixate-generator: volume %s is sealed to TPM NV index 0x%01X; the volume "
                 "key will be checked against the digest frozen at provisioning", volume,
                 VNGRD_NV_INDEX);

        FixateCrypttabEntry entry;
        int found = fixate_crypttab_lookup(crypttab, volume, &entry);
        if (found < 0) {
                fixate_crypttab_entry_done(&entry);
                return 1;
        }
        if (found == 0) {
                diagnose("vngrd-fixate-generator: %s does not name a volume '%s', but NV index "
                         "0x%01X holds a fixate digest for it.\n"
                         "  The check will not happen: the volume will open without it. The digest "
                         "covers the volume name, so the crypttab and the seal have drifted apart.\n",
                         crypttab, volume, VNGRD_NV_INDEX);
                return 1;
        }

        /* Write to every directory systemd offered; duplicate content is
         * harmless. */
        for (size_t i = 0; i < n_out_dirs; i++) {
                char *dropin = NULL;
                if (asprintf(&dropin, "%s/systemd-cryptsetup@%s.service.d/50-vngrd-fixate.conf",
                             out_dirs[i], entry.name) < 0) {
                        diagnose("vngrd-fixate-generator: out of memory building the drop-in path\n");
                        fixate_crypttab_entry_done(&entry);
                        return 1;
                }

                int rc = fixate_write_dropin(dropin, &entry, hex);
                if (rc < 0) {
                        diagnose("vngrd-fixate-generator: could not write %s\n", dropin);
                        free(dropin);
                        fixate_crypttab_entry_done(&entry);
                        return 1;
                }

                if (verbose)
                        diagnose("vngrd-fixate-generator: wrote %s\n", dropin);
                else
                        diagnose("vngrd-fixate-generator: fixate check applied via %s", dropin);
                free(dropin);
        }

        fixate_crypttab_entry_done(&entry);
        return 0;
}

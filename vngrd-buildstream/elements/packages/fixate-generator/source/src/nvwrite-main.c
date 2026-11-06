/* nvwrite-main.c — vngrd-fixate-nvwrite.
 *
 * Freezes the digest repart wrote into the generated crypttab, then locks the
 * register. Separate from the generator because the generator runs automatically
 * on every boot and must not be able to write a one-shot register.
 *
 * The digest is a one-way HMAC, not a secret, so passing it as an argument is
 * fine. Nothing secret is involved on this side (see nvwrite.h).
 */

#define _GNU_SOURCE

#include "diagnose.h"
#include "fixate.h"
#include "nvindex.h"
#include "nvwrite.h"
#include "provisioning.h"

#include <errno.h>
#include <stdbool.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VNGRD_DEFAULT_TCTI "device:/dev/tpmrm0"

/* Present on the boot that creates the volume, absent after. */
#define VNGRD_DEFAULT_CRYPTAB VNGRD_PROVISIONING_MARKER
#define VNGRD_DEFAULT_MARKER VNGRD_PROVISIONING_MARKER

/* Same name as main.c and the crypttab; base-files/build asserts they agree. */
#define VNGRD_VOLUME_NAME "vngrd-root"

/* Extract "fixate-volume-key=<hex>" from repart's crypttab. Keeping this in C
 * avoids a shell: /usr/bin/sh is fish, and the initrd has no POSIX shell.
 * Returns 0/found, 1 for a file without the option (normal after provisioning),
 * or -1 on a read error. */
#define CRYPTTAB_NOTHING 0
#define CRYPTTAB_FOUND 1
#define CRYPTTAB_FAULT (-1)

static int read_fixate_from_crypttab(const char *path, char *out, size_t out_sz) {
        FixateCrypttabEntry entry;

        /* No fixate option is normal after provisioning: repart rewrites the
         * crypttab every boot but only appends the option when it formats the
         * volume. Check existence first so an unreadable file is a fault, not
         * "nothing to freeze". */
        if (access(path, F_OK) != 0)
                return CRYPTTAB_NOTHING;


        int found = fixate_crypttab_lookup(path, VNGRD_VOLUME_NAME, &entry);
        if (found < 0)
                return CRYPTTAB_FAULT;
        if (found == 0) {
                diagnose("vngrd-fixate-nvwrite: %s exists but names no volume '%s'. repart"
                         " generates this file from the root definition on every boot, but a"
                         " line for the volume carrying the fixate digest exists only on the"
                         " boot that formatted it; without that line there is nothing to freeze.",
                         path, VNGRD_VOLUME_NAME);
                return CRYPTTAB_FAULT;
        }

        /* The marker requires fixate-volume-key= and on the unit's path is the
         * same file. Recheck so a caller passing a separate --marker, or a file
         * changed between reads, cannot silently freeze nothing. */
        const char *opt = strstr(entry.options, "fixate-volume-key=");
        if (opt == NULL) {
                diagnose("vngrd-fixate-nvwrite: %s has no fixate-volume-key= option, but the"
                         " provisioning marker check saw one. Options are '%s'. Nothing was"
                         " frozen; refusing rather than treating the normal later-boot crypttab"
                         " as the provisioning value. Check that EncryptedVolume= in 10-root.conf"
                         " has fixate-volume-key in its FOURTH colon-separated field.",
                         path, entry.options);
                fixate_crypttab_entry_done(&entry);
                return CRYPTTAB_FAULT;
        }
        opt += strlen("fixate-volume-key=");

        const char *end = opt;
        while (*end != '\0' && *end != ',')
                end++;
        size_t n = (size_t) (end - opt);
        if (n == 0 || n >= out_sz) {
                diagnose("vngrd-fixate-nvwrite: %s has a fixate-volume-key of %zu characters, "
                         "which is not a %u-character digest",
                         path, n, 2 * VNGRD_FIXATE_DIGEST_LEN);
                fixate_crypttab_entry_done(&entry);
                return -1;
        }
        memcpy(out, opt, n);
        out[n] = '\0';
        fixate_crypttab_entry_done(&entry);
        return 1;
}

static void usage(const char *argv0) {
        fprintf(stderr,
                "usage: %s [--crypttab=PATH] [--marker=PATH] [--fixate=HEX]\n"
                "          [--index=N] [--tcti=CONF]\n"
                "\n"
                "Freeze a fixate digest into TPM NV index 0x%08X and lock it against\n"
                "further writes.\n"
                "\n"
                "  --crypttab PATH   read the digest from the crypttab repart generated\n"
                "                     (default /run/vngrd/repart-crypttab).\n"
                "  --marker PATH     the provisioning marker (defaults to the crypttab\n"
                "                     path). An absent index may only be defined when\n"
                "                     this exists; on any other boot the freeze refuses\n"
                "                     rather than re-arming the control.\n"
                "  --fixate HEX      use this digest directly instead. %u hex\n"
                "                     characters, a SHA-256 digest, not a secret.\n"
                "\n"
                "Exits 0 if the digest is now frozen, including when it already was:\n"
                "the register is one-shot, so re-running is the normal state of every\n"
                "machine after its first boot and must not be an error.\n",
                argv0, VNGRD_NV_INDEX, 2 * VNGRD_FIXATE_DIGEST_LEN);
}

int main(int argc, char **argv) {

	/* First boot probes an absent index; esys logs that as an error. Silence it
	 * unless TSS2_LOG is already set. */
	setenv("TSS2_LOG", "esys+none,tcti+none", 0);
        const char *fixate = NULL;
        const char *crypttab = VNGRD_DEFAULT_CRYPTAB;
        const char *marker = NULL;
        const char *tcti = VNGRD_DEFAULT_TCTI;
        uint32_t index = VNGRD_NV_INDEX;
        bool verbose = false;

        for (int i = 1; i < argc; i++) {
                if (strncmp(argv[i], "--fixate=", 9) == 0) {
                        fixate = argv[i] + 9;
                } else if (strncmp(argv[i], "--crypttab=", 11) == 0) {
                        crypttab = argv[i] + 11;
                } else if (strncmp(argv[i], "--marker=", 9) == 0) {
                        marker = argv[i] + 9;
                } else if (strncmp(argv[i], "--tcti=", 7) == 0) {
                        tcti = argv[i] + 7;
                } else if (strncmp(argv[i], "--index=", 8) == 0) {
                        char *end = NULL;
                        unsigned long v = strtoul(argv[i] + 8, &end, 0);
                        if (end == argv[i] + 8 || *end != '\0') {
                                diagnose("vngrd-fixate-nvwrite: --index is not a number: %s", argv[i] + 8);
                                return 1;
                        }
                        index = (uint32_t) v;
                } else if (strcmp(argv[i], "--verbose") == 0) {
                        verbose = true;
                } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                        usage(argv[0]);
                        return 0;
                } else {
                        diagnose("vngrd-fixate-nvwrite: unknown argument: %s", argv[i]);
                        usage(argv[0]);
                        return 1;
                }
        }

        /* The crypttab IS the provisioning marker on the unit's path. A caller
         * that overrides --crypttab for a test follows it unless it also names a
         * separate marker. */
        if (marker == NULL)
                marker = crypttab;

        char hex_buf[2 * VNGRD_FIXATE_DIGEST_LEN + 1];

        /* The TPM is the source of truth for "provisioned", not a file on the
         * volume being provisioned: such a marker is written on the boot that
         * freezes the digest and is gone on the next, which caused a reboot
         * loop. If the register holds a digest, there is nothing to do. */
        char probed[2 * VNGRD_FIXATE_DIGEST_LEN + 1];
        NvReadResult probe = nvindex_read_fixate(tcti, probed, sizeof(probed));
        if (probe == NV_READ_OK) {
                if (verbose)
                        diagnose("vngrd-fixate-nvwrite: NV index 0x%08X already holds a digest, so "
                                 "this machine is provisioned; nothing to freeze", index);
                return 0;
        }
        if (probe == NV_READ_FAILED)
                return 1; /* could not tell whether it is provisioned */

        /* An absent index is only defined on the boot that created the volume.
         * Without this check, a host-root attacker could undefine the register,
         * boot an older image, and have the freeze re-record whatever the old
         * image expected -- the silent re-arm this control exists to stop. */
        if (!provisioning_marker_present(marker)) {
                diagnose("vngrd-fixate-nvwrite: NV index 0x%08X is empty but the provisioning "
                         "marker %s does not exist. This is not the boot that created the root, "
                         "so the digest is NOT re-frozen: an absent register on a provisioned "
                         "machine means it was deleted, and defining it here would re-arm the "
                         "check at whatever value this boot happens to see.",
                         index, marker);
                return 1;
        }

        if (fixate == NULL) {
                int r = read_fixate_from_crypttab(crypttab, hex_buf, sizeof(hex_buf));
                if (r == CRYPTTAB_FAULT)
                        return 1;
                if (r == CRYPTTAB_NOTHING) {
                        /* Marker exists but the crypttab path does not: a caller
                         * overrode one of them. Nothing to freeze. */
                        diagnose("vngrd-fixate-nvwrite: NV index 0x%08X is empty AND %s does not "
                                 "exist. An empty register means this machine is not provisioned, so "
                                 "this is the boot that had to freeze the digest -- but repart wrote "
                                 "no crypttab, so there was nothing to freeze. The fixate check will "
                                 "NOT run on this machine. Check that repart's --generate-crypttab="
                                 " is in systemd-repart.service.d/10-device.conf and that "
                                 "EncryptedVolume= in 10-root.conf has fixate-volume-key in its "
                                 "fourth colon-separated field.",
                                 index, crypttab);
                        return 1;
                }
                fixate = hex_buf;
        }

        NvWriteResult r = nvwrite_freeze(tcti, fixate, index);

        switch (r) {
        case NV_WRITE_OK:
                diagnose("vngrd-fixate-nvwrite: NV index 0x%08X now holds %s and is write-locked",
                         index, fixate);
                break;

        case NV_WRITE_ALREADY_PRESENT:
                if (verbose)
                        diagnose("vngrd-fixate-nvwrite: NV index 0x%08X was already defined; "
                                 "leaving it alone", index);
                break;

        case NV_WRITE_FAILED:
        default:
                return 1;
        }

        return 0;
}

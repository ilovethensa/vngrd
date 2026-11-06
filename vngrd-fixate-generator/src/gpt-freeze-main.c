/* gpt-freeze-main.c — freeze the GPT identity, once.
 *
 * Idempotent: the TPM register, not a file, says whether it is done. An absent
 * register is defined only with repart's provisioning marker; on a later boot
 * re-freezing would re-arm against an attacker-controlled table.
 */

#define _GNU_SOURCE

#include "diagnose.h"
#include "gpt.h"
#include "nvindex.h"
#include "nvwrite.h"
#include "provisioning.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VNGRD_DEFAULT_TCTI "device:/dev/tpmrm0"
#define VNGRD_DEFAULT_PARTLABEL VNGRD_ROOT_PARTLABEL
#define VNGRD_DEFAULT_MARKER VNGRD_PROVISIONING_MARKER

#define VNGRD_DISK_MAX 256u

static void usage(const char *argv0) {
        fprintf(stderr,
                "usage: %s [--partlabel=NAME] [--marker=PATH] [--tcti=CONF]\n"
                "\n"
                "Compute the GPT identity digest of the disk behind\n"
                "/dev/disk/by-partlabel/NAME and freeze it into TPM NV index 0x%08X.\n"
                "A no-op when the index already exists. An absent index is only\n"
                "defined when the provisioning crypttab carries fixate-volume-key=.\n"
                "\n"
                "  --partlabel NAME  the partition used to find the disk (default %s)\n"
                "  --marker PATH     repart's generated crypttab (default %s)\n",
                argv0, VNGRD_NV_GPT_INDEX, VNGRD_DEFAULT_PARTLABEL, VNGRD_DEFAULT_MARKER);
}

int main(int argc, char **argv) {
        setenv("TSS2_LOG", "esys+none,tcti+none", 0);

        const char *tcti = VNGRD_DEFAULT_TCTI;
        const char *partlabel = VNGRD_DEFAULT_PARTLABEL;
        const char *marker = VNGRD_DEFAULT_MARKER;

        for (int i = 1; i < argc; i++) {
                if (strncmp(argv[i], "--tcti=", 7) == 0) {
                        tcti = argv[i] + 7;
                } else if (strncmp(argv[i], "--partlabel=", 12) == 0) {
                        partlabel = argv[i] + 12;
                } else if (strncmp(argv[i], "--marker=", 9) == 0) {
                        marker = argv[i] + 9;
                } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                        usage(argv[0]);
                        return 0;
                } else {
                        diagnose("vngrd-gpt-freeze: unknown argument: %s", argv[i]);
                        usage(argv[0]);
                        return 1;
                }
        }

        uint8_t existing[VNGRD_GPT_DIGEST_LEN];
        size_t got = 0;
        NvReadResult probe = nvindex_read_raw(tcti, VNGRD_NV_GPT_INDEX, existing,
                                              sizeof(existing), &got);
        if (probe == NV_READ_OK)
                return 0; /* frozen on an earlier boot */
        if (probe == NV_READ_FAILED)
                return 1; /* could not tell whether it is frozen */

        /* Only define on the provisioning boot; later absence is deletion. */
        if (!provisioning_marker_present(marker)) {
                diagnose("vngrd-gpt-freeze: NV index 0x%08X is empty but the provisioning marker "
                         "%s does not exist. This is not the boot that created the root, so the "
                         "partition identity is NOT re-frozen; an absent register on a provisioned "
                         "machine means it was deleted.",
                         VNGRD_NV_GPT_INDEX, marker);
                return 1;
        }

        char disk[VNGRD_DISK_MAX];
        if (gpt_disk_for_partlabel(partlabel, disk, sizeof(disk)) != 0) {
                /* Fatal: a control that silently did not install looks installed. */
                diagnose("vngrd-gpt-freeze: cannot find the disk behind "
                         "/dev/disk/by-partlabel/%s, so the partition identity cannot be frozen "
                         "and vngrd-gpt-guard will not run on this machine.", partlabel);
                return 1;
        }

        uint8_t digest[VNGRD_GPT_DIGEST_LEN];
        if (gpt_identity_digest(disk, digest) != 0)
                return 1;

        NvWriteResult w = nvwrite_freeze_raw(tcti, digest, sizeof(digest), VNGRD_NV_GPT_INDEX);
        switch (w) {
        case NV_WRITE_OK:
                diagnose("vngrd-gpt-freeze: NV index 0x%08X now holds the partition identity of "
                         "%s and is write-locked", VNGRD_NV_GPT_INDEX, disk);
                return 0;
        case NV_WRITE_ALREADY_PRESENT:
                return 0;
        case NV_WRITE_FAILED:
        default:
                return 1;
        }
}

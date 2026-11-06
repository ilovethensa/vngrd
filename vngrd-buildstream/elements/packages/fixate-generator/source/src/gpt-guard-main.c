/* gpt-guard-main.c — refuse a boot whose GPT identity changed.
 *
 * PCR 7 is the same on every machine this authority signs, and PCR 5 cannot be
 * in the seal because repart creates the root after the firmware measured the
 * table. The frozen digest is what binds the disk identity.
 *
 * Fail closed on a provisioned machine. An absent register passes only when
 * there is no root partition (never provisioned) or on the provisioning boot
 * (repart's marker exists, freeze runs later). Once present, any failure to
 * re-check is a refusal.
 */

#define _GNU_SOURCE

#include "diagnose.h"
#include "gpt.h"
#include "nvindex.h"
#include "provisioning.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VNGRD_DEFAULT_TCTI "device:/dev/tpmrm0"

/* The by-partlabel name shared with the cmdline and crypttab. */
#define VNGRD_DEFAULT_PARTLABEL VNGRD_ROOT_PARTLABEL
#define VNGRD_DEFAULT_MARKER VNGRD_PROVISIONING_MARKER

#define VNGRD_DISK_MAX 256u

static void usage(const char *argv0) {
        fprintf(stderr,
                "usage: %s [--partlabel=NAME] [--marker=PATH] [--tcti=CONF]\n"
                "\n"
                "Refuse to boot when the GPT identity of the disk behind\n"
                "/dev/disk/by-partlabel/NAME differs from the digest frozen in TPM NV\n"
                "index 0x%08X. Exits 0 when the boot may proceed, 1 when it must not.\n"
                "\n"
                "  --partlabel NAME  the partition used to find the disk, and the root\n"
                "                     partition whose existence means this machine was\n"
                "                     provisioned (default %s)\n"
                "  --marker PATH     repart's generated crypttab (default %s); it carries\n"
                "                     fixate-volume-key= only on the boot that created the root\n",
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
                        diagnose("vngrd-gpt-guard: unknown argument: %s", argv[i]);
                        usage(argv[0]);
                        return 1;
                }
        }

        uint8_t frozen[VNGRD_GPT_DIGEST_LEN];
        size_t got = 0;
        NvReadResult r = nvindex_read_raw(tcti, VNGRD_NV_GPT_INDEX, frozen, sizeof(frozen), &got);

        if (r == NV_READ_ABSENT) {
                /* Provisioning boot or untouched disk: no register yet. Any
                 * other absence is a deleted register and a refusal. */
                if (provisioning_marker_present(marker))
                        return 0;
                if (!root_partition_present(partlabel)) {
                        diagnose("vngrd-gpt-guard: no GPT identity is frozen and "
                                 "/dev/disk/by-partlabel/%s does not exist, so this disk has not "
                                 "been provisioned yet; nothing to enforce.", partlabel);
                        return 0;
                }
                diagnose("vngrd-gpt-guard: /dev/disk/by-partlabel/%s exists, so this machine was "
                         "provisioned, but NV index 0x%08X is empty and %s is absent. The frozen "
                         "GPT identity was deleted. Refusing to boot a provisioned machine "
                         "without the check it was provisioned with.",
                         partlabel, VNGRD_NV_GPT_INDEX, marker);
                return 1;
        }
        if (r == NV_READ_FAILED) {
                diagnose("vngrd-gpt-guard: the partition identity is frozen in NV index 0x%08X but "
                         "could not be read. Refusing to continue.", VNGRD_NV_GPT_INDEX);
                return 1;
        }
        if (got != VNGRD_GPT_DIGEST_LEN) {
                diagnose("vngrd-gpt-guard: NV index 0x%08X holds %zu bytes, expected %u. Refusing "
                         "to compare against something that is not a digest.",
                         VNGRD_NV_GPT_INDEX, got, VNGRD_GPT_DIGEST_LEN);
                return 1;
        }

        char disk[VNGRD_DISK_MAX];
        if (gpt_disk_for_partlabel(partlabel, disk, sizeof(disk)) != 0) {
                diagnose("vngrd-gpt-guard: a partition identity is frozen in the TPM but the disk "
                         "behind /dev/disk/by-partlabel/%s cannot be found. Refusing to continue.",
                         partlabel);
                return 1;
        }

        uint8_t now[VNGRD_GPT_DIGEST_LEN];
        if (gpt_identity_digest(disk, now) != 0)
                return 1; /* gpt_identity_digest has already said why on the console */

        if (memcmp(frozen, now, VNGRD_GPT_DIGEST_LEN) != 0) {
                /* The digest covers several fields; naming one would be worse
                 * than naming none. Give the fact and the recovery path. */
                diagnose("vngrd-gpt-guard: the partition table of %s does not match the identity "
                         "frozen in the TPM. A partition has been added, removed, moved, resized "
                         "or substituted since this machine was provisioned. Refusing to "
                         "continue.", disk);
                return 1;
        }

        return 0;
}

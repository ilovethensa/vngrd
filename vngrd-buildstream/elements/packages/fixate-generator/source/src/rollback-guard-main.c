/* rollback-guard-main.c — refuse a boot below the TPM floor.
 *
 * Reads the counter and IMAGE_VERSION from the verified /usr
 * (/sysusr/usr/lib/os-release), not the initramfs copy. The read side is a
 * separate binary from the commit side on purpose.
 *
 * Fail closed on a provisioned machine: an absent counter passes only with no
 * root partition or on the provisioning boot. Any unreadable or unparseable
 * value is a refusal.
 */

#define _GNU_SOURCE

#include "diagnose.h"
#include "nvindex.h"
#include "provisioning.h"
#include "rollback.h"

#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* /dev/tpmrm0 must exist before this runs; see nvindex.h. */
#define VNGRD_DEFAULT_TCTI "device:/dev/tpmrm0"

/* The verified /usr; the initramfs copy is a different tree. */
#define VNGRD_DEFAULT_OS_RELEASE "/sysusr/usr/lib/os-release"
#define VNGRD_DEFAULT_MARKER VNGRD_PROVISIONING_MARKER
#define VNGRD_DEFAULT_ROOT_PARTLABEL VNGRD_ROOT_PARTLABEL

static void usage(const char *argv0) {
        fprintf(stderr,
                "usage: %s [OS-RELEASE-PATH] [--os-release=PATH]\n"
                "          [--root-partlabel=NAME] [--marker=PATH] [--tcti=CONF]\n"
                "\n"
                "Refuse to boot an image whose rollback index is below the floor in TPM\n"
                "NV index 0x%08X. Exits 0 when the boot may proceed, 1 when it must not.\n"
                "\n"
                "  OS-RELEASE-PATH        the verified os-release to read IMAGE_VERSION\n"
                "                         from (default %s)\n"
                "  --root-partlabel NAME  the root partition whose existence means this\n"
                "                         machine was provisioned (default %s)\n"
                "  --marker PATH          repart's generated crypttab (default %s)\n",
                argv0, VNGRD_NV_ROLLBACK_INDEX, VNGRD_DEFAULT_OS_RELEASE,
                VNGRD_DEFAULT_ROOT_PARTLABEL, VNGRD_DEFAULT_MARKER);
}

int main(int argc, char **argv) {
        /* First-boot probe logs an expected TPM error; silence unless set. */
        setenv("TSS2_LOG", "esys+none,tcti+none", 0);

        const char *tcti = VNGRD_DEFAULT_TCTI;
        const char *os_release = VNGRD_DEFAULT_OS_RELEASE;
        const char *root_partlabel = VNGRD_DEFAULT_ROOT_PARTLABEL;
        const char *marker = VNGRD_DEFAULT_MARKER;

        for (int i = 1; i < argc; i++) {
                if (strncmp(argv[i], "--tcti=", 7) == 0) {
                        tcti = argv[i] + 7;
                } else if (strncmp(argv[i], "--os-release=", 13) == 0) {
                        os_release = argv[i] + 13;
                } else if (strncmp(argv[i], "--root-partlabel=", 17) == 0) {
                        root_partlabel = argv[i] + 17;
                } else if (strncmp(argv[i], "--marker=", 9) == 0) {
                        marker = argv[i] + 9;
                } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                        usage(argv[0]);
                        return 0;
                } else if (argv[i][0] != '-') {
                        os_release = argv[i];
                } else {
                        diagnose("vngrd-rollback-guard: unknown argument: %s", argv[i]);
                        usage(argv[0]);
                        return 1;
                }
        }

        uint64_t floor = 0;
        RollbackResult fr = rollback_floor_read(tcti, &floor);

        if (fr == ROLLBACK_NO_FLOOR) {
                /* Pass only where there is nothing to protect; a deleted counter
                 * would otherwise let the running image define its own floor. */
                if (provisioning_marker_present(marker))
                        return 0;
                if (!root_partition_present(root_partlabel)) {
                        diagnose("vngrd-rollback-guard: no rollback floor is committed and "
                                 "/dev/disk/by-partlabel/%s does not exist, so this disk has not "
                                 "been provisioned yet; nothing to enforce.", root_partlabel);
                        return 0;
                }
                diagnose("vngrd-rollback-guard: /dev/disk/by-partlabel/%s exists, so this machine "
                         "was provisioned, but NV index 0x%08X is empty and %s is absent. The "
                         "rollback floor was deleted. Refusing to boot a provisioned machine "
                         "without the anti-rollback check it was provisioned with.",
                         root_partlabel, VNGRD_NV_ROLLBACK_INDEX, marker);
                return 1;
        }
        if (fr == ROLLBACK_FAILED) {
                diagnose("vngrd-rollback-guard: the rollback register exists but could not be "
                         "read, so this boot cannot be shown to be at or above the floor. "
                         "Refusing to continue.");
                return 1;
        }

        uint32_t running = 0;
        if (rollback_index_from_os_release(os_release, &running) != 0) {
                diagnose("vngrd-rollback-guard: cannot determine this image's version, so it "
                         "cannot be shown to be at or above the floor (%" PRIu64 "). Refusing to "
                         "continue.", floor);
                return 1;
        }

        if ((uint64_t) running < floor) {
                diagnose("vngrd-rollback-guard: this image is rollback index %" PRIu32 " and the "
                         "floor is %" PRIu64 ". A machine that has run a newer version does not "
                         "run an older one; refusing to continue. A legitimate recovery is a "
                         "re-provisioning, not a passphrase boot: clearing the TPM also removes "
                         "the registers this guard requires, so the recovery passphrase opens "
                         "the volume from a recovery environment but does not by itself get "
                         "this check past.",
                         running, floor);
                return 1;
        }

        return 0;
}

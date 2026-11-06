/* rollback-commit-main.c — raise the TPM rollback floor.
 *
 * --create is allowed only on the provisioning boot and with repart's marker.
 * Every other run increments only; an absent counter is a failure, never a new
 * register at the running version.
 *
 * The host run is ordered at boot-complete, so a version that boots and then
 * misbehaves never raises the floor, and a blessed version cannot be rolled back
 * later. Failure must fail the unit: a silently unraised floor looks protected
 * but is not.
 */

#define _GNU_SOURCE

#include "diagnose.h"
#include "nvindex.h"
#include "provisioning.h"
#include "rollback.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VNGRD_DEFAULT_TCTI "device:/dev/tpmrm0"
#define VNGRD_DEFAULT_OS_RELEASE "/usr/lib/os-release"
#define VNGRD_DEFAULT_MARKER VNGRD_PROVISIONING_MARKER

static void usage(const char *argv0) {
        fprintf(stderr,
                "usage: %s [OS-RELEASE-PATH] [--os-release=PATH] [--create]\n"
                "          [--marker=PATH] [--tcti=CONF]\n"
                "\n"
                "Raise the rollback floor in TPM NV index 0x%08X to this image's index.\n"
                "Idempotent: a no-op when the floor is already at or above it.\n"
                "\n"
                "  OS-RELEASE-PATH  the verified os-release to read IMAGE_VERSION from\n"
                "                   (default %s)\n"
                "  --create         permit defining an absent counter, but only on a boot\n"
                "                   whose crypttab carries fixate-volume-key=. The initrd uses\n"
                "                   this on the boot that repart created the root. Without\n"
                "                   it, an absent counter is a refusal.\n"
                "  --marker PATH    repart's generated crypttab (default %s); the marker\n"
                "                   that distinguishes the provisioning boot.\n",
                argv0, VNGRD_NV_ROLLBACK_INDEX, VNGRD_DEFAULT_OS_RELEASE,
                VNGRD_DEFAULT_MARKER);
}

int main(int argc, char **argv) {
        setenv("TSS2_LOG", "esys+none,tcti+none", 0);

        const char *tcti = VNGRD_DEFAULT_TCTI;
        const char *os_release = VNGRD_DEFAULT_OS_RELEASE;
        const char *marker = VNGRD_DEFAULT_MARKER;
        bool create = false;

        for (int i = 1; i < argc; i++) {
                if (strncmp(argv[i], "--tcti=", 7) == 0) {
                        tcti = argv[i] + 7;
                } else if (strncmp(argv[i], "--os-release=", 13) == 0) {
                        os_release = argv[i] + 13;
                } else if (strncmp(argv[i], "--marker=", 9) == 0) {
                        marker = argv[i] + 9;
                } else if (strcmp(argv[i], "--create") == 0) {
                        create = true;
                } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                        usage(argv[0]);
                        return 0;
                } else if (argv[i][0] != '-') {
                        os_release = argv[i];
                } else {
                        diagnose("vngrd-rollback-commit: unknown argument: %s", argv[i]);
                        usage(argv[0]);
                        return 1;
                }
        }

        uint32_t running = 0;
        if (rollback_index_from_os_release(os_release, &running) != 0) {
                diagnose("vngrd-rollback-commit: cannot determine this image's version, so the "
                         "rollback floor cannot be raised to it. Failing rather than blessing a "
                         "boot whose floor was not committed.");
                return 1;
        }

        int rc = create ? rollback_commit_create(tcti, running, marker)
                        : rollback_commit(tcti, running);
        if (rc != 0) {
                diagnose("vngrd-rollback-commit: could not raise the rollback floor to index "
                         "%u. The boot is not being marked as a version the machine may not go "
                         "below; a downgrade check that silently did not update is worse than "
                         "one that fails.", running);
                return 1;
        }

        return 0;
}

/* fixate-guard-main.c — refuse a provisioned machine whose fixate index is gone.
 *
 * The generator cannot fail a boot, so an undefined index silently disables the
 * volume-key check. This guard supplies the failure. It refuses only the state
 * the generator cannot handle: root partition present, no register, no
 * provisioning marker. A TPM clear is the same re-provisioning event.
 */

#define _GNU_SOURCE

#include "nvindex.h"
#include "provisioning.h"

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define VNGRD_TCTI "device:/dev/tpmrm0"

static void usage(const char *argv0) {
        fprintf(stderr,
                "usage: %s [OPTIONS]\n"
                "\n"
                "Fails closed when a provisioned machine has no fixate digest in NV.\n"
                "\n"
                "  --tcti CONF     TPM TCTI (default %s)\n"
                "  --marker PATH   repart's provisioning crypttab (default %s)\n"
                "  --root PATH     root partition node (default /dev/disk/by-partlabel/%s)\n"
                "  --verbose       say what was decided\n",
                argv0, VNGRD_TCTI, VNGRD_PROVISIONING_MARKER, VNGRD_ROOT_PARTLABEL);
}

/* nvindex_read_fixate maps an unavailable TCTI to ABSENT for the generator. Here
 * on a provisioned machine, no TPM means the check cannot run: refuse. */
static bool tcti_device_present(const char *tcti) {
        static const char prefix[] = "device:";

        if (tcti == NULL || strncmp(tcti, prefix, sizeof(prefix) - 1) != 0)
                return true;
        return access(tcti + sizeof(prefix) - 1, F_OK) == 0;
}

static bool path_present(const char *path) {
        return path != NULL && access(path, F_OK) == 0;
}

int main(int argc, char **argv) {
        const char *tcti = VNGRD_TCTI;
        const char *marker = VNGRD_PROVISIONING_MARKER;
        char root_default[256];
        const char *root = root_default;
        bool verbose = false;

        int n = snprintf(root_default, sizeof(root_default), "/dev/disk/by-partlabel/%s",
                         VNGRD_ROOT_PARTLABEL);
        if (n < 0 || (size_t) n >= sizeof(root_default)) {
                fprintf(stderr, "vngrd-fixate-guard: root path too long\n");
                return 1;
        }

        for (int i = 1; i < argc; i++) {
                const char *a = argv[i];

                if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
                        usage(argv[0]);
                        return 0;
                }
                if (strncmp(a, "--tcti=", 7) == 0) {
                        tcti = a + 7;
                } else if (strcmp(a, "--tcti") == 0 && i + 1 < argc) {
                        tcti = argv[++i];
                } else if (strncmp(a, "--marker=", 9) == 0) {
                        marker = a + 9;
                } else if (strcmp(a, "--marker") == 0 && i + 1 < argc) {
                        marker = argv[++i];
                } else if (strncmp(a, "--root=", 7) == 0) {
                        root = a + 7;
                } else if (strcmp(a, "--root") == 0 && i + 1 < argc) {
                        root = argv[++i];
                } else if (strcmp(a, "--verbose") == 0) {
                        verbose = true;
                } else {
                        fprintf(stderr, "vngrd-fixate-guard: unknown argument '%s'\n", a);
                        usage(argv[0]);
                        return 2;
                }
        }

        /* repart writes this only when it formats the root. Check it before any
         * TPM access; all four guards use the same predicate. */
        if (provisioning_marker_present(marker)) {
                if (verbose)
                        printf("vngrd-fixate-guard: provisioning marker present, index may be absent\n");
                return 0;
        }

        if (!path_present(root)) {
                if (verbose)
                        printf("vngrd-fixate-guard: no root partition, disk is not provisioned\n");
                return 0;
        }

        if (!tcti_device_present(tcti)) {
                fprintf(stderr,
                        "vngrd-fixate-guard: root partition exists and %s is unavailable; "
                        "a provisioned machine cannot skip the fixate check\n",
                        tcti);
                return 1;
        }

        char hex[2 * VNGRD_FIXATE_DIGEST_LEN + 1];
        NvReadResult r = nvindex_read_fixate(tcti, hex, sizeof(hex));

        if (r == NV_READ_ABSENT) {
                fprintf(stderr,
                        "vngrd-fixate-guard: root partition exists but the fixate digest in "
                        "NV is absent; refusing to release the volume with no volume-key check\n");
                return 1;
        }
        if (r != NV_READ_OK) {
                fprintf(stderr,
                        "vngrd-fixate-guard: the fixate digest exists but could not be read; "
                        "refusing to boot without the check\n");
                return 1;
        }

        if (verbose)
                printf("vngrd-fixate-guard: fixate digest present\n");
        return 0;
}

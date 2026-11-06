/* esp-freeze-main.c — freeze the ESP identity, once. Sibling of gpt-freeze.
 *
 * Idempotent: the TPM register is the authority. An absent register is defined
 * only with repart's provisioning marker; on a later boot re-freezing would
 * re-arm against whatever is currently on the ESP.
 */

#define _GNU_SOURCE

#include "diagnose.h"
#include "esp.h"
#include "nvindex.h"
#include "nvwrite.h"
#include "provisioning.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VNGRD_DEFAULT_TCTI "device:/dev/tpmrm0"
#define VNGRD_DEFAULT_PARTLABEL "vngrd-esp"
#define VNGRD_DEFAULT_MARKER VNGRD_PROVISIONING_MARKER

static void usage(const char *argv0) {
        fprintf(stderr,
                "usage: %s [--partlabel=NAME] [--marker=PATH] [--tcti=CONF]\n"
                "\n"
                "Digest the contents of the ESP at /dev/disk/by-partlabel/NAME and\n"
                "freeze it into TPM NV index 0x%08X. A no-op when the index already\n"
                "exists. An absent index is only defined when the provisioning crypttab\n"
                "carries fixate-volume-key=.\n"
                "\n"
                "  --partlabel NAME  the ESP partition label (default %s)\n"
                "  --marker PATH     repart's generated crypttab (default %s)\n",
                argv0, VNGRD_NV_ESP_INDEX, VNGRD_DEFAULT_PARTLABEL, VNGRD_DEFAULT_MARKER);
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
                        diagnose("vngrd-esp-freeze: unknown argument: %s", argv[i]);
                        usage(argv[0]);
                        return 1;
                }
        }

        uint8_t existing[VNGRD_ESP_DIGEST_LEN];
        size_t got = 0;
        NvReadResult probe = nvindex_read_raw(tcti, VNGRD_NV_ESP_INDEX, existing,
                                              sizeof(existing), &got);
        if (probe == NV_READ_OK)
                return 0; /* frozen on an earlier boot */
        if (probe == NV_READ_FAILED)
                return 1; /* could not tell whether it is frozen */

        /* Only define on the provisioning boot; later absence is deletion. */
        if (!provisioning_marker_present(marker)) {
                diagnose("vngrd-esp-freeze: NV index 0x%08X is empty but the provisioning marker "
                         "%s does not exist. This is not the boot that created the root, so the "
                         "ESP identity is NOT re-frozen; an absent register on a provisioned "
                         "machine means it was deleted.",
                         VNGRD_NV_ESP_INDEX, marker);
                return 1;
        }

        uint8_t digest[VNGRD_ESP_DIGEST_LEN];
        if (esp_identity_digest(partlabel, digest) != 0) {
                /* Already reported; fatal for the same reason as gpt-freeze. */
                diagnose("vngrd-esp-freeze: the ESP identity cannot be computed, so "
                         "vngrd-esp-guard will not run on this machine.");
                return 1;
        }

        NvWriteResult w = nvwrite_freeze_raw(tcti, digest, sizeof(digest), VNGRD_NV_ESP_INDEX);
        switch (w) {
        case NV_WRITE_OK:
                diagnose("vngrd-esp-freeze: NV index 0x%08X now holds the ESP identity and is "
                         "write-locked", VNGRD_NV_ESP_INDEX);
                return 0;
        case NV_WRITE_ALREADY_PRESENT:
                return 0;
        case NV_WRITE_FAILED:
        default:
                return 1;
        }
}

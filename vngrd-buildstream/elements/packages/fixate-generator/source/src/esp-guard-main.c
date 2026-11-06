/* esp-guard-main.c — refuse a boot whose ESP contents changed.
 *
 * The GPT digest does not see inside the ESP. sd-boot and loader.conf are not
 * covered by Secure Boot or any measurement in the seal, so the frozen digest
 * binds them. Fail closed like the GPT guard; the ESP exists on the factory
 * image, so the root partition is the provisioning signal.
 */

#define _GNU_SOURCE

#include "diagnose.h"
#include "esp.h"
#include "nvindex.h"
#include "provisioning.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VNGRD_DEFAULT_TCTI "device:/dev/tpmrm0"

/* Label from mkosi.repart/00-esp.conf. Present from the factory image. */
#define VNGRD_DEFAULT_PARTLABEL "vngrd-esp"
#define VNGRD_DEFAULT_ROOT_PARTLABEL VNGRD_ROOT_PARTLABEL
#define VNGRD_DEFAULT_MARKER VNGRD_PROVISIONING_MARKER

static void usage(const char *argv0) {
        fprintf(stderr,
                "usage: %s [--partlabel=NAME] [--root-partlabel=NAME]\n"
                "          [--marker=PATH] [--tcti=CONF]\n"
                "\n"
                "Refuse to boot when the contents of the ESP at\n"
                "/dev/disk/by-partlabel/NAME differ from the digest frozen in TPM NV\n"
                "index 0x%08X. Exits 0 when the boot may proceed, 1 when it must not.\n"
                "\n"
                "  --partlabel NAME       the ESP partition label (default %s)\n"
                "  --root-partlabel NAME  the root partition whose existence means this\n"
                "                         machine was provisioned (default %s)\n"
                "  --marker PATH          repart's generated crypttab (default %s)\n",
                argv0, VNGRD_NV_ESP_INDEX, VNGRD_DEFAULT_PARTLABEL,
                VNGRD_DEFAULT_ROOT_PARTLABEL, VNGRD_DEFAULT_MARKER);
}

int main(int argc, char **argv) {
        setenv("TSS2_LOG", "esys+none,tcti+none", 0);

        const char *tcti = VNGRD_DEFAULT_TCTI;
        const char *partlabel = VNGRD_DEFAULT_PARTLABEL;
        const char *root_partlabel = VNGRD_DEFAULT_ROOT_PARTLABEL;
        const char *marker = VNGRD_DEFAULT_MARKER;

        for (int i = 1; i < argc; i++) {
                if (strncmp(argv[i], "--tcti=", 7) == 0) {
                        tcti = argv[i] + 7;
                } else if (strncmp(argv[i], "--partlabel=", 12) == 0) {
                        partlabel = argv[i] + 12;
                } else if (strncmp(argv[i], "--root-partlabel=", 17) == 0) {
                        root_partlabel = argv[i] + 17;
                } else if (strncmp(argv[i], "--marker=", 9) == 0) {
                        marker = argv[i] + 9;
                } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                        usage(argv[0]);
                        return 0;
                } else {
                        diagnose("vngrd-esp-guard: unknown argument: %s", argv[i]);
                        usage(argv[0]);
                        return 1;
                }
        }

        uint8_t frozen[VNGRD_ESP_DIGEST_LEN];
        size_t got = 0;
        NvReadResult r = nvindex_read_raw(tcti, VNGRD_NV_ESP_INDEX, frozen, sizeof(frozen), &got);

        if (r == NV_READ_ABSENT) {
                /* The ESP cannot signal provisioning; the root partition can.
                 * The marker covers the provisioning boot. */
                if (provisioning_marker_present(marker))
                        return 0;
                if (!root_partition_present(root_partlabel)) {
                        diagnose("vngrd-esp-guard: no ESP identity is frozen and "
                                 "/dev/disk/by-partlabel/%s does not exist, so this disk has not "
                                 "been provisioned yet; nothing to enforce.", root_partlabel);
                        return 0;
                }
                diagnose("vngrd-esp-guard: /dev/disk/by-partlabel/%s exists, so this machine was "
                         "provisioned, but NV index 0x%08X is empty and %s is absent. The frozen "
                         "ESP identity was deleted. Refusing to boot a provisioned machine "
                         "without the check it was provisioned with.",
                         root_partlabel, VNGRD_NV_ESP_INDEX, marker);
                return 1;
        }
        if (r == NV_READ_FAILED) {
                diagnose("vngrd-esp-guard: the ESP identity is frozen in NV index 0x%08X but "
                         "could not be read. Refusing to continue.", VNGRD_NV_ESP_INDEX);
                return 1;
        }
        if (got != VNGRD_ESP_DIGEST_LEN) {
                diagnose("vngrd-esp-guard: NV index 0x%08X holds %zu bytes, expected %u. Refusing "
                         "to compare against something that is not a digest.",
                         VNGRD_NV_ESP_INDEX, got, VNGRD_ESP_DIGEST_LEN);
                return 1;
        }

        uint8_t now[VNGRD_ESP_DIGEST_LEN];
        if (esp_identity_digest(partlabel, now) != 0) {
                /* Already explained on the console; a frozen digest that cannot
                 * be checked is fatal. */
                return 1;
        }

        if (memcmp(frozen, now, VNGRD_ESP_DIGEST_LEN) != 0) {
                diagnose("vngrd-esp-guard: the contents of the ESP (/dev/disk/by-partlabel/%s) do "
                         "not match the identity frozen in the TPM. The bootloader, its "
                         "configuration, or their location has changed since this machine was "
                         "provisioned. Refusing to continue.", partlabel);
                return 1;
        }

        return 0;
}

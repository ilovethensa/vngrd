/* bootsync-main.c — host-side sd-boot update. See bootsync.h. */

#define _GNU_SOURCE

#include "bootsync.h"
#include "diagnose.h"

#include <stdio.h>
#include <string.h>

static void usage(const char *argv0) {
        printf("usage: %s [--esp=LABEL] [--source=PATH]\n"
               "\n"
               "Copy the signed sd-boot from verified /usr to the ESP when it differs.\n"
               "\n"
               "  --esp LABEL    ESP partition label (default vngrd-esp)\n"
               "  --source PATH  signed loader (default %s)\n"
               "\n"
               "Both EFI/systemd/systemd-bootx64.efi and EFI/BOOT/BOOTX64.EFI are\n"
               "written from the one source and verified by reading them back.\n"
               "A missing or unsigned source is a failure, not a fallback: the\n"
               "firmware would refuse the result on the next boot.\n",
               argv0, VNGRD_BOOTSYNC_SOURCE);
}

int main(int argc, char **argv) {
        const char *partlabel = "vngrd-esp";
        const char *source = VNGRD_BOOTSYNC_SOURCE;

        for (int i = 1; i < argc; i++) {
                if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                        usage(argv[0]);
                        return 0;
                }
                if (strncmp(argv[i], "--esp=", 6) == 0) {
                        partlabel = argv[i] + 6;
                } else if (strncmp(argv[i], "--source=", 9) == 0) {
                        source = argv[i] + 9;
                } else {
                        diagnose("vngrd-bootloader-sync: unknown argument '%s'", argv[i]);
                        usage(argv[0]);
                        return 2;
                }
        }

        if (*partlabel == '\0' || *source == '\0') {
                diagnose("vngrd-bootloader-sync: empty --esp or --source");
                return 2;
        }

        if (bootsync_esp(partlabel, source) != 0) {
                diagnose("vngrd-bootloader-sync: the ESP loader was not updated; refusing to "
                         "let boot-complete bless this slot");
                return 1;
        }

        return 0;
}

/* pcr-main.c — vngrd-fixate-pcr. Prints the PCRs the root seal is bound to. */

#define _GNU_SOURCE

#include "pcrdump.h"

#include <stdio.h>
#include <string.h>

#define VNGRD_DEFAULT_TCTI "device:/dev/tpmrm0"

int main(int argc, char **argv) {
        const char *tcti = VNGRD_DEFAULT_TCTI;

        for (int i = 1; i < argc; i++) {
                if (strncmp(argv[i], "--tcti=", 7) == 0)
                        tcti = argv[i] + 7;
                else {
                        fprintf(stderr, "vngrd-fixate-pcr: unknown argument: %s\n", argv[i]);
                        return 1;
                }
        }

        /* 0 and 4 and 12 too: they are what "PCR 5 is the GPT" is argued against,
         * and having them next to 5 makes a moved 5 obvious. */
        const int pcrs[] = { 0, 4, 5, 7, 11, 12 };
        fprintf(stderr, "vngrd-fixate-pcr: reading PCRs from %s\n", tcti);
        return pcrdump(tcti, pcrs, sizeof(pcrs) / sizeof(*pcrs));
}

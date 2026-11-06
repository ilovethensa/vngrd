/* provisioning.c — see provisioning.h. The provisioning marker is the crypttab
 * line repart writes only when it formats the root, not the file's existence. */

#include "provisioning.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define VNGRD_PARTLABEL_PATH_MAX 256u
#define VNGRD_MARKER_LINE_MAX 8192u

bool provisioning_marker_present(const char *path) {
        if (path == NULL || *path == '\0')
                return false;

        /* The file itself exists on every boot: repart runs every boot and
         * context_crypttab() writes it from the definition whenever
         * EncryptedVolume= is set. What is unique to the provisioning boot is the
         * fixate-volume-key= option, appended by crypt_format() only after it has
         * the volume key. Checking for that option, rather than access(F_OK), is
         * the difference between a marker and a file that is always there. */
        FILE *f = fopen(path, "re");
        if (f == NULL)
                return false;

        char line[VNGRD_MARKER_LINE_MAX];
        bool found = false;
        while (fgets(line, sizeof(line), f) != NULL) {
                if (strstr(line, "fixate-volume-key=") != NULL) {
                        found = true;
                        break;
                }
        }
        fclose(f);
        return found;
}

bool root_partition_present(const char *partlabel) {
        char path[VNGRD_PARTLABEL_PATH_MAX];

        if (partlabel == NULL || *partlabel == '\0')
                return false;

        int n = snprintf(path, sizeof(path), "/dev/disk/by-partlabel/%s", partlabel);
        if (n < 0 || (size_t) n >= sizeof(path))
                return false;

        return access(path, F_OK) == 0;
}

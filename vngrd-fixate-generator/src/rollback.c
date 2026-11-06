/* rollback.c — version arithmetic and the TPM calls. See rollback.h. */

#define _GNU_SOURCE

#include "rollback.h"

#include "diagnose.h"
#include "nvindex.h"
#include "nvwrite.h"
#include "provisioning.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Keeps major*100 inside uint32; a larger version is refused, not wrapped. */
#define ROLLBACK_MAJOR_MAX 42949672u

int rollback_index_from_version(const char *version, uint32_t *out) {
        uint32_t parts[3] = { 0, 0, 0 };
        const char *p;
        int n = 0;

        if (version == NULL || out == NULL)
                return -1;

        p = version;
        for (;;) {
                uint32_t v = 0;

                /* Empty components ("1..2", ".1") are not versions. */
                if (*p < '0' || *p > '9')
                        return -1;

                while (*p >= '0' && *p <= '9') {
                        v = v * 10 + (uint32_t) (*p - '0');
                        /* Stop before a long number wraps into range. */
                        if (v > 429496729u)
                                return -1;
                        p++;
                }

                parts[n++] = v;
                if (*p == '\0')
                        break;
                if (*p != '.' || n == 3)
                        return -1;
                p++;
        }

        /* major*100 + minor*10 + patch; caps keep it injective. */
        if (parts[0] > ROLLBACK_MAJOR_MAX)
                return -1;
        if (parts[1] > 9 || parts[2] > 9)
                return -1;

        uint32_t index = parts[0] * 100u + parts[1] * 10u + parts[2];

        /* Zero means "no floor"; a real version must not pack to it. */
        if (index == 0)
                return -1;

        *out = index;
        return 0;
}

/* Strip one layer of quotes and trailing CR/space; os-release permits quotes. */
static void unquote(char *v) {
        size_t len = strlen(v);

        while (len > 0 && (v[len - 1] == '\n' || v[len - 1] == '\r' || v[len - 1] == ' ' ||
                           v[len - 1] == '\t'))
                v[--len] = '\0';

        if (len >= 2 && (v[0] == '"' || v[0] == '\'') && v[len - 1] == v[0]) {
                memmove(v, v + 1, len - 2);
                v[len - 2] = '\0';
        }
}

int rollback_index_from_os_release(const char *path, uint32_t *out) {
        FILE *f;
        char *line = NULL;
        size_t cap = 0;
        int rc = -1;
        bool saw_key = false;

        if (path == NULL || out == NULL)
                return -1;

        f = fopen(path, "re");
        if (f == NULL) {
                diagnose("vngrd-rollback: cannot open %s", path);
                return -1;
        }

        while (getline(&line, &cap, f) >= 0) {
                if (strncmp(line, "IMAGE_VERSION=", 14) != 0)
                        continue;

                char *v = line + 14;
                unquote(v);
                saw_key = true;

                rc = rollback_index_from_version(v, out);
                if (rc != 0)
                        diagnose("vngrd-rollback: IMAGE_VERSION '%s' in %s is not a version this "
                                 "rollback encoding accepts (see rollback.h: components must be "
                                 "dotted decimals and minor/patch must be a single digit)", v, path);
                break;
        }

        if (!saw_key)
                diagnose("vngrd-rollback: %s has no IMAGE_VERSION", path);

        free(line);
        fclose(f);
        return rc;
}

RollbackResult rollback_floor_read(const char *tcti_conf, uint64_t *floor_out) {
        uint8_t raw[8];
        size_t got = 0;
        NvReadResult r;

        r = nvindex_read_raw(tcti_conf, VNGRD_NV_ROLLBACK_INDEX, raw, sizeof(raw), &got);
        if (r == NV_READ_ABSENT)
                return ROLLBACK_NO_FLOOR;
        if (r == NV_READ_FAILED)
                return ROLLBACK_FAILED;

        if (got != sizeof(raw)) {
                diagnose("vngrd-rollback: NV index 0x%08X holds %zu bytes, expected %zu. Refusing "
                         "to guess what the floor is.",
                         VNGRD_NV_ROLLBACK_INDEX, got, sizeof(raw));
                return ROLLBACK_FAILED;
        }

        /* Counter is big-endian UINT64. */
        uint64_t floor = 0;
        for (unsigned i = 0; i < sizeof(raw); i++)
                floor = (floor << 8) | raw[i];

        if (floor_out != NULL)
                *floor_out = floor;

        return ROLLBACK_OK;
}

RollbackResult rollback_check(const char *tcti_conf, uint32_t running, uint64_t *floor_out) {
        uint64_t floor = 0;
        RollbackResult r = rollback_floor_read(tcti_conf, &floor);

        if (floor_out != NULL)
                *floor_out = floor;
        if (r != ROLLBACK_OK)
                return r;

        if ((uint64_t) running < floor)
                return ROLLBACK_BELOW_FLOOR;
        return ROLLBACK_OK;
}

int rollback_commit(const char *tcti_conf, uint32_t running) {
        uint64_t floor = 0;
        RollbackResult fr = rollback_floor_read(tcti_conf, &floor);

        if (fr == ROLLBACK_NO_FLOOR) {
                diagnose("vngrd-rollback-commit: NV index 0x%08X is absent, so this machine has "
                         "no committed floor. Refusing to define one from a running image: that "
                         "is exactly how a deleted counter would be re-armed at the attacker's "
                         "chosen version.", VNGRD_NV_ROLLBACK_INDEX);
                return -1;
        }
        if (fr == ROLLBACK_FAILED)
                return -1;

        NvWriteResult r = nvwrite_counter_ensure(tcti_conf, VNGRD_NV_ROLLBACK_INDEX,
                                                 (uint64_t) running, /* create= */ false);
        return r == NV_WRITE_OK ? 0 : -1;
}

int rollback_commit_create(const char *tcti_conf, uint32_t running, const char *marker) {
        if (!provisioning_marker_present(marker)) {
                uint64_t floor = 0;
                RollbackResult fr = rollback_floor_read(tcti_conf, &floor);

                if (fr == ROLLBACK_NO_FLOOR) {
                        diagnose("vngrd-rollback-commit: the provisioning marker is absent and "
                                 "NV index 0x%08X is also absent. This is not the boot that "
                                 "created the root, so the floor is not redefined here; a "
                                 "provisioned machine with no counter has had it deleted.",
                                 VNGRD_NV_ROLLBACK_INDEX);
                        return -1;
                }
                if (fr == ROLLBACK_FAILED)
                        return -1;

                /* Only define on the provisioning boot; later absence is deletion. */
                return 0;
        }

        NvWriteResult r = nvwrite_counter_ensure(tcti_conf, VNGRD_NV_ROLLBACK_INDEX,
                                                 (uint64_t) running, /* create= */ true);
        return r == NV_WRITE_OK ? 0 : -1;
}

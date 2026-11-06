/* rollback.h — the TPM-backed rollback floor.
 *
 * A TPM2_NT_COUNTER holds the highest image version this machine has committed.
 * Commit happens after boot-complete, so a version that hangs does not raise the
 * floor and the previous slot stays reachable. Once a version has been blessed,
 * older slots are refused; that is the A/B consequence and it is deliberate.
 *
 * The guard checks before the root is used, but it is not part of the unseal.
 * A cleared TPM removes the counter and the seal together, so recovery means
 * re-provisioning, not a passphrase prompt.
 *
 * IMAGE_VERSION is packed as major*100 + minor*10 + patch. Two-digit minor or
 * patch components collide (0.10 == 1.0), so they are refused rather than packed
 * silently; vngrd-image asserts the shipped version fits at build time.
 */

#ifndef VNGRD_ROLLBACK_H
#define VNGRD_ROLLBACK_H

#include <stdint.h>

typedef enum RollbackResult {
        ROLLBACK_OK = 0,
        /* No counter yet. Pass; expected before the first commit and after a
         * TPM clear. */
        ROLLBACK_NO_FLOOR,
        ROLLBACK_BELOW_FLOOR,
        /* Unreadable or not an index. Fail closed. */
        ROLLBACK_FAILED,
} RollbackResult;

/* Parse "MAJOR[.MINOR[.PATCH]]". Returns 0 and writes *out on success; -1 on bad
 * grammar or a component that would collide. */
int rollback_index_from_version(const char *version, uint32_t *out);

/* Read IMAGE_VERSION= from the verified os-release at path. */
int rollback_index_from_os_release(const char *path, uint32_t *out);

/* Read the counter without comparing it. */
RollbackResult rollback_floor_read(const char *tcti_conf, uint64_t *floor_out);

/* Compare running against the frozen floor; floor_out is optional. */
RollbackResult rollback_check(const char *tcti_conf, uint32_t running, uint64_t *floor_out);

/* Raise the floor to at least running. An absent counter is a failure. */
int rollback_commit(const char *tcti_conf, uint32_t running);

/* Provisioning variant: define the counter only when marker carries
 * fixate-volume-key=. marker may be NULL. */
int rollback_commit_create(const char *tcti_conf, uint32_t running, const char *marker);

#endif /* VNGRD_ROLLBACK_H */

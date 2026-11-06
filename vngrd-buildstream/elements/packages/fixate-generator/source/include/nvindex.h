/* nvindex.h — read the fixate digest and the other guards' values from TPM NV.
 *
 * Read-only: the indexes are written once at provisioning. Auth is OWNERREAD
 * because the generator runs before the root is unlocked; the values are
 * non-secret digests/counters, so reading them discloses nothing.
 */

#ifndef VNGRD_NVINDEX_H
#define VNGRD_NVINDEX_H

#include <stddef.h>
#include <stdint.h>

/* 0x01800000-0x01BFFFFF is systemd's NVPCR pool (tpm2-util.h:644-645);
 * systemd-pcrlock uses 0x1C001000. 0x01C00000 is above the pool. The TCG profile
 * was not checked and swtpm enforces no reservations. */
#define VNGRD_NV_INDEX 0x01C00000u

/* One SHA-256 digest, hex-encoded into the crypttab. */
#define VNGRD_FIXATE_DIGEST_LEN 32u

/* Companion indexes, same range and OWNERREAD:
 *   0x01C00001 rollback counter (rollback.h)
 *   0x01C00002 GPT identity digest (gpt.h)
 *   0x01C00003 ESP contents digest (esp.h) */
#define VNGRD_NV_ROLLBACK_INDEX 0x01C00001u
#define VNGRD_NV_GPT_INDEX      0x01C00002u
#define VNGRD_NV_ESP_INDEX      0x01C00003u

/* ABSENT and FAILED must stay distinct: the first is an unprovisioned machine,
 * the second is a provisioned machine whose check silently stopped working. */
typedef enum NvReadResult {
        NV_READ_OK = 0,
        /* No index. Normal before provisioning and on the provisioning boot;
         * vngrd-fixate-guard turns it into a refusal on a provisioned machine. */
        NV_READ_ABSENT,
        /* Index exists but cannot be read. Fail closed. */
        NV_READ_FAILED,
} NvReadResult;

/* Read VNGRD_NV_INDEX into 2*VNGRD_FIXATE_DIGEST_LEN lowercase hex digits plus
 * NUL. tcti_conf is normally "device:/dev/tpmrm0"; the TPM drivers must be
 * built in, or the node does not exist when generators run. */
NvReadResult nvindex_read_fixate(const char *tcti_conf, char *out_hex, size_t out_hex_sz);

/* Read any index into out; no assumed length. The caller compares *out_got, so
 * an index of the wrong size is a refusal, not a truncated comparison. */
NvReadResult nvindex_read_raw(const char *tcti_conf, uint32_t index, uint8_t *out,
                              size_t out_cap, size_t *out_got);

#endif /* VNGRD_NVINDEX_H */

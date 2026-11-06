/* nvwrite.h — freeze values into TPM NV once, permanently.
 *
 * Write is authorised by the owner hierarchy with an empty password; the one-shot
 * property comes from WRITEDEFINE + WriteLock, not from a secret. An authValue
 * could be matched and used to rewrite the digest; a locked index cannot.
 *
 * Undefine is still possible with owner auth. Accepted: PCR 7 does not separate
 * host root from the initrd, so a delete policy buys no boundary. It becomes a
 * denial of service, not a silent downgrade, because an absent index off the
 * provisioning boot is refused by the guards.
 */

#ifndef VNGRD_NVWRITE_H
#define VNGRD_NVWRITE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "nvindex.h"

typedef enum NvWriteResult {
        NV_WRITE_OK = 0,
        /* Already frozen: the normal state after first boot; not an error. */
        NV_WRITE_ALREADY_PRESENT,
        NV_WRITE_FAILED,
} NvWriteResult;

/* OWNERREAD before unlock; WRITEDEFINE enables the permanent WriteLock; WRITEALL
 * avoids a half-written digest; NO_DA keeps reads off the DA counter.
 * POLICY_DELETE is clear on purpose (see above). */
#define VNGRD_NV_ATTRS                                                              \
        (0x00020000u /* OWNERREAD   */ | 0x00000002u /* OWNERWRITE */ |             \
         0x00002000u /* WRITEDEFINE */ | 0x00001000u /* WRITEALL    */ |             \
         0x02000000u /* NO_DA       */)

/* TPM2_NT_COUNTER (0x1 << 4): the TPM accepts only Increment, so the floor can
 * never be lowered. No WRITEDEFINE: a locked counter could never be incremented
 * again, which would make the next update unbootable. */
#define VNGRD_NV_COUNTER_ATTRS                                                      \
        (0x00000010u /* COUNTER (TPM2_NT_COUNTER << 4) */ |                        \
         0x00000002u /* OWNERWRITE */ | 0x00020000u /* OWNERREAD */ |              \
         0x02000000u /* NO_DA      */)

/* fixate_hex must be exactly 2*VNGRD_FIXATE_DIGEST_LEN hex digits. */
NvWriteResult nvwrite_freeze(const char *tcti_conf, const char *fixate_hex, uint32_t index);

/* Same define-write-lock for raw values (the GPT digest). */
NvWriteResult nvwrite_freeze_raw(const char *tcti_conf, const uint8_t *data, size_t len,
                                 uint32_t index);

/* Raise the rollback counter to target, incrementing only as far as needed.
 * create=false makes an absent counter a failure: defining it from a running
 * image would re-arm the floor at an attacker-chosen version. */
NvWriteResult nvwrite_counter_ensure(const char *tcti_conf, uint32_t index, uint64_t target,
                                     bool create);

#endif /* VNGRD_NVWRITE_H */

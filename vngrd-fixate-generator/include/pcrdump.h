/* pcrdump.h — print live PCR values from the TPM.
 *
 * A diagnostic, not part of the control. It exists because the seal binds
 * PolicyPCR over PCR 7 to concrete values, and "the unseal failed silently" does
 * not distinguish "PCR 7 moved" from "PCR 11 does not match the .pcrsig" from
 * "the key is wrong". Reading PCRs 4, 5, 7 and 11 settles it in one boot; PCR 5
 * is not in the seal but is the fastest way to see a changed GPT.
 */

#ifndef VNGRD_PCRDUMP_H
#define VNGRD_PCRDUMP_H

#include <stddef.h>
#include <stdint.h>

/* Print PCRs 4, 5, 7, 11 (sha256 bank) to stderr, one per line, as
 * "PCR <n> = <64 hex>". Returns 0 if all were read. */
int pcrdump(const char *tcti_conf, const int *pcrs, size_t n_pcrs);

#endif /* VNGRD_PCRDUMP_H */

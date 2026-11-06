/* sha256.h — the one hash this tree needs, implemented here on purpose.
 *
 * The GPT identity digest (gpt.c) and the ESP identity digest (esp.c) are
 * SHA-256s, and the obvious source is libcrypto. It is deliberately not used, for
 * one reason that is specific to where this runs: the guards that check those
 * digests execute in the initrd BEFORE the verified /usr is up, on a path where libcrypto is only present
 * because something else dlopen()ed it. libcrypto 3.x also resolves SHA-256
 * through its provider machinery, and the initrd seeds no ossl-modules, so
 * "libcrypto is linked" is not the same statement as "a digest will come out".
 *
 * A flat 60-line implementation removes the dependency entirely: the guard links
 * the same three libraries as the rest of the fixate toolkit and nothing that can
 * decide to load something that is not there. It is checked against the NIST
 * vectors in tests/test-sha256.c, including the two-block case, because a hash
 * that is wrong in a way that only shows up on long input is exactly the failure
 * that would make every GPT digest differ and every boot refuse.
 */

#ifndef VNGRD_SHA256_H
#define VNGRD_SHA256_H

#include <stddef.h>
#include <stdint.h>

#define VNGRD_SHA256_LEN 32u

/* The streaming form. It exists for one caller -- the ESP identity digest
 * (esp.h) -- which hashes a byte stream assembled from a directory tree plus the
 * contents of possibly-large files (the ESP's kernel image is ~16 MiB) and cannot
 * hold the whole stream in memory on an initrd whose only heap is what the stub
 * left. A wrong hash is the one failure that is invisible until a machine is
 * provisioned, so the one-shot below and this share a single block function and
 * tests/test-sha256.c checks that feeding the same bytes in every split size
 * agrees with the one-shot. */
typedef struct VngrdSha256 {
        uint32_t state[8];
        uint64_t total;   /* message bytes so far, for the length field */
        uint8_t buf[128]; /* pending block, plus room for the final padding block */
        size_t buflen;    /* pending bytes; always < 64 between updates */
} VngrdSha256;

void vngrd_sha256_init(VngrdSha256 *c);
void vngrd_sha256_update(VngrdSha256 *c, const void *data, size_t len);
void vngrd_sha256_final(VngrdSha256 *c, uint8_t out[VNGRD_SHA256_LEN]);

/* One-shot SHA-256 of data[0..len). */
void vngrd_sha256(const uint8_t *data, size_t len, uint8_t out[VNGRD_SHA256_LEN]);

#endif /* VNGRD_SHA256_H */

/* sha256.c — FIPS 180-4 SHA-256. See sha256.h for why it is not libcrypto. */

#include "sha256.h"

#include <string.h>

/* The eight round constants: the first 32 bits of the fractional parts of the
 * cube roots of the first 64 primes. */
static const uint32_t k[64] = {
        0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u,
        0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
        0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u,
        0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
        0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
        0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
        0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
        0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
        0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au,
        0x5b9cca4fu, 0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
        0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

/* The initial hash value: the first 32 bits of the fractional parts of the
 * square roots of the first 8 primes. */
static const uint32_t h0[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
};

static uint32_t rotr(uint32_t x, unsigned n) {
        return (x >> n) | (x << (32 - n));
}

/* One block: the unit update() tops up to and the unit it then compresses.
 * c->buf is TWO of these, but only so final() has room for the worst-case
 * padding block; the pending bytes between updates must never exceed ONE, or
 * bytes past offset 64 are dropped by the single sha256_block() below. */
enum { SHA256_BLOCK = 64 };

/* Process one 64-byte block. `w' is the message schedule. */
static void sha256_block(uint32_t state[8], const uint8_t block[64]) {
        uint32_t w[64];

        for (unsigned i = 0; i < 16; i++)
                w[i] = ((uint32_t) block[4 * i] << 24) | ((uint32_t) block[4 * i + 1] << 16) |
                       ((uint32_t) block[4 * i + 2] << 8) | (uint32_t) block[4 * i + 3];

        for (unsigned i = 16; i < 64; i++) {
                uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
                uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
                w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }

        uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
        uint32_t e = state[4], f = state[5], g = state[6], h = state[7];

        for (unsigned i = 0; i < 64; i++) {
                uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
                uint32_t ch = (e & f) ^ (~e & g);
                uint32_t t1 = h + s1 + ch + k[i] + w[i];
                uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
                uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
                uint32_t t2 = s0 + maj;

                h = g;
                g = f;
                f = e;
                e = d + t1;
                d = c;
                c = b;
                b = a;
                a = t1 + t2;
        }

        state[0] += a;
        state[1] += b;
        state[2] += c;
        state[3] += d;
        state[4] += e;
        state[5] += f;
        state[6] += g;
        state[7] += h;
}

void vngrd_sha256_init(VngrdSha256 *c) {
        memcpy(c->state, h0, sizeof(c->state));
        c->total = 0;
        c->buflen = 0;
}

void vngrd_sha256_update(VngrdSha256 *c, const void *data, size_t len) {
        const uint8_t *p = data;

        c->total += len;

        /* Top up only to the end of the current block, not the end of the
         * 128-byte buffer; otherwise bytes past 64 are silently dropped. */
        if (c->buflen != 0) {
                size_t need = SHA256_BLOCK - c->buflen;
                size_t take = len < need ? len : need;

                memcpy(c->buf + c->buflen, p, take);
                c->buflen += take;
                p += take;
                len -= take;

                if (c->buflen < SHA256_BLOCK)
                        return;
                sha256_block(c->state, c->buf);
                c->buflen = 0;
        }

        while (len >= SHA256_BLOCK) {
                sha256_block(c->state, p);
                p += SHA256_BLOCK;
                len -= SHA256_BLOCK;
        }

        if (len != 0) {
                memcpy(c->buf, p, len);
                c->buflen = len;
        }
}

void vngrd_sha256_final(VngrdSha256 *c, uint8_t out[VNGRD_SHA256_LEN]) {
        /* The same padding as the one-shot, built in c->buf rather than a stack
         * array: the pending bytes are already at c->buf[0], and one block (64) or
         * two (128) is enough for a 0x80 and the 64-bit length whatever buflen is
         * (it is < 64 here). */
        size_t rem = c->buflen;

        c->buf[rem++] = 0x80;

        size_t pad_end = (rem <= 56) ? 64 : 128;
        memset(c->buf + rem, 0, pad_end - rem - 8);

        uint64_t bits = c->total * 8u;
        for (unsigned i = 0; i < 8; i++)
                c->buf[pad_end - 1 - i] = (uint8_t) (bits >> (8 * i));

        sha256_block(c->state, c->buf);
        if (pad_end == 128)
                sha256_block(c->state, c->buf + 64);

        for (unsigned i = 0; i < 8; i++) {
                out[4 * i] = (uint8_t) (c->state[i] >> 24);
                out[4 * i + 1] = (uint8_t) (c->state[i] >> 16);
                out[4 * i + 2] = (uint8_t) (c->state[i] >> 8);
                out[4 * i + 3] = (uint8_t) c->state[i];
        }
}

void vngrd_sha256(const uint8_t *data, size_t len, uint8_t out[VNGRD_SHA256_LEN]) {
        VngrdSha256 c;

        vngrd_sha256_init(&c);
        vngrd_sha256_update(&c, data, len);
        vngrd_sha256_final(&c, out);
}

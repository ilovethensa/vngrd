/* test-sha256.c — SHA-256 against the NIST/FIPS 180-4 vectors, and the streaming
 * form against the one-shot.
 *
 * The GPT identity digest (gpt.c) and the ESP identity digest (esp.c) are
 * SHA-256s, and a hash that is wrong only on long or unaligned input is exactly the
 * mistake that stays invisible until a machine is provisioned and then every boot
 * refuses: the frozen digest was computed by the same wrong code, so it "matched"
 * until the input length crossed whatever boundary the bug was at. The
 * one-million-'a' vector is here for that reason, not for its own sake.
 *
 * esp.c hashes its byte stream incrementally (the ESP's kernel image does not fit
 * comfortably on the initrd heap), which is a second implementation of the padding
 * -- so the second half of this file feeds the same bytes in every split size and
 * requires the streaming and one-shot digests to be identical, lengths 0..200 so
 * the 55/56 and 63/64 block boundaries and the 64-bit length field are all crossed.
 *
 * Build: make test
 */

#include "sha256.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void to_hex(const uint8_t *in, size_t n, char *out) {
        static const char digits[] = "0123456789abcdef";

        for (size_t i = 0; i < n; i++) {
                out[2 * i] = digits[in[i] >> 4];
                out[2 * i + 1] = digits[in[i] & 0x0f];
        }
        out[2 * n] = '\0';
}

static void check(const char *what, const uint8_t *data, size_t len, const char *want) {
        uint8_t digest[VNGRD_SHA256_LEN];
        char got[2 * VNGRD_SHA256_LEN + 1];

        vngrd_sha256(data, len, digest);
        to_hex(digest, sizeof(digest), got);

        if (strcmp(got, want) == 0) {
                printf("  ok   %s\n", what);
                return;
        }
        printf("  FAIL %s\n    want: %s\n    got:  %s\n", what, want, got);
        failures++;
}

/* Feed the same bytes to the streaming API in every split size and require it to
 * agree with the one-shot. The one-shot is itself built on the streaming functions
 * now, so this is a check that update()'s block handling is right at every offset,
 * which is the part of the incremental path that a single-call test never reaches. */
static void streaming_equivalence(void) {
        static const size_t chunks[] = { 0 /* one byte at a time */, 1, 7, 13, 63, 64, 65, 200 };
        static uint8_t buf[200];
        uint8_t one[VNGRD_SHA256_LEN], stream[VNGRD_SHA256_LEN];
        int bad = 0;

        for (size_t i = 0; i < sizeof(buf); i++)
                buf[i] = (uint8_t) (i * 7 + 1);

        for (size_t len = 0; len <= sizeof(buf); len++) {
                vngrd_sha256(buf, len, one);

                for (size_t ci = 0; ci < sizeof(chunks) / sizeof(chunks[0]); ci++) {
                        size_t chunk = chunks[ci];
                        VngrdSha256 c;

                        vngrd_sha256_init(&c);
                        if (chunk == 0) {
                                for (size_t i = 0; i < len; i++)
                                        vngrd_sha256_update(&c, buf + i, 1);
                        } else {
                                for (size_t off = 0; off < len; off += chunk) {
                                        size_t n = len - off < chunk ? len - off : chunk;
                                        vngrd_sha256_update(&c, buf + off, n);
                                }
                        }
                        vngrd_sha256_final(&c, stream);

                        if (memcmp(one, stream, VNGRD_SHA256_LEN) != 0) {
                                printf("  FAIL streaming mismatch at length %zu, chunk %zu\n", len,
                                       chunk);
                                failures++;
                                bad++;
                        }
                }
        }

        if (bad == 0)
                printf("  ok   streaming agrees with the one-shot for lengths 0..200, every split\n");
}

int main(void) {
        printf("test-sha256: FIPS 180-4 vectors\n");

        check("empty", (const uint8_t *) "", 0,
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        check("abc", (const uint8_t *) "abc", 3,
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        check("two-block 56 byte", (const uint8_t *) "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56,
              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

        /* The classic multi-block case. Also the only one that exercises the 64-bit
         * length field above a single low byte: 8,000,000 bits. */
        {
                static uint8_t million[1000000];
                memset(million, 'a', sizeof(million));
                check("one million 'a'", million, sizeof(million),
                      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
        }

        streaming_equivalence();

        if (failures != 0) {
                printf("test-sha256: %d FAILED\n", failures);
                return 1;
        }
        printf("test-sha256: all cases pass\n");
        return 0;
}

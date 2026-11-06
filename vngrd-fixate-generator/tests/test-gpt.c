/* test-gpt.c — the GPT identity digest, over a synthetic partition table.
 *
 * The whole point of the digest is which fields move it and which deliberately do
 * not, and that is decided without a disk and without a TPM. The two cases that
 * matter most:
 *
 *   - the usr and usr-verity slots' uuid, label and attributes are EXCLUDED, so a
 *     systemd-sysupdate that renames a slot and fixates a new UUID onto it does
 *     not turn the next boot into a refusal;
 *   - the ESP and the root entry are fully covered, so a substituted ESP or a
 *     re-provisioned layout does.
 *
 * A regression in either direction is silent until a machine is in the field:
 * including the usr fields breaks every update, and excluding the ESP fields is
 * the substitution the control exists to refuse.
 *
 * Build: make test
 */

#define _GNU_SOURCE

#include "gpt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SECTOR 512u
#define ENTRY_SIZE 128u
#define N_ENTRIES 128u
#define ENTRY_LBA 2u
#define IMG_SIZE (ENTRY_LBA * SECTOR + N_ENTRIES * ENTRY_SIZE)

/* The type GUIDs, in on-disk (mixed-endian) byte order. See gpt.c guid_to_string. */
static const uint8_t TYPE_ESP[16] = {
        0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11,
        0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b,
};
static const uint8_t TYPE_USR[16] = {
        0x0c, 0x68, 0x84, 0x84, 0x21, 0x95, 0xc6, 0x48,
        0x9c, 0x11, 0xb0, 0x72, 0x06, 0x56, 0xf6, 0x9e,
};
static const uint8_t TYPE_ROOT[16] = {
        0xe3, 0xbc, 0x68, 0x4f, 0xcd, 0xe8, 0xb1, 0x4d,
        0x96, 0xe7, 0xfb, 0xca, 0xf9, 0x84, 0xb7, 0x09,
};

static uint8_t image[IMG_SIZE];
static uint8_t baseline[VNGRD_GPT_DIGEST_LEN];

static int failures;

static void put_le32(uint8_t *p, uint32_t v) {
        for (unsigned i = 0; i < 4; i++)
                p[i] = (uint8_t) (v >> (8 * i));
}

static void put_le64(uint8_t *p, uint64_t v) {
        for (unsigned i = 0; i < 8; i++)
                p[i] = (uint8_t) (v >> (8 * i));
}

static void put_name(uint8_t *p, const char *name) {
        memset(p, 0, 72);
        for (unsigned i = 0; name[i] != '\0' && i < 36; i++)
                p[2 * i] = (uint8_t) name[i];
}

/* The entry-th record (0-based) in the array. */
static uint8_t *entry(unsigned i) {
        return image + ENTRY_LBA * SECTOR + (size_t) i * ENTRY_SIZE;
}

static void set_entry(unsigned i, const uint8_t type[16], uint8_t salt,
                      uint64_t start, uint64_t end, const char *name) {
        uint8_t *e = entry(i);

        memcpy(e, type, 16);
        for (unsigned b = 0; b < 16; b++)
                e[16 + b] = (uint8_t) (0xa0 + salt + b); /* a stable, distinct uuid */
        put_le64(e + 32, start);
        put_le64(e + 40, end);
        put_le64(e + 48, 0);
        put_name(e + 56, name);
}

static void build(void) {
        memset(image, 0, sizeof(image));

        uint8_t *h = image + SECTOR;
        memcpy(h, "EFI PART", 8);
        put_le32(h + 8, 0x00010000u);
        put_le32(h + 12, 92u);
        for (unsigned b = 0; b < 16; b++)
                h[56 + b] = (uint8_t) (0x10 + b); /* the disk GUID */
        put_le64(h + 72, ENTRY_LBA);
        put_le32(h + 80, N_ENTRIES);
        put_le32(h + 84, ENTRY_SIZE);

        set_entry(0, TYPE_ESP, 0x01, 2048, 657407, "vngrd-esp");
        set_entry(1, TYPE_USR, 0x02, 657408, 726527, "vngrd-usr_A");
        set_entry(2, TYPE_ROOT, 0x03, 726528, 4000000, "vngrd-root");
}

static void digest(uint8_t out[VNGRD_GPT_DIGEST_LEN]) {
        const char *path = "/tmp/vngrd-test-gpt.img";
        FILE *f = fopen(path, "we");

        if (f == NULL) {
                perror(path);
                exit(1);
        }
        if (fwrite(image, 1, sizeof(image), f) != sizeof(image)) {
                perror("fwrite");
                exit(1);
        }
        fclose(f);

        if (gpt_identity_digest(path, out) != 0) {
                printf("  FAIL gpt_identity_digest returned non-zero\n");
                failures++;
                memset(out, 0, VNGRD_GPT_DIGEST_LEN);
        }
}

static void expect_same(const char *what) {
        uint8_t d[VNGRD_GPT_DIGEST_LEN];
        digest(d);

        if (memcmp(d, baseline, VNGRD_GPT_DIGEST_LEN) == 0) {
                printf("  ok   %s (digest unchanged)\n", what);
                return;
        }
        printf("  FAIL %s (digest changed, but must not)\n", what);
        failures++;
}

static void expect_different(const char *what) {
        uint8_t d[VNGRD_GPT_DIGEST_LEN];
        digest(d);

        if (memcmp(d, baseline, VNGRD_GPT_DIGEST_LEN) != 0) {
                printf("  ok   %s (digest changed)\n", what);
                return;
        }
        printf("  FAIL %s (digest did not change, but must)\n", what);
        failures++;
}

int main(void) {
        printf("test-gpt: partition identity digest\n");
        build();
        digest(baseline);

        /* Volatile: what sysupdate rewrites on an update. */
        build();
        entry(1)[16] ^= 0xff; /* the usr slot's uuid */
        expect_same("usr uuid changed");

        build();
        put_name(entry(1) + 56, "vngrd-usr_B");
        expect_same("usr label changed");

        build();
        put_le64(entry(1) + 48, 0x1000000000000000ull); /* ReadOnly + flags */
        expect_same("usr attributes changed");

        /* Stable: geometry, and everything about the ESP and root. */
        build();
        put_le64(entry(1) + 32, 657409); /* usr first_lba */
        expect_different("usr start LBA moved");

        build();
        entry(0)[18] ^= 0x01; /* the ESP uuid */
        expect_different("ESP uuid changed");

        build();
        put_name(entry(0) + 56, "other-esp");
        expect_different("ESP label changed");

        build();
        put_name(entry(2) + 56, "other-root");
        expect_different("root label changed");

        build();
        put_le64(entry(2) + 40, 3999999); /* root end LBA */
        expect_different("root size changed");

        build();
        image[SECTOR + 56] ^= 0x01; /* disk GUID */
        expect_different("disk GUID changed");

        if (failures != 0) {
                printf("test-gpt: %d FAILED\n", failures);
                return 1;
        }
        printf("test-gpt: all cases pass\n");
        return 0;
}

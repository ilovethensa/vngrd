/* gpt.c — the GPT identity digest and whole-disk resolution. See gpt.h. */

#define _GNU_SOURCE

#include "gpt.h"
#include "diagnose.h"
#include "sha256.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

/* BLKSSZGET from linux/fs.h. Do not include that header: its structs collide
 * with libc's, and the ioctl number has been stable since 2.4. */
#ifndef BLKSSZGET
#define BLKSSZGET _IO(0x12, 104)
#endif

/* LBA 1, little-endian; offsets from EFI_PARTITION_TABLE_HEADER. */
#define GPT_HEADER_LBA 1u
#define GPT_HEADER_MIN 92u
#define GPT_SIG "EFI PART"
#define GPT_OFF_DISK_GUID 56u
#define GPT_OFF_ENTRY_LBA 72u
#define GPT_OFF_NUM_ENTRIES 80u
#define GPT_OFF_ENTRY_SIZE 84u

/* Cap the entry array: 128x128 is the universal size; believing the header's
 * 2^32 entries would be a memory-exhaustion bug. */
#define GPT_MAX_ENTRIES 4096u
#define GPT_MIN_ENTRY_SIZE 128u
#define GPT_MAX_ENTRY_SIZE 512u

/* sd-gpt.h USR_X86_64 and USR_X86_64_VERITY; see gpt.h for exclusions. */
#define GPT_GUID_USR "8484680c-9521-48c6-9c11-b0720656f69e"
#define GPT_GUID_USR_VERITY "77ff5f63-e7b6-4633-acf4-1565b864c0e6"

static uint32_t rd_le32(const uint8_t *p) {
        return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) |
               ((uint32_t) p[3] << 24);
}

static uint64_t rd_le64(const uint8_t *p) {
        uint64_t v = 0;
        for (unsigned i = 0; i < 8; i++)
                v |= (uint64_t) p[i] << (8 * i);
        return v;
}

/* Mixed-endian GUID to canonical lowercase: first three fields LE, rest verbatim. */
static void guid_to_string(const uint8_t g[16], char out[37]) {
        snprintf(out, 37,
                 "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                 g[3], g[2], g[1], g[0], g[5], g[4], g[7], g[6], g[8], g[9], g[10], g[11],
                 g[12], g[13], g[14], g[15]);
}

static bool guid_is_zero(const uint8_t g[16]) {
        for (unsigned i = 0; i < 16; i++)
                if (g[i] != 0)
                        return false;
        return true;
}

/* Is this partition's type one whose uuid/label/attributes sysupdate rewrites? */
static bool guid_is_volatile(const uint8_t g[16]) {
        char s[37];
        guid_to_string(g, s);
        return strcmp(s, GPT_GUID_USR) == 0 || strcmp(s, GPT_GUID_USR_VERITY) == 0;
}

int gpt_disk_for_partlabel(const char *partlabel, char *out, size_t out_sz) {
        char link[256];
        char resolved[PATH_MAX];
        char syslink[320];
        char sysresolved[PATH_MAX];
        char *slash;

        if (partlabel == NULL || out == NULL)
                return -1;
        out[0] = '\0';

        snprintf(link, sizeof(link), "/dev/disk/by-partlabel/%s", partlabel);
        if (realpath(link, resolved) == NULL) {
                /* Absent on the first boot; the caller decides whether that is fatal. */
                return -1;
        }

        /* via /sys/class/block realpath to .../block/<disk>/<part>; the parent
         * basename is the whole-disk name for any naming scheme. */
        slash = strrchr(resolved, '/');
        if (slash == NULL || slash[1] == '\0')
                return -1;
        snprintf(syslink, sizeof(syslink), "/sys/class/block/%s", slash + 1);
        if (realpath(syslink, sysresolved) == NULL)
                return -1;

        char *dir = strrchr(sysresolved, '/');
        if (dir == NULL || dir == sysresolved)
                return -1;
        *dir = '\0';
        char *disk = strrchr(sysresolved, '/');
        if (disk == NULL || disk[1] == '\0')
                return -1;

        int n = snprintf(out, out_sz, "/dev/%s", disk + 1);
        if (n < 0 || (size_t) n >= out_sz) {
                out[0] = '\0';
                return -1;
        }
        return 0;
}

int gpt_identity_digest(const char *disk_path, uint8_t out[VNGRD_GPT_DIGEST_LEN]) {
        if (disk_path == NULL || out == NULL)
                return -1;

        int fd = open(disk_path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
                diagnose("vngrd-gpt: cannot open %s: %s", disk_path, strerror(errno));
                return -1;
        }

        /* LBA is the logical block size: 4096 on 4Kn, so query it. */
        unsigned sector = 512;
        int lsz = 0;
        if (ioctl(fd, BLKSSZGET, &lsz) == 0 && lsz > 0)
                sector = (unsigned) lsz;
        if (sector < 512)
                sector = 512;

        uint8_t hdr[GPT_HEADER_MIN];
        if (pread(fd, hdr, sizeof(hdr), (off_t) GPT_HEADER_LBA * sector) != (ssize_t) sizeof(hdr)) {
                diagnose("vngrd-gpt: cannot read the GPT header of %s", disk_path);
                close(fd);
                return -1;
        }
        if (memcmp(hdr, GPT_SIG, 8) != 0) {
                diagnose("vngrd-gpt: %s has no GPT (the LBA 1 header is not 'EFI PART')", disk_path);
                close(fd);
                return -1;
        }

        uint32_t num = rd_le32(hdr + GPT_OFF_NUM_ENTRIES);
        uint32_t esz = rd_le32(hdr + GPT_OFF_ENTRY_SIZE);
        uint64_t elba = rd_le64(hdr + GPT_OFF_ENTRY_LBA);

        if (num == 0 || num > GPT_MAX_ENTRIES || esz < GPT_MIN_ENTRY_SIZE || esz > GPT_MAX_ENTRY_SIZE) {
                diagnose("vngrd-gpt: %s has an implausible partition entry array (%u entries of %u bytes)",
                         disk_path, num, esz);
                close(fd);
                return -1;
        }

        size_t arr = (size_t) num * esz;
        uint8_t *entries = malloc(arr);
        if (entries == NULL) {
                close(fd);
                return -1;
        }
        if (pread(fd, entries, arr, (off_t) elba * sector) != (ssize_t) arr) {
                diagnose("vngrd-gpt: cannot read the partition entry array of %s", disk_path);
                free(entries);
                close(fd);
                return -1;
        }
        close(fd);

        /* disk GUID, count, entry size, then fixed 128-byte records for non-empty
         * partitions. */
        size_t cap = 24 + (size_t) num * 128;
        uint8_t *canon = malloc(cap);
        if (canon == NULL) {
                free(entries);
                return -1;
        }
        size_t o = 0;

        memcpy(canon + o, hdr + GPT_OFF_DISK_GUID, 16);
        o += 16;
        for (unsigned i = 0; i < 4; i++)
                canon[o++] = (uint8_t) (num >> (8 * i));
        for (unsigned i = 0; i < 4; i++)
                canon[o++] = (uint8_t) (esz >> (8 * i));

        for (uint32_t i = 0; i < num; i++) {
                const uint8_t *e = entries + (size_t) i * esz;
                const uint8_t *type = e;
                const uint8_t *uniq = e + 16;

                if (guid_is_zero(type))
                        continue;

                bool volatile_fields = guid_is_volatile(type);

                memcpy(canon + o, type, 16);
                o += 16;
                if (volatile_fields) {
                        memset(canon + o, 0, 16);
                        o += 16;
                } else {
                        memcpy(canon + o, uniq, 16);
                        o += 16;
                }
                memcpy(canon + o, e + 32, 8); /* starting_lba, verbatim */
                o += 8;
                memcpy(canon + o, e + 40, 8); /* ending_lba */
                o += 8;
                if (volatile_fields) {
                        memset(canon + o, 0, 8); /* attributes */
                        o += 8;
                        memset(canon + o, 0, 72); /* partition name */
                        o += 72;
                } else {
                        memcpy(canon + o, e + 48, 8);
                        o += 8;
                        memcpy(canon + o, e + 56, 72);
                        o += 72;
                }
        }

        vngrd_sha256(canon, o, out);

        free(canon);
        free(entries);
        return 0;
}

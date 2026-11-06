/* esp.c — the ESP identity digest and the mount that makes it readable. See esp.h. */

#define _GNU_SOURCE

#include "esp.h"
#include "diagnose.h"
#include "sha256.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

/* The private mountpoint. /run is a tmpfs in the initrd, so this is cheap and it
 * cannot collide with /efi, which is where the HOST mounts the ESP (the guards and
 * the freeze all run in the initrd, so this never races that). */
#define VNGRD_ESP_MOUNTPOINT "/run/vngrd-esp"

/* Join a and b with a single '/', or return -1 if it does not fit. Used for both
 * the device path and the walk's paths; truncation here would silently digest the
 * wrong file, so it is a hard error rather than a snprintf that reports success. */
static int join_path(char *dst, size_t dst_sz, const char *a, const char *b) {
        int n = snprintf(dst, dst_sz, "%s/%s", a, b);
        return (n < 0 || (size_t) n >= dst_sz) ? -1 : 0;
}

/* The canonical stream's fixed-width fields, little-endian so they do not depend
 * on the host's byte order (the digest is compared across boots of the same
 * machine, but a 4Kn ARM board with a TPM would want the same bytes as an x86 one
 * if this toolkit is ever ported, and being explicit costs nothing). */
static void cs_u32(VngrdSha256 *c, uint32_t v) {
        uint8_t b[4];
        for (unsigned i = 0; i < 4; i++)
                b[i] = (uint8_t) (v >> (8 * i));
        vngrd_sha256_update(c, b, sizeof(b));
}

static void cs_u64(VngrdSha256 *c, uint64_t v) {
        uint8_t b[8];
        for (unsigned i = 0; i < 8; i++)
                b[i] = (uint8_t) (v >> (8 * i));
        vngrd_sha256_update(c, b, sizeof(b));
}

/* One item: tag, path length, path. See esp.h for the stream. */
static void cs_item(VngrdSha256 *c, uint8_t tag, const char *rel) {
        size_t len = strlen(rel);

        vngrd_sha256_update(c, &tag, 1);
        cs_u32(c, (uint32_t) len);
        vngrd_sha256_update(c, rel, len);
}

/* Case-insensitive because vfat folds case and writers disagree; see esp.h. */
static bool path_is(const char *rel, const char *want) {
        for (; *rel != '\0' && *want != '\0'; rel++, want++) {
                unsigned char a = (unsigned char) *rel;
                unsigned char b = (unsigned char) *want;

                if (a >= 'A' && a <= 'Z')
                        a = (unsigned char) (a - 'A' + 'a');
                if (b >= 'A' && b <= 'Z')
                        b = (unsigned char) (b - 'A' + 'a');
                if (a != b)
                        return false;
        }
        return *rel == '\0' && *want == '\0';
}

/* Exclusions live here; esp.h documents them. A match is pruned and its
 * directory entry is not hashed. */
static bool excluded(const char *rel) {
        return path_is(rel, "EFI/systemd") || path_is(rel, "EFI/BOOT") ||
               path_is(rel, "EFI/Linux") || path_is(rel, "loader/entries") ||
               path_is(rel, "loader/entries.srel") || path_is(rel, "loader/credentials") ||
               path_is(rel, "loader/random-seed");
}

/* Hash 'F' + path + size + content. The size is st_size and the read must yield
 * exactly that many bytes: a short read is a file that changed under us or a
 * broken filesystem, and digesting a prefix of it would freeze a value no later
 * boot could reproduce. */
static int hash_file(VngrdSha256 *c, const char *rel, const char *full,
                     const struct stat *st) {
        int fd = open(full, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) {
                diagnose("vngrd-esp: cannot open %s: %s", full, strerror(errno));
                return -1;
        }

        cs_item(c, 'F', rel);
        cs_u64(c, (uint64_t) st->st_size);

        uint8_t buf[65536];
        uint64_t left = (uint64_t) st->st_size;

        while (left > 0) {
                size_t want = left < sizeof(buf) ? (size_t) left : sizeof(buf);
                ssize_t got = read(fd, buf, want);

                if (got < 0) {
                        diagnose("vngrd-esp: read of %s failed: %s", full, strerror(errno));
                        close(fd);
                        return -1;
                }
                if (got == 0) {
                        diagnose("vngrd-esp: %s is shorter than its directory entry claims", full);
                        close(fd);
                        return -1;
                }
                vngrd_sha256_update(c, buf, (size_t) got);
                left -= (uint64_t) got;
        }

        close(fd);
        return 0;
}

static int cmp_names(const void *a, const void *b) {
        return strcmp(*(const char *const *) a, *(const char *const *) b);
}

/* Pre-order walk of root/rel, children sorted by strcmp so the stream is a
 * function of the tree and not of readdir order. */
static int walk(const char *root, const char *rel, VngrdSha256 *c) {
        char full[PATH_MAX];

        if (*rel == '\0') {
                int n = snprintf(full, sizeof(full), "%s", root);

                if (n < 0 || (size_t) n >= sizeof(full)) {
                        diagnose("vngrd-esp: path too long: %s", root);
                        return -1;
                }
        } else if (join_path(full, sizeof(full), root, rel) != 0) {
                diagnose("vngrd-esp: path too long under %s", root);
                return -1;
        }

        DIR *d = opendir(full);
        if (d == NULL) {
                diagnose("vngrd-esp: cannot read directory %s: %s", full, strerror(errno));
                return -1;
        }

        char **names = NULL;
        size_t n = 0, cap = 0;
        struct dirent *e;

        while ((e = readdir(d)) != NULL) {
                if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
                        continue;
                if (n == cap) {
                        size_t ncap = cap != 0 ? cap * 2 : 16;
                        char **grown = realloc(names, ncap * sizeof(*grown));

                        if (grown == NULL) {
                                closedir(d);
                                goto fail;
                        }
                        names = grown;
                        cap = ncap;
                }
                names[n] = strdup(e->d_name);
                if (names[n] == NULL) {
                        closedir(d);
                        goto fail;
                }
                n++;
        }
        closedir(d);

        qsort(names, n, sizeof(*names), cmp_names);

        int rc = 0;
        for (size_t i = 0; i < n; i++) {
                char child[PATH_MAX];
                char cfull[PATH_MAX];

                if (*rel == '\0') {
                        int cn = snprintf(child, sizeof(child), "%s", names[i]);

                        if (cn < 0 || (size_t) cn >= sizeof(child)) {
                                diagnose("vngrd-esp: path too long under %s", root);
                                rc = -1;
                                break;
                        }
                } else if (join_path(child, sizeof(child), rel, names[i]) != 0) {
                        diagnose("vngrd-esp: path too long under %s", root);
                        rc = -1;
                        break;
                }

                if (excluded(child))
                        continue;

                if (join_path(cfull, sizeof(cfull), root, child) != 0) {
                        diagnose("vngrd-esp: path too long under %s", root);
                        rc = -1;
                        break;
                }

                struct stat st;
                if (lstat(cfull, &st) != 0) {
                        diagnose("vngrd-esp: cannot stat %s: %s", cfull, strerror(errno));
                        rc = -1;
                        break;
                }

                if (S_ISDIR(st.st_mode)) {
                        cs_item(c, 'D', child);
                        if (walk(root, child, c) != 0) {
                                rc = -1;
                                break;
                        }
                } else if (hash_file(c, child, cfull, &st) != 0) {
                        rc = -1;
                        break;
                }
        }

        for (size_t i = 0; i < n; i++)
                free(names[i]);
        free(names);
        return rc;

fail:
        for (size_t i = 0; i < n; i++)
                free(names[i]);
        free(names);
        return -1;
}

int esp_digest_tree(const char *root, uint8_t out[VNGRD_ESP_DIGEST_LEN]) {
        if (root == NULL || out == NULL)
                return -1;

        VngrdSha256 c;
        vngrd_sha256_init(&c);

        if (walk(root, "", &c) != 0)
                return -1;

        vngrd_sha256_final(&c, out);
        return 0;
}

int esp_identity_digest(const char *partlabel, uint8_t out[VNGRD_ESP_DIGEST_LEN]) {
        if (partlabel == NULL || out == NULL)
                return -1;

        char dev[PATH_MAX];
        char resolved[PATH_MAX];

        int dn = snprintf(dev, sizeof(dev), "/dev/disk/by-partlabel/%s", partlabel);

        if (dn < 0 || (size_t) dn >= sizeof(dev)) {
                diagnose("vngrd-esp: partition label too long: %s", partlabel);
                return -1;
        }
        if (realpath(dev, resolved) == NULL) {
                diagnose("vngrd-esp: cannot resolve %s: %s", dev, strerror(errno));
                return -1;
        }

        if (mkdir(VNGRD_ESP_MOUNTPOINT, 0700) != 0 && errno != EEXIST) {
                diagnose("vngrd-esp: cannot create %s: %s", VNGRD_ESP_MOUNTPOINT,
                         strerror(errno));
                return -1;
        }

        /* Read-only and nosuid/nodev/noexec: the ESP is attacker-writable and
         * nothing here is executed. A non-vfat partition fails the mount. */
        if (mount(resolved, VNGRD_ESP_MOUNTPOINT, "vfat",
                  MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) != 0) {
                diagnose("vngrd-esp: cannot mount %s on %s read-only: %s", dev,
                         VNGRD_ESP_MOUNTPOINT, strerror(errno));
                return -1;
        }

        int rc = esp_digest_tree(VNGRD_ESP_MOUNTPOINT, out);

        /* Lazy unmount so a busy filesystem (a readdir in flight, which cannot
         * outlive this process) still detaches; the process is about to exit and
         * nothing references the mountpoint again. */
        if (umount2(VNGRD_ESP_MOUNTPOINT, MNT_DETACH) != 0)
                diagnose("vngrd-esp: cannot unmount %s: %s", VNGRD_ESP_MOUNTPOINT,
                         strerror(errno));

        return rc;
}

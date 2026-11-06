/* bootsync.c — see bootsync.h. Copy, fsync, rename, read back, compare. */

#define _GNU_SOURCE

#include "bootsync.h"
#include "diagnose.h"
#include "sha256.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

/* The two paths bootctl installs, and the source is the same binary: mkosi signs
 * one sd-boot and bootctl copies it to both. Writing both from the one buffer
 * keeps them equal even if the source is replaced between two copies. */
static const char *const targets[] = {
        "EFI/systemd/systemd-bootx64.efi",
        "EFI/BOOT/BOOTX64.EFI",
};

/* ~200 KiB normally; the cap catches a block device or wrong path. */
#define SOURCE_MAX (32u * 1024u * 1024u)

static int join(char *dst, size_t dst_sz, const char *a, const char *b) {
        int n = snprintf(dst, dst_sz, "%s/%s", a, b);

        return (n < 0 || (size_t) n >= dst_sz) ? -1 : 0;
}

/* Read one regular file into a fresh malloc. O_NOFOLLOW is deliberate: the ESP is
 * attacker-writable between boots, and a redirect to another file is not a loader
 * update. */
static int read_regular(const char *path, uint8_t **out, size_t *out_len) {
        int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);

        if (fd < 0) {
                diagnose("vngrd-bootloader-sync: cannot open %s: %s", path, strerror(errno));
                return -1;
        }

        struct stat st;
        if (fstat(fd, &st) != 0) {
                diagnose("vngrd-bootloader-sync: stat %s failed: %s", path, strerror(errno));
                close(fd);
                return -1;
        }
        if (!S_ISREG(st.st_mode)) {
                diagnose("vngrd-bootloader-sync: %s is not a regular file", path);
                close(fd);
                return -1;
        }
        if (st.st_size <= 0 || (uint64_t) st.st_size > SOURCE_MAX) {
                diagnose("vngrd-bootloader-sync: refusing %s of %lld bytes", path,
                         (long long) st.st_size);
                close(fd);
                return -1;
        }

        size_t len = (size_t) st.st_size;
        uint8_t *buf = malloc(len);
        if (buf == NULL) {
                diagnose("vngrd-bootloader-sync: out of memory reading %s", path);
                close(fd);
                return -1;
        }

        size_t got = 0;
        while (got < len) {
                ssize_t n = read(fd, buf + got, len - got);

                if (n < 0) {
                        diagnose("vngrd-bootloader-sync: read %s failed: %s", path,
                                 strerror(errno));
                        free(buf);
                        close(fd);
                        return -1;
                }
                if (n == 0) {
                        diagnose("vngrd-bootloader-sync: %s is shorter than its size", path);
                        free(buf);
                        close(fd);
                        return -1;
                }
                got += (size_t) n;
        }
        close(fd);

        *out = buf;
        *out_len = len;
        return 0;
}

/* 1 = same, 0 = missing/different, -1 = unreadable. Treating unreadable as
 * different would rename over what may be the only working loader. */
static int same_file(const char *path, const uint8_t *data, size_t len) {
        int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);

        if (fd < 0) {
                if (errno == ENOENT)
                        return 0;
                diagnose("vngrd-bootloader-sync: cannot read %s: %s", path, strerror(errno));
                return -1;
        }

        struct stat st;
        if (fstat(fd, &st) != 0) {
                diagnose("vngrd-bootloader-sync: stat %s failed: %s", path, strerror(errno));
                close(fd);
                return -1;
        }
        if (!S_ISREG(st.st_mode) || (uint64_t) st.st_size != len) {
                close(fd);
                return 0;
        }

        uint8_t buf[65536];
        size_t off = 0;
        while (off < len) {
                size_t want = len - off < sizeof(buf) ? len - off : sizeof(buf);
                ssize_t n = read(fd, buf, want);

                if (n <= 0) {
                        diagnose("vngrd-bootloader-sync: read %s failed: %s", path,
                                 n < 0 ? strerror(errno) : "short read");
                        close(fd);
                        return -1;
                }
                if (memcmp(buf, data + off, (size_t) n) != 0) {
                        close(fd);
                        return 0;
                }
                off += (size_t) n;
        }
        close(fd);
        return 1;
}

/* mkdir -p for a path whose parent may not exist on a fresh ESP. */
static int mkdir_p(const char *path) {
        char work[PATH_MAX];

        if (snprintf(work, sizeof(work), "%s", path) >= (int) sizeof(work)) {
                diagnose("vngrd-bootloader-sync: path too long: %s", path);
                return -1;
        }

        for (char *p = work + 1; *p != '\0'; p++) {
                if (*p != '/')
                        continue;
                *p = '\0';
                if (mkdir(work, 0755) != 0 && errno != EEXIST) {
                        diagnose("vngrd-bootloader-sync: mkdir %s failed: %s", work,
                                 strerror(errno));
                        return -1;
                }
                *p = '/';
        }
        if (mkdir(work, 0755) != 0 && errno != EEXIST) {
                diagnose("vngrd-bootloader-sync: mkdir %s failed: %s", work, strerror(errno));
                return -1;
        }
        return 0;
}

/* Write temp in the target's own directory, fsync it, rename over the target, and
 * fsync the directory. The rename is the moment the new loader becomes visible;
 * fsync before it means a crash leaves the old loader, not a torn new one. */
static int write_atomic(const char *path, const uint8_t *data, size_t len) {
        char tmp[PATH_MAX];
        char dir[PATH_MAX];

        if (snprintf(tmp, sizeof(tmp), "%s.vngrd-tmp", path) >= (int) sizeof(tmp) ||
            snprintf(dir, sizeof(dir), "%s", path) >= (int) sizeof(dir)) {
                diagnose("vngrd-bootloader-sync: path too long: %s", path);
                return -1;
        }
        char *slash = strrchr(dir, '/');
        if (slash == NULL) {
                diagnose("vngrd-bootloader-sync: no directory in %s", path);
                return -1;
        }
        *slash = '\0';

        int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0644);
        if (fd < 0) {
                diagnose("vngrd-bootloader-sync: cannot create %s: %s", tmp, strerror(errno));
                return -1;
        }

        size_t off = 0;
        while (off < len) {
                ssize_t n = write(fd, data + off, len - off);

                if (n < 0) {
                        diagnose("vngrd-bootloader-sync: write %s failed: %s", tmp,
                                 strerror(errno));
                        close(fd);
                        unlink(tmp);
                        return -1;
                }
                off += (size_t) n;
        }
        if (fsync(fd) != 0) {
                diagnose("vngrd-bootloader-sync: fsync %s failed: %s", tmp, strerror(errno));
                close(fd);
                unlink(tmp);
                return -1;
        }
        if (close(fd) != 0) {
                diagnose("vngrd-bootloader-sync: close %s failed: %s", tmp, strerror(errno));
                unlink(tmp);
                return -1;
        }

        if (rename(tmp, path) != 0) {
                diagnose("vngrd-bootloader-sync: rename %s to %s failed: %s", tmp, path,
                         strerror(errno));
                unlink(tmp);
                return -1;
        }

        /* vfat may return EINVAL for a directory fsync; the file fsync above is the
         * one that carries the data, and the rename is already durable enough for
         * the next boot on the filesystems this runs on. Anything else is real. */
        int dfd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (dfd >= 0) {
                if (fsync(dfd) != 0 && errno != EINVAL)
                        diagnose("vngrd-bootloader-sync: fsync %s failed: %s", dir,
                                 strerror(errno));
                close(dfd);
        }

        int same = same_file(path, data, len);
        if (same != 1) {
                diagnose("vngrd-bootloader-sync: %s does not read back as the source%s", path,
                         same < 0 ? "" : " (different bytes)");
                return -1;
        }
        return 0;
}

int bootsync_tree(const char *source, const char *esp_root) {
        if (source == NULL || esp_root == NULL)
                return -1;

        uint8_t *data = NULL;
        size_t len = 0;

        if (read_regular(source, &data, &len) != 0)
                return -1;

        int rc = 0;
        for (size_t i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
                char path[PATH_MAX];

                if (join(path, sizeof(path), esp_root, targets[i]) != 0) {
                        diagnose("vngrd-bootloader-sync: path too long under %s", esp_root);
                        rc = -1;
                        break;
                }

                int same = same_file(path, data, len);
                if (same < 0) {
                        rc = -1;
                        break;
                }
                if (same == 1)
                        continue;

                char parent[PATH_MAX];
                if (snprintf(parent, sizeof(parent), "%s", path) >= (int) sizeof(parent)) {
                        rc = -1;
                        break;
                }
                char *slash = strrchr(parent, '/');
                if (slash == NULL) {
                        rc = -1;
                        break;
                }
                *slash = '\0';

                if (mkdir_p(parent) != 0 || write_atomic(path, data, len) != 0) {
                        rc = -1;
                        break;
                }
        }

        free(data);
        return rc;
}

int bootsync_esp(const char *partlabel, const char *source) {
        if (partlabel == NULL || source == NULL)
                return -1;

        char dev[PATH_MAX];
        char resolved[PATH_MAX];

        int n = snprintf(dev, sizeof(dev), "/dev/disk/by-partlabel/%s", partlabel);
        if (n < 0 || (size_t) n >= sizeof(dev)) {
                diagnose("vngrd-bootloader-sync: partition label too long: %s", partlabel);
                return -1;
        }
        if (realpath(dev, resolved) == NULL) {
                diagnose("vngrd-bootloader-sync: cannot resolve %s: %s", dev, strerror(errno));
                return -1;
        }

        if (mkdir(VNGRD_BOOTSYNC_MOUNTPOINT, 0700) != 0 && errno != EEXIST) {
                diagnose("vngrd-bootloader-sync: cannot create %s: %s",
                         VNGRD_BOOTSYNC_MOUNTPOINT, strerror(errno));
                return -1;
        }

        /* Read-write, unlike esp.c's read-only digest mount: this program's whole
         * job is the write. nosuid/nodev/noexec because nothing here is executed
         * from this mount; the firmware reads the partition itself. */
        if (mount(resolved, VNGRD_BOOTSYNC_MOUNTPOINT, "vfat",
                  MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) != 0) {
                diagnose("vngrd-bootloader-sync: cannot mount %s on %s: %s", dev,
                         VNGRD_BOOTSYNC_MOUNTPOINT, strerror(errno));
                return -1;
        }

        int rc = bootsync_tree(source, VNGRD_BOOTSYNC_MOUNTPOINT);

        if (umount2(VNGRD_BOOTSYNC_MOUNTPOINT, MNT_DETACH) != 0)
                diagnose("vngrd-bootloader-sync: cannot unmount %s: %s",
                         VNGRD_BOOTSYNC_MOUNTPOINT, strerror(errno));

        return rc;
}

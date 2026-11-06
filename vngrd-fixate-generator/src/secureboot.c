/* secureboot.c — signed variable update and reseal marker.  See secureboot.h. */

#define _GNU_SOURCE

#include "secureboot.h"

#include "diagnose.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <unistd.h>

#ifndef EFIVARFS_MAGIC
#define EFIVARFS_MAGIC 0xde5e81e4
#endif

/* Malformed-file cap, not a memory budget. */
#define AUTH_MAX (32u * 1024u * 1024u)
#define VARIABLE_MAX (32u * 1024u * 1024u)

/* EFI_TIME (16), WIN_CERTIFICATE header (8), CertType GUID (16), CertData. */
#define AUTH_TIME_SIZE 16u
#define WIN_CERT_HEADER_SIZE 8u
#define WIN_CERT_UEFI_GUID_SIZE 24u

/* offsets within EFI_VARIABLE_AUTHENTICATION_2 */
#define AUTH_DWLENGTH_OFF 16u
#define AUTH_REVISION_OFF 20u
#define AUTH_CERTTYPE_OFF 24u
#define AUTH_CERTDATA_OFF 40u

static const uint8_t pkcs7_guid[16] = {
        0x9d, 0xd2, 0xaf, 0x4a, 0xdf, 0x68, 0xee, 0x49,
        0x8a, 0xa9, 0x34, 0x7d, 0x37, 0x56, 0x65, 0xa7,
};

static uint16_t get_le16(const uint8_t *p) {
        return (uint16_t) (p[0] | ((uint16_t) p[1] << 8));
}

static uint32_t get_le32(const uint8_t *p) {
        return (uint32_t) p[0] | ((uint32_t) p[1] << 8) | ((uint32_t) p[2] << 16) |
               ((uint32_t) p[3] << 24);
}

static void put_le32(uint8_t *p, uint32_t v) {
        p[0] = (uint8_t) (v & 0xff);
        p[1] = (uint8_t) ((v >> 8) & 0xff);
        p[2] = (uint8_t) ((v >> 16) & 0xff);
        p[3] = (uint8_t) ((v >> 24) & 0xff);
}

int secureboot_auth_parse(const uint8_t *data, size_t len, SecureBootAuth *out) {
        if (data == NULL || out == NULL)
                return -1;
        if (len < AUTH_CERTDATA_OFF) {
                diagnose("vngrd-secureboot-update: the auth file is %zu bytes; a "
                         "time-based authenticated update needs at least %u before any "
                         "signed content", len, AUTH_CERTDATA_OFF);
                return -1;
        }
        if (len > AUTH_MAX) {
                diagnose("vngrd-secureboot-update: the auth file is %zu bytes, larger than the "
                         "%u-byte limit", len, AUTH_MAX);
                return -1;
        }

        uint32_t win_cert_len = get_le32(data + AUTH_DWLENGTH_OFF);
        if (win_cert_len < WIN_CERT_UEFI_GUID_SIZE) {
                diagnose("vngrd-secureboot-update: WIN_CERTIFICATE length %u is smaller than "
                         "the %u-byte GUID header", win_cert_len, WIN_CERT_UEFI_GUID_SIZE);
                return -1;
        }

        /* dwLength counts the certificate header itself. */
        size_t descriptor_len = (size_t) AUTH_TIME_SIZE + win_cert_len;
        if (descriptor_len > len) {
                diagnose("vngrd-secureboot-update: the auth descriptor claims %zu bytes but the "
                         "file is %zu", descriptor_len, len);
                return -1;
        }
        if (get_le16(data + AUTH_REVISION_OFF) != 0x0200) {
                diagnose("vngrd-secureboot-update: WIN_CERTIFICATE revision is 0x%04x, expected "
                         "0x0200", get_le16(data + AUTH_REVISION_OFF));
                return -1;
        }
        if (get_le16(data + AUTH_REVISION_OFF + 2) != 0x0ef1) {
                diagnose("vngrd-secureboot-update: certificate type is 0x%04x, not "
                         "WIN_CERT_TYPE_EFI_GUID (0x0ef1)",
                         get_le16(data + AUTH_REVISION_OFF + 2));
                return -1;
        }
        if (memcmp(data + AUTH_CERTTYPE_OFF, pkcs7_guid, sizeof(pkcs7_guid)) != 0) {
                diagnose("vngrd-secureboot-update: the auth descriptor does not name "
                         "EFI_CERT_TYPE_PKCS7_GUID");
                return -1;
        }

        size_t payload_len = len - descriptor_len;
        if (payload_len == 0) {
                diagnose("vngrd-secureboot-update: the auth file carries a signature and no "
                         "variable payload");
                return -1;
        }

        out->descriptor = data;
        out->descriptor_len = descriptor_len;
        out->payload = data + descriptor_len;
        out->payload_len = payload_len;
        return 0;
}

int secureboot_efivarfs_buffer(const SecureBootAuth *auth, uint32_t attributes, uint8_t **out,
                               size_t *out_len) {
        if (auth == NULL || out == NULL || out_len == NULL)
                return -1;
        if (auth->descriptor_len > SIZE_MAX - auth->payload_len ||
            auth->descriptor_len + auth->payload_len > SIZE_MAX - sizeof(attributes))
                return -1;

        size_t len = sizeof(attributes) + auth->descriptor_len + auth->payload_len;
        uint8_t *buf = malloc(len);
        if (buf == NULL) {
                diagnose("vngrd-secureboot-update: out of memory building the efivarfs write");
                return -1;
        }

        put_le32(buf, attributes);
        memcpy(buf + sizeof(attributes), auth->descriptor, auth->descriptor_len);
        memcpy(buf + sizeof(attributes) + auth->descriptor_len, auth->payload, auth->payload_len);

        *out = buf;
        *out_len = len;
        return 0;
}

int secureboot_append_matches(const uint8_t *before, size_t before_len, const uint8_t *after,
                              size_t after_len, const uint8_t *payload, size_t payload_len) {
        if (after == NULL || payload == NULL)
                return 0;
        if (before_len > SIZE_MAX - payload_len)
                return 0;
        if (after_len != before_len + payload_len)
                return 0;
        if (before_len > 0 && (before == NULL || memcmp(after, before, before_len) != 0))
                return 0;
        return memcmp(after + before_len, payload, payload_len) == 0;
}

static int mkpath(const char *path) {
        char work[PATH_MAX];

        if (path == NULL || *path == '\0')
                return -1;
        if (snprintf(work, sizeof(work), "%s", path) >= (int) sizeof(work))
                return -1;

        for (char *p = work + 1; *p != '\0'; p++) {
                if (*p != '/')
                        continue;
                *p = '\0';
                if (mkdir(work, 0755) != 0 && errno != EEXIST) {
                        diagnose("vngrd-secureboot-update: mkdir %s failed: %s", work,
                                 strerror(errno));
                        return -1;
                }
                *p = '/';
        }
        if (mkdir(work, 0755) != 0 && errno != EEXIST) {
                diagnose("vngrd-secureboot-update: mkdir %s failed: %s", work, strerror(errno));
                return -1;
        }
        return 0;
}

int secureboot_write_marker(const char *path) {
        static const char content[] = "vngrd-secureboot-update\n";
        char parent[PATH_MAX];

        if (path == NULL || *path == '\0')
                return -1;
        if (snprintf(parent, sizeof(parent), "%s", path) >= (int) sizeof(parent))
                return -1;
        char *slash = strrchr(parent, '/');
        if (slash == NULL)
                return -1;
        if (slash == parent)
                return -1;
        *slash = '\0';

        if (mkpath(parent) != 0)
                return -1;

        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd < 0) {
                diagnose("vngrd-secureboot-update: cannot create %s: %s", path, strerror(errno));
                return -1;
        }
        ssize_t n = write(fd, content, sizeof(content) - 1);
        if (n != (ssize_t) (sizeof(content) - 1)) {
                diagnose("vngrd-secureboot-update: writing %s failed: %s", path,
                         n < 0 ? strerror(errno) : "short write");
                close(fd);
                return -1;
        }
        if (fsync(fd) != 0) {
                diagnose("vngrd-secureboot-update: fsync %s failed: %s", path, strerror(errno));
                close(fd);
                return -1;
        }
        if (close(fd) != 0) {
                diagnose("vngrd-secureboot-update: close %s failed: %s", path, strerror(errno));
                return -1;
        }

        int dfd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (dfd >= 0) {
                if (fsync(dfd) != 0 && errno != EINVAL)
                        diagnose("vngrd-secureboot-update: fsync %s failed: %s", parent,
                                 strerror(errno));
                close(dfd);
        }
        return 0;
}

static int variable_path(char *dst, size_t dst_sz, const char *efivars, const char *variable,
                         const char *guid) {
        int n;

        if (efivars == NULL || variable == NULL || guid == NULL || *variable == '\0' ||
            *guid == '\0')
                return -1;
        if (strchr(variable, '/') != NULL || strchr(guid, '/') != NULL)
                return -1;

        n = snprintf(dst, dst_sz, "%s/%s-%s", efivars, variable, guid);
        return (n < 0 || (size_t) n >= dst_sz) ? -1 : 0;
}

int secureboot_read_variable(const char *efivars, const char *variable, const char *guid,
                             uint8_t **data, size_t *len) {
        char path[PATH_MAX];
        uint8_t *buf = NULL;

        if (data == NULL || len == NULL)
                return -2;
        *data = NULL;
        *len = 0;
        if (variable_path(path, sizeof(path), efivars, variable, guid) != 0)
                return -2;

        int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) {
                if (errno == ENOENT)
                        return -1;
                diagnose("vngrd-secureboot-update: cannot open %s: %s", path, strerror(errno));
                return -2;
        }

        struct stat st;
        if (fstat(fd, &st) != 0) {
                diagnose("vngrd-secureboot-update: stat %s failed: %s", path, strerror(errno));
                close(fd);
                return -2;
        }
        if (!S_ISREG(st.st_mode) || st.st_size < 0 ||
            (uint64_t) st.st_size > VARIABLE_MAX + 4u) {
                diagnose("vngrd-secureboot-update: %s is not a sensible efivarfs file", path);
                close(fd);
                return -2;
        }

        size_t total = (size_t) st.st_size;
        if (total < 4u) {
                diagnose("vngrd-secureboot-update: %s has no attribute word", path);
                close(fd);
                return -2;
        }
        buf = malloc(total > 0 ? total : 1u);
        if (buf == NULL) {
                close(fd);
                return -2;
        }

        size_t got = 0;
        while (got < total) {
                ssize_t n = read(fd, buf + got, total - got);

                if (n < 0) {
                        diagnose("vngrd-secureboot-update: read %s failed: %s", path,
                                 strerror(errno));
                        free(buf);
                        close(fd);
                        return -2;
                }
                if (n == 0) {
                        diagnose("vngrd-secureboot-update: %s is shorter than its size", path);
                        free(buf);
                        close(fd);
                        return -2;
                }
                got += (size_t) n;
        }
        close(fd);

        size_t payload = total - 4u;
        if (payload > 0)
                memmove(buf, buf + 4, payload);
        *data = buf;
        *len = payload;
        return 0;
}

int secureboot_mount_efivarfs(const char *dir) {
        struct statfs st;

        if (dir == NULL || *dir == '\0')
                return -1;
        if (statfs(dir, &st) == 0 && (unsigned long) st.f_type == (unsigned long) EFIVARFS_MAGIC)
                return 0;

        if (mount("efivarfs", dir, "efivarfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) != 0) {
                if (errno != EBUSY) {
                        diagnose("vngrd-secureboot-update: cannot mount efivarfs at %s: %s", dir,
                                 strerror(errno));
                        return -1;
                }
        }
        if (statfs(dir, &st) != 0 ||
            (unsigned long) st.f_type != (unsigned long) EFIVARFS_MAGIC) {
                diagnose("vngrd-secureboot-update: %s is not an efivarfs mount after mounting",
                         dir);
                return -1;
        }
        return 0;
}

/* secureboot-main.c — vngrd-secureboot-update. See secureboot.h.
 *
 * Read auth -> mount efivarfs -> check Secure Boot -> append -> read back ->
 * marker -> reboot. Before the marker, every failure is recoverable. After a
 * successful append, a marker failure would leave PCR 7 moved with no reseal
 * requested, so that case prints the path to create and does not reboot.
 */

#define _GNU_SOURCE

#include "diagnose.h"
#include "secureboot.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <unistd.h>

#define GLOBAL_VARIABLE_GUID "8be4df61-93ca-11d2-aa0d-00e098032b8c"

/* Matches the parser's cap; rejected before allocating. */
#define AUTH_FILE_MAX (32u * 1024u * 1024u)

static const char *progname = "vngrd-secureboot-update";

static void usage(const char *argv0) {
        printf("usage: %s AUTH-FILE [--no-reboot] [--efivars=DIR] [--marker=PATH]\n"
               "\n"
               "Apply a signed EFI authenticated variable update (dbx.auth), then\n"
               "create %s and reboot so the next boot reseals the root token\n"
               "with the recovery passphrase.\n"
               "\n"
               "  AUTH-FILE       the file produced by\n"
               "                  sign-efi-sig-list -a -g KEK dbx dbx.esl dbx.auth\n"
               "  --no-reboot     stop after the marker is written\n"
               "  --efivars=DIR   efivarfs mountpoint (default %s)\n"
               "  --marker=PATH   reseal trigger (default %s)\n"
               "\n"
               "The update is appended to dbx.  The firmware verifies the PKCS7\n"
               "signature; this tool verifies the descriptor shape and reads the\n"
               "variable back before creating the marker.\n",
               argv0, VNGRD_RESEAL_MARKER, VNGRD_EFIVARFS, VNGRD_RESEAL_MARKER);
}

static int read_regular(const char *path, uint8_t **out, size_t *out_len) {
        int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);

        if (fd < 0) {
                diagnose("vngrd-secureboot-update: cannot open %s: %s", path, strerror(errno));
                return -1;
        }

        struct stat st;
        if (fstat(fd, &st) != 0) {
                diagnose("vngrd-secureboot-update: stat %s failed: %s", path, strerror(errno));
                close(fd);
                return -1;
        }
        if (!S_ISREG(st.st_mode) || st.st_size <= 0) {
                diagnose("vngrd-secureboot-update: %s is not a non-empty regular file", path);
                close(fd);
                return -1;
        }
        if ((uint64_t) st.st_size > AUTH_FILE_MAX) {
                diagnose("vngrd-secureboot-update: %s is %lld bytes, larger than the %u-byte "
                         "limit", path, (long long) st.st_size, AUTH_FILE_MAX);
                close(fd);
                return -1;
        }

        size_t len = (size_t) st.st_size;
        uint8_t *buf = malloc(len);
        if (buf == NULL) {
                diagnose("vngrd-secureboot-update: out of memory reading %s", path);
                close(fd);
                return -1;
        }

        size_t got = 0;
        while (got < len) {
                ssize_t n = read(fd, buf + got, len - got);

                if (n < 0) {
                        diagnose("vngrd-secureboot-update: read %s failed: %s", path,
                                 strerror(errno));
                        free(buf);
                        close(fd);
                        return -1;
                }
                if (n == 0) {
                        diagnose("vngrd-secureboot-update: %s is shorter than its size", path);
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

/* One syscall: efivarfs does not reassemble a value split over writes. */
static int write_variable(const char *efivars, const char *variable, const char *guid,
                          const uint8_t *buf, size_t len) {
        char path[4096];
        int n = snprintf(path, sizeof(path), "%s/%s-%s", efivars, variable, guid);

        if (n < 0 || (size_t) n >= sizeof(path)) {
                diagnose("vngrd-secureboot-update: efivarfs path is too long");
                return -1;
        }

        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd < 0) {
                diagnose("vngrd-secureboot-update: cannot open %s for writing: %s", path,
                         strerror(errno));
                return -1;
        }

        ssize_t wrote = write(fd, buf, len);
        if (wrote != (ssize_t) len) {
                diagnose("vngrd-secureboot-update: writing %s failed: %s", path,
                         wrote < 0 ? strerror(errno) : "short write");
                close(fd);
                return -1;
        }
        /* efivarfs may reject fsync; the firmware call already completed. */
        if (fsync(fd) != 0 && errno != EINVAL && errno != ENOTSUP)
                diagnose("vngrd-secureboot-update: fsync %s failed: %s", path, strerror(errno));
        if (close(fd) != 0) {
                diagnose("vngrd-secureboot-update: close %s failed: %s", path, strerror(errno));
                return -1;
        }
        return 0;
}

static int secure_boot_enabled(const char *efivars) {
        uint8_t *data = NULL;
        size_t len = 0;
        int rc = secureboot_read_variable(efivars, "SecureBoot", GLOBAL_VARIABLE_GUID, &data,
                                          &len);

        if (rc == -1) {
                diagnose("vngrd-secureboot-update: there is no SecureBoot variable. This tool "
                         "is only for a machine already running under Secure Boot; a setup-mode "
                         "machine has no policy for a dbx update to change.");
                return -1;
        }
        if (rc != 0)
                return -1;
        if (len != 1 || data[0] != 1) {
                diagnose("vngrd-secureboot-update: SecureBoot is not enabled (value length %zu, "
                         "first byte 0x%02x). Applying a dbx update here would move no policy "
                         "the root is bound to.", len, len > 0 ? data[0] : 0);
                free(data);
                return -1;
        }
        free(data);
        return 0;
}

int main(int argc, char **argv) {
        const char *auth_path = NULL;
        const char *efivars = VNGRD_EFIVARFS;
        const char *marker = VNGRD_RESEAL_MARKER;
        bool reboot_after = true;

        for (int i = 1; i < argc; i++) {
                if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                        usage(progname);
                        return 0;
                }
                if (strcmp(argv[i], "--no-reboot") == 0) {
                        reboot_after = false;
                } else if (strncmp(argv[i], "--efivars=", 10) == 0) {
                        efivars = argv[i] + 10;
                } else if (strncmp(argv[i], "--marker=", 9) == 0) {
                        marker = argv[i] + 9;
                } else if (argv[i][0] == '-') {
                        diagnose("vngrd-secureboot-update: unknown argument '%s'", argv[i]);
                        usage(progname);
                        return 2;
                } else if (auth_path == NULL) {
                        auth_path = argv[i];
                } else {
                        diagnose("vngrd-secureboot-update: more than one auth file given");
                        usage(progname);
                        return 2;
                }
        }

        if (auth_path == NULL || *efivars == '\0' || *marker == '\0') {
                diagnose("vngrd-secureboot-update: an auth file, a non-empty efivarfs path and "
                         "a non-empty marker path are required");
                usage(progname);
                return 2;
        }

        uint8_t *file = NULL;
        size_t file_len = 0;
        if (read_regular(auth_path, &file, &file_len) != 0)
                return 1;

        SecureBootAuth auth;
        if (secureboot_auth_parse(file, file_len, &auth) != 0) {
                free(file);
                return 1;
        }

        if (secureboot_mount_efivarfs(efivars) != 0) {
                free(file);
                return 1;
        }
        if (secure_boot_enabled(efivars) != 0) {
                free(file);
                return 1;
        }

        /* An absent dbx is odd but not a reason to refuse the first entry; the
         * read-back still proves the append. */
        uint8_t *before = NULL;
        size_t before_len = 0;
        int have_before = secureboot_read_variable(efivars, "dbx",
                                                   VNGRD_EFI_IMAGE_SECURITY_DATABASE_GUID, &before,
                                                   &before_len);
        if (have_before == -2) {
                free(file);
                return 1;
        }
        if (have_before == -1) {
                before = NULL;
                before_len = 0;
        }

        uint8_t *write_buf = NULL;
        size_t write_len = 0;
        if (secureboot_efivarfs_buffer(&auth, VNGRD_EFI_DBX_APPEND_ATTRS, &write_buf,
                                       &write_len) != 0) {
                free(before);
                free(file);
                return 1;
        }

        printf("vngrd-secureboot-update: appending %zu bytes to dbx\n", auth.payload_len);
        if (write_variable(efivars, "dbx", VNGRD_EFI_IMAGE_SECURITY_DATABASE_GUID, write_buf,
                           write_len) != 0) {
                free(write_buf);
                free(before);
                free(file);
                return 1;
        }
        free(write_buf);

        uint8_t *after = NULL;
        size_t after_len = 0;
        if (secureboot_read_variable(efivars, "dbx", VNGRD_EFI_IMAGE_SECURITY_DATABASE_GUID, &after,
                                     &after_len) != 0) {
                diagnose("vngrd-secureboot-update: dbx was written but cannot be read back; not "
                         "creating the reseal marker for an update that cannot be shown to have "
                         "landed");
                free(before);
                free(file);
                return 1;
        }

        if (!secureboot_append_matches(before, before_len, after, after_len, auth.payload,
                                       auth.payload_len)) {
                diagnose("vngrd-secureboot-update: dbx does not read back as the old value with "
                         "this payload appended (before %zu, after %zu, payload %zu). The "
                         "firmware rejected the update or the signature does not match the "
                         "attributes; the reseal marker is not being created.",
                         before_len, after_len, auth.payload_len);
                free(after);
                free(before);
                free(file);
                return 1;
        }

        free(after);
        free(before);
        free(file);

        if (secureboot_write_marker(marker) != 0) {
                diagnose("vngrd-secureboot-update: the dbx update landed, but %s could not be "
                         "created. The next boot may move PCR 7 and need the recovery "
                         "passphrase; create the marker by hand before rebooting.",
                         marker);
                return 1;
        }

        printf("vngrd-secureboot-update: dbx updated and %s created\n", marker);
        if (!reboot_after) {
                printf("vngrd-secureboot-update: --no-reboot, so nothing was restarted\n");
                return 0;
        }

        sync();
        printf("vngrd-secureboot-update: rebooting into the reseal boot\n");
        fflush(stdout);
        if (reboot(RB_AUTOBOOT) != 0) {
                diagnose("vngrd-secureboot-update: reboot failed: %s. The update and marker are "
                         "in place; reboot with systemctl reboot.", strerror(errno));
                return 1;
        }
        return 0;
}

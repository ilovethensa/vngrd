/* test-secureboot.c — descriptor validation, read-back predicate and marker.
 *
 * No firmware, no efivarfs and no TPM: the cases that decide whether the tool
 * writes the wrong blob or creates the reseal marker after a rejected update are
 * all ordinary buffers and files. Build: make test
 */

#define _GNU_SOURCE

#include "secureboot.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;

static void die(const char *what) {
        fprintf(stderr, "test-secureboot: %s: %s\n", what, strerror(errno));
        exit(1);
}

static void expect_case(const char *what, int ok) {
        if (ok) {
                printf("  ok   %s\n", what);
        } else {
                printf("  FAIL %s\n", what);
                failures++;
        }
}

static void put_le16(uint8_t *p, uint16_t v) {
        p[0] = (uint8_t) (v & 0xff);
        p[1] = (uint8_t) ((v >> 8) & 0xff);
}

static void put_le32(uint8_t *p, uint32_t v) {
        p[0] = (uint8_t) (v & 0xff);
        p[1] = (uint8_t) ((v >> 8) & 0xff);
        p[2] = (uint8_t) ((v >> 16) & 0xff);
        p[3] = (uint8_t) ((v >> 24) & 0xff);
}

static const uint8_t pkcs7_guid[16] = {
        0x9d, 0xd2, 0xaf, 0x4a, 0xdf, 0x68, 0xee, 0x49,
        0x8a, 0xa9, 0x34, 0x7d, 0x37, 0x56, 0x65, 0xa7,
};

/* Build a minimal structurally valid EFI_VARIABLE_AUTHENTICATION_2.  The PKCS7
 * bytes are not a real signature; this test is about the framing the kernel and
 * firmware parse, and the firmware is the signature verifier. */
static uint8_t *make_auth(size_t certdata_len, const uint8_t *payload, size_t payload_len,
                          size_t *out_len) {
        size_t descriptor = 40u + certdata_len;
        size_t len = descriptor + payload_len;
        uint8_t *buf = calloc(1, len);

        if (buf == NULL)
                die("calloc");
        put_le32(buf + 16, (uint32_t) (24u + certdata_len));
        put_le16(buf + 20, 0x0200);
        put_le16(buf + 22, 0x0ef1);
        memcpy(buf + 24, pkcs7_guid, sizeof(pkcs7_guid));
        if (payload_len > 0)
                memcpy(buf + descriptor, payload, payload_len);
        *out_len = len;
        return buf;
}

static char *fresh_dir(void) {
        char tmpl[] = "/tmp/vngrd-test-secureboot-XXXXXX";
        char *d = mkdtemp(tmpl);

        if (d == NULL)
                die("mkdtemp");
        return strdup(d);
}

static void write_file(const char *path, const uint8_t *data, size_t len) {
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);

        if (fd < 0)
                die(path);
        if (write(fd, data, len) != (ssize_t) len)
                die("write");
        close(fd);
}

static int file_equals(const char *path, const char *want) {
        char buf[256];
        int fd = open(path, O_RDONLY);
        ssize_t n;

        if (fd < 0)
                return 0;
        n = read(fd, buf, sizeof(buf));
        close(fd);
        return n == (ssize_t) strlen(want) && memcmp(buf, want, (size_t) n) == 0;
}

int main(void) {
        static const uint8_t payload[] = { 0x30, 0x82, 0x00, 0x10, 'd', 'b', 'x' };
        size_t auth_len = 0;
        uint8_t *auth = make_auth(37, payload, sizeof(payload), &auth_len);
        SecureBootAuth parsed;

        printf("test-secureboot: signed update framing\n");

        expect_case("a well-formed auth file parses",
                    secureboot_auth_parse(auth, auth_len, &parsed) == 0);
        expect_case("descriptor length includes the 16-byte timestamp",
                    parsed.descriptor_len == 40u + 37u);
        expect_case("payload starts after the descriptor",
                    parsed.payload_len == sizeof(payload) &&
                        memcmp(parsed.payload, payload, sizeof(payload)) == 0);

        uint8_t *bad = malloc(auth_len);
        if (bad == NULL)
                die("malloc");

        memcpy(bad, auth, auth_len);
        expect_case("a truncated descriptor is refused",
                    secureboot_auth_parse(bad, 39, &parsed) != 0);
        expect_case("an overlong descriptor is refused",
                    secureboot_auth_parse(bad, 40u + 12u, &parsed) != 0);

        memcpy(bad, auth, auth_len);
        put_le32(bad + 16, 23);
        expect_case("a WIN_CERTIFICATE shorter than its GUID header is refused",
                    secureboot_auth_parse(bad, auth_len, &parsed) != 0);

        memcpy(bad, auth, auth_len);
        put_le16(bad + 20, 0x0100);
        expect_case("an unexpected revision is refused",
                    secureboot_auth_parse(bad, auth_len, &parsed) != 0);

        memcpy(bad, auth, auth_len);
        put_le16(bad + 22, 0x0001);
        expect_case("a non-GUID certificate is refused",
                    secureboot_auth_parse(bad, auth_len, &parsed) != 0);

        memcpy(bad, auth, auth_len);
        bad[32] ^= 0xff;
        expect_case("a descriptor without the PKCS7 GUID is refused",
                    secureboot_auth_parse(bad, auth_len, &parsed) != 0);

        /* A descriptor that fills the whole file has no variable data to append. */
        size_t empty_len = 0;
        uint8_t *empty = make_auth(5, NULL, 0, &empty_len);
        expect_case("an auth file with no payload is refused",
                    secureboot_auth_parse(empty, empty_len, &parsed) != 0);
        free(empty);

        if (secureboot_auth_parse(auth, auth_len, &parsed) != 0)
                die("reparse");

        uint8_t *write_buf = NULL;
        size_t write_len = 0;
        expect_case("the efivarfs buffer builds",
                    secureboot_efivarfs_buffer(&parsed, VNGRD_EFI_DBX_APPEND_ATTRS, &write_buf,
                                               &write_len) == 0);
        expect_case("the attribute word is little-endian append",
                    write_len == auth_len + 4 && write_buf[0] == 0x67 && write_buf[1] == 0 &&
                        write_buf[2] == 0 && write_buf[3] == 0);
        expect_case("the descriptor is copied verbatim",
                    memcmp(write_buf + 4, auth, parsed.descriptor_len) == 0);
        expect_case("the payload is copied after the descriptor",
                    memcmp(write_buf + 4 + parsed.descriptor_len, payload, sizeof(payload)) == 0);

        expect_case("an empty dbx reads back as exactly the payload",
                    secureboot_append_matches(NULL, 0, payload, sizeof(payload), payload,
                                              sizeof(payload)));
        uint8_t old[] = { 'o', 'l', 'd' };
        uint8_t after[sizeof(old) + sizeof(payload)];
        memcpy(after, old, sizeof(old));
        memcpy(after + sizeof(old), payload, sizeof(payload));
        expect_case("old data followed by the payload matches",
                    secureboot_append_matches(old, sizeof(old), after, sizeof(after), payload,
                                              sizeof(payload)));
        expect_case("a missing prefix does not match",
                    !secureboot_append_matches((const uint8_t *) "OLD", 3, after, sizeof(after),
                                               payload, sizeof(payload)));
        expect_case("a truncated append does not match",
                    !secureboot_append_matches(old, sizeof(old), after, sizeof(after) - 1, payload,
                                               sizeof(payload)));
        expect_case("a different payload does not match",
                    !secureboot_append_matches(old, sizeof(old), after, sizeof(after),
                                               (const uint8_t *) "other", 5));

        char *root = fresh_dir();
        char efivars[4096], var[4096], marker[4096];
        snprintf(efivars, sizeof(efivars), "%s/efivars", root);
        snprintf(marker, sizeof(marker), "%s/var/lib/vngrd/reseal-requested", root);
        if (mkdir(efivars, 0700) != 0)
                die("mkdir efivars");
        snprintf(var, sizeof(var), "%s/dbx-%s", efivars, VNGRD_EFI_IMAGE_SECURITY_DATABASE_GUID);

        uint8_t stored[4 + sizeof(payload)];
        stored[0] = 0x27;
        stored[1] = stored[2] = stored[3] = 0;
        memcpy(stored + 4, payload, sizeof(payload));
        write_file(var, stored, sizeof(stored));

        uint8_t *read_back = NULL;
        size_t read_len = 0;
        expect_case("a variable reads back without its attribute word",
                    secureboot_read_variable(efivars, "dbx",
                                             VNGRD_EFI_IMAGE_SECURITY_DATABASE_GUID, &read_back,
                                             &read_len) == 0 &&
                        read_len == sizeof(payload) &&
                        memcmp(read_back, payload, sizeof(payload)) == 0);
        free(read_back);
        read_back = NULL;
        expect_case("an absent variable is distinguished from a broken one",
                    secureboot_read_variable(efivars, "PK",
                                             VNGRD_EFI_IMAGE_SECURITY_DATABASE_GUID, &read_back,
                                             &read_len) == -1);

        expect_case("the reseal marker is created",
                    secureboot_write_marker(marker) == 0 &&
                        file_equals(marker, "vngrd-secureboot-update\n"));
        expect_case("an existing reseal marker is accepted",
                    secureboot_write_marker(marker) == 0 &&
                        file_equals(marker, "vngrd-secureboot-update\n"));

        free(read_back);
        free(root);
        free(write_buf);
        free(bad);
        free(auth);

        if (failures > 0) {
                fprintf(stderr, "test-secureboot: %d failure(s)\n", failures);
                return 1;
        }
        printf("test-secureboot: all cases passed\n");
        return 0;
}

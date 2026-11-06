/* secureboot.h — apply a signed authenticated EFI variable update and request a
 * reseal on the next boot.
 *
 * A dbx update moves PCR 7, so the existing root token stops unsealing. The
 * operator is already present for the reseal; an unattended firmware-update
 * daemon would be a much larger trust surface.
 *
 * The auth blob is EFI_VARIABLE_AUTHENTICATION_2: timestamp, WIN_CERTIFICATE
 * header, PKCS7, then the payload, as produced by
 *   sign-efi-sig-list -a -g KEK dbx dbx.esl dbx.auth
 * The firmware verifies the signature. After the write, dbx is read back and the
 * old value must be a prefix with exactly the payload appended; a silently
 * ignored write must fail before the reseal marker is created.
 */

#ifndef VNGRD_SECUREBOOT_H
#define VNGRD_SECUREBOOT_H

#include <stddef.h>
#include <stdint.h>

/* EFI_IMAGE_SECURITY_DATABASE_GUID */
#define VNGRD_EFI_IMAGE_SECURITY_DATABASE_GUID "d719b2cb-3d3a-4596-a3bc-dad00e67656f"

#define VNGRD_EFIVARFS "/sys/firmware/efi/efivars"

/* Same trigger vngrd-reseal.service watches. */
#define VNGRD_RESEAL_MARKER "/var/lib/vngrd/reseal-requested"

/* dbx: NV | BS | RT | TIME_BASED_AUTH | APPEND_WRITE. */
#define VNGRD_EFI_DBX_APPEND_ATTRS 0x00000067u

/* EFI_TIME (16) + WIN_CERTIFICATE_UEFI_GUID header (8 + 16). */
#define VNGRD_EFI_AUTH_FIXED 40u

typedef struct SecureBootAuth {
        const uint8_t *descriptor;
        size_t descriptor_len;
        const uint8_t *payload;
        size_t payload_len;
} SecureBootAuth;

/* Structurally validate an auth file; the timestamp is not interpreted because
 * the firmware owns monotonicity. */
int secureboot_auth_parse(const uint8_t *data, size_t len, SecureBootAuth *out);

/* Build the efivarfs buffer: little-endian attributes, descriptor, payload. */
int secureboot_efivarfs_buffer(const SecureBootAuth *auth, uint32_t attributes, uint8_t **out,
                               size_t *out_len);

/* after must be before+payload, or exactly payload when before is empty. */
int secureboot_append_matches(const uint8_t *before, size_t before_len, const uint8_t *after,
                              size_t after_len, const uint8_t *payload, size_t payload_len);

/* Create the reseal marker, fsynced. */
int secureboot_write_marker(const char *path);

/* Read a variable, stripping the 4-byte attribute mask. 0, -1 absent, -2 error. */
int secureboot_read_variable(const char *efivars, const char *variable, const char *guid,
                             uint8_t **data, size_t *len);

/* Mount efivarfs at dir unless it already is one. */
int secureboot_mount_efivarfs(const char *dir);

#endif /* VNGRD_SECUREBOOT_H */

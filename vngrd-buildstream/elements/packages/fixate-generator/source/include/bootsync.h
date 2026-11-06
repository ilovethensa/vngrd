/* bootsync.h — copy the signed sd-boot from verified /usr to the ESP.
 *
 * Secure Boot authenticates sd-boot but cannot keep the ESP copy current; an
 * image update leaves the old loader until copied. mkosi's .signed file lives in
 * dm-verity /usr, so copying it byte-for-byte copies the artifact the firmware
 * will verify. Never fall back to the unsigned .efi: that would install a loader
 * the firmware refuses. The helper does not verify PE itself; the firmware does
 * on the next boot. esp.h excludes these paths for the same reason.
 */

#ifndef VNGRD_BOOTSYNC_H
#define VNGRD_BOOTSYNC_H

#include <stddef.h>

/* mkosi's signed sd-boot in verified /usr. */
#define VNGRD_BOOTSYNC_SOURCE \
        "/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed"

/* Private tmpfs mountpoint, so it cannot collide with /efi. */
#define VNGRD_BOOTSYNC_MOUNTPOINT "/run/vngrd-bootloader-esp"

/* Copy to both sd-boot paths when different; esp_root is a directory, not a
 * device. Success requires the read-back to match. */
int bootsync_tree(const char *source, const char *esp_root);

/* Mount read-write nosuid/nodev/noexec, copy, unmount. */
int bootsync_esp(const char *partlabel, const char *source);

#endif /* VNGRD_BOOTSYNC_H */

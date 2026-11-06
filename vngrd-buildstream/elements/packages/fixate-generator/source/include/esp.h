/* esp.h — a digest of the ESP's contents, frozen in TPM NV.
 *
 * Secure Boot authenticates the loaders, and PCR 11 covers the UKI, but neither
 * covers loader.conf or the enrollment keys; PCR 4 covers the loader but moves on
 * every update. The digest is computed once at provisioning and compared on every
 * later boot. It is a check, not part of the unseal.
 *
 * Stream: pre-order walk, children sorted by strcmp, per item
 *   'D'|'F', u32 LE path length, path, [u64 LE size, content]
 * Directories are hashed, so an empty added/renamed directory still moves it.
 *
 * Excluded because legitimate boots/updates rewrite them:
 *   EFI/systemd, EFI/BOOT   sd-boot, synced from verified /usr
 *   EFI/Linux               sysupdate target; sd-boot renames entries (+N-M)
 *   loader/entries*         entry set, already covered by the UKI
 *   loader/credentials      pcrlock credential, fresh nonce every boot
 *   loader/random-seed      written by sd-boot
 * Matching is case-insensitive because vfat tools disagree about case.
 *
 * loader.conf, loader/keys and the kernel image are NOT excluded: that is the
 * point, and Secure Boot does not cover loader.conf.
 */

#ifndef VNGRD_ESP_H
#define VNGRD_ESP_H

#include <stddef.h>
#include <stdint.h>

#define VNGRD_ESP_DIGEST_LEN 32u

/* Digest the tree at root (a filesystem path, not a device). */
int esp_digest_tree(const char *root, uint8_t out[VNGRD_ESP_DIGEST_LEN]);

/* Mount /dev/disk/by-partlabel/<partlabel> read-only, digest it, unmount. The
 * kernel's vfat must be built in, since this runs before verified /usr. */
int esp_identity_digest(const char *partlabel, uint8_t out[VNGRD_ESP_DIGEST_LEN]);

#endif /* VNGRD_ESP_H */

/* gpt.h — a digest of this machine's partition identity, frozen in TPM NV.
 *
 * The root seal is PolicyAuthorize over PCR 11 plus PolicyPCR{7}, and PCR 7 is
 * the Secure Boot policy -- identical on every machine this authority signs. PCR
 * 5 would name this machine's GPT but cannot be in the seal: repart creates the
 * root partition on first boot, after ExitBootServices has already extended PCR
 * 5 (see 10-root.conf). So this is the OS-side substitute, frozen once at
 * provisioning and recomputed on every later boot. A check, not part of the
 * unseal.
 *
 * Covered: disk GUID, and every partition's type GUID, start/end LBA, plus
 * unique GUID, attributes and label. For usr and usr-verity the last three are
 * excluded: sysupdate renames the slot (MatchPattern=vngrd-usr_@v in
 * 50-usr.transfer) and rewrites its UUID and flags, so hashing them would refuse
 * every update. Geometry stays, so an added, removed, moved or resized partition
 * still refuses.
 */

#ifndef VNGRD_GPT_H
#define VNGRD_GPT_H

#include <stddef.h>
#include <stdint.h>

/* One SHA-256, matching VNGRD_NV_GPT_INDEX's dataSize. */
#define VNGRD_GPT_DIGEST_LEN 32u

/* Resolve the whole-disk block device behind /dev/disk/by-partlabel/<partlabel>.
 *
 * The GPT lives in the first sectors of the whole disk, not on the partition, so
 * the disk node comes from sysfs (the parent of the partition's /sys/class/block
 * entry) rather than by trimming a name suffix: sda3, nvme0n1p3 and mmcblk0p3
 * all follow different rules.
 *
 * Returns 0 on success; out is left empty on failure.
 */
int gpt_disk_for_partlabel(const char *partlabel, char *out, size_t out_sz);

/* SHA-256 over the canonical identity of disk_path's GPT (see the header note for
 * the field list). Returns 0 on success, -1 if the device cannot be read or does
 * not carry a GPT this code recognises. */
int gpt_identity_digest(const char *disk_path, uint8_t out[VNGRD_GPT_DIGEST_LEN]);

#endif /* VNGRD_GPT_H */

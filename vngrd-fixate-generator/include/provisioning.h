/* provisioning.h — did this boot create the root volume?
 *
 * Only that boot may define an absent NV index; defining one later would let a
 * running image re-arm the control at an attacker-chosen value. The marker is
 * repart's crypttab carrying fixate-volume-key=, which only the format path
 * writes. It lives in the initrd's /run tmpfs, so it does not survive to the next
 * boot and a host root cannot pre-create it.
 *
 * The root partition is the independent "provisioned" signal for the guards, so
 * an absent index can fail closed there while passing on an untouched disk.
 */

#ifndef VNGRD_PROVISIONING_H
#define VNGRD_PROVISIONING_H

#include <stdbool.h>

/* repart's --generate-crypttab= destination. The file exists every boot; only
 * fixate-volume-key= marks the format boot. */
#define VNGRD_PROVISIONING_MARKER "/run/vngrd/repart-crypttab"

/* Present on every boot after repart created it. */
#define VNGRD_ROOT_PARTLABEL "vngrd-root"

/* The file must also carry fixate-volume-key=; repart appends it only when it
 * formats the root. */
bool provisioning_marker_present(const char *path);

/* True when /dev/disk/by-partlabel/<partlabel> exists. */
bool root_partition_present(const char *partlabel);

#endif /* VNGRD_PROVISIONING_H */

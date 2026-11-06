/* fixate.h — turn a fixate digest into a systemd-cryptsetup drop-in.
 *
 * The options string is built by systemd-cryptsetup-generator from the crypttab
 * (generator.c:977-981), so the only place to add fixate-volume-key= is the
 * unit's ExecStart. /etc is read-only to generators (manager.c:4443-4448),
 * SYSTEMD_CRYPTTAB is not injectable, and CRYPTTAB_OPTIONS does not exist in
 * systemd. Drop-ins resolve at unit load time, after every generator has exited.
 */

#ifndef VNGRD_FIXATE_H
#define VNGRD_FIXATE_H

/* A parsed /etc/crypttab line; fields are owned by the struct. */
typedef struct FixateCrypttabEntry {
        char *name;
        char *device;
        char *keyfile;
        char *options;
} FixateCrypttabEntry;

/* Look up `name' in the crypttab at crypttab_path. Returns 1 and fills out on
 * success, 0 if the entry is absent, -1 on a read error. A missing entry (a
 * crypttab that no longer names the sealed volume) is a distinct outcome from an
 * unreadable one (a broken initrd).
 */
int fixate_crypttab_lookup(const char *crypttab_path, const char *name, FixateCrypttabEntry *out);

/* Release what fixate_crypttab_lookup filled in. Safe on a zeroed struct. */
void fixate_crypttab_entry_done(FixateCrypttabEntry *entry);

/* Write the drop-in that re-runs the cryptsetup attach with fixate-volume-key
 * added to the entry's options. dropin_path is where the override goes; returns
 * 0 on success, negative on error.
 */
int fixate_write_dropin(const char *dropin_path,
                        const FixateCrypttabEntry *entry,
                        const char *fixate_hex);

#endif /* VNGRD_FIXATE_H */

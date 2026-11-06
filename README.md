# vngrd

vngrd is an image-based Linux system for x86-64 UEFI machines, built from source. It needs no hardware beyond a TPM 2.0. If the platform can't hold up its end of the deal (Secure Boot not enforced, firmware changed, disk swapped), the system refuses to boot instead of degrading.

`/usr` is a read-only erofs image checked by dm-verity. The writable root is a LUKS2 ext4 volume whose key is sealed to the TPM and released only under the boot policy in effect. Updates replace the whole `/usr` image (A/B) instead of editing files in place.

## Properties

| Area | Design |
|---|---|
| Firmware | UEFI Secure Boot, signed UKI, systemd-boot |
| Kernel | LLVM/clang-built Linux, minimal config, lockdown, no modules |
| `/usr` | read-only erofs + dm-verity, A/B slots |
| Root | LUKS2-encrypted ext4, created on first boot, shared by both slots |
| `/etc` | tmpfs, populated from the verified `/usr` at every boot |
| Unlock | TPM2 PCR 7 + `PolicyAuthorize(PCR 11)`, PIN, recovery passphrase |
| Updates | `systemd-sysupdate`, whole-partition payloads, rollback floor in TPM NV |
| Boot checks | fixate digest, GPT identity, ESP contents, rollback counter, signed cmdline. A mismatch reboots the machine; it never boots a degraded state |
| Build | source packages pinned by URL, clang/lld. Checksums are still `SKIP` (see vngrd-rootfs): pinned but not content-verified |

## Boot chain

```
UEFI firmware
  └─ signed UKI (kernel + initrd + signed command line)
       └─ initrd
            ├─ mounts /usr by usrhash=, verifies dm-verity
            ├─ runs the fail-closed guards against TPM NV
            ├─ unlocks the LUKS2 root with PCR 7 + PolicyAuthorize(PCR 11)
            └─ systemd-repart creates the root on first boot
                 └─ switch_root
                      ├─ immutable /usr
                      ├─ tmpfs /etc
                      └─ encrypted /var and /home
```

## Partition layout

The image ships 5 partitions and the first boot adds the root. The two slot B
partitions are just empty space until the first update.

**Before provisioning** (straight from the image, `vngrd_0.1.raw`):

| # | Label | Type | Size | Contents |
|---|---|---|---|---|
| 1 | vngrd-esp | ESP | 320 MB | systemd-boot, UKI in `EFI/Linux/`, pcrlock credentials |
| 2 | vngrd-usr_0.1 | usr | 192 MB | slot A `/usr` (erofs) |
| 3 | vngrd-usr_0.1_verity | usr-verity | 2 MB | dm-verity hash tree for slot A |
| 4 | _empty | usr | 192 MB | slot B, empty, waiting for the next version |
| 5 | _empty | usr-verity | 2 MB | slot B hash tree, empty |

**After provisioning** (after the first boot):

| # | Label | Type | Size | Contents |
|---|---|---|---|---|
| 1 | vngrd-esp | ESP | 320 MB | same as shipped, now watched by the ESP guard |
| 2 | vngrd-usr_0.1 | usr | 192 MB | slot A `/usr` (erofs) |
| 3 | vngrd-usr_0.1_verity | usr-verity | 2 MB | dm-verity hash tree for slot A |
| 4 | _empty | usr | 192 MB | still empty, filled by the first sysupdate |
| 5 | _empty | usr-verity | 2 MB | still empty |
| 6 | vngrd-root | root, LUKS2 | remaining space (1 GB minimum) | writable root; `/etc` is tmpfs, `/var` and `/home` persistent |

sysupdate writes the next version into slot B (relabelled with the new version)
and the two slots alternate from there. The root partition is shared by both
slots and is created once, on the first boot, by `systemd-repart` from the
initrd.

## Installation

1. Write the image to the target disk:
   ```
   dd if=vngrd_0.1.raw of=/dev/sdX bs=4M status=progress
   sync
   ```
   `vngrd_0.1.raw` is a complete GPT disk image, so dd it to a whole disk, not a
   partition. Check it against the published SHA256SUMS first.

2. Enrol the Secure Boot keys from trusted media with the machine in setup
   mode. Production images do not carry the enrolment keys on their own ESP, so
   nothing does this for you. The signed variable updates ship with the image
   under `output/image/secureboot/` (see `vngrd-image/README.md`, "Secure Boot
   key lifecycle"):
   ```
   efi-updatevar -f PK.auth PK
   efi-updatevar -f KEK.auth KEK
   efi-updatevar -f db.auth db
   efi-readvar -v db
   ```
   Without Secure Boot enforced, the first boot refuses to provision.
   `systemd-repart` only runs under `ConditionSecurity=uefi-secureboot`,
   because sealing the root's key to a platform that isn't attesting to
   anything would be worth nothing.

3. Boot from the disk. The first-boot console asks you to pick a root recovery
   passphrase and a TPM2 PIN, each twice. The recovery passphrase is what you
   fall back to when the TPM can't unseal (say, after a firmware or dbx
   update), and it's never printed again, so write it down somewhere safe.
   After the prompts everything else happens on its own: the TPM NV checks are
   frozen, the root is created and unlocked, and the login prompt appears.

4. That's the whole install. After that, updates are `systemd-sysupdate` runs
   that fill slot B, the rollback floor moves up in TPM NV once a slot reaches
   `boot-complete`, and a failed update costs nothing but slot B.

## Licensing

vngrd is licensed under the GNU General Public License, version 3 (see
[LICENSE.md](LICENSE.md)). The GPL covers what is authored in this repository.
The packages under `vngrd-rootfs/packages/` and the upstream trees they build
(kernel, systemd, ...) keep their own licenses.

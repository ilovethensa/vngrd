# vngrd

vngrd is an image-based Linux system for x86-64 UEFI machines built from source, with no special hardware required beyond a TPM 2.0. When the platform cannot keep a guarantee — no Secure Boot enforcement, a firmware change, a replaced disk — the system refuses to boot rather than degrade.

`/usr` is a read-only erofs image whose every byte is checked against dm-verity. The writable root is a LUKS2 ext4 volume whose key is sealed to the TPM and released only under the boot policy in effect. Updates replace the whole `/usr` pair (A/B) instead of editing files in place.

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
| Boot checks | fixate digest, GPT identity, ESP contents, rollback counter, signed cmdline; mismatch → reboot, not degraded boot |
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

The image ships 5 partitions; the first boot provisions the root. The two slot B
partitions are placeholder sizes until the first update writes into them.

**Before provisioning** (straight from the image, `vngrd_0.1.raw`):

| # | Label | Type | Size | Contents |
|---|---|---|---|---|
| 1 | vngrd-esp | ESP | 320 MB | systemd-boot, UKI in `EFI/Linux/`, pcrlock credentials |
| 2 | vngrd-usr_0.1 | usr | 192 MB | slot A `/usr` (erofs) |
| 3 | vngrd-usr_0.1_verity | usr-verity | 2 MB | dm-verity hash tree for slot A |
| 4 | _empty | usr | 192 MB | slot B, empty; sysupdate writes the next version here |
| 5 | _empty | usr-verity | 2 MB | slot B hash tree, empty |

**After provisioning** (first boot):

| # | Label | Type | Size | Contents |
|---|---|---|---|---|
| 1 | vngrd-esp | ESP | 320 MB | unchanged; its contents are now pinned by the ESP guard |
| 2 | vngrd-usr_0.1 | usr | 192 MB | slot A `/usr` (erofs) |
| 3 | vngrd-usr_0.1_verity | usr-verity | 2 MB | dm-verity hash tree for slot A |
| 4 | _empty | usr | 192 MB | still empty; filled by the first sysupdate |
| 5 | _empty | usr-verity | 2 MB | still empty |
| 6 | vngrd-root | root, LUKS2 | remaining space (1 GB minimum) | writable root: `/etc` is tmpfs, `/var` and `/home` persistent |

sysupdate writes the next version into slot B (relabelled with the new version),
and slots alternate with every update after that. The root partition is shared
by both slots and is created exactly once, on the first boot, by
`systemd-repart` running from the initrd.

## Installation

1. Write the image to the target disk:
   ```
   dd if=vngrd_0.1.raw of=/dev/sdX bs=4M status=progress
   sync
   ```
   `vngrd_0.1.raw` is a complete GPT disk image, not a filesystem dump, so dd it
   to a whole disk, not to a partition. Verify the artifact against the
   published SHA256SUMS first.

2. Enrol the Secure Boot keys from trusted media with the machine in setup
   mode. Production images do not carry the enrolment keys on their own ESP, so
   nothing does this for you; the signed variable updates are published with
   the image under `output/image/secureboot/` (see `vngrd-image/README.md`,
   "Secure Boot key lifecycle"):
   ```
   efi-updatevar -f PK.auth PK
   efi-updatevar -f KEK.auth KEK
   efi-updatevar -f db.auth db
   efi-readvar -v db
   ```
   Without enforced Secure Boot the first boot refuses to provision
   (`systemd-repart` is gated on `ConditionSecurity=uefi-secureboot`): the
   system will not seal the root's key to a platform that is not attesting to
   anything.

3. Boot from the disk. The first-boot console asks you to choose a root
   recovery passphrase and a TPM2 PIN (each twice). The recovery passphrase is
   the fallback when the TPM cannot unseal — a changed firmware or dbx update —
   and it is never printed again, so record it somewhere safe. After the
   prompts, provisioning completes on its own: the TPM NV checks are frozen,
   the root is created and unlocked, and the login prompt appears.

4. That is the whole install. Updates are `systemd-sysupdate` runs that fill
   slot B; the rollback floor moves up in TPM NV once a slot reaches
   `boot-complete`, and a failed update wastes nothing but slot B.

## Licensing

vngrd is licensed under the GNU General Public License, version 3 (see
[LICENSE.md](LICENSE.md)). The GPL covers what is authored in this repository.
The packages under `vngrd-rootfs/packages/` and the upstream trees they build
(kernel, systemd, ...) keep their own licenses.

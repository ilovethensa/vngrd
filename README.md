# vngrd

vngrd is an image-based Linux system for ordinary x86-64 UEFI machines. It does not require custom firmware, a discrete TPM, or special hardware: it is built to make the strongest guarantees the platform already provides, and to fail closed when those guarantees are absent or have changed.

The shipped system is immutable. `/usr` is a read-only, dm-verity-protected image. The writable root is LUKS2-encrypted and released by the TPM. Updates replace the whole system image through an A/B pair rather than mutating it in place.

## Properties

| Area | Design |
|---|---|
| Firmware | UEFI Secure Boot, signed UKI, systemd-boot |
| Kernel | LLVM/clang-built Linux, minimal config, lockdown, no modules |
| `/usr` | read-only erofs + dm-verity, A/B slots |
| Root | LUKS2-encrypted ext4, created on first boot, shared by both slots |
| `/etc` | tmpfs, populated from the verified `/usr` at every boot |
| Unlock | TPM2 PCR 7 + `PolicyAuthorize(PCR 11)`, PIN-protected, recovery passphrase |
| Updates | `systemd-sysupdate`, whole-partition payloads, rollback floor in TPM NV |
| Boot checks | fixate digest, GPT identity, ESP contents, rollback counter, signed cmdline |
| Build | source packages pinned by URL, built with clang/lld — checksums are still `SKIP` (see vngrd-rootfs), so builds are pinned but not yet content-verified |

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

## Licensing

vngrd is licensed under the GNU General Public License, version 3 (see
[LICENSE.md](LICENSE.md)). Note the boundary: everything in this repository is
the author's work and GPL-3.0, while the packages under `vngrd-rootfs/packages/`
and the upstream trees they build (kernel, systemd, ...) remain under their own
licenses — this license describes only what is authored here, not the software
the rootfs builds from upstream sources.

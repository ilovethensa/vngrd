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

## Licensing

vngrd is licensed under the GNU General Public License, version 3 (see
[LICENSE.md](LICENSE.md)). The GPL covers what is authored in this repository.
The packages under `vngrd-rootfs/packages/` and the upstream trees they build
(kernel, systemd, ...) keep their own licenses.

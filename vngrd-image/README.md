# vngrd-image

Builds the bootable vngrd disk image: ESP, signed UKI, verity-protected `/usr`, spare A/B slot, and a LUKS2 root created on first boot. Assembly uses [mkosi](https://github.com/systemd/mkosi) with a custom distribution and no network package fetches.

This repository only assembles the image. The tests live in [vngrd-tests](../vngrd-tests).

## Inputs

| Input | Producer |
|---|---|
| `../output/rootfs/` | `vngrd-rootfs/scripts/publish.sh` or `vngrd-buildstream/scripts/publish.sh` |
| `../output/kernel/` | `vngrd-kernel/scripts/build.sh` |

The rootfs must already contain the binaries installed by the top-level `build.sh` fixate step.

## Requirements

- `mkosi`
- Secure Boot and PCR signing keys
- `qemu`, `swtpm` and OVMF for running the result

The first `mkosi build` downloads mkosi's tools tree from the Arch mirrors
(mkosi.tools.manifest pins what goes into it); that is a build-time dependency,
independent of the "no network package fetches" rule that governs the image
contents.

Create the gitignored `mkosi.conf.d/50-local-keys.conf`:

```ini
[Validation]
SecureBootKey=/path/to/secureboot.key
SecureBootCertificate=/path/to/secureboot.crt
SignExpectedPcrKey=/path/to/pcr.key
SignExpectedPcrCertificate=/path/to/pcr.crt
```

For a quick start, `./scripts/gen-test-keys.sh` generates both pairs under
keys/local/ (gitignored) and needs no config: mkosi.conf defaults the PCR pair
to that directory. The values above override it — absolute paths work as-is;
repo-relative paths in mkosi.conf are resolved relative to mkosi.conf. The PCR
key must be RSA; lib/image.sh refuses anything else with the openssl recipe.
The build refuses to run without valid key material.

## Usage

```bash
./build.sh
```

The script checks inputs, assembles the initrd, runs `mkosi build`, verifies the UKI, extends the GPT to the configured disk size, and removes stale split payloads.

`mkosi build` on its own is not supported: it skips the signing and verification hooks.

`IMAGE_VERSION` and `IMAGE_DISK_SIZE` can be set in the environment; otherwise they come from `mkosi.conf`.

## Outputs

```
../output/image/vngrd_0.1.raw          bootable disk image
../output/image/vngrd_0.1_*.usr.xz     A/B update payload
../output/image/vngrd_0.1_*.verity.xz  A/B verity payload
../output/image/secureboot/            PK.auth, KEK.auth, db.auth
../output/image/SHA256SUMS             published hashes
```

## Run and inspect

```bash
./scripts/run-vm.sh            # one-off VM, console attached
./scripts/run-vm.sh --gui      # GTK window
./scripts/vm-setup.sh          # provision a persistent interactive VM
./scripts/vm-boot.sh           # boot that VM

mkosi shell
systemd-dissect ../output/image/vngrd_0.1.raw
sfdisk -l ../output/image/vngrd_0.1.raw
```

`vm-setup.sh` and `vm-boot.sh` use their own state directory and do not touch the test suite's machine.

## Layout

```
build.sh              image build driver
lib/common.sh         paths and mkosi.conf reader
lib/initrd.sh         initrd construction
lib/image.sh          input checks, UKI verification, GPT extension
lib/hooks.sh          mkosi finalize and postoutput logic
initrd/*.txt          initrd seed and allow lists
mkosi.conf            image definition
mkosi.conf.d/         local keys and workspace overrides (gitignored)
mkosi.repart/         partition definitions
mkosi.finalize        mkosi finalize hook
mkosi.postoutput      mkosi postoutput hook
scripts/run-vm.sh     one-off QEMU boot (honours OVMF_CODE/OVMF_VARS overrides)
scripts/vm-setup.sh   provision the interactive VM
scripts/vm-boot.sh    boot the interactive VM
scripts/ukify         UKI wrapper that pins the PCR phase set
scripts/gen-test-keys.sh  create the two key pairs for a first build
scripts/fix-gpt.py    backup GPT relocation
keys/                 pinned Microsoft CA certificates
mkosi.tools/          generated tools tree (gitignored)
```

## Secure Boot

Production images do not carry enrolment keys on the ESP. Enrol the signed `PK.auth`, `KEK.auth` and `db.auth` from trusted media with the machine in setup mode:

```bash
efi-updatevar -f PK.auth PK
efi-updatevar -f KEK.auth KEK
efi-updatevar -f db.auth db
efi-readvar -v db
```

Do not enrol from the image's own ESP. See the project README for the key lifecycle and recovery procedures.

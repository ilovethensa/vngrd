# vngrd-fixate-generator

The pre-boot guard, provisioning and update tools for vngrd. The binaries run during the initrd before the root is unlocked, on the first-boot provisioning path, or on the running host.

## Binaries

| Binary | Runs | Purpose |
|---|---|---|
| `vngrd-fixate-generator` | initrd generator, every boot | injects the fixate digest check into `systemd-cryptsetup` |
| `vngrd-fixate-guard` | initrd, every boot | refuses a provisioned machine whose fixate digest is missing |
| `vngrd-fixate-nvwrite` | provisioned boot | writes the fixate digest to TPM NV |
| `vngrd-gpt-guard` | initrd, every boot | checks the frozen GPT identity |
| `vngrd-gpt-freeze` | provisioned boot | freezes the GPT identity |
| `vngrd-esp-guard` | initrd, every boot | checks the frozen ESP contents |
| `vngrd-esp-freeze` | provisioned boot | freezes the ESP contents |
| `vngrd-bootloader-sync` | host, before boot completion | copies the signed bootloader from `/usr` to the ESP |
| `vngrd-rollback-guard` | initrd, every boot | refuses a version below the TPM rollback floor |
| `vngrd-rollback-commit` | provisioned boot and host | creates and raises the rollback floor |
| `vngrd-cmdline-guard` | initrd, every boot | compares `/proc/cmdline` with the signed UKI command line |
| `vngrd-passphrase` | provisioning and reseal | prompts for the recovery passphrase and enrols it |
| `vngrd-secureboot-update` | host | applies a signed dbx update and requests reseal/reboot |
| `vngrd-fixate-pcr` | operator tool | prints boot-time PCR values for diagnosis |

## Requirements

- x86-64 Linux
- the vngrd builder container, or an equivalent clang/lld sysroot with tpm2-tss

## Usage

```bash
make                    # build
make test               # unit tests; no TPM required
make run                # exercise the no-index path
make install            # install into $(SYSROOT)
make format             # clang-format
make tidy               # clang-tidy
make clean
```

The top-level `build.sh` builds and installs these binaries into `output/rootfs`:

```bash
make SYSROOT=/out
make SYSROOT=/out test
make SYSROOT=/out install
```

The installed ELF interpreter must be `/usr/lib/ld-linux-x86-64.so.2`, and every `DT_NEEDED` must resolve inside the sysroot. `make install` checks both.

## Layout

```
include/    public headers for each component
src/        one implementation per component, plus one *-main.c per binary
tests/      unit tests for the drop-in, cmdline, SHA-256, rollback and GPT logic
Makefile
```

The TPM NV indices, digest formats and the reasoning for each check are documented in the headers and in `vngrd-image/README.md`.

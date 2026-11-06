# vngrd-buildstream

BuildStream definitions for the vngrd rootfs. The result is a merged-`/usr` tree published to `../output/rootfs`, where [vngrd-image](../vngrd-image) reads it.

## Requirements

- BuildStream 2.8
- `buildstream-plugins` (autotools, cmake, make, meson)
- Docker or Podman for the generated inputs
- unprivileged user namespaces for the sandbox

## Usage

```bash
# once: generate the imported trees
(cd ../vngrd-rootfs && ./scripts/export-seed.sh ../vngrd-buildstream/elements/seed)
./scripts/export-rust.sh
./scripts/export-vendor.sh
./scripts/export-subprojects.sh

# build and verify
./scripts/build.sh rootfs.bst verify.bst

# build, verify, and publish to ../output/rootfs
./scripts/publish.sh

# inspect an element's build sandbox
bst shell --build packages/fish.bst
```

`scripts/build.sh` generates any missing imported tree before running `bst build`. The seed and Rust exports need the vngrd builder image; the vendor and subproject exports need network access. Builds themselves run without network.

`scripts/clean.sh` removes the generated trees. Add `--all` to drop BuildStream caches as well.

## Generated inputs

These trees are gitignored and must exist before a first build:

| Tree | Producer |
|---|---|
| `elements/seed/` | `vngrd-rootfs/scripts/export-seed.sh` |
| `elements/toolchain/rust/` | `scripts/export-rust.sh` |
| `elements/packages/fish/files/vendor/` | `scripts/export-vendor.sh` |
| `elements/packages/dbus-broker/files/subprojects/` | `scripts/export-subprojects.sh` |

Each export records its source in a `*-SOURCE` marker. Regenerating one changes the artifact and rebuilds everything below it.

## Layout

```
project.conf              toolchain options, fatal warnings, plugin config
elements/
  seed.bst                imported build toolchain
  base.bst                linux-headers + glibc sysroot
  rootfs.bst              base + all packages
  verify.bst              FHS/ELF checks over the assembled rootfs
  audit-tools.bst         build tools for the verifier
  auditor.bst             verify script import
  packages/*.bst          one element per package
  toolchain/rust.bst      imported Rust toolchain
scripts/
  build.sh                generate missing inputs, then bst build
  publish.sh              build, verify, check out to ../output/rootfs
  clean.sh                remove generated state
  export-*.sh             generate imported trees
  verify-rootfs.sh        standalone filesystem check
  verify-tree.py          check any tree
```

## Verification

`verify.bst` fails the build when the rootfs has:

- a top-level `/bin`, `/sbin`, `/lib`, `/lib64` or `/lib32`, including symlinks
- anything under `/usr` besides `bin`, `lib`, `include` and `share`
- an ELF interpreter other than `/usr/lib/ld-linux-x86-64.so.2`
- an unresolvable `DT_NEEDED` or a runpath escaping the image
- a dangling symlink or a shebang under `/bin` or `/sbin`

`overlaps` is fatal: two packages may not install the same path.

The auditor runs from a filtered copy of the seed, not from the rootfs being checked, so the tools do not audit themselves. An empty `/usr/bin` fails instead of passing vacuously.

## Configuration

The user-level BuildStream configuration controls parallelism. On a desktop, leave one core free:

```yaml
# ~/.config/buildstream.conf
scheduler:
  builders: 1
build:
  max-jobs: 3
```

See `project.conf` for element options and fatal warnings.

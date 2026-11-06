# vngrd-rootfs

KISS-style package builder for vngrd. It produces a merged-`/usr` root filesystem and exports the build toolchain seed used by [vngrd-buildstream](../vngrd-buildstream).

This repository does not build the kernel or the image.

**Version contract:** `packages/linux-headers/version` must match `vngrd-kernel/version`.

## Requirements

- x86-64 Linux host
- Docker or Podman

## Usage

```bash
# one-time builder image
docker build -f docker/Dockerfile.builder -t vngrd-builder docker/

# all packages, in dependency order (package builds need no Bootlin toolchain)
./scripts/01-build.sh

# one package
./scripts/build-pkg.sh systemd

# publish the merged-/usr tree for the image build
./scripts/publish.sh          # -> ../output/rootfs

# remove all caches and outputs
./scripts/00-clean.sh
```

`01-build.sh` reads the package order from its `ORDER` list. Package builds are cached in `bin/`; downloaded sources go to `sources/`, extracted trees to `work/<pkg>/`, and installed files to `out/`.

## Layout

```
packages/<name>/        version, sources, checksums, depends, build
docker/                 builder container
config/                 kiss.conf and docker.env
scripts/                build and publish scripts
toolchain/              Bootlin cross-toolchain seed for vngrd-buildstream
                        (run ./scripts/bootstrap-toolchain.sh to fetch; not
                        needed for the package builds themselves)
out/                    installed packages / rootfs (gitignored)
bin/                    package archive markers (gitignored)
sources/ work/          download and build caches (gitignored)
```

Checksums are currently `SKIP`: sources are pinned by URL and version, but the
sha256 pins land with the vngrd-buildstream move, so a build is not yet
content-verified. Treat the pinning claim in the main README accordingly.

`docker` is the default container CLI in these scripts; Podman works as a
drop-in with `DOCKER=podman`.

## Adding a package

Create `packages/<name>/` with:

- `version` — version string
- `sources` — one source URL per line
- `checksums` — sha256 per source line (`SKIP` for git/local)
- `depends` — one package per line, empty if none
- `build` — executable shell script receiving `DESTDIR` as `$1`

Add the package to the `ORDER` list in `scripts/01-build.sh` after its dependencies.

## Output contract

`out/` and `../output/rootfs` are merged-`/usr` trees: only `/usr/{bin,lib,include,share}`, `/etc` and `/var`. There is no kernel and no top-level `/bin`, `/sbin`, `/lib` or `/lib64`.

See `AGENTS.md` at the repository root for the project-wide build rules.

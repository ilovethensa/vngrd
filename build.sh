#!/usr/bin/env bash
# build.sh — end-to-end vngrd build: rootfs -> fixate -> kernel -> image.
#
# The order is not arbitrary. The fixate generator is a compiled binary that gets
# installed INTO output/rootfs, so it has to run after the rootfs is published and
# before mkosi reads that tree; the kernel is independent of both.
#
# Usage:
#   ./build.sh                              full build (kernel from source)
#   ./build.sh --kernel-prebuilt <path>     use a precompiled kernel instead
#                                           (<path> = dir or tarball with
#                                            boot/vmlinuz + lib/modules/)
#   ./build.sh --skip-rootfs                reuse existing ../output/rootfs
#                                          (the fixate step still runs: it
#                                           installs into output/rootfs)
#   ./build.sh --skip-image                 stop after publishing rootfs+kernel
set -euo pipefail

# Podman is a drop-in for everything used here: set DOCKER=podman.
DOCKER=${DOCKER:-docker}

ROOT="$(cd "$(dirname "$0")" && pwd)"

KERNEL_PREBUILT=""
SKIP_ROOTFS=0
SKIP_IMAGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel-prebuilt)
            [ -n "${2:-}" ] || { echo "error: --kernel-prebuilt requires a path" >&2; exit 1; }
            # Resolve now — we cd into subrepos before this is used.
            case "$2" in
                /*) KERNEL_PREBUILT="$2" ;;
                *)  KERNEL_PREBUILT="$PWD/$2" ;;
            esac
            shift 2 ;;
        --skip-rootfs) SKIP_ROOTFS=1; shift ;;
        --skip-image)  SKIP_IMAGE=1;  shift ;;
        -h|--help)
            sed -n '2,10p' "$0"; exit 0 ;;
        *)
            echo "error: unknown option: $1" >&2; exit 1 ;;
    esac
done

step() { printf '\n==> %s\n' "$*"; }

# --- rootfs ---------------------------------------------------------
if [ "$SKIP_ROOTFS" -eq 0 ]; then
    step "rootfs: build packages"
    cd "$ROOT/vngrd-rootfs"
    if [ ! -d out ]; then
        ${DOCKER} build -f docker/Dockerfile.builder -t vngrd-builder docker/
    fi
    ./scripts/01-build.sh

    step "rootfs: publish -> ../output/rootfs"
    ./scripts/publish.sh
else
    step "rootfs: skipped (--skip-rootfs)"
fi

# --- fixate generator ----------------------------------------------------
# Between the rootfs and the image, and that position is load-bearing rather than
# tidy: this installs a binary INTO output/rootfs, so it has to run after the
# rootfs is published or it installs into a tree nothing reads, and it has to run
# before mkosi builds or the image is built without it. Putting it after the
# kernel step would work too, but then the rootfs is not final until after the
# kernel is done, which is a worse thing to have to reason about.
#
# Not a package. Everything under packages/ is an upstream source package, and
# this is ours; the pkg-config/verify/stamp machinery in build-pkg.sh is for
# fetching a tarball and diffing a hermetic-layout delta, none of which applies.
# The trade is that it does not get those checks, so the ones that matter are done
# explicitly in `make install` -- the merged-/usr interpreter and every DT_NEEDED
# resolving inside the sysroot -- and the output is asserted in
# vngrd-image/lib/initrd.sh, where a missing generator is a build failure
# rather than a boot that quietly skips the fixate check.
if [ ! -d "$ROOT/output/rootfs" ]; then
    echo "build.sh: $ROOT/output/rootfs does not exist; build or restore the rootfs first" >&2
    exit 1
fi
if [ ! -d "$ROOT/vngrd-rootfs/out" ]; then
    echo "build.sh: $ROOT/vngrd-rootfs/out does not exist; it is the sysroot this links against" >&2
    exit 1
fi
if [ ! -d "$ROOT/vngrd-rootfs/toolchain" ]; then
    # Same order as the rootfs step: build the builder image if it is missing.
    echo "build.sh: building the builder image"
    ${DOCKER} build -f "$ROOT/vngrd-rootfs/docker/Dockerfile.builder" -t vngrd-builder "$ROOT/vngrd-rootfs/docker/"
fi
if ! ${DOCKER} image inspect vngrd-builder >/dev/null 2>&1; then
    ${DOCKER} build -f "$ROOT/vngrd-rootfs/docker/Dockerfile.builder" -t vngrd-builder "$ROOT/vngrd-rootfs/docker/"
fi

step "fixate: build vngrd-fixate-generator -> ../output/rootfs"
# Sources and the sysroot are bind-mounted, not copied: the generator is built
# here and nowhere else, and a stale copy of it in the image would be worse than
# a missing one because it would look like it was working.
${DOCKER} run --rm \
    -v "$ROOT/vngrd-fixate-generator:/src" \
    -v "$ROOT/vngrd-rootfs/out:/out" \
    -v "$ROOT/vngrd-rootfs/config:/config:ro" \
    vngrd-builder sh -c '
        set -e
        # kiss.conf inside the container, for the same reason build-pkg.sh does it
        # there and not in the caller environment: the caller has not exported it.
        set -a; . /config/kiss.conf; set +a
        cd /src
        make SYSROOT=/out
        make SYSROOT=/out test
        make SYSROOT=/out install SYSROOT=/out
    '

# `make install` puts the binary in vngrd-rootfs/out/, which is the accumulating
# install tree. It is NOT the tree the image is built from: mkosi reads
# ../output/rootfs, and vngrd-image/lib/initrd.sh reads the same tree. The
# two are only the same tree immediately after scripts/publish.sh, and with
# --skip-rootfs there is no publish.
#
# So with --skip-rootfs the install above lands in out/ and the image silently
# gets no generator at all: the root opens, the fixate check does not run, and
# nothing in the boot says so. That happened, and the symptom was a boot that was
# otherwise perfect.
#
# Both copies are needed and neither is redundant. out/ is canonical, so the file
# survives the next scripts/publish.sh rather than being deleted by it;
# output/rootfs is what this build's mkosi and initrd actually read.
# Both binaries, and both locations. A list rather than one path because the
# generator and the write helper have different homes (systemd's fixed
# SYSTEM_GENERATOR_DIR, and usr/lib/vngrd) and a single hardcoded path meant the
# second one was installed into out/ and never reached the image -- the unit then
# failed to load with "Command /usr/lib/vngrd/vngrd-fixate-nvwrite is not
# executable", which is at least a loud failure, but only because
# systemd-analyze verify happens to be run by hand.
#
# The rollback/GPT/ESP binaries are here for the same reason. rollback-guard,
# gpt-guard and esp-guard run in the initrd (Before=sysroot.mount, so they must be
# present on the boot that would otherwise proceed); rollback-commit runs on the
# host, and gpt-freeze and esp-freeze as the fixate unit's second and third
# ExecStart. All of them are installed by the same `make install', and all have to
# reach output/rootfs or the image gets a unit that execs a path that is not there.
for rel in usr/lib/systemd/system-generators/vngrd-fixate-generator \
           usr/lib/vngrd/vngrd-fixate-nvwrite \
           usr/lib/vngrd/vngrd-fixate-pcr \
           usr/lib/vngrd/vngrd-cmdline-guard \
           usr/lib/vngrd/vngrd-rollback-guard \
           usr/lib/vngrd/vngrd-rollback-commit \
           usr/lib/vngrd/vngrd-gpt-guard \
           usr/lib/vngrd/vngrd-gpt-freeze \
           usr/lib/vngrd/vngrd-esp-guard \
           usr/lib/vngrd/vngrd-esp-freeze \
           usr/lib/vngrd/vngrd-fixate-guard \
           usr/lib/vngrd/vngrd-bootloader-sync \
           usr/lib/vngrd/vngrd-passphrase \
           usr/lib/vngrd/vngrd-secureboot-update; do
    src="$ROOT/vngrd-rootfs/out/$rel"
    dst="$ROOT/output/rootfs/$rel"
    [ -f "$src" ] || { echo "build.sh: $src was not installed" >&2; exit 1; }
    mkdir -p "$(dirname "$dst")"
    install -m 0755 "$src" "$dst"
    [ -x "$dst" ] || { echo "build.sh: $dst is not executable after install" >&2; exit 1; }
    # The two copies must be identical, or the next publish will install one of
    # them and not the other, and which one that is depends on which half of the
    # build ran last.
    cmp -s "$src" "$dst" || {
        echo "build.sh: $src and $dst differ." >&2
        echo "  The image is built from output/rootfs and the next rootfs build publishes" >&2
        echo "  from out/, so a difference here becomes a fixate check that appears and" >&2
        echo "  disappears depending on which half of the build ran last." >&2
        exit 1
    }
done

# --- kernel ---------------------------------------------------------
cd "$ROOT/vngrd-kernel"
if [ -n "$KERNEL_PREBUILT" ]; then
    step "kernel: prebuilt -> ../output/kernel"
    ./scripts/build.sh --prebuilt "$KERNEL_PREBUILT"
else
    step "kernel: build -> ../output/kernel"
    ./scripts/build.sh
fi

# --- image ----------------------------------------------------------
if [ "$SKIP_IMAGE" -eq 0 ]; then
    step "image: build -> ../output/image"
    "$ROOT/vngrd-image/build.sh"
    step "done: $ROOT/output/image/vngrd_${IMAGE_VERSION:-0.1}.raw"
    echo "Boot with: cd vngrd-image && ./scripts/run-vm.sh"
else
    step "image: skipped (--skip-image)"
fi

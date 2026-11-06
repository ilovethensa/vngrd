#!/bin/sh -e
# Usage: scripts/build.sh [--clean | --prebuilt <dir|tarball>]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/../output/kernel"
BUILDER_IMAGE=vngrd-kernel-builder

# Podman is a drop-in for everything used here: set DOCKER=podman.
DOCKER=${DOCKER:-docker}

fail() { echo "error: $*" >&2; exit 1; }

validate_tree() {
    dir="$1"
    [ -e "$dir/boot/vmlinuz" ] || fail "missing $dir/boot/vmlinuz"
    # Merged /usr: modules must be at usr/lib/modules (not lib/modules).
    #
    # The directory is required even though it is empty: it is the marker mkosi
    # and ukify find the kernel through (mkosi.finalize step 3 copies /boot/vmlinuz
    # into usr/lib/modules/*/vmlinuz, and mkosi's own kernel discovery looks for
    # usr/lib/modules/<kver>/vmlinuz). CONFIG_MODULES=n means there is no module
    # loader at all, so build-inner.sh creates the directory explicitly instead
    # of relying on `make modules_install' to.
    if [ -d "$dir/usr/lib/modules" ]; then
        mod_base="$dir/usr/lib/modules"
    elif [ -d "$dir/lib/modules" ]; then
        echo "WARN: $dir/lib/modules is legacy non-merged path — should be usr/lib/modules (AGENTS.md)" >&2
        mod_base="$dir/lib/modules"
    else
        fail "missing $dir/usr/lib/modules (and no legacy lib/modules)"
    fi
    echo "Using precompiled kernel from $dir"
    echo "  $(ls "$dir/boot" 2>/dev/null | tr '\n' ' ')"
    echo "  modules: $(ls -d "$mod_base"/* 2>/dev/null | xargs -n1 basename 2>/dev/null) (none: CONFIG_MODULES=n)"
    # vmlinuz and the modules directory must be from the same kernel release,
    # else the image builds fine but ukify picks a tree whose vermagic does not
    # match the bzImage and the initrd's modules fail at boot (emergency mode).
    kver_img="$(file -b "$dir/boot/vmlinuz" | sed -n 's/.*version \([^ ,]*\).*/\1/p')"
    [ -n "$kver_img" ] || fail "cannot extract kernel version from $dir/boot/vmlinuz (file output)"
    for kdir in "$mod_base"/*/; do
        kver_mod="$(basename "$kdir")"
        [ "$kver_mod" = "$kver_img" ] || fail "version mismatch: boot/vmlinuz is $kver_img but lib/modules has $kver_mod — the tree mixes kernels and will not boot"
    done
    # A .ko in a tree whose config says CONFIG_MODULES=n means one of the two is
    # wrong, and the more likely reading is that the tree was built with modules
    # enabled. That is not cosmetic: the initrd script asserts no .ko ever
    # reaches the initrd, and a kernel with a module loader and MODULE_SIG=n
    # will load an unsigned one without complaint. Refuse rather than guess.
    if find "$mod_base" \( -name '*.ko' -o -name '*.ko.*' \) -print 2>/dev/null | grep -q .; then
        fail "$mod_base contains .ko files but this kernel is CONFIG_MODULES=n — the tree was built with modules enabled, or is not the kernel that shipped configs/vngrd.config"
    fi
    # The lockdown floor and the holes it is not the answer to, asserted from the
    # published config rather than trusted: lockdown is what makes the running kernel
    # unforgeable from the writable root, and a --prebuilt tree is an external input.
    # build-inner.sh asserts the same properties against .config before it builds, and
    # these are the ones that have to hold of the artifact that actually ships.
    #
    # Note the polarity, which is easy to get backwards: the floor must be *present*,
    # so that check is `|| fail'; the off-switches must be *absent*, so theirs are
    # `&& fail'. It is also why the explicit `return 0' below is not decoration: under
    # `set -e', a trailing `grep && fail' list exits 1 on the good path, and that would
    # become the function's status and abort the build precisely when the tree is
    # correct.
    #
    # Each of these is a different reason the tree is not the kernel vngrd means to run:
    # MODULES=y loads an unsigned module with no complaint; KEXEC=y is the
    # unsigned-kernel persistence path, which bypasses Secure Boot and dm-verity
    # together; DEVMEM=y is readable physical memory; and PROC_KCORE=y is the same
    # read as a file, which lockdown=integrity does not block either, because
    # LOCKDOWN_KCORE is enum value 22 while LOCKDOWN_INTEGRITY_MAX is 21 and
    # lockdown_is_locked_down() only denies when kernel_locked_down >= what.
    cfg="$dir/boot/config"
    if [ -f "$cfg" ]; then
        grep -q '^CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y' "$cfg" ||
            fail "$cfg: lockdown floor is not CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y (see configs/vngrd.config)"
        grep -q '^CONFIG_MODULES=y' "$cfg" &&
            fail "$cfg: CONFIG_MODULES=y — this tree has a module loader (see configs/vngrd.config)"
        grep -q '^CONFIG_KEXEC=y' "$cfg" &&
            fail "$cfg: CONFIG_KEXEC=y — unsigned-kernel persistence path (see configs/vngrd.config)"
        grep -q '^CONFIG_DEVMEM=y' "$cfg" &&
            fail "$cfg: CONFIG_DEVMEM=y — readable physical memory (see configs/vngrd.config)"
        grep -q '^CONFIG_PROC_KCORE=y' "$cfg" &&
            fail "$cfg: CONFIG_PROC_KCORE=y — /proc/kcore is a full physical-RAM read, and lockdown=integrity does not block it (see configs/vngrd.config)"
        # AGENTS.md: LLVM only. Recorded so a tree whose vmlinux was linked by GNU ld
        # is caught here rather than trusted, since a mixed toolchain otherwise builds
        # and boots identically.
        grep -q '^CONFIG_LD_IS_BFD=y' "$cfg" &&
            fail "$cfg: CONFIG_LD_IS_BFD=y — vmlinux was linked by GNU ld, not ld.lld (AGENTS.md)"
    fi
    return 0
}

publish() {
    src="$1"
    if [ "$(readlink -f "$src")" = "$(readlink -f "$OUTPUT")" ]; then
        echo "Already published at $OUTPUT"
        validate_tree "$OUTPUT"
        return
    fi
    echo "Publishing -> ${OUTPUT#$ROOT/../}"
    rm -rf "$OUTPUT"
    mkdir -p "$OUTPUT"
    tar -C "$src" --no-same-owner -cf - . | tar -C "$OUTPUT" --no-same-owner -xf -
    echo "Done: $OUTPUT"
    validate_tree "$OUTPUT"
}

if [ "${1:-}" = "--clean" ]; then
    echo "Cleaning work/ and out/ for fresh build"
    rm -rf "$ROOT/work" "$ROOT/out"
    mkdir -p "$ROOT/work" "$ROOT/out"
    shift
fi

if [ "${1:-}" = "--prebuilt" ]; then
    [ -n "${2:-}" ] || fail "--prebuilt requires a path (dir or tarball)"
    SRC="$2"
    [ -e "$SRC" ] || fail "not found: $SRC"

    if [ -d "$SRC" ]; then
        validate_tree "$SRC"
        publish "$SRC"
        exit 0
    fi

    case "$SRC" in
        *.tar.gz|*.tgz|*.tar.xz|*.tar.zst|*.tar.bz2|*.tar) ;;
        *) fail "prebuilt path must be a directory or tarball: $SRC" ;;
    esac

    STAGE="$ROOT/work/prebuilt"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    echo "Extracting $SRC -> work/prebuilt/"
    case "$SRC" in
        *.tar.zst) tar --zstd -xf "$SRC" -C "$STAGE" ;;
        *)         tar -xf "$SRC" -C "$STAGE" ;;
    esac

    # Accept either the artifact shape at the root, or a single top-level dir.
    if [ ! -e "$STAGE/boot/vmlinuz" ]; then
        top="$(ls -A "$STAGE")"
        case "$top" in
            *'
'*) fail "tarball has multiple top-level entries; expected boot/vmlinuz at root" ;;
        esac
        [ -d "$STAGE/$top" ] && STAGE="$STAGE/$top"
    fi
    validate_tree "$STAGE"
    publish "$STAGE"
    exit 0
fi

VERSION="$(cat "$ROOT/version")"
# Cross-repo contract (see the READMEs): linux-headers built into the rootfs must
# be the generation this kernel was written against, or its Makefile-driven
# module version drifts from the headers and modules fail to build inside the
# builder. Checked here rather than in the rootfs because the kernel is the
# producer.
if [ -f "$ROOT/../vngrd-rootfs/packages/linux-headers/version" ]; then
    hdr="$(cat "$ROOT/../vngrd-rootfs/packages/linux-headers/version")"
    [ "$hdr" = "$VERSION" ] || fail "version contract: vngrd-kernel/version is $VERSION but vngrd-rootfs linux-headers is $hdr — bump one to match the other"
else
    fail "cannot check the version contract: ../vngrd-rootfs/packages/linux-headers/version is missing"
fi
TOPDIR="linux-$VERSION"
SRC_URL="$(grep -v '^\s*#' "$ROOT/sources" | grep -v '^\s*$' | head -n1)"
FNAME="$(basename "$SRC_URL")"
WORK="$ROOT/work/$TOPDIR"
OUT="$ROOT/out"
CACHE="$ROOT/cache"

mkdir -p "$CACHE" "$ROOT/work" "$OUT" "$OUTPUT"

if [ ! -f "$CACHE/$FNAME" ]; then
    echo "Fetching $SRC_URL"
    curl -L "$SRC_URL" -o "$CACHE/$FNAME"
fi

SUM="$(grep -v '^\s*#' "$ROOT/checksums" | grep -v '^\s*$' | head -n1)"
if [ -n "$SUM" ] && [ "$SUM" != "SKIP" ]; then
    echo "$SUM  $CACHE/$FNAME" | sha256sum -c -
fi

if [ ! -d "$WORK" ]; then
    echo "Extracting cache/$FNAME -> work/$TOPDIR/"
    tar -xf "$CACHE/$FNAME" -C "$ROOT/work"
fi

if ! ${DOCKER} image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
    echo "Building $BUILDER_IMAGE"
    ${DOCKER} build -t "$BUILDER_IMAGE" "$ROOT/docker"
fi

echo "Building kernel $VERSION (incremental, use --clean for full rebuild)"
${DOCKER} run --rm \
    -v "$WORK:/build:rw" \
    -v "$OUT:/out:rw" \
    -v "$ROOT/kernel.config:/config/kernel.config:ro" \
    -v "$ROOT/configs:/config/configs:ro" \
    -v "$ROOT/scripts/build-inner.sh:/build-inner.sh:ro" \
    "$BUILDER_IMAGE" \
    sh -e /build-inner.sh

publish "$OUT"

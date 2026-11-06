#!/bin/sh -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Build order. Each package must follow its declared dependencies.
#
# base-files is last: it asserts that systemd's units and the vngrd-* symlinks
# resolve in DESTDIR, so systemd must already be installed.
ORDER="
linux-headers
glibc
zlib
ncurses
# libpam links libcrypt, which comes from the system dep rather than from this
# ordering. Single quotes here are deliberate: this block is inside a
# double-quoted shell string, and a double quote would end it early.
libpam
openssl
ca-certificates
curl
lvm2
popt
# util-linux-libs is here, not util-linux, because of a genuine cycle:
# cryptsetup needs uuid/uuid.h from libuuid, util-linux's findmnt needs
# libudev.h from systemd, and systemd needs libcryptsetup. util-linux's
# *libraries* never touch libudev, so building them here breaks the loop.
# See packages/util-linux-libs/build for the whole argument.
util-linux-libs
cryptsetup
tpm2-tss
tpm2-tools
kmod
kbd
systemd
# These two need systemd itself. util-linux compiles misc-utils/findmnt.c
# against libudev.h, and dbus-broker's tests link libsystemd.so.
# Single quotes in this comment are deliberate -- the block below lives inside
# a double-quoted shell string, and a double quote here would end it early.
dbus-broker
util-linux
# e2fsprogs is configured with --disable-libblkid, so it uses util-linux's
# libblkid and needs blkid/blkid.h; util-linux must come first.
e2fsprogs
# libgcc is a copy, not a build: fish is the image's only C++ and only
# Rust program, so it is the only thing that emits a DT_NEEDED on
# libgcc_s.so.1. See packages/libgcc/build for why -static-libgcc is not
# an option. It must precede fish.
libgcc
fish
coreutils
base-files
"

# ORDER carries inline comments, so it cannot be word-split: `for pkg in $ORDER'
# would hand the loop words from comment lines. Derive the list line by line and
# keep only package-shaped words.
ORDER_LIST=$(printf '%s\n' "$ORDER" | tr -d '"' \
             | grep -E '^[[:space:]]*[a-z0-9][a-z0-9-]*[[:space:]]*$' | tr -d ' ')

for pkg in $ORDER_LIST; do
    # Still fail on a genuine typo: a missing package directory is a bug in this
    # file, not something to skip quietly.
    [ -d "$ROOT/packages/$pkg" ] || {
        echo "01-build.sh: no such package in packages/: $pkg" >&2
        exit 1
    }
    # Re-source global config so per-package overrides (e.g. glibc bootstrap) don't leak
    if [ -f "$ROOT/config/kiss.conf" ]; then
        . "$ROOT/config/kiss.conf"
    fi
    "$ROOT/scripts/build-pkg.sh" "$pkg"
done

echo "All packages built. Next: scripts/publish.sh  (-> ../output/rootfs, read by vngrd-image)"

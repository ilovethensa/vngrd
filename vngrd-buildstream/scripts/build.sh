#!/bin/sh
# Build the vngrd rootfs, generating every imported tree first.
#
# Three of the four are not committed, and "clone, then build" has to work on a
# fresh checkout without the operator knowing why any of them exists:
#
#   elements/seed                           vngrd-rootfs's export-seed.sh, out
#                                           of the pinned vngrd-builder image
#   elements/toolchain/rust                 scripts/export-rust.sh, same image
#   elements/packages/fish/files/vendor     scripts/export-vendor.sh (network)
#   elements/packages/dbus-broker/files/subprojects
#                                           scripts/export-subprojects.sh (git)
#
# Only the seed is another repo's script: the other three live here, and
# regenerating any of them is how a toolchain or crates.io snapshot is
# refreshed. Each script refuses to write into an existing tree, so a partial
# export can never mix two snapshots -- and that is why the checks below are
# for one specific well-formed file per tree rather than "is the directory
# non-empty" (a leftover half-export would satisfy that and the build would
# fail later, further from the cause).
#
# Note what refreshing an input costs: every export script records its
# timestamp in the tree (SEED-SOURCE, TOOLCHAIN-SOURCE, VENDOR-SOURCE,
# SUBPROJECTS-SOURCE), so a regenerated tree is a new artifact and the world
# below it rebuilds. That is the correct answer for a from-source distro -- a
# new toolchain or crates snapshot SHOULD rebuild everything -- and it is why
# regeneration is a deliberate act rather than something build.sh does when it
# finds a stale-looking tree.
set -eu

cd "$(dirname "$0")/.."
ROOTFS=../vngrd-rootfs

need_export=0
[ -x "$ROOTFS/scripts/export-seed.sh" ] || {
    echo "build.sh: $ROOTFS/scripts/export-seed.sh is missing" >&2
    echo "  the seed is exported from the vngrd-rootfs checkout beside this one" >&2
    exit 1
}

[ -f elements/seed/usr/bin/clang ] || {
    echo "### elements/seed missing; exporting the build toolchain"
    "$ROOTFS/scripts/export-seed.sh" elements/seed
    need_export=1
}
[ -x elements/toolchain/rust/usr/lib/rust/bin/cargo ] || {
    echo "### elements/toolchain/rust missing; exporting the Rust toolchain"
    ./scripts/export-rust.sh
    need_export=1
}
[ -f elements/packages/fish/files/vendor/pcre2-sys/Cargo.toml ] || {
    echo "### fish's vendored crates missing; vendoring"
    ./scripts/export-vendor.sh
    need_export=1
}
[ -f elements/packages/dbus-broker/files/subprojects/libcdvar-1/meson.build ] || {
    echo "### dbus-broker's subprojects missing; vendoring"
    ./scripts/export-subprojects.sh
    need_export=1
}
[ "$need_export" = 0 ] || echo

echo "### bst build $*"
exec bst build "$@"

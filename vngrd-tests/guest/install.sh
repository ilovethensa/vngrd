#!/bin/sh -e
# install.sh — copy the guest test payload into a built tree.
#
#   guest/install.sh <tree> rootfs    # the reporter, checks and the selftest unit
#   guest/install.sh <tree> initrd    # the reporter and the initrd milestone units
#
# <tree> is a staged filesystem, e.g. output/rootfs or output/initrd-root. This
# script only writes into a derived test image; it never touches the shipped
# artefact, and the units it installs are inert without `vngrd.test=1` on the
# kernel command line.
#
# Rebuilding the UKI/initrd after installing is the caller's job. See
# docs/boot-instrumentation.md.

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree=${1:?usage: install.sh <tree> rootfs|initrd}
role=${2:?usage: install.sh <tree> rootfs|initrd}

[ -d "$tree/usr/lib/systemd/system" ] || {
    echo "install.sh: $tree has no usr/lib/systemd/system; not a systemd tree" >&2
    exit 1
}

lib="$tree/usr/lib/vngrd-tests"
install -d -m755 "$lib"
install -m755 "$SELF/vngrd-testreport" "$lib/vngrd-testreport"

want() {
    _unit=$1
    _target=$2
    install -m644 "$SELF/units/$_unit" "$tree/usr/lib/systemd/system/$_unit"
    install -d -m755 "$tree/usr/lib/systemd/system/$_target.wants"
    ln -sf "../$_unit" "$tree/usr/lib/systemd/system/$_target.wants/$_unit"
}

case "$role" in
    rootfs)
        install -d -m755 "$tree/usr/share/vngrd/tests"
        install -m644 "$SELF/checks.tsv" "$tree/usr/share/vngrd/tests/checks.tsv"
        want vngrd-selftest.service multi-user.target
        ;;
    initrd)
        want vngrd-testreport-usr.service initrd-root-fs.target
        want vngrd-testreport-root.service initrd-switch-root.target
        ;;
    *)
        echo "install.sh: role must be rootfs or initrd, got '$role'" >&2
        exit 1
        ;;
esac

echo "installed the vngrd test payload into $tree ($role)"
echo "add vngrd.test=1 to the kernel command line and rebuild the UKI/initrd"

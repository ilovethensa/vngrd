# The assembled vngrd rootfs.
#
# A stack: every element below contributes to one tree, and BuildStream rejects
# two elements that install the same path. That overlap check is the reason this
# is a stack rather than a copy loop.
#
# When porting a package, add it here and remove it from
# ../vngrd-rootfs/scripts/01-build.sh's ORDER in the same commit: a package in
# both build systems accumulates two flag sets that drift.
#
# The seed is build-only and is listed by the packages themselves, not here.
kind: stack

depends:
- base.bst
- packages/util-linux-libs.bst
- packages/lvm2.bst
- packages/cryptsetup.bst
- packages/tpm2-tss.bst
- packages/tpm2-tools.bst
- packages/curl.bst
- packages/kmod.bst
- packages/kbd.bst
- packages/systemd.bst
- packages/dbus-broker.bst
- packages/util-linux.bst
- packages/e2fsprogs.bst
- packages/fish.bst
- packages/base-files.bst
# The fixate generator: the volume-key substitution defence the boot gate
# assumes. Its units ship in base-files' payload, and its binaries are their
# own element -- see the note in that element about why the source is vendored.
- packages/fixate-generator.bst
- packages/openssl.bst
- packages/ncurses.bst
- packages/libpam.bst
- packages/libgcc.bst
- packages/ca-certificates.bst
- packages/popt.bst
- packages/coreutils.bst
- packages/expat.bst
- packages/json-c.bst
- packages/libcap.bst
- packages/libseccomp.bst
- packages/libxcrypt.bst
- packages/pcre2.bst
- packages/xz.bst
- packages/zlib.bst
- packages/zstd.bst

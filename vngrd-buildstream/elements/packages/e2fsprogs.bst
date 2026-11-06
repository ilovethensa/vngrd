# e2fsprogs 1.47.4 -- mkfs.ext4 and fsck: systemd-repart execs mkfs.ext4 to
# create the root volume and the first boot fsck's it.
#
# --disable-libblkid is the load-bearing flag and it is the reason this package
# sits after util-linux, not before: e2fsprogs' own blkid would be a second
# implementation of the same probing, so it compiles against the util-linux one
# (lib/support/plausible.c:36) and ships no library of its own.
#
# The prunes after install are vngrd-rootfs's, and each has a reason:
#   usr/libexec        e2fsck.static & friends, an initrd artefact this image
#                      does not build an initrd with
#   e2scrub(_all)      LVM scrubbers, and their cron/udev hooks -- no cron, no
#                      udev rules of ours
#   compile_et, mk_cmds com_err build helpers with #!/bin/sh shebangs
#   *.a, et/ ss/ e2p/ ext2fs/ headers, the *.pc files  static-link cruft: the
#                      image links nothing against e2fsprogs' libs
#   usr/share/info     the manual
kind: autotools

build-depends:
- seed.bst
- base.bst
- packages/util-linux.bst
# util-linux-libs.bst, not just util-linux.bst, because of what the flags below
# mean: --disable-libuuid/--disable-libblkid do not mean "without" -- they mean
# use the EXTERNAL copies, which vngrd-rootfs's ORDER comment spells out
# ("--disable-libblkid, so it uses util-linux's libblkid"). Those external
# copies are packages/util-linux-libs.bst's install: lib/support/plausible.c:36
# compiles against blkid/blkid.h and configure probes for libuuid. When this
# element got them transitively through util-linux.bst's own full `make
# install`, the library prune in that element took them away -- a
# build-dependency is another element's artifact, not its dependencies'.
- packages/util-linux-libs.bst

variables:
  conf-local: >-
    --with-root-prefix=/
    --disable-libuuid
    --disable-libblkid
    --disable-nls
    --disable-uuidd
    --disable-install-chroot
    --disable-backtrace
    --enable-fsck
    --enable-hardening

config:
  install-commands:
  - |
    %{make-install}
    set -eu
    dest=%{install-root}

    rm -rf "$dest/usr/libexec"
    rm -f  "$dest/usr/bin/e2scrub" "$dest/usr/bin/e2scrub_all"
    rm -f  "$dest/usr/lib/systemd/system/e2scrub"*.service \
           "$dest/usr/lib/systemd/system/e2scrub"*.timer
    rm -f  "$dest/usr/lib/udev/rules.d/e2scrub.rules" \
           "$dest/usr/lib/udev/rules.d/ext4.rules"
    rm -f  "$dest/etc/cron.d/e2scrub_all" "$dest/etc/e2scrub.conf"

    rm -f "$dest/usr/bin/compile_et" "$dest/usr/bin/mk_cmds"

    rm -f  "$dest/usr/lib/libcom_err.a" "$dest/usr/lib/libss.a" \
           "$dest/usr/lib/libe2p.a" "$dest/usr/lib/libext2fs.a"
    rm -rf "$dest/usr/include/et" "$dest/usr/include/ss" \
           "$dest/usr/include/e2p" "$dest/usr/include/ext2fs"
    rm -f  "$dest/usr/lib/pkgconfig/com_err.pc" "$dest/usr/lib/pkgconfig/ss.pc" \
           "$dest/usr/lib/pkgconfig/e2p.pc" "$dest/usr/lib/pkgconfig/ext2fs.pc"
    rm -rf "$dest/usr/share/et" "$dest/usr/share/info"

    # Merged /usr, moved rather than asserted-and-failed: e2fsprogs installs
    # some bits under a top-level /sbin and /lib even with the flags above.
    for d in bin sbin lib; do
      if [ -d "$dest/$d" ]; then
        if [ "$d" = lib ]; then t=lib; else t=bin; fi
        mkdir -p "$dest/usr/$t"
        cp -a "$dest/$d/." "$dest/usr/$t/"
        rm -rf "$dest/$d"
      fi
    done
    if [ -d "$dest/usr/local" ]; then
      cp -a "$dest/usr/local/." "$dest/usr/"
      rm -rf "$dest/usr/local"
    fi
    if [ -d "$dest/usr/var" ]; then
      mkdir -p "$dest/var"
      cp -a "$dest/usr/var/." "$dest/var/"
      rm -rf "$dest/usr/var"
    fi
    for d in bin sbin lib lib64; do
      test ! -e "$dest/$d" || {
        echo "e2fsprogs.bst: top-level /$d in the install tree" >&2
        exit 1
      }
    done

    # The two binaries the boot actually uses, asserted because a
    # --disable-feature drift here is invisible until repart fails.
    test -x "$dest/usr/bin/mkfs.ext4" || {
      echo "e2fsprogs.bst: mkfs.ext4 missing (systemd-repart's Format=ext4 needs it)" >&2
      exit 1
    }
    test -x "$dest/usr/bin/fsck.ext4" || {
      echo "e2fsprogs.bst: fsck.ext4 missing" >&2
      exit 1
    }
    # fsck is THIS package's, not util-linux's: it follows util-linux.bst in
    # vngrd-rootfs's ORDER, so the rootfs's cumulative build shipped e2fsprogs'
    # copy, and packages/util-linux.bst now prunes its own. systemd-fsck-root
    # and repart exec fsck.ext4 through it, so the file that survives the
    # prune must be present here.
    test -x "$dest/usr/bin/fsck" || {
      echo "e2fsprogs.bst: fsck missing; it is the shipped one (util-linux prunes its copy)" >&2
      exit 1
    }

sources:
- kind: tar
  url: https://github.com/tytso/e2fsprogs/archive/refs/tags/v1.47.4.tar.gz
  ref: 9f82eaa7002673291629077b80ee005cadfcd49854907a22007fed70b0ef596e

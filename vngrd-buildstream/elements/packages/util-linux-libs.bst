# util-linux's libraries, without its tools: libuuid, libblkid, libmount,
# libsmartcols.
#
# The package exists to break a cycle, and the argument for the split is
# worth restating because BuildStream makes it a dependency edge rather than a
# comment in an ORDER file:
#
#   cryptsetup needs uuid/uuid.h + libuuid.so     (this package)
#   util-linux needs libudev.h                   (systemd's, misc-utils/findmnt.c)
#   systemd needs libcryptsetup.so              (-Dlibcryptsetup=enabled)
#
# vngrd-rootfs built the libraries early out of an emergent ordering; here it
# is simply what cryptsetup.bst and systemd.bst declare. What does not change is
# WHY the libraries can come first: they never touch libudev.
#
# `autotools` with the install reduced to the library, header and pkgconfig
# targets, discovered from the generated Makefile exactly as
# vngrd-rootfs's recipe did -- autotools derives install-<var> per install
# variable, so grepping the names out of the Makefile survives a rename where a
# hard-coded list would not.
kind: autotools

build-depends:
- seed.bst
- base.bst
- packages/libcap.bst

variables:
  conf-local: >-
    --localstatedir=/var
    --runstatedir=/run
    --disable-nls
    --disable-static
    --disable-bash-completion
    --disable-pylibmount
    --disable-werror
    --enable-libuuid
    --enable-libblkid
    --enable-libmount
    --enable-libsmartcols
    --disable-use-tty-group
    --disable-makeinstall-chown
    --disable-makeinstall-setuid
    --disable-makeinstall-tty-setgid

config:
  build-commands:
  - |
    %{configure}
    # Only the libraries: `make all` would build the programs too, and the
    # whole point of the split is that the programs need libudev.h.
    make -j%{max-jobs} %{make-args} libuuid.la libblkid.la libmount.la libsmartcols.la

  install-commands:
  - |
    set -eu
    dest=%{install-root}

    # Discover the install targets rather than hard-coding them, per the
    # vngrd-rootfs recipe's argument (a rename upstream would otherwise be
    # silent here): autotools derives one install-<var> target per install
    # variable, so grepping the names out of the generated Makefile survives a
    # rename where a hard-coded list would fail with "No rule to make target".
    HDR_TARGETS=$(grep -oE '^install-[A-Za-z0-9_]+HEADERS:' Makefile | tr -d ':' | sort -u)
    LIB_TARGETS=$(grep -oE '^install-[A-Za-z0-9_]+LTLIBRARIES:' Makefile | tr -d ':' | sort -u)
    PC_TARGET=$(grep -oE '^install-pkgconfigDATA:' Makefile | tr -d ':' | head -1)

    if [ -z "$HDR_TARGETS" ] || [ -z "$LIB_TARGETS" ]; then
      echo "util-linux-libs.bst: found no header or library install targets." >&2
      echo "  expected install-*HEADERS and install-*LTLIBRARIES in the generated Makefile." >&2
      exit 1
    fi

    # NOTE the absence of the word `install` in front of each target. It is
    # not a mode: `make install DESTDIR=... install-uuidincHEADERS` asks make
    # for the goal `install` AND for the specific target, and the goal
    # installs everything in the tree -- every program, with theirs. That is
    # how this build once tried to compile misc-utils/lsblk-properties.c
    # against a libudev.h that deliberately is not in this sandbox, which is
    # the whole reason this package is separate. vngrd-rootfs's recipe spells
    # the targets bare, and that is not a stylistic choice.
    # shellcheck disable=SC2086
    make DESTDIR="$dest" $HDR_TARGETS
    # shellcheck disable=SC2086
    make DESTDIR="$dest" $LIB_TARGETS
    if [ -n "$PC_TARGET" ]; then
      # shellcheck disable=SC2086
      make DESTDIR="$dest" $PC_TARGET
    fi

    # This package installs NO programs, but the install targets above pull some
    # in: util-linux's libraries live in usrlib_exec_LTLIBRARIES, and automake's
    # exec-class install target carries install-exec-am with it, so every program
    # util-linux builds is installed here and automake's install-exec-hooks run
    # with it. In vngrd-rootfs's cumulative out/ those programs were overwritten
    # by the util-linux build that followed and nobody noticed; here they would
    # collide with it. So they are deleted, and the hooks' operations that need
    # root are switched off at configure time instead.
    #
    # The flags that make the hooks non-fatal are upstream's own, and they matter
    # more than they look: install-exec-hook-wall runs `chgrp tty usr/bin/wall`,
    # and this sandbox has no tty group and no root to chown as -- the install
    # dies at "chgrp: invalid group: 'tty'" with the library half-installed.
    # --disable-makeinstall-chown/-setuid/-tty-setgid are what a non-root
    # installer is supposed to pass anyway, so this is not a workaround for a
    # broken environment but the correct invocation of them.
    for d in usr/bin usr/sbin; do
      if [ -d "$dest/$d" ]; then
        find "$dest/$d" -mindepth 1 -delete
        rmdir "$dest/$d"
      fi
    done

    # The contract with the consumers. cryptsetup's configure probes for
    # uuid/uuid.h and links -luuid; e2fsprogs (built with --disable-libblkid)
    # compiles lib/support/plausible.c against blkid/blkid.h. Missing either
    # fails the next package with a message about a file and no link back here.
    for f in usr/include/uuid/uuid.h usr/include/blkid/blkid.h; do
      test -f "$dest/$f" || {
        echo "util-linux-libs.bst: $f missing from the install." >&2
        exit 1
      }
    done
    test -f "$dest/usr/lib/pkgconfig/uuid.pc" || {
      echo "util-linux-libs.bst: usr/lib/pkgconfig/uuid.pc missing." >&2
      echo "  tpm2-tss and e2fsprogs configure against libuuid via pkg-config." >&2
      exit 1
    }
    for l in libuuid.so libblkid.so libmount.so libsmartcols.so; do
      test -e "$dest/usr/lib/$l" || {
        echo "util-linux-libs.bst: $l missing from the install" >&2
        exit 1
      }
    done

  strip-commands: []

sources:
- kind: tar
  url: https://cdn.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.4.tar.xz
  ref: fbd62a100ab7bb8746ba0661255c3c48185b1e9021507c624da01fbc696330ec

# util-linux 2.42.4 -- the second half of vngrd-rootfs's util-linux split, and
# the packages that need libudev.h from systemd (findmnt is the file that
# cannot compile without it, misc-utils/findmnt.c:36).
#
# The configure is the same run as packages/util-linux-libs.bst, with two
# differences: it happens where systemd.bst has already staged libudev.h, and
# it installs the programs as well as the libraries. Both halves install into
# /usr/bin, /usr/share and /etc, which is why they are separate ELEMENTS rather
# than one element with two passes -- BuildStream's overlap check would refuse
# the second pass over the first.
#
# --disable-nls and --disable-static are vngrd-rootfs's choices and stay: no
# translations ship in the image, and a libblkid that did not come from this
# package (e2fsprogs is configured --disable-libblkid precisely so it uses the
# util-linux one).
kind: autotools

build-depends:
- seed.bst
- base.bst
- packages/libcap.bst
- packages/util-linux-libs.bst
- packages/systemd.bst
# libpam, because --enable-login does not mean "build a login without PAM":
# util-linux's configure refuses the combination with "login selected, but
# required PAM header file not available". vngrd-rootfs's builder sandbox had
# libpam already in its cumulative out/ when util-linux was built (libpam comes
# early in that ORDER), so the recipe never needed to name it. Here the
# dependency is stated, and libpam's own deps are only the seed and libxcrypt,
# so there is no cycle to worry about. The runtime side already exists: the
# image ships libpam and the factory /etc/pam.d/login.
- packages/libpam.bst
# libxcrypt, because sulogin links libcrypt and the seed's Debian copy is the
# wrong one to link. The seed stages /usr/lib/x86_64-linux-gnu/libcrypt.so.1
# (soname libcrypt.so.1, Debian's libxcrypt), and a build that does not name
# the image's own libcrypt links THAT: the link succeeds at build time and
# verify.bst then fails with "usr/bin/sulogin needs libcrypt.so.1, which is
# not in the tree" -- vngrd's libxcrypt is packages/libxcrypt.bst, whose
# header records why the image ships soname .2 rather than .1. Staging it
# here makes configure find /usr/lib/libcrypt.so and the soname the binary
# records is the one the image actually carries.
- packages/libxcrypt.bst

variables:
  # No systemd units, and no libsystemd link: upstream installs
  # fstrim.service, fstrim.timer, uuidd.service and uuidd.socket when it is
  # allowed to, and vngrd ships none of them -- nothing in this image has a use
  # for them (the root is a TPM-sealed partition and /usr is read-only
  # dm-verity), while the initrd build refuses the pair: the units exec
  # binaries the initrd does not seed, and the check that catches it is
  # "a unit execs /usr/bin/fstrim, which is not in the initrd". The same reason
  # vngrd-rootfs's recipe passes both.
  # The login family. util-linux does NOT build login by default:
  # --enable-login is required. This is a porting bug that hid for months --
  # the rootfs recipe builds these, the first port of this element did not
  # carry the flags, and nothing noticed. The shipped tree had nologin,
  # sulogin and wall but no /usr/bin/login, so agetty printed the prompt on
  # ttyS0, exec'd a binary that does not exist, and respawned: every "log in
  # on the console" attempt returned a fresh prompt with no error, which read
  # as "this image has no console login" and is really "the port dropped a
  # configure flag". wall is kept even though the rootfs disables it, because
  # systemd-ask-password-wall.path execs it.
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
    --enable-login
    --enable-nologin
    --enable-sulogin
    --disable-use-tty-group
    --disable-makeinstall-chown
    --disable-makeinstall-setuid
    --disable-makeinstall-tty-setgid
    --without-systemd
    --without-systemdsystemunitdir

config:
  build-commands:
  # The merged-/usr patch, between configure and make, for the same reason
  # vngrd-rootfs put it there: the Makefile that needs editing is generated,
  # so the sed runs after configure exists and before it is read.
  #
  #   usrsbin_execdir -- util-linux hardcodes /usr/sbin here for the nine
  #       usrsbin tools (addpart, delpart, halt, init, ...) no matter what
  #       --sbindir says, which is what put a top-level /usr/sbin in the
  #       image: a merged-usr violation verify.bst fails on, and a tree the
  #       vngrd-rootfs recipe had already fixed the same way.
  #   usrbin_execdir -- asserted rather than assumed, because it is supposed
  #       to already be /usr/bin and the sed must not be what makes it so.
  - |
    set -eu
    # ...and agetty's compiled-in login path, which defaults to /bin/login --
    # a file this image does not have. The rootfs recipe asserted the patch
    # the same way; here the assert stays with the sed that must succeed.
    sed -i 's|# define _PATH_LOGIN[[:space:]]*"/bin/login"|# define _PATH_LOGIN  "/usr/bin/login"|' \
        include/pathnames.h 2>/dev/null || true
    grep -q '_PATH_LOGIN.*"/usr/bin/login"' include/pathnames.h || {
      echo "util-linux.bst: _PATH_LOGIN patch failed; agetty would exec /bin/login" >&2
      exit 1
    }
    sed -i 's|^usrsbin_execdir =.*|usrsbin_execdir = /usr/bin|' Makefile
    sed -i 's|^usrbin_execdir =.*|usrbin_execdir = /usr/bin|' Makefile
    grep -q '^usrbin_execdir = /usr/bin' Makefile || {
      echo "util-linux.bst: usrbin_execdir was not /usr/bin after configure" >&2
      exit 1
    }
  - |
    %{make}

  install-commands:
  - |
    %{make-install}
    set -eu
    dest=%{install-root}
    # Merged /usr, asserted rather than hoped for: these are the binaries the
    # first boot actually runs. fsck used to be in this list and is not any
    # more: the shipped fsck is e2fsprogs' (see the prune below), and an
    # assertion of it here would be asserting a file this element throws away.
    for t in mount umount sulogin findmnt lsblk; do
      test -e "$dest/usr/bin/$t" || {
        echo "util-linux.bst: $t missing from the install" >&2
        exit 1
      }
    done
    for d in bin sbin; do
      test ! -e "$dest/$d" || {
        echo "util-linux.bst: top-level /$d in the install tree" >&2
        exit 1
      }
    done

    # --- the ownership transfers, made explicit -----------------------------
    #
    # vngrd-rootfs resolved all of these by install ORDER: the later package's
    # files silently replaced the earlier package's in the cumulative out/.
    # BuildStream refuses that, which is the point of the fatal overlaps
    # warning, so each override becomes a prune HERE with the reason attached.
    #
    # 1. The libraries belong to packages/util-linux-libs.bst. This element
    #    runs a full `make install`, which lays down lib{blkid,fdisk,mount,
    #    smartcols,uuid} and their headers and .pc files over the same paths
    #    the libraries' own element installs. Same source, different
    #    configure (this one runs where libudev.h exists, so findmnt and
    #    friends come back), so the files are NOT identical -- the overlap is
    #    real, not deduplicable. The programs link against these at build
    #    time through the staged dependency, and the image gets their
    #    runtime copies from the element that owns them. This mirrors the
    #    rootfs split's own asymmetry: the libraries never touch libudev.
    rm -f "$dest"/usr/lib/lib{blkid,fdisk,mount,smartcols,uuid}.so* \
          "$dest"/usr/lib/lib{blkid,fdisk,mount,smartcols,uuid}.la \
          "$dest"/usr/lib/pkgconfig/{blkid,fdisk,mount,smartcols,uuid}.pc
    rm -rf "$dest"/usr/include/{blkid,libfdisk,libmount,libsmartcols,uuid}
    # ...and the assertion that the pruned files are really gone, so an
    # upstream rename that puts the libraries elsewhere fails here rather
    # than in verify.bst's overlap check with no hint of which element won.
    for l in libblkid libfdisk libmount libsmartcols libuuid; do
      test ! -e "$dest/usr/lib/$l.so" || {
        echo "util-linux.bst: /usr/lib/$l.so survived the library prune" >&2
        exit 1
      }
    done
    test ! -e "$dest/usr/include/blkid/blkid.h" || {
      echo "util-linux.bst: blkid/blkid.h survived the library prune" >&2
      exit 1
    }

    # 2. fsck and its man page belong to e2fsprogs, which follows this
    #    package in vngrd-rootfs's ORDER -- e2fsprogs' fsck is the shipped
    #    one, and this element's copy of it is the loser. Pruned rather than
    #    left to lose the overlap sweepstakes.
    rm -f "$dest/usr/bin/fsck" "$dest/usr/share/man/man8/fsck.8"

    # 3. kill and its man page belong to coreutils, which likewise follows
    #    this package. The list stays narrow on purpose: a program that
    #    collides with a LATER package is pruned here, and everything else
    #    util-linux installs is its own.
    rm -f "$dest/usr/bin/kill" "$dest/usr/share/man/man1/kill.1"

sources:
- kind: tar
  url: https://cdn.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.4.tar.xz
  ref: fbd62a100ab7bb8746ba0661255c3c48185b1e9021507c624da01fbc696330ec

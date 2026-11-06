# ncurses 6.5 -- the terminal database, and the C library fish links.
#
# A port of vngrd-rootfs's recipe: --with-shared --with-normal --widec and no
# ada. The one post-install step that is not upstream's is the pair of
# symlinks: ncursesw installs itself under libncursesw*, and fish's cmake
# looks for libncurses, so libncurses.so and libcurses.so point at the wide
# build.
#
# ncursesw6-config is dropped, for vngrd-rootfs's recorded reason: it is a
# development helper with a #!/bin/sh shebang, and this image has no POSIX
# shell to run one (its /usr/bin/sh is fish, which would misparse a shell
# script). Nothing here builds against ncurses. tic and infocmp stay -- fish and
# systemd-localed use them and both are C.
kind: autotools

build-depends:
- seed.bst
- base.bst

variables:
  conf-local: >-
    --mandir=/usr/share/man
    --with-shared
    --with-normal
    --without-debug
    --without-ada
    --enable-widec
    --with-manpage-format=normal
    --enable-pc-files
    --with-pkg-config-libdir=/usr/lib/pkgconfig

config:
  install-commands:
  - |
    %{make-install}
    set -eu
    dest=%{install-root}
    ln -sf libncursesw.so "$dest/usr/lib/libncurses.so"
    ln -sf libncursesw.so "$dest/usr/lib/libcurses.so"
    rm -f "$dest/usr/bin/ncursesw6-config"
    test ! -e "$dest/usr/bin/ncursesw6-config" || {
      echo "ncurses.bst: ncursesw6-config should have been pruned but is present" >&2
      exit 1
    }
    for t in tic infocmp; do
      test -x "$dest/usr/bin/$t" || {
        echo "ncurses.bst: $t missing from the install" >&2
        exit 1
      }
    done

sources:
- kind: tar
  url: https://ftp.gnu.org/gnu/ncurses/ncurses-6.5.tar.gz
  ref: 136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6

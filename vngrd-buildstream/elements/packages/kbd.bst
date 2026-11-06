# kbd 2.10.0 -- loadkeys and friends, the console keymap loader.
#
# --disable-vlock is vngrd-rootfs's flag and stays: vlock is an interactive
# console locker of no use to a headless image. unicode_start and
# unicode_stop are shell wrappers around loadkeys with #!/bin/sh shebangs, and
# this image's /usr/bin/sh is fish, so they are dropped rather than shipped as
# programs whose interpreter is not there. loadkeys is asserted present: it is
# the reason the package exists.
kind: autotools

build-depends:
- seed.bst
- base.bst

variables:
  conf-local: >-
    --datadir=/usr/share
    --sysconfdir=/etc
    --disable-vlock

config:
  install-commands:
  - |
    %{make-install}
    set -eu
    dest=%{install-root}
    for t in unicode_start unicode_stop; do
      rm -f "$dest/usr/bin/$t"
      test ! -e "$dest/usr/bin/$t" || {
        echo "kbd.bst: $t should have been pruned but is present" >&2
        exit 1
      }
    done
    test -x "$dest/usr/bin/loadkeys" || {
      echo "kbd.bst: loadkeys missing from the install" >&2
      exit 1
    }

sources:
- kind: tar
  url: https://cdn.kernel.org/pub/linux/utils/kbd/kbd-2.10.0.tar.xz
  ref: 6e5ca4f8d76ee9e3a8db700b667f13e12aac9933828a64e1aaad93d26be9b479

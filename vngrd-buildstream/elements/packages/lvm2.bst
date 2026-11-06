# LVM2's device-mapper library -- libdevmapper and its headers, which
# cryptsetup links (-Dlibcryptsetup=enabled).
#
# The package, not the tools: vngrd-rootfs's recipe built libdm.device-mapper
# and installed it plus libdm's headers, and the tools are absent from the
# image. This element is the same, and LVM2 has no "libraries only" configure
# toggle, so it is expressed in the make targets (libdm.device-mapper) rather
# than a flag.
#
# CC=gcc, LD=ld.bfd: vngrd-rootfs's recipe used exactly that, and it is the one
# other package besides glibc allowed to (a gcc-driven build), which is worth
# stating here so a future editor does not "fix" it to clang without noticing
# that the recipe's quiet acceptance of gcc was a decision. The pkg-config
# alias (devmapper.pc -> libdevmapper.pc) is for libcryptsetup's
# Requires.private: devmapper, spelled without the lib.
kind: manual

build-depends:
- seed.bst
- base.bst

environment:
  CC: gcc
  CXX: g++
  LD: ld.bfd
  # LDFLAGS restated rather than inherited, and the project's is deliberately
  # not used: it carries -fuse-ld=lld, and lld cannot link LVM2's version
  # script. The build fails with
  #
  #     ld.lld: error: version script assignment of 'Base' to symbol
  #       'dm_udev_create_cookie' failed: symbol not defined
  #
  # which is lld refusing the script's wildcard version listing, not a
  # vngrd bug -- GNU ld accepts it. This is the other reason vngrd-rootfs's
  # recipe named LD=ld.bfd for this package: lld is the project default, but
  # the version script is upstream's contract and it is ld.bfd that honours
  # it. -Wl,--dynamic-linker and -L/usr/lib are kept, because those are the
  # merged-/usr invariants rather than a linker choice.
  LDFLAGS: -Wl,-O1 -Wl,--as-needed -L/usr/lib -Wl,--dynamic-linker=/usr/lib/ld-linux-x86-64.so.2

config:
  build-commands:
  - |
    set -eu
    ./configure \
        --prefix=/usr \
        --libdir=/usr/lib \
        --sbindir=/usr/bin \
        --bindir=/usr/bin \
        --with-usrlibdir=/usr/lib \
        --enable-device-mapper \
        --disable-selinux \
        --disable-udev \
        --disable-lvm2app \
        --disable-cmdlib \
        --disable-dmeventd \
        --disable-lvmetad \
        --disable-lvmpolld \
        --with-thin=internal \
        --enable-thin_check_needs_check \
        --enable-cache_check_needs_check
    make CC=gcc LD=ld.bfd \
        -j"$(nproc)" libdm.device-mapper

  install-commands:
  - |
    set -eu
    dest=%{install-root}
    make DESTDIR="$dest" CC=gcc LD=ld.bfd \
        -C libdm install
    make DESTDIR="$dest" -C libdm install_include 2>/dev/null || true
    if [ -f libdm/libdevmapper.pc ]; then
      mkdir -p "$dest/usr/lib/pkgconfig"
      cp -a libdm/libdevmapper.pc "$dest/usr/lib/pkgconfig/"
      ln -sf libdevmapper.pc "$dest/usr/lib/pkgconfig/devmapper.pc"
    fi
    if [ -d "$dest/sbin" ]; then
      mkdir -p "$dest/usr/bin"
      mv "$dest/sbin"/* "$dest/usr/bin/" 2>/dev/null || true
      rmdir "$dest/sbin"
    fi
    test -f "$dest/usr/lib/libdevmapper.so.1.02" || {
      echo "lvm2.bst: libdevmapper.so missing from the install" >&2
      echo "  cryptsetup links it for -Dlibcryptsetup=enabled." >&2
      exit 1
    }
    test -f "$dest/usr/include/libdevmapper.h" || {
      echo "lvm2.bst: libdevmapper.h missing from the install" >&2
      exit 1
    }

  strip-commands: []

sources:
- kind: tar
  url: https://sourceware.org/pub/lvm2/LVM2.2.03.28.tgz
  ref: b822baff6b62df36382c717ceba98a2688ebb31bf2b768f3ffa2b6d5e2557242

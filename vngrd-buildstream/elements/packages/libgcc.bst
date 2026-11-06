# libgcc_s.so.1 -- the shared unwinder, for fish (the image's only C++ and only
# Rust binary).
#
# A COPY, not a build, exactly as vngrd-rootfs's libgcc package was: the file
# comes out of the compiler's runtime, and there is no compiler in the image to
# build it with. Which compiler is the whole point of the port -- it is now the
# seed's gcc 12 (Debian bookworm, the one packages/glibc.bst was bootstrapped
# with), not a host's, and it is fetched from the seed tree rather than from a
# builder image's filesystem.
#
# The address is /usr/lib/x86_64-linux-gnu/libgcc_s.so.1, where Debian keeps
# it and where the seed's staged tree has it. It lands at /usr/lib in the image
# because that is where vngrd's merged-/usr tree puts every library.
#
# The assertions are vngrd-rootfs's, and they matter more now than before: this
# is the one element in the project whose output is not compiled, so a
# mis-resolved path would otherwise be caught only by an unresolvable
# DT_NEEDED in verify.bst -- ten packages and a full build later.
kind: manual

build-depends:
- seed.bst

config:
  build-commands: []

  install-commands:
  - |
    set -eu
    dest=%{install-root}
    src=/usr/lib/x86_64-linux-gnu/libgcc_s.so.1

    test -e "$src" || {
      echo "libgcc.bst: $src not present in the seed" >&2
      echo "  export-seed.sh copies gcc's runtime; check that gcc-12 is still" >&2
      echo "  in vngrd-rootfs/docker/Dockerfile.builder." >&2
      exit 1
    }

    mkdir -p "$dest/usr/lib"
    install -m 0755 "$src" "$dest/usr/lib/libgcc_s.so.1"

    test -e "$dest/usr/lib/libgcc_s.so.1" || {
      echo "libgcc.bst: libgcc_s.so.1 missing after install" >&2
      exit 1
    }
    test ! -L "$dest/usr/lib/libgcc_s.so.1" || {
      echo "libgcc.bst: installed a symlink, not a file" >&2
      exit 1
    }
    readelf -h "$dest/usr/lib/libgcc_s.so.1" 2>/dev/null | grep -q DYN || {
      echo "libgcc.bst: libgcc_s.so.1 is not a shared object (no DYN header)" >&2
      exit 1
    }

  strip-commands: []

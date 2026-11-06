# zstd 1.5.7 -- liblzma's sibling in the compression row of runtime-keep: the
# library plus `zstd`, `zstdcat`, `unzstd`, `zstdmt` (installed by
# programs/Makefile as symlinks to the one binary) and `pzstd`.
#
# The Makefile path, not Arch's: vngrd-rootfs's recipe is `make PREFIX=/usr`,
# and Arch builds the same tarball through build/cmake with zlib, lzma and lz4
# support and ZSTD_BUILD_CONTRIB. Following the recipe keeps this element a
# port rather than a re-decision -- the one concession is installing pzstd
# explicitly, because the top-level `install` target recurses only into lib and
# programs and leaves contrib out, while the keep list has always carried
# /usr/bin/pzstd from Arch's build.
kind: make

build-depends:
- seed.bst
- base.bst

variables:
  # project.conf's make-args carries prefix/libdir/bindir/SHELL and the
  # toolchain names; zstd spells its prefix PREFIX and derives BINDIR,
  # LIBDIR and MANDIR from it, so this is the one thing make-local adds.
  make-local: PREFIX=/usr

  # zstdgrep and zstdless go, as in vngrd-rootfs's recipe: they are pipes
  # around zgrep and zless, neither of which this image carries (see xz for
  # the same argument), so keeping them would ship a program whose first
  # command fails.
  make-install: |
    make -j1 %{make-install-args}
    rm -f "%{install-root}/usr/bin/zstdgrep" "%{install-root}/usr/bin/zstdless"
    for t in zstd zstdcat unzstd zstdmt; do
      test -e "%{install-root}/usr/bin/$t" || {
        echo "zstd: $t missing from the install" >&2; exit 1; }
    done
    for gone in zstdgrep zstdless; do
      test ! -e "%{install-root}/usr/bin/$gone" || {
        echo "zstd: $gone should have been pruned but is present" >&2; exit 1; }
    done

sources:
- kind: tar
  url: https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
  ref: eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3

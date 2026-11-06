# libxcrypt 4.5.2 -- libcrypt for the image (glibc 2.44 no longer provides it).
#
# --enable-hashes=all is the KISS setting: every crypt() scheme, not just the
# defaults, so older /etc/shadow hashes keep verifying.
#
# --enable-obsolete-api=no is not optional here, it is the ABI of the base:
# the option defaults to `yes`, which installs libcrypt.so.1 (the glibc-legacy
# soname, plus the bigcrypt/fcrypt/encrypt/setkey entry points), while base is
# the Arch libxcrypt built with `no`, i.e. libcrypt.so.2:
#
#     configure.ac:364: "When set to \"no\" ... change the soname of the
#                        installed library to libcrypt.so.2. [default=yes]"
#     Arch PKGBUILD: --enable-hashes=strong,glibc --enable-obsolete-api=no
#
# Without it the port ships .so.1 next to base's .so.2, so the keep rule for
# libcrypt cannot be dropped at all (the two trees install different files
# under the same names) and every crypt() consumer picks its soname from
# whichever side of the split it was linked against. With it the package
# replaces base's libcrypt file-for-file and the trim is exact. The obsolete
# entry points are gone either way -- `no` only changes which *existing*
# binaries can still be satisfied (configure.ac, same paragraph), and new
# programs cannot link them at all.
#
# The one leaf package that needs its own compile flags. libxcrypt's
# configure adds -Werror when it thinks it has a GCC-compatible compiler, and
# clang is stricter about discarding qualifiers than the code is clean for:
#
#     export CFLAGS="$CFLAGS -Wno-error -Wno-error=incompatible-pointer-types-discards-qualifiers"
#
# passed as `CFLAGS=...` on the configure line rather than in the environment,
# because a configure *argument* is per-element while `environment:` is
# project-wide. It restates `%{cflags}` for the same reason -- a bare
# `CFLAGS=-Wno-error` would replace the optimisation flags, not add to them.
kind: autotools

build-depends:
- seed.bst
- base.bst

variables:
  conf-local: >-
    --enable-hashes=all
    --enable-obsolete-api=no
    CFLAGS="%{cflags} -Wno-error -Wno-error=incompatible-pointer-types-discards-qualifiers"

sources:
- kind: tar
  url: https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz
  ref: 71513a31c01a428bccd5367a32fd95f115d6dac50fb5b60c779d5c7942aec071

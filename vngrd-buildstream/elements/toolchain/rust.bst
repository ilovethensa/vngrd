# The Rust toolchain: cargo and rustc for fish, and nothing else.
#
# This is the second prebuilt input after elements/seed.bst, and the same
# argument applies: a compiler cannot compile itself from nothing. fish 4.x is
# written in Rust, and its cmake build calls `find_package(Rust REQUIRED)`
# unconditionally (cmake/Rust.cmake, before anything else in CMakeLists.txt),
# so packages/fish.bst cannot even configure without a cargo on PATH. The seed
# carries clang, LLVM, lld and a gcc for the glibc bootstrap -- and nothing
# else, because everything above the seed is supposed to be source-built.
#
# Regenerate with scripts/export-rust.sh out of the vngrd-builder image, whose
# toolchain the export pins by digest. The tree is NOT committed, for the same
# reason the seed is not: it is 500+ MB of upstream binaries, reproducibly
# regenerable, and no element lists it at runtime, so none of it reaches
# rootfs.bst. The exported binaries are the ones that built fish for
# vngrd-rootfs, so what ships here is what was already measured.
#
# Layout, and it is not arbitrary. The toolchain arrives from rustup as
# <toolchain>/bin/{cargo,rustc} + <toolchain>/lib/{libLLVM*,librustc_driver*}
# + <toolchain>/lib/rustlib/<target>/, and both binaries carry
# RUNPATH=$ORIGIN/../lib. rustc finds its sysroot the same relative way
# (<exe>/../lib/rustlib). The export keeps that shape under /usr/lib/rust with
# /usr/bin/{cargo,rustc} as symlinks into it: $ORIGIN follows /proc/self/exe,
# not the symlink, so the relative paths still resolve. The real binaries at
# /usr/bin instead would point their RUNPATH at vngrd's /usr/lib, where glibc
# lives -- the one directory the seed's binaries must never be told to search.
#
# Both binaries' PT_INTERP is /lib64/ld-linux-x86-64.so.2 and their
# DT_NEEDED closure is Debian's multiarch libc, all of which the seed already
# stages, so they run in any sandbox the seed is staged in -- which is every
# build sandbox. That is why this element depends on the seed and why fish's
# build-depends names both.
kind: import

sources:
- kind: local
  path: elements/toolchain/rust

build-depends:
- seed.bst

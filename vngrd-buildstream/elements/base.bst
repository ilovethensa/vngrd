# The vngrd libc base: the kernel headers and the C library, built here.
#
# A stack, because exactly these two artifacts are what every package in the
# project compiles against -- glibc's headers and crt objects, its loader at
# /usr/lib/ld-linux-x86-64.so.2, and the kernel's /usr/include/{linux,asm}.
# One element names that pair so a package writes `build-depends: [base.bst]`
# and means "the sysroot", the way it meant base.bst when this was an import
# of somebody else's tree.
#
# Nothing else is in here, and that is the point: the toolchain that compiles
# against this base is elements/seed.bst, a build-only dependency that no
# element lists at runtime. The image contains what this stack builds and what
# the packages build, and nothing the seed brought in.
#
# The ordering constraint: glibc.bst needs the kernel headers staged at
# /usr/include when it builds, and linux-headers.bst's artifact is only
# /usr/include/{linux,asm-generic,asm} -- disjoint from glibc's own
# /usr/include/{bits,gnu,sys,...}, so staging both here is not an overlap.
kind: stack

depends:
- packages/linux-headers.bst
- packages/glibc.bst

# libseccomp 2.6.1 -- a plain autotools package, and the shape the other leaf packages
# can copy: kind, build-depends, sources.
#
# The release tarball ships a pregenerated configure and pregenerated syscall
# tables, so nothing here needs python or autotools on the host. --disable-static
# comes from project.conf's conf-global; shared is the default.
#
# The KISS build's /out ld-linux symlink hack is not needed: this sandbox
# stages base.bst at /, so /usr/lib/ld-linux-x86-64.so.2 already exists.
kind: autotools

build-depends:
- seed.bst
- base.bst

sources:
- kind: tar
  url: https://github.com/seccomp/libseccomp/releases/download/v2.6.1/libseccomp-2.6.1.tar.gz
  ref: 501f66c667225d53791b97e1d7cf85ab764c297d04881f60f38f451c4b0ee1be

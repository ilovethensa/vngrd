# libcap 2.78 -- the first `make` kind, hence the first user of
# project.conf's `make-local` hook.
#
# libcap has no configure script; its Make.Rules computes everything from
# `prefix` and `lib` (default `lib=lib64` on x86-64, which is wrong here), and
# the build only honours capitalised names for the install dirs. PAM_CAP=no
# because no libpam headers are available yet, and
# GOLANG=no because nothing here needs the Go bindings.
#
# RAISE_SETFCAP=no rides on install: without it `make install` tries to raise
# the setcap bits on its own tools, which a bwrap sandbox cannot do.
kind: make

build-depends:
- seed.bst
- base.bst

variables:
  make-local: >-
    lib=lib
    SBINDIR=/usr/bin
    PAM_CAP=no
    GOLANG=no
    RAISE_SETFCAP=no

sources:
- kind: tar
  url: https://cdn.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-2.78.tar.xz
  ref: 0d621e562fd932ccf67b9660fb018e468a683d7b827541df27813228c996bb11

# expat 2.8.5 -- XML parser; nothing in the image links it yet, it lands here
# because its `depends` file is glibc only and it is a leaf.
#
# --without-docbook: the docs build wants xsltproc, which is not in the base.
# --without-tests: the test suite is built but never run by this element, and
# the tests want more of the world than the base provides.
kind: autotools

build-depends:
- seed.bst
- base.bst

variables:
  conf-local: >-
    --without-docbook
    --without-tests

sources:
- kind: tar
  url: https://github.com/libexpat/libexpat/releases/download/R_2_8_5/expat-2.8.5.tar.gz
  ref: 920dde485e15eda0cce8d2310b41d492c534e5e3d89ad407a0b4176dd2ff88fe

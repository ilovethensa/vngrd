# json-c 0.19 -- JSON parser used by systemd, cryptsetup and lvm2 in the later
# stages; like pcre2 it is here because `depends` says glibc only.
#
# cmake is the only build system upstream ships (no autotools fallback, no
# meson), so this is the project's first `kind: cmake` -- and therefore the
# first element to exercise project.conf's cmake block, which had never run a
# build. BUILD_SHARED_LIBS=ON is the whole element: vngrd-rootfs passes the
# same one flag, and a static json-c would be a second copy of the same code
# for no consumer.
kind: cmake

build-depends:
- seed.bst
- base.bst

variables:
  cmake-local: >-
    -DBUILD_SHARED_LIBS=ON

sources:
- kind: tar
  url: https://s3.amazonaws.com/json-c_releases/releases/json-c-0.19.tar.gz
  ref: 37ad0249902e301bd9052bf712e511fcc6acff4ecaad4b5900aad9ce564e26de

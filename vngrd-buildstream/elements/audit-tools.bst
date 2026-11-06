# The tools the rootfs audit runs: sh, find, grep, sed, head, ls, readlink,
# llvm-readelf.
#
# A filter over seed.bst rather than base.bst as before, because the auditor
# must not be part of what it audits: elements/verify.bst stages this beside
# the assembled rootfs, and a rootfs that contains coreutils' own
# /usr/bin/find would collide with the seed's copy. Selecting the audit
# domain from the seed keeps the collision impossible by construction.
#
# The whole multiarch library dir is included with them, because that is where
# these tools' own libraries are (Debian grep/sed/find link libselinux and
# libpcre2; llvm-readelf links libLLVM).
kind: filter

build-depends:
- seed.bst

config:
  include:
  - audit
  include-orphans: false

# Invariant checks over the assembled rootfs.
#
# The checks live in scripts/verify-rootfs.sh so they can be run directly
# against any artifact checkout (`./scripts/verify-rootfs.sh /tmp/rfs`) and
# linted like any other shell. This element only arranges the sandbox:
#
#   * the rootfs is staged at /staged -- what would ship, nothing else;
#   * elements/audit-tools.bst is staged at / to supply sh, find, grep, sed,
#     head, ls, readlink and llvm-readelf. It is a filter over the seed rather
#     than the seed itself: the auditor is not part of what it audits, and a
#     rootfs that ships coreutils' own find and grep would collide with the
#     seed's copies;
#   * the script arrives via elements/auditor.bst (a script element may not
#     declare sources), staged at / beside the tools -- one file, no overlap;
#   * the script fails on a tree with no populated /usr/bin and on zero ELF
#     files: an earlier version checked its own empty install tree and passed
#     vacuously with "ELF files inspected: 0".
kind: script

build-depends:
- audit-tools.bst
- auditor.bst
- filename: rootfs.bst
  config:
    location: /staged

config:
  root-read-only: true

  commands:
  - READELF=/usr/bin/llvm-readelf sh /verify-rootfs.sh /staged

# The verifier's own tool, imported as a one-file element.
#
# scripts/verify-rootfs.sh does the actual checking and is runnable standalone:
#
#     ./scripts/verify-rootfs.sh /path/to/a/rootfs-checkout
#
# This element only carries it into the sandbox. verify.bst stages it at /
# next to base.bst -- one file, no overlap with the base tree -- because a
# script element may not declare sources of its own.
kind: import

sources:
- kind: local
  path: scripts/verify-rootfs.sh

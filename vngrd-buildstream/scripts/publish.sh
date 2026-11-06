#!/bin/sh
# publish.sh — publish the BuildStream rootfs artifact to ../output/rootfs.
#
# What this replaces and why it looks the way it does: vngrd-rootfs's
# publish.sh published a cumulative out/ tree, and this one publishes an
# immutable artifact instead. The destination is the SAME path mkosi already
# reads (vngrd-image: BaseTrees=../output/rootfs ../output/kernel), so nothing
# downstream changes — only which producer owns the tree does. vngrd-rootfs is
# still the kernel's and the seed's producer; this script is the rootfs's.
#
# The two steps, and neither is optional:
#
#   1. `bst build rootfs.bst verify.bst` first, always. A publish must not be
#      able to ship an element that verify.bst has never passed: the artifact
#      is content-addressed, so the second run is a cache hit and costs
#      seconds, and the one case where it does work is exactly the case where
#      the tree changed. The alternative — checking out whatever happens to be
#      cached — is how a stale or half-fixed tree reaches the image.
#   2. checkout, then exclude, then guard. The exclusions are vngrd-rootfs
#      publish.sh's, for the same reasons: var/db/Makefile is glibc's locale
#      helper, regenerated at runtime, and etc/credstore* are the runtime
#      state provisioning creates. An artifact carries them because the
#      packages install them; the image must not, because they would ship as
#      empty directories that then get written at boot.
#
# The hermetic-layout and merged-/usr guards are ported from the same script,
# because publish is the boundary where a tree becomes image content —
# verify.bst already enforces the first set on the assembled rootfs, but this
# is the last moment the tree and its provenance are together, and a guard
# here names the failure while the artifact is still in hand.
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/../output"
OUTPUT="$OUT/rootfs"
STAGING="$OUT/.rootfs-staging"

BST=${BST:-bst}

# --- the build, so the artifact exists and is verified ----------------------
echo "==> bst build rootfs.bst verify.bst"
"$BST" build rootfs.bst verify.bst

# --- checkout into staging, never into place --------------------------------
# Checked out to a sibling of the destination (same filesystem) so the final
# step is a rename: a reader — mkosi, a test harness — either sees the old
# tree or the new one, never a half-copied one. bst itself checks the artifact
# out; the exclusions are applied here because they are a fact about the
# image, not about the artifact.
rm -rf "$STAGING"
mkdir -p "$STAGING"
"$BST" artifact checkout rootfs.bst --directory "$STAGING"

echo "==> excluding runtime state and build helpers"
rm -rf "$STAGING/var/db" \
       "$STAGING/etc/credstore" \
       "$STAGING/etc/credstore.encrypted"

mkdir -p "$OUTPUT"
# Replace by directory swap rather than tar-piping into place: the staging
# tree is already the filtered tree.
rm -rf "$OUTPUT.old"
[ ! -e "$OUTPUT" ] || mv "$OUTPUT" "$OUTPUT.old"
mv "$STAGING" "$OUTPUT"
rm -rf "$OUTPUT.old"

# --- hermetic layout guard (AGENTS.md) ---------------------------------------
# The published tree is layered into the image verbatim via mkosi BaseTrees=
# and mkosi.finalize hard-fails on legacy top-level dirs. Catch violations
# here, at the source, while the artifact that produced them is identifiable.
for d in bin sbin lib lib64; do
    [ -e "$OUTPUT/$d" ] || [ -L "$OUTPUT/$d" ] || continue
    if [ "$d" = lib ] && [ -d "$OUTPUT/lib/modules" ]; then continue; fi  # kernel modules
    echo "ERROR: $OUTPUT/$d violates the hermetic layout — no top-level /bin, /sbin, /lib, /lib64 (AGENTS.md)" >&2
    exit 1
done
# /usr must contain only bin, include, lib, share (catches dotfiles too)
strays="$(find "$OUTPUT/usr" -mindepth 1 -maxdepth 1 \
    ! -name bin ! -name include ! -name lib ! -name share \
    -printf '%f\n' 2>/dev/null || true)"
if [ -n "$strays" ]; then
    echo "ERROR: forbidden entries under /usr (only bin, include, lib, share allowed) — AGENTS.md:" >&2
    echo "$strays" | sed 's/^/  usr\//' >&2
    exit 1
fi

# --- merged /usr reference check (no duct-tape) ------------------------------
# Units and scripts must not reference /bin, /sbin, /lib outside /usr (AGENTS.md).
# The element must be fixed, not publish.sh: systemd's units carry the same
# patches packages/systemd.bst applies (the agetty path and the /sbin rewrite),
# so a failure here means an element regressed.
bad_refs="$(grep -r --exclude-dir=credstore --exclude-dir=credstore.encrypted -l '"/\(bin\|sbin\|lib\)/' "$OUTPUT" 2>/dev/null | grep -E '\.(service|socket|target|mount|conf|sh|py)$' | head -n 20 || true)"
hard_bad="$(grep -R -n 'ExecStart=.*/sbin/\(agetty\|modprobe\|ldconfig\)' "$OUTPUT" 2>/dev/null | head -n 20 || true)"
hard_bad2="$(grep -R -n '"/sbin/\|"/bin/\| /sbin/\| /bin/' "$OUTPUT/usr/lib/systemd" 2>/dev/null | grep -v '/usr/bin' | grep -v '/usr/lib' | head -n 20 || true)"
if [ -n "$hard_bad" ] || [ -n "$hard_bad2" ]; then
    echo "ERROR: found references to /sbin or /bin outside /usr (the element must fix, not publish.sh):" >&2
    echo "$hard_bad" >&2
    echo "$hard_bad2" >&2
    echo "hint: the same patching packages/systemd.bst does for /sbin/agetty regressed" >&2
    exit 1
fi

echo "Published $ROOT rootfs.bst artifact -> $OUTPUT (hermetic layout verified)"
du -sh "$OUTPUT" | sed 's/^/  size: /'
printf '  binaries: %s\n' "$(find "$OUTPUT/usr/bin" -maxdepth 1 -type f -o -maxdepth 1 -type l | wc -l)"

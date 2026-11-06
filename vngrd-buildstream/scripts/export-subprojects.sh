#!/bin/sh
# export-subprojects.sh -- vendor dbus-broker's c-util git subprojects.
#
# Why this exists beside export-vendor.sh: dbus-broker's meson.build resolves
# seven dependencies (libcdvar, libcini, libclist, libcrbtree, libcshquote,
# libcstdaux, libcutf8) whose only upstream source is a wrap-git into
# github.com/c-util, and BuildStream builds under bwrap --unshare-net, so
# meson cannot fetch them. vngrd-rootfs solved the same wall by allowing
# network for the wrapper downloads; here the wrap-named directories are
# pre-cloned and staged beside the wraps, and meson's --wrap-mode=nodownload
# uses what is on disk. Nothing is downloaded at build time, and the pins are
# read from the wraps rather than restated here, so a dbus-broker bump that
# moves a tag moves the vendored tree with it.
#
# The clones carry no .git: the build needs the tree at one revision, not the
# history, and meson reads no git state for a directory it finds present.
#
# Usage: scripts/export-subprojects.sh [dest-dir]
#        # default: elements/packages/dbus-broker/files/subprojects
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST=${1:-elements/packages/dbus-broker/files/subprojects}
ELEMENT="$ROOT/elements/packages/dbus-broker.bst"

if [ -e "$DEST" ]; then
    echo "$0: $DEST already exists; remove it first" >&2
    exit 1
fi
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)

[ -z "${DEST##"$ROOT"/*}" ] || {
    echo "$0: $DEST is not inside $ROOT" >&2
    exit 1
}

# The tarball URL and ref come from the element itself -- one source of truth,
# the same way export-vendor.sh reads fish's.
url=$(sed -n 's|^ *url: \(https://github.com/bus1/dbus-broker/archive/[^ ]*\)$|\1|p' "$ELEMENT" | head -1)
ref=$(sed -n 's/^ *ref: \([0-9a-f]\{64\}\)$/\1/p' "$ELEMENT" | head -1)
[ -n "$url" ] && [ -n "$ref" ] || {
    echo "$0: could not read url/ref from $ELEMENT" >&2
    exit 1
}

echo "==> vendoring dbus-broker's subprojects from $url"
echo "    ref: $ref"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$work"
curl -fsSL "$url" -o dbus-broker.tar.gz
echo "$ref  dbus-broker.tar.gz" | sha256sum -c -
tar -xzf dbus-broker.tar.gz
srcdir=$(find . -maxdepth 1 -type d -name 'dbus-broker-*' | head -1)
[ -d "$srcdir/subprojects" ] || {
    echo "$0: the tarball has no subprojects/ directory" >&2
    exit 1
}

# One wrap-git per subproject. The directory name meson looks for is the wrap
# file's basename minus .wrap, and url+revision are the pin.
exported=0
for wrap in "$srcdir"/subprojects/*.wrap; do
    name=$(basename "$wrap" .wrap)
    wurl=$(sed -n 's/^url = //p' "$wrap")
    wrev=$(sed -n 's/^revision = //p' "$wrap")
    [ -n "$wurl" ] && [ -n "$wrev" ] || {
        echo "$0: $wrap has no url/revision pair" >&2
        exit 1
    }

    echo "    $name <- $wurl @ $wrev"
    git clone -q --depth 1 --branch "$wrev" "$wurl" "$work/$name"
    git -C "$work/$name" checkout -q "$wrev"

    # The exact commit the tag points at, recorded so the tree's identity is
    # the object hash and not a branch name that can move.
    commit=$(git -C "$work/$name" rev-parse HEAD)

    rm -rf "$work/$name/.git"
    cp -a "$work/$name" "$DEST/$name"

    exported=$((exported + 1))
    printf '%s %s %s\n' "$name" "$wrev" "$commit" >> "$work/provenance.txt"
done

[ "$exported" -gt 0 ] || {
    echo "$0: no wrap-git files found in subprojects/" >&2
    exit 1
}

# Provenance beside the crates, the way the seed and the vendor tree record
# theirs.
{
    echo "# Produced by scripts/export-subprojects.sh -- dbus-broker's"
    echo "# c-util subprojects, vendored because the sandbox has no network."
    echo "# Regenerate: ./scripts/export-subprojects.sh (after removing the old tree)"
    echo "dbus-broker-tarball: $url"
    echo "dbus-broker-ref: $ref"
    echo "exported: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "subprojects (name tag commit):"
    sed 's/^/  /' "$work/provenance.txt"
} > "$DEST/SUBPROJECTS-SOURCE"
chmod 644 "$DEST/SUBPROJECTS-SOURCE"

echo "==> done: $DEST"
du -sh "$DEST" | sed 's/^/  size: /'
echo "    subprojects: $exported"

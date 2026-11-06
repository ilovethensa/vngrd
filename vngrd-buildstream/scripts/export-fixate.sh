#!/bin/sh
# export-fixate.sh -- copy ../vngrd-fixate-generator's sources into
# elements/packages/fixate-generator/source.
#
# Why a copy and not a source pointing at the sibling repo: BuildStream refuses
# a `..` component in a local source path ("first component must not be '..'"),
# so an element cannot read a directory outside the project. The alternative
# was a second copy of the repository to keep in step by hand; this script is
# that copy, made honestly -- one command, run after editing the generator, and
# the element's cache key moves so the rootfs rebuilds with it.
#
# What is copied, and what is not: the C sources, the headers, the Makefile and
# the tidy config. NOT build/ (its objects are from whenever the repository was
# last built by hand, and a make(1) that finds them newer than the sources would
# install them without compiling anything) and not .git (the generator is
# versioned by its own repository, and staging history into a build sandbox is
# nothing but weight).
set -eu

cd "$(dirname "$0")/.."
SRC=../vngrd-fixate-generator
DEST=elements/packages/fixate-generator/source

[ -f "$SRC/Makefile" ] && [ -d "$SRC/src" ] && [ -d "$SRC/include" ] || {
    echo "$0: $SRC is not the vngrd-fixate-generator checkout" >&2
    exit 1
}

rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$SRC/Makefile" "$SRC/.clang-tidy" "$DEST/" 2>/dev/null || true
cp -a "$SRC/src" "$SRC/include" "$DEST/"

# Provenance: which revision of the generator this is, recorded where the
# other generated trees record theirs.
rev=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo "  (unknown)")
{
    echo "# Copied by scripts/export-fixate.sh from ../vngrd-fixate-generator."
    echo "# Regenerate: ./scripts/export-fixate.sh"
    echo "source-repo: ../vngrd-fixate-generator"
    echo "source-rev: $rev"
    echo "exported: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DEST/SOURCE"

echo "==> copied $SRC -> $DEST ($(du -sh "$DEST" | cut -f1))"
echo "    source-rev: $rev"

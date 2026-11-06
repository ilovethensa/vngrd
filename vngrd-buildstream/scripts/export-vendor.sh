#!/bin/sh
# export-vendor.sh -- vendor fish's Rust crates, because the build sandbox has
# no network.
#
# Why this exists beside export-rust.sh: packages/fish.bst's cmake build calls
# `cargo build` as an ALL target, and BuildStream runs its builds under bwrap
# --unshare-net. cargo therefore cannot fetch crates.io or fish's three git
# dependencies (fluent-rs, fluent-ftl-tools, rust-pcre2). `cargo vendor` over
# the tarball's own Cargo.lock produces the tree once, on a machine that does
# have network, and the element then points cargo at it with a source
# replacement config (see packages/fish.bst's configure step, which appends
# cargo's own printed block to the tarball's .cargo/config.toml).
#
# The lockfile pins the versions; the vendor tree is the checksummed contents
# of those exact packages. Both come from upstream, neither is hand-written,
# so the tree is regenerable rather than committed: it is ~165 MB, 174 crates,
# and the element that consumes it asserts its shape before cargo runs.
#
# What the script verifies, because a vendor tree that does not match the lock
# is a silently different build:
#   * the tarball is pinned by the same sha256 ref as packages/fish.bst reads
#     (the URL and ref are PARSED FROM the element, so they cannot drift);
#   * cargo vendor runs with --locked, so it fails rather than re-resolves if
#     the lock does not match the manifests;
#   * the tree lands with cargo's per-crate .cargo-checksum.json files, which
#     fish.bst asserts at build time.
#
# It does NOT regenerate elements/toolchain/rust: that is export-rust.sh, and
# this script merely needs its cargo to exist (the toolchain pins the compiler
# that produces the build).
#
# Usage: scripts/export-vendor.sh [dest-dir]
#        # default: elements/packages/fish/files/vendor
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST=${1:-elements/packages/fish/files/vendor}
FISH_ELEMENT="$ROOT/elements/packages/fish.bst"

# Refuse to write into an existing tree: a partial export from a previous run
# would silently mix two crates.io snapshots. Both export scripts refuse the
# same way.
[ -e "$DEST" ] && {
    echo "$0: $DEST already exists; remove it first" >&2
    exit 1
}
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)

[ -z "${DEST##"$ROOT"/*}" ] || {
    echo "$0: $DEST is not inside $ROOT" >&2
    exit 1
}

# The tarball URL and ref come from the element itself. One source of truth:
# bump the version in fish.bst and this script follows it.
url=$(sed -n 's|^ *url: \(https://github.com/fish-shell/fish-shell/releases/download/[^ ]*\)$|\1|p' "$FISH_ELEMENT" | head -1)
ref=$(sed -n 's/^ *ref: \([0-9a-f]\{64\}\)$/\1/p' "$FISH_ELEMENT" | head -1)
[ -n "$url" ] && [ -n "$ref" ] || {
    echo "$0: could not read url/ref from $FISH_ELEMENT" >&2
    exit 1
}

CARGO="$ROOT/elements/toolchain/rust/usr/lib/rust/bin/cargo"
[ -x "$CARGO" ] || {
    echo "$0: $CARGO is missing; run scripts/export-rust.sh first" >&2
    exit 1
}

echo "==> vendoring fish's crates: $url"
echo "    ref: $ref"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$work"
# The pinned tarball, or nothing: a 404 body must fail here rather than become
# the vendored tree. curl follows the GitHub release redirect.
curl -fsSL "$url" -o fish.tar.xz
echo "$ref  fish.tar.xz" | sha256sum -c -

tar -xf fish.tar.xz
srcdir=$(find . -maxdepth 1 -type d -name 'fish-*' | head -1)
[ -n "$srcdir" ] || {
    echo "$0: the tarball has no fish-<version>/ directory" >&2
    exit 1
}
cd "$srcdir"

# --locked: the lockfile decides. Without it cargo may re-resolve against the
# network and the tree would not match what packages/fish.bst's configure step
# asserts. The vendored crates land in ./vendor.
"$CARGO" vendor --locked vendor >"$work/vendor-config.txt"

# The three git sources plus crates.io must all be replaced, and the printed
# block must say so -- a tree vendored while one source was unreachable is a
# tree that will fail at build time with a network error instead.
n=$(grep -c 'replace-with = "vendored-sources"' "$work/vendor-config.txt")
[ "$n" -ge 4 ] || {
    echo "$0: cargo vendor replaced only $n sources; expected crates-io and the 3 git deps" >&2
    cat "$work/vendor-config.txt" >&2
    exit 1
}
grep -q '^\[source.vendored-sources\]' "$work/vendor-config.txt" ||
    { echo "$0: no [source.vendored-sources] section; cargo vendor output changed" >&2
      exit 1; }

cp -a vendor/. "$DEST"/

# Provenance, the way the seed and the toolchain record theirs: what was
# vendored, from where, with which compiler. The lockfile hash is here because
# it is the identity of the tree -- a different lock is a different tree, and
# this is the line that says which one this is.
lock_sha=$(sha256sum Cargo.lock | cut -d' ' -f1)
tc_source=$(cat "$ROOT/elements/toolchain/rust/TOOLCHAIN-SOURCE" 2>/dev/null || echo "  (toolchain not recorded)")
{
    echo "# Produced by scripts/export-vendor.sh -- fish's cargo dependencies."
    echo "# Regenerate: ./scripts/export-vendor.sh (after removing the old tree)"
    echo "fish-tarball: $url"
    echo "fish-ref: $ref"
    echo "cargo-lock-sha256: $lock_sha"
    echo "vendored-with: $("$CARGO" --version)"
    echo "exported: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "$tc_source" | sed 's/^/  /'
} > "$DEST/VENDOR-SOURCE"
chmod 644 "$DEST/VENDOR-SOURCE"

# The tree must be readable by the build, which runs as an unprivileged uid
# inside bwrap; cargo's own .cargo-checksum.json files are what
# packages/fish.bst asserts before it lets cargo run.
find "$DEST" -type d -exec chmod 755 {} +
find "$DEST" -type f -exec chmod 644 {} +

echo "==> done: $DEST"
du -sh "$DEST" | sed 's/^/  size: /'
echo "    crates: $(find "$DEST" -maxdepth 1 -mindepth 1 -type d | wc -l)"

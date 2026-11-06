#!/bin/sh
# export-rust.sh -- export the Rust toolchain from the vngrd-builder image.
#
# Why this exists beside export-seed.sh: fish 4.x is written in Rust. Its cmake
# build calls `cargo build` unconditionally (cmake/Rust.cmake does
# `find_package(Rust REQUIRED)`, and CMakeLists.txt calls it before anything
# else), so packages/fish.bst cannot configure at all without a cargo in the
# build sandbox. The seed does not carry one -- it carries clang, LLVM, lld and
# a gcc for the glibc bootstrap, and nothing else, because everything above the
# seed is supposed to be source-built.
#
# A compiler cannot compile itself from nothing, which is the same argument
# seed.bst makes for the C toolchain. This is the second such apology, not a
# licence to import more: the shipped image (elements/rootfs.bst) still
# contains nothing this tree holds.
#
# Layout, and it is not arbitrary. The toolchain arrives from rustup as
# <toolchain>/bin/{cargo,rustc} + <toolchain>/lib/{libLLVM*,librustc_driver*}
# + <toolchain>/lib/rustlib/<target>/, and both binaries carry
# RUNPATH=$ORIGIN/../lib. rustc finds its sysroot the same relative way
# (<exe>/../lib/rustlib). So the tree is staged keeping that shape under
# /usr/lib/rust, with /usr/bin/{cargo,rustc} as symlinks into it: $ORIGIN
# follows /proc/self/exe, not the symlink, so the relative paths still resolve.
# Putting the real binaries at /usr/bin instead would point their RUNPATH at
# vngrd's /usr/lib -- where glibc lives -- and that is the one directory the
# seed's binaries must never be told to search.
#
# One thing is added to that lib directory beyond what rustup provides: the
# librt.so.1 and libpthread.so.0 stubs the binaries' DT_NEEDED names, which
# are exported there so the loader finds them on the RUNPATH before it can
# reach vngrd's /usr/lib. See the copy below for why that directory is the
# only safe home for them.
#
# What is deliberately NOT in here: rustup itself (the shims in
# /root/.cargo/bin are 6-byte proxies that need a rustup toolchain to
# dispatch to), the docs (share/, ~17 MB), the targets other than the host's
# ($rust-version in fish's Cargo.toml is 1.85; nothing cross-compiles here),
# and the rustup-managed toolchain list. What the build needs is bin + lib.
#
# Usage: scripts/export-rust.sh [dest-dir]   # default: elements/toolchain/rust
set -eu

BUILDER_IMAGE=${BUILDER_IMAGE:-vngrd-builder}
DEST=${1:-elements/toolchain/rust}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Refuse to write into an existing tree: a partial export from a previous run
# would silently mix two toolchains. export-seed.sh refuses the same way.
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

command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 || {
    echo "$0: need docker or podman" >&2
    exit 1
}

echo "==> exporting the rust toolchain from $BUILDER_IMAGE into $DEST"

runtime=$(command -v docker || command -v podman)

# -i is required: `sh -s` reads the script from stdin, and without -i the
# runtime closes stdin and the container runs an empty script -- which exits 0
# having written nothing, so the export would look like it succeeded. The same
# bug export-seed.sh's comment records.
"$runtime" run --rm -i \
    -v "$DEST":/out:rw \
    "$BUILDER_IMAGE" sh -s <<'EXPORT'
set -eu

out=/out
arch=x86_64-unknown-linux-gnu

# The one toolchain the rustup in the image installed, which is also the one
# that built fish for vngrd-rootfs. Pin it: a `stable` bump here would silently
# recompile every rust build with a different compiler.
tc=/root/.rustup/toolchains/stable-${arch}
echo "  toolchain: $tc"

mkdir -p "$out/usr/lib/rust/bin" "$out/usr/lib/rust/lib" "$out/usr/bin"

# The driver and its libraries. -L because libLLVM.so.<ver>-<label> and the
# toolchain's bin/cargo are symlinks into this same directory.
cp -L "$tc"/bin/cargo "$out/usr/lib/rust/bin/cargo"
cp -L "$tc"/bin/rustc "$out/usr/lib/rust/bin/rustc"
cp -rL "$tc/lib/"*.so* "$out/usr/lib/rust/lib/"

# The two glibc-2.34+ stub libraries the cargo/rustc binaries carry in
# DT_NEEDED: librt.so.1 and libpthread.so.0, both of which are real files in
# the builder's /usr/lib/x86_64-linux-gnu and empty of everything except a
# forward to libc. They are exported HERE, and not left to the sandbox,
# because nothing else in the project carries them:
#
#   * the seed's library-closure pass ships only what the seed's own binaries
#     link, and Debian's clang links neither, so it carries no librt;
#   * every OTHER sandbox has vngrd's glibc staged at /usr/lib, and vngrd
#     builds librt from source into that same directory.
#
# The binaries' PT_INTERP is the builder's own /lib64 loader, and it resolves
# DT_NEEDED by searching the RUNPATH first: $ORIGIN/../lib is
# /usr/lib/rust/lib, exactly where librustc_driver already lands. A loader
# that finds its own librt there never reaches vngrd's. Without this the
# build dies at
#     rustc: symbol lookup error: /usr/lib/librt.so.1: undefined symbol:
#         __pointer_chk_guard, version GLIBC_PRIVATE
# which is the same loader/libc handshake failure elements/seed.bst records:
# a Debian-ABI loader driving a vngrd-ABI library, from the one directory
# (/usr/lib) where the seed's binaries must never be told to search.
cp -L /usr/lib/x86_64-linux-gnu/librt.so.1 "$out/usr/lib/rust/lib/"
cp -L /usr/lib/x86_64-linux-gnu/libpthread.so.0 "$out/usr/lib/rust/lib/"

# The standard library and rustc's private data for the host target only, plus
# /etc (rustc's own config, empty here but searched for unconditionally).
mkdir -p "$out/usr/lib/rust/lib/rustlib"
cp -rL "$tc/lib/rustlib/$arch" "$out/usr/lib/rust/lib/rustlib/$arch"
cp -rL "$tc/lib/rustlib/etc" "$out/usr/lib/rust/lib/rustlib/etc"

# The names cmake's find_program() looks for. $ORIGIN follows the real path, so
# the relative RUNPATH and sysroot above still resolve.
ln -s ../lib/rust/bin/cargo "$out/usr/bin/cargo"
ln -s ../lib/rust/bin/rustc "$out/usr/bin/rustc"

# --- the invariants, asserted here rather than in a package build ------------
# 1. The relative shape the binaries depend on:
#    $ORIGIN/../lib must hold the driver's libraries, and
#    $exe/../lib/rustlib must be rustc's sysroot.
[ -x "$out/usr/lib/rust/bin/rustc" ] || { echo "rustc missing" >&2; exit 1; }
ls "$out/usr/lib/rust/lib/" | grep -q '^librustc_driver-.*\.so$' ||
    { echo "librustc_driver missing from /usr/lib/rust/lib" >&2; exit 1; }
[ -d "$out/usr/lib/rust/lib/rustlib/$arch/lib" ] ||
    { echo "rustlib/$arch/lib missing" >&2; exit 1; }
for stub in librt.so.1 libpthread.so.0; do
    [ -f "$out/usr/lib/rust/lib/$stub" ] ||
        { echo "$stub missing from /usr/lib/rust/lib" >&2; exit 1; }
done

# 2. The binaries actually run -- through the tree's own Debian loader, which
#    is /lib64 here, not /usr/lib. Run them the way the sandbox will.
"$out/usr/lib/rust/bin/cargo" --version >/dev/null
"$out/usr/lib/rust/bin/rustc" --version >/dev/null

# 3. rustc agrees where its sysroot is. This is the check that catches a
#    re-layout that broke the relative path -- and it is also the reason the
#    tree is /usr/lib/rust and not, say, /usr/lib/rust/bin copied to /usr/bin:
#    rustc derives its sysroot as <exe>/.. and then looks for lib/rustlib
#    under it, so the binary has to stay one level above the libraries. The
#    expected value is prefixed with /out because that is where the tree is
#    mounted while this check runs; in the sandbox the same relative path
#    lands at /usr/lib/rust, which is the whole point of keeping the
#    toolchain's own shape.
sysroot=$("$out/usr/lib/rust/bin/rustc" --print sysroot)
[ "$sysroot" = "$out/usr/lib/rust" ] || {
    echo "rustc sysroot is $sysroot, expected $out/usr/lib/rust" >&2
    exit 1
}

# 4. It compiles and it links with the merged-/usr interpreter -- the flag set
#    packages/fish.bst gives RUSTFLAGS, minus the -L that needs base.bst
#    beside it. A PT_INTERP anything other than vngrd's own loader means
#    fish's binaries would ship a loader the image does not have.
cat > /tmp/hello.rs <<'EOF'
fn main() { println!("rust-ok"); }
EOF
"$out/usr/lib/rust/bin/rustc" \
    -C linker=clang \
    -C link-arg=-fuse-ld=lld \
    -C link-arg=-L/usr/lib \
    -C link-arg=-L/usr/lib/x86_64-linux-gnu \
    -C link-arg=-Wl,--dynamic-linker=/usr/lib/ld-linux-x86-64.so.2 \
    /tmp/hello.rs -o /tmp/hello-rust
interp=$(readelf -l /tmp/hello-rust | sed -n 's/.*interpreter: \(.*\)\].*/\1/p')
[ "$interp" = "/usr/lib/ld-linux-x86-64.so.2" ] || {
    echo "rustc baked PT_INTERP=$interp, expected /usr/lib/ld-linux-x86-64.so.2" >&2
    exit 1
}

# docker writes as root, which makes the tree unremovable by the invoking user
# and unreadable by BuildStream if the umask was tight.
chown -R "$(stat -c %u:%g /out)" /out
chmod -R u+rwX,go+rX /out

echo "EXPORT_OK"
EXPORT

status=$?
[ "$status" = 0 ] || { echo "$0: export failed inside $BUILDER_IMAGE" >&2; exit 1; }

# The toolchain is the second prebuilt input, so pin what it was built from.
{
    echo "# Produced by scripts/export-rust.sh from $BUILDER_IMAGE"
    echo "# Regenerate: ./scripts/export-rust.sh <dest> (after removing the old tree)"
    echo "builder-image: $BUILDER_IMAGE"
    echo "builder-digest: $($runtime image inspect "$BUILDER_IMAGE" --format '{{.Id}}')"
    echo "exported: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DEST/TOOLCHAIN-SOURCE"
chmod 644 "$DEST/TOOLCHAIN-SOURCE"

echo "==> done: $DEST"
du -sh "$DEST" | sed 's/^/  size: /'

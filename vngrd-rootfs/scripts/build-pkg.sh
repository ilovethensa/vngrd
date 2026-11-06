#!/bin/sh -e
# Build one package: fetch → verify → extract → build → verify → archive
# Layout: sources/ (tarballs) → work/<pkg>/ (source) → out/ (installed) → bin/*.tar.gz

PKG="$1"
[ -n "$PKG" ] || { echo "usage: $0 <package>" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Podman is a drop-in for everything used here: set DOCKER=podman.
DOCKER=${DOCKER:-docker}
. "$ROOT/config/docker.env"
[ -f "$ROOT/config/kiss.conf" ] && . "$ROOT/config/kiss.conf"

VERSION=$(cat "$ROOT/packages/$PKG/version")
ARCHIVE="$ROOT/bin/$PKG-$VERSION.tar.gz"
WORK="$ROOT/work/$PKG"
SRC_CACHE="$ROOT/sources"

mkdir -p "$ROOT/out" "$ROOT/bin" "$WORK" "$SRC_CACHE"

# The stamp is a content hash, not a version: base-files has no upstream version,
# and a changed recipe or payload would otherwise be skipped and silently ship an
# old archive. Hash the recipe, payload, version and kiss.conf (which changes the
# compiler and flags); work/ is excluded because sources+checksums fix it.
#
# Symlinks are hashed by link text, not contents: enablement symlinks are
# relative, and following them would make a rename look like a content change.
inputs_hash() {
    _inputs_listing | sha256sum | cut -d' ' -f1
}

# A listing rather than a hash, so a missing sha256sum still yields well-formed
# input and the guard on the result reports it. The mode is part of each line:
# contents alone missed a chmod-only change and republished a stale archive.
_inputs_listing() (
    cd "$ROOT"
    for f in "packages/$PKG/build" "packages/$PKG/version" config/kiss.conf; do
        if [ -f "$f" ]; then
            printf 'F %s %s %s\n' "$f" "$(stat -c '%a' "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
        fi
    done
    if [ -d "packages/$PKG/files" ]; then
        find "packages/$PKG/files" \( -type f -o -type l \) -print | sort | while read -r f; do
            if [ -L "$f" ]; then
                printf 'L %s %s\n' "$f" "$(readlink "$f")"
            else
                printf 'F %s %s %s\n' "$f" "$(stat -c '%a' "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
            fi
        done
    fi
    # Other recipe inputs that are easy to forget and do change behaviour: the
    # dependency list (it is documentation for ORDER, but a stale one is a trap)
    # and the source list (it is the only thing that decides which tarball is
    # unpacked into work/).
    for f in "packages/$PKG/depends" "packages/$PKG/sources"; do
        [ -f "$f" ] && printf 'F %s %s %s\n' "$f" "$(stat -c '%a' "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
    done
    # The trailing `true` is load-bearing: a for loop returns its last command's
    # status, which is false when a package has no sources file, and set -e would
    # abort the build silently.
    true
)

STAMP="$ROOT/bin/$PKG-$VERSION.stamp"
HASH=$(inputs_hash)

# A lost subshell status here would make an empty HASH compare unequal to every
# stamp (rebuild forever) or equal to nothing (skip stale). Require a sha256.
case "$HASH" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *)
        echo "$0: inputs_hash for $PKG returned '$HASH', not a sha256. Refusing to" >&2
        echo "  proceed: an empty or malformed hash would make every skip decision" >&2
        echo "  wrong, in a way that produces stale output rather than an error." >&2
        exit 1
        ;;
esac

# Skip only if the archive was produced from these exact inputs. No stamp means
# rebuild once, rather than blessing whatever is in bin/.
if [ -f "$ARCHIVE" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$HASH" ]; then
    echo "$PKG $VERSION already built, skipping"
    exit 0
fi
if [ -f "$ARCHIVE" ] && [ ! -f "$STAMP" ]; then
    # One-shot adoption for archives predating the stamp: only if nothing is newer
    # than the archive. An edited input always has a current mtime, so the risky
    # case rebuilds; only a back-dated mtime fools it.
    _newest=$(find "packages/$PKG" config/kiss.conf -newer "$ARCHIVE" \
                  \( -type f -o -type l \) -print 2>/dev/null | head -n 5)
    if [ -z "$_newest" ]; then
        printf '%s\n' "$HASH" > "$STAMP"
        echo "$PKG $VERSION already built, adopting stamp (bootstrap)"
        exit 0
    fi
    echo "$PKG $VERSION: inputs are newer than the archive, rebuilding" >&2
    echo "$_newest" | sed 's/^/  changed: /' >&2
fi

if [ -f "$ROOT/packages/$PKG/sources" ]; then
    while read -r url || [ -n "$url" ]; do
        # skip empty and comments
        [ -z "$url" ] && continue
        case "$url" in \#*) continue;; esac

        file=$(basename "$url")
        dest="$SRC_CACHE/$file"

        if [ -f "$dest" ]; then
            echo "Found $file, skipping download"
        else
            echo "Fetching $url"
            curl -L "$url" -o "$dest"
        fi
    done < "$ROOT/packages/$PKG/sources"
fi

if [ -f "$ROOT/packages/$PKG/checksums" ]; then
    paste "$ROOT/packages/$PKG/sources" "$ROOT/packages/$PKG/checksums" | while IFS="$(printf '\t')" read -r url sum; do
        [ -z "$url" ] && continue
        case "$url" in \#*) continue;; esac
        [ "$sum" = "SKIP" ] && continue
        [ -z "$sum" ] && continue

        file=$(basename "$url")
        echo "Verifying $file"
        echo "$sum  $SRC_CACHE/$file" | sha256sum -c -
    done
fi

# Most sources are tarballs; some are a single plain file (a CA bundle, a
# keystore), which tar cannot unpack. Detect rather than wrap every data package.
if [ -s "$ROOT/packages/$PKG/sources" ]; then
    first_url=$(grep -v '^\s*#' "$ROOT/packages/$PKG/sources" | grep -v '^\s*$' | head -n1)
    file=$(basename "$first_url")

    # only extract if work is empty
    if [ -z "$(ls -A "$WORK" 2>/dev/null)" ]; then
        case "$file" in
            *.tar.*|*.tgz|*.txz) kind="tar" ;;
            *)                   kind="file" ;;
        esac
        echo "Extracting $file ($kind) → work/$PKG/"
        ${DOCKER} run --rm \
            -v "$SRC_CACHE:/sources:ro" \
            -v "$WORK:/work" \
            "$BUILDER_IMAGE" \
            sh -c "if [ '$kind' = tar ]; then tar -xf /sources/$file -C /work; else cp /sources/$file /work/; fi"
    fi
fi

# Use work/ if it has sources, else use the package directory itself (e.g. base-files)
if [ -n "$(ls -A "$WORK" 2>/dev/null)" ]; then
    SRC_DIR="/work"
else
    SRC_DIR="/packages/$PKG"
fi

# Snapshot before for verify delta: "%p %s %T@" so verify.sh sees an overwrite as
# well as an addition. A bare path list would miss 500 replaced files.
before_list=$(mktemp)
find "$ROOT/out" -printf '%p %s %T@\n' 2>/dev/null | sort > "$before_list" || \
    find "$ROOT/out" 2>/dev/null | sort > "$before_list" || true

${DOCKER} run --rm \
    -v "$ROOT/packages:/packages:ro" \
    -v "$ROOT/config:/config:ro" \
    -v "$ROOT/out:/out" \
    -v "$ROOT/toolchain:/toolchain:ro" \
    -v "$WORK:/work" \
    -v "$SRC_CACHE:/sources" \
    -e KISS_ROOT -e KISS_PATH -e SYSROOT \
    -e CC -e CXX -e CFLAGS -e CXXFLAGS -e CPPFLAGS -e LDFLAGS -e MAKEFLAGS \
    -e RUSTFLAGS -e CARGO_BUILD_JOBS -e CARGO_TERM_QUIET \
    -e AR -e RANLIB -e NM -e LD -e STRIP -e OBJCOPY -e OBJDUMP -e READELF \
    -e PKG_CONFIG_SYSROOT_DIR -e PKG_CONFIG_LIBDIR -e PKG_CONFIG_PATH \
    -e KISS_KERNEL -e KISS_PREFIX -e HOST \
    "$BUILDER_IMAGE" sh -c '
        # Source kiss.conf inside the container: it is sourced at the top of this
        # script but not exported, so without this a package builds with Debian
        # gcc and empty LDFLAGS (verify.sh would catch the /lib64 interpreter).
        set -a; . /config/kiss.conf; set +a

        # Let configure test binaries run: provide target ld-linux on host
        if [ -f /out/usr/lib/ld-linux-x86-64.so.2 ]; then
            mkdir -p /usr/lib
            ln -sf /out/usr/lib/ld-linux-x86-64.so.2 /usr/lib/ld-linux-x86-64.so.2
        fi
        cd "$1" && sh -e "/packages/$2/build" /out
    ' _ "$SRC_DIR" "$PKG"

after_list=$(mktemp)
find "$ROOT/out" -printf '%p %s %T@\n' 2>/dev/null | sort > "$after_list" || \
    find "$ROOT/out" 2>/dev/null | sort > "$after_list" || true
"$ROOT/scripts/verify.sh" "$PKG" "$VERSION" "$before_list" "$after_list"
rm -f "$before_list" "$after_list"

tar --ignore-failed-read -czf "$ARCHIVE" -C "$ROOT/out" . 2>/dev/null || gzip -c /dev/null > "$ARCHIVE"
# Written last, only after a build that passed verify.sh.
printf '%s\n' "$HASH" > "$STAMP"
echo "$PKG $VERSION built → $ARCHIVE"

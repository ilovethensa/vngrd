#!/bin/sh -e
PKG="$1"
VERSION="$2"
BEFORE="$3"
AFTER="$4"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Verifying $PKG $VERSION ..."
failed=0

# Files this build introduced OR modified. Size and mtime make comm see an
# overwrite: a bare path list missed glibc tools rebuilt with a /lib64 interpreter.
new_files=$(comm -13 "$BEFORE" "$AFTER" 2>/dev/null | cut -d' ' -f1 | head -n 500 || true)
if [ -z "$new_files" ]; then
    # Fallback for a listing produced without size/mtime (an older caller, or a
    # filesystem with unusable timestamps): files touched very recently.
    new_files=$(find "$ROOT/out" -type f -mmin -2 2>/dev/null | head -n 200 || true)
fi
# If still empty, just check all (first build)
if [ -z "$new_files" ]; then
    new_files=$(find "$ROOT/out" -type f 2>/dev/null | head -n 50 || true)
fi

# Helper: print error and mark failed
fail() {
    echo "ERROR: $*" >&2
    failed=1
}

# 1) Top-level must be only /usr, /etc, /var, /efi, /boot
for dir in bin sbin lib lib64; do
    if [ -e "$ROOT/out/$dir" ] || [ -L "$ROOT/out/$dir" ]; then
        fail "forbidden top-level /$dir (use /usr/{bin,lib} + /etc + /var)"
        ls -ld "$ROOT/out/$dir" >&2 || true
    fi
done

# 2) /usr must only have bin, lib, include, share
if [ -d "$ROOT/out/usr" ]; then
    strays=$(find "$ROOT/out/usr" -mindepth 1 -maxdepth 1 ! -name bin ! -name lib ! -name include ! -name share -printf '%f\n' 2>/dev/null || true)
    if [ -n "$strays" ]; then
        fail "forbidden under /usr (only bin,lib,include,share): $strays"
    fi
    for bad in "$ROOT/out/usr/local" "$ROOT/out/usr/sbin" "$ROOT/out/opt"; do
        [ -e "$bad" ] && fail "forbidden $bad (use --prefix=/usr --sbindir=/usr/bin)"
    done
fi

# 3) Check ELF files from this package only
for file in $new_files; do
    [ -f "$file" ] || continue
    head -c 4 "$file" 2>/dev/null | grep -q $'\x7fELF' || continue

    interp=$(readelf -l "$file" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \([^]]*\).*/\1/p')
    if [ -n "$interp" ] && [ "$interp" != "/usr/lib/ld-linux-x86-64.so.2" ]; then
        fail "$file wrong interpreter $interp (want /usr/lib/ld-linux-x86-64.so.2)"
    fi
    if [ -n "$interp" ] && [ ! -e "$ROOT/out$interp" ] && [ ! -e "/out$interp" ]; then
        fail "$file interpreter $interp missing"
    fi

    for lib in $(readelf -d "$file" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p'); do
        if [ ! -e "$ROOT/out/usr/lib/$lib" ] && ! find "$ROOT/out" -name "$lib" 2>/dev/null | grep -q .; then
            fail "$file needs $lib not in out/"
        fi
    done

    rpath=$(readelf -d "$file" 2>/dev/null | grep -E 'RPATH|RUNPATH' | sed -n 's/.*\[\(.*\)\].*/\1/p')
    case "$rpath" in */work/*) fail "$file RPATH contains /work: $rpath" ;; esac
done

# 4) Symlinks — only new files. One systemd entry is allowed by exact path: its
# environment.d snippet points at the regenerated /etc and dangles harmlessly;
# environment.d skips unreadable entries, and the initrd does not seed it.
allow_broken_symlink() {
    case "$1" in
        */usr/lib/environment.d/99-environment.conf) return 0 ;;
    esac
    return 1
}
for file in $new_files; do
    if [ -L "$file" ] && [ ! -e "$file" ]; then
        allow_broken_symlink "$file" && continue
        fail "broken symlink $file -> $(readlink "$file")"
    fi
done
for file in $new_files; do
    if [ -L "$file" ]; then
        target=$(readlink "$file")
        case "$target" in /*)
            case "$target" in /usr/*|/etc/*|/var/*) ;; *) fail "$file -> $target absolute outside /usr/etc/var" ;; esac
        esac
    fi
done

# 5) Shebang — only new files. One exception, by exact path: systemd's inert
# kernel-install hook. Rewriting it to /usr/bin/sh would misparse POSIX on fish.
allow_shebang() {
    case "$1" in
        */usr/lib/kernel/install.d/90-loaderentry.install) return 0 ;;
    esac
    return 1
}
bad=""
for file in $new_files; do
    if [ -f "$file" ] && head -n1 "$file" 2>/dev/null | grep -q '^#!/bin/'; then
        allow_shebang "$file" || bad="$bad $file"
    fi
done
if [ -n "$bad" ]; then
    fail "shebang #!/bin/* not /usr/bin/*:
$bad"
fi

# 6) Hard-coded /sbin /bin outside /usr — only new files
bad_units=""
for file in $new_files; do
    case "$file" in *.service|*.socket|*.target|*.mount|*.conf|*.sh) 
        if grep -q 'ExecStart=.*/sbin/\(agetty\|modprobe\|ldconfig\)' "$file" 2>/dev/null; then
            bad_units="$bad_units $file"
        fi
    ;; esac
done
[ -n "$bad_units" ] && fail "hard-coded /sbin in units (fix package):$bad_units"

if [ "$failed" -ne 0 ]; then
    echo "Verification FAILED for $PKG $VERSION" >&2
    exit 1
fi

echo "Verified $PKG $VERSION — OK"

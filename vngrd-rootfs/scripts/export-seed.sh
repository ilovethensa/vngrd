# export-seed.sh -- export the vngrd-builder image as the BuildStream seed.
#
# The seed is the only prebuilt input: it compiles glibc and runs build tools.
# It is not a rootfs. Debian's multiarch libc coincides with vngrd's merged-/usr
# glibc, so three rules keep them apart:
#   1. Debian's glibc headers move to /usr/lib/debian-headers, or they would
#      collide with the vngrd glibc staged into /usr/include.
#   2. Debian's glibc binaries are not exported; vngrd's own are installed.
#   3. No /etc/ld.so.cache: a cache naming Debian's libc breaks vngrd's loader
#      with "undefined symbol: __pointer_chk_guard". Both loaders find their own
#      libraries from compiled-in paths.
#
# Usage: scripts/export-seed.sh ../vngrd-buildstream/elements/seed
set -eu

BUILDER_IMAGE=${BUILDER_IMAGE:-vngrd-builder}
DEST=${1:?usage: export-seed.sh <dest-dir>}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Podman is a drop-in for everything used here: set DOCKER=podman.
DOCKER=${DOCKER:-docker}

# Refuse to write into an existing tree: a partial export from a previous run
# would silently mix two toolchains.
if [ -e "$DEST" ]; then
    echo "$0: $DEST already exists; remove it first" >&2
    exit 1
fi
[ -d "$DEST" ] || mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)

# GNU/Linux only: the whole design is ELF + bwrap.
[ "$(uname -s)" = Linux ] || { echo "$0: Linux only" >&2; exit 1; }

echo "==> exporting seed from $BUILDER_IMAGE into $DEST"

# -i is required: `sh -s` reads the script from stdin, and without -i docker
# closes stdin and the container runs an empty script -- which exits 0 having
# written nothing, so the export would look like it succeeded.
${DOCKER} run --rm -i \
    -v "$DEST":/out:rw \
    "$BUILDER_IMAGE" sh -s <<'EXPORT'
set -eu

out=/out
arch=/usr/lib/x86_64-linux-gnu

# Sandbox layout; /bin is a symlink for upstream #!/bin/sh scripts.
mkdir -p "$out/usr/bin" "$out/usr/lib" "$out/usr/share" "$out/etc" \
         "$out/usr/include" "$out/root" "$out/home" \
         "$out/dev" "$out/proc" "$out/sys" "$out/run" "$out/tmp" "$out/var/tmp"
cp -a /dev/null "$out/dev/null"

# /bin for upstream #!/bin/sh, /lib64 for Debian's PT_INTERP. Symlinks, never
# pre-created dirs (mkdir then ln -s yields /bin/bin).
ln -s usr/bin "$out/bin"
mkdir -p "$out/usr/lib64"
cp -L /lib64/ld-linux-x86-64.so.2 "$out/usr/lib64/ld-linux-x86-64.so.2"
ln -s usr/lib64 "$out/lib64"

# BuildStream runs `sh -e -c`; Debian bash accepts -e, fish does not. This shell
# is build-only; the image gets its own from packages/fish.bst.
ln -s bash "$out/usr/bin/sh"

# clang/lld for everything; gcc/binutils only for the glibc bootstrap.
for b in clang clang++ ld.lld lld \
         llvm-ar llvm-ranlib llvm-strip llvm-objcopy llvm-objdump \
         llvm-readelf llvm-nm llvm-config; do
    cp -L "/usr/bin/$b" "$out/usr/bin/" 2>/dev/null || true
done
for b in gcc g++ cc c++ gcc-12 g++-12 as ld ld.bfd gold ar ranlib nm objcopy \
         objdump strip readelf elfedit; do
    cp -L "/usr/bin/$b" "$out/usr/bin/" 2>/dev/null || true
done

# gcc's runtime tree: crt objects, libgcc and the unwinder.
mkdir -p "$out/usr/lib/gcc/x86_64-linux-gnu"
cp -rL /usr/lib/gcc/x86_64-linux-gnu/12 "$out/usr/lib/gcc/x86_64-linux-gnu/"
# Drop what a vngrd build never invokes: sanitizers, objc, itm, quadmath, gomp
# and plugin headers. libgcc.bst builds the shared unwinder from this gcc.
rm -rf "$out/usr/lib/gcc/x86_64-linux-gnu/12/plugin"
rm -f "$out"/usr/lib/gcc/x86_64-linux-gnu/12/lib{asan,asan_preinit.o,tsan,*_preinit.o,hwasan,lsan,ubsan,mpx,mpxwrappers,objc*,itm*,quadmath*,gomp*}.so* \
      "$out"/usr/lib/gcc/x86_64-linux-gnu/12/lib{asan,tsan,ubsan,objc,itm,quadmath,gomp,hwasan}.a \
      "$out"/usr/lib/gcc/x86_64-linux-gnu/12/lib{ubsan,asan,tsan,lsan,hwasan}_preinit.o \
      "$out"/usr/lib/gcc/x86_64-linux-gnu/12/crtoffload*

# clang's resource headers; without them every compile stops at <stddef.h>.
# Do not copy /usr/lib/llvm-17/lib: those are symlinks into the multiarch dir and
# the closure pass brings in the real file.
mkdir -p "$out/usr/lib/clang/17"
cp -rL /usr/lib/llvm-17/lib/clang/17/include "$out/usr/lib/clang/17/"

# Move Debian's headers out of /usr/include (see rule 1). Only the C++ headers
# stay, since vngrd's glibc installs none and clang++ needs them.
mkdir -p "$out/usr/lib/debian-headers"
( cd /usr/include && tar cf - \
    --exclude=c++ --exclude=x86_64-linux-gnu/c++ --exclude=clang . ) \
  | ( cd "$out/usr/lib/debian-headers" && tar xf - )
cp -a /usr/include/c++ "$out/usr/include/c++"
mkdir -p "$out/usr/include/x86_64-linux-gnu/c++"
cp -a /usr/include/x86_64-linux-gnu/c++/. "$out/usr/include/x86_64-linux-gnu/c++/"

# Build tools, coreutils included wholesale: configure and glibc's Makefiles
# call many of them and a missing one fails late.
for b in basename cat chgrp chmod chown chroot cksum comm cp csplit cut date dd df \
         dir dirname du dircolors echo env expand expr factor false fmt fold head \
         hostid id install join link ln logname ls md5sum mkdir mkfifo mknod \
         mktemp mv nice nl nohup nproc numfmt od paste pathchk pinky pr \
         printenv printf ptx pwd readlink realpath rm rmdir runcon seq sha1sum \
         sha224sum sha256sum sha384sum sha512sum shred shuf sleep sort split stat \
         stdbuf stty sum sync tac tail tee test timeout touch tr true truncate \
         tsort tty uname unexpand uniq unlink users vdir wc who whoami yes; do
    cp -L "/usr/bin/$b" "$out/usr/bin/" 2>/dev/null || true
done
# rsync is used by headers_install; xz by autopoint (popt's tarball needs
# autoreconf). xz overlaps the image package, which carries the whitelist.
for b in bash diff diff3 cmp find xargs grep egrep fgrep sed gawk m4 patch \
         bison yacc flex lex gperf rsync msgfmt msgmerge msgcat xgettext \
         msgattrib msgconv msgen msgexec msgfilter msguniq msginit autopoint \
makeinfo make perl python3 cmake meson ninja tar xz gzip bzip2 unxz; do
    cp -L "/usr/bin/$b" "$out/usr/bin/" 2>/dev/null || true
done
ln -s gawk "$out/usr/bin/awk" 2>/dev/null || true
ln -s test "$out/usr/bin/[" 2>/dev/null || true

# pkg-config reads the vngrd sysroot.
for b in pkg-config pkgconf; do
    cp -L "/usr/bin/$b" "$out/usr/bin/" 2>/dev/null || true
done
for b in autoconf autoreconf autoheader autom4te autoscan autoupdate ifnames \
         automake aclocal libtoolize libtool aclocal-1.16 automake-1.16; do
    cp -L "/usr/bin/$b" "$out/usr/bin/" 2>/dev/null || true
done

# Data directories outside PATH: autom4te, config.guess, install-sh, depcomp,
# texinfo and meson. aclocal-1.16 is separate from the aclocal symlink farm and
# is required for popt's autoreconf.
for d in autoconf automake-1.16 aclocal aclocal-1.16 libtool gettext texinfo \
         bison cmake-3.25 cmake perl; do
    [ -d "/usr/share/$d" ] && cp -rL "/usr/share/$d" "$out/usr/share/" 2>/dev/null || true
done
# pod2man is used by openssl's install; Pod::Man comes with perl below.
cp -L /usr/bin/pod2man "$out/usr/bin/" 2>/dev/null || true
# perl is split three ways on Debian; libxcrypt's expand-selected-hashes needs
# all three: perl-base, the XS modules and the pure-perl tree.
mkdir -p "$out/usr/lib/x86_64-linux-gnu"
for d in /usr/lib/x86_64-linux-gnu/perl-base /usr/lib/x86_64-linux-gnu/perl; do
    [ -d "$d" ] && cp -rL "$d" "$out/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true
done
for d in /usr/share/perl/*; do
    [ -d "$d" ] && cp -rL "$d" "$out/usr/share/perl/" 2>/dev/null || true
done
# Text::Unidecode is in /usr/share/perl5 and is needed for glibc's makeinfo.
cp -rL /usr/share/perl5 "$out/usr/share/" 2>/dev/null || true
# NDBM_File/ODBM_File bind to gdbm, which no build here uses.
rm -rf "$out"/usr/lib/x86_64-linux-gnu/perl/5.36/auto/NDBM_File \
       "$out"/usr/lib/x86_64-linux-gnu/perl/5.36/auto/ODBM_File
# perl's three trees, as above.
cp -rL /usr/lib/x86_64-linux-gnu/perl-base "$out/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true
cp -rL /usr/lib/x86_64-linux-gnu/perl "$out/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true
mkdir -p "$out/usr/lib/x86_64-linux-gnu"
for d in /usr/lib/x86_64-linux-gnu/perl* /usr/share/perl/*; do
    [ -e "$d" ] || continue
    cp -rL "$d" "$out$(dirname "$d")/" 2>/dev/null || true
done
# Stdlib before dist-packages: both land under usr/lib/python3, and the wrong
# order deletes the whole tree, breaking every meson run.
cp -rL /usr/lib/python3.11 "$out/usr/lib/" 2>/dev/null || true
# dist-packages includes Jinja2/Markupsafe for systemd's meson build; a partial
# copy risks a later failure, so the whole tree comes.
mkdir -p "$out/usr/lib/python3"
cp -rL /usr/lib/python3/dist-packages "$out/usr/lib/python3/" 2>/dev/null || true
cp -rL /usr/share/python3 "$out/usr/share/" 2>/dev/null || true
# Lazy imports of libs Debian has; drop them rather than pull their closure.
rm -f "$out"/usr/lib/python3.11/lib-dynload/_curses*.so \
      "$out"/usr/lib/python3.11/lib-dynload/_curses_panel*.so \
      "$out"/usr/lib/python3.11/lib-dynload/nis*.so \
      "$out"/usr/lib/python3.11/lib-dynload/_dbm*.so \
      "$out"/usr/lib/python3.11/lib-dynload/_sqlite3*.so \
      "$out"/usr/lib/python3.11/lib-dynload/_uuid*.so \
      "$out"/usr/lib/python3.11/lib-dynload/_dbus*.so \
      "$out"/usr/lib/python3.11/lib-dynload/readline*.so

# A passwd so getpwuid() works for perl, python and configure.
cat > "$out/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/usr/bin/sh
daemon:x:1:1:daemon:/:/usr/sbin/nologin
vngrd:x:1000:1000:vngrd:/home/vngrd:/usr/bin/sh
EOF
cat > "$out/etc/group" <<'EOF'
root:x:0:
daemon:x:1:
vngrd:x:1000:
EOF
cat > "$out/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
hosts: files
EOF
chmod 644 "$out/etc/passwd" "$out/etc/group" "$out/etc/nsswitch.conf"

# Compute the library closure rather than hand-list it. Each soname stays at
# Debian's path, so it cannot collide with vngrd's /usr/lib.
copy_if_present() {
    for soname in "$@"; do
        [ -e "$out/usr/lib/$soname" ] && continue
        for d in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib /usr/lib; do
            if [ -e "$d/$soname" ]; then
                mkdir -p "$out$d"
                cp -L "$d/$soname" "$out$d/" 2>/dev/null || true
                break
            fi
        done
    done
}

resolve_missing() {
# Walk every ELF, not just /usr/bin: perl XS modules and gcc's cc1 have their
# own loads. The first version missed libdb/libgdbm behind perl's DB_File.
    for so in "$out/usr/bin/"* \
              $(find "$out/usr/lib" -type f \( -name '*.so*' -o -name '*.so' \) 2>/dev/null); do
        [ -e "$so" ] || continue
        ldd "$so" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++)
            if ($i ~ /^\//) print $i }'
    done | sort -u | while read -r path; do
        case "$path" in
            /usr/lib/debian-headers/*) continue ;;
        esac
        soname=${path##*/}
        [ -e "$out$path" ] && continue
# ldd reports /lib; normalise to the multiarch path.
        case "$path" in
            /lib/x86_64-linux-gnu/*) path="/usr/lib/x86_64-linux-gnu/$soname" ;;
        esac
        mkdir -p "$out$(dirname "$path")"
        cp -L "$path" "$out$(dirname "$path")" 2>/dev/null || true
    done
# cc1, liblto and friends are dlopen'd or named absolutely.
    for so in libisl.so.23 libmpc.so.3 libmpfr.so.6 libgmp.so.10; do
        copy_if_present "$so"
    done
}
# Three rounds: copying a library can pull in one of its own.
resolve_missing
resolve_missing
resolve_missing

# ldd only sees runtime loads. Linkers ask for crt1.o, Scrt1.o, crti.o, crtn.o
# and libc.so by name. Debian's libc.so is a GNU ld script and its lib*.so
# aliases point into /lib, which does not exist here; rewrite both relative.
# vngrd's -L/usr/lib precedes the multiarch dir, so its packages get vngrd's crt.
mkdir -p "$out/usr/lib/x86_64-linux-gnu"
for f in crt1.o Scrt1.o crti.o crtn.o Mcrt1.o gcrt1.o grcrt1.o rcrt1.o; do
    cp -L "/usr/lib/x86_64-linux-gnu/$f" "$out/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true
done
for f in libc.so libc_nonshared.a libmvec_nonshared.a; do
    cp -L "/usr/lib/x86_64-linux-gnu/$f" "$out/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true
done
for link in /usr/lib/x86_64-linux-gnu/lib*.so; do
    name=${link##*/}
    if [ -L "$link" ]; then
        target=$(readlink "$link")
        case "$target" in
            /*) soname=${target##*/} ;;
            *)  soname=$target ;;
        esac
        [ -e "$out/usr/lib/x86_64-linux-gnu/$soname" ] || continue
        ln -sfn "$soname" "$out/usr/lib/x86_64-linux-gnu/$name"
    elif [ -f "$link" ] && [ "$(stat -c %s "$link")" -lt 4096 ]; then
# GNU ld script (Debian's libc.so and libm.so are text).
        cp -L "$link" "$out/usr/lib/x86_64-linux-gnu/" 2>/dev/null || true
    fi
done
# Recreate the -l aliases glibc 2.34 merged away.
for pair in libdl.so:libdl.so.2 librt.so:librt.so.2 libpthread.so:libpthread.so.0 \
            libutil.so:libutil.so.2 libresolv.so:libresolv.so.2; do
    soname=${pair#*:}
    [ -e "$out/usr/lib/x86_64-linux-gnu/$soname" ] || continue
    ln -sfn "$soname" "$out/usr/lib/x86_64-linux-gnu/${pair%%:*}"
done

# Repoint libc.so's absolute /lib paths; the loader lives at /usr/lib64.
for script in "$out"/usr/lib/x86_64-linux-gnu/*.so; do
    [ -f "$script" ] || continue
    head -c 64 "$script" | grep -q 'GNU ld script' || continue
# Anchor on the leading space: an unanchored /lib/... also matches /usr/lib/....
    sed -i -e 's| /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2| /usr/lib64/ld-linux-x86-64.so.2|g' \
           -e 's| /lib/x86_64-linux-gnu/| /usr/lib/x86_64-linux-gnu/|g' "$script"
done
# Libraries named only by linker scripts (libmvec via libm.so) were never loaded
# by a running binary; glibc's first C++ link test needs them.
for script in "$out"/usr/lib/x86_64-linux-gnu/*.so; do
    [ -f "$script" ] || continue
    head -c 64 "$script" | grep -q 'GNU ld script' || continue
    for named in $(grep -o '/usr/lib/x86_64-linux-gnu/[A-Za-z0-9_.+-]*' "$script"); do
        soname=${named##*/}
        [ -e "$out/usr/lib/x86_64-linux-gnu/$soname" ] && continue
        [ -e "/usr/lib/x86_64-linux-gnu/$soname" ] || continue
        cp -L "/usr/lib/x86_64-linux-gnu/$soname" "$out/usr/lib/x86_64-linux-gnu/" || true
    done
done

# Debian's LLVM tools carry RUNPATH=$ORIGIN/../lib, which is /usr/lib once the
# vngrd glibc is staged there. That makes Debian's loader load vngrd's libc and
# fail with GLIBC_PRIVATE __pointer_chk_guard. Neutralise the runpath so the
# tools use the multiarch libs the closure pass already copied.
python3 - "$out" <<'RPATH'
import os, sys

out = sys.argv[1]
# Same length as the replaced string: shrinking moves every later section
# offset. Pad with NULs; the loader stops at the first.
TARGET = b"$ORIGIN/../lib\0"
NEUTRAL = b"/nonexistent" + b"\0" * (len(TARGET) - len(b"/nonexistent"))
assert len(NEUTRAL) == len(TARGET)

def rewrite(path):
    with open(path, "rb") as f:
        data = f.read()
    if TARGET not in data:
        return False
    with open(path, "wb") as f:
        f.write(data.replace(TARGET, NEUTRAL))
    return True

n = 0
for root, _, files in os.walk(os.path.join(out, "usr", "bin")):
    for name in files:
        path = os.path.join(root, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            if f.read(4) != b"\x7fELF":
                continue
        n += rewrite(path)
print(f"  ok: neutralised $ORIGIN runpaths on {n} binaries")
RPATH

# A tool that cannot start cannot be caught later.
"$out/usr/bin/clang" --version >/dev/null 2>&1 || {
    echo "$0: the seed's clang no longer runs" >&2
    exit 1
}

# Debian ELFs carry PT_INTERP=/lib64/..., so Debian's loader must be there.
# vngrd's own loader is built by packages/glibc.bst.
echo "==> verifying the seed tree"

# 1. Every PT_INTERP must exist in the tree.
bad=0
for f in "$out/usr/bin/"*; do
    [ -f "$f" ] || continue
    interp=$(readelf -l "$f" 2>/dev/null | sed -n 's/.*interpreter: \(.*\)\].*/\1/p')
    [ -z "$interp" ] && continue
    [ -e "$out$interp" ] || { echo "MISSING INTERP $interp for $f" >&2; bad=1; }
done

# Every DT_NEEDED must resolve inside the seed.
python3 - "$out" <<'VERIFY'
import os, subprocess, sys

out = sys.argv[1]
missing = []
for root, _, files in os.walk(out):
    for name in files:
        path = os.path.join(root, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            if f.read(4) != b"\x7fELF":
                continue
        elf = subprocess.run(["readelf", "-d", path],
                             capture_output=True, text=True).stdout
        for line in elf.splitlines():
            if "NEEDED" not in line:
                continue
            soname = line.split("[")[1].split("]")[0]
            if soname == "linux-vdso.so.1":
                continue
            found = False
            for subdir in ("usr/lib", "lib", "usr/lib64", "lib64",
                           "usr/lib/x86_64-linux-gnu", "lib/x86_64-linux-gnu"):
                if os.path.exists(os.path.join(out, subdir, soname)):
                    found = True
                    break
            if not found:
                missing.append((soname, path))
if missing:
    print("unresolvable DT_NEEDED entries:", file=sys.stderr)
    for soname, path in sorted(set(missing)):
        print(f"  {soname}  (needed by {path})", file=sys.stderr)
    sys.exit(1)
print("  ok: every DT_NEEDED resolves inside the seed")
VERIFY

# No glibc header may survive at /usr/include (rule 1).
if find "$out/usr/include" -mindepth 1 -maxdepth 1 ! -name 'c++' \
        ! -name 'x86_64-linux-gnu' | grep -q .; then
    echo "SEED HAS STRAY /usr/include ENTRIES:" >&2
    find "$out/usr/include" -mindepth 1 -maxdepth 1 ! -name 'c++' \
        ! -name 'x86_64-linux-gnu' >&2
    exit 1
fi

[ "$bad" = 0 ] || { echo "$0: interpreter check failed" >&2; exit 1; }

# No dangling symlinks: the tree is relocated and BuildStream treats it as
# authoritative.
dangling=$(find "$out" -xtype l -print | head -n 20)
if [ -n "$dangling" ]; then
    echo "DANGLING SYMLINKS:" >&2
    printf '%s\n' "$dangling" >&2
    exit 1
fi

# Compile, link and run against Debian's libc through Debian's loader.
printf 'int main(void){return 0;}\n' > /tmp/conftest.c
"$out/usr/bin/clang" -c /tmp/conftest.c -o /tmp/conftest.o
"$out/usr/bin/clang" /tmp/conftest.o -o /tmp/conftest
/tmp/conftest || { echo "$0: seed compiler cannot run its own output" >&2; exit 1; }

# docker writes as root; make the tree removable and readable.
chown -R "$(stat -c %u:%g /out)" /out
chmod -R u+rwX,go+rX /out

echo "EXPORT_OK"
EXPORT

status=$?
[ "$status" = 0 ] || { echo "$0: export failed inside $BUILDER_IMAGE" >&2; exit 1; }

# The seed is the one prebuilt artifact, so pin what it was built from.
{
    echo "# Produced by scripts/export-seed.sh from $BUILDER_IMAGE"
    echo "# Regenerate: ./scripts/export-seed.sh <dest> (after removing the old tree)"
    echo "builder-image: $BUILDER_IMAGE"
    echo "builder-digest: $(${DOCKER} image inspect "$BUILDER_IMAGE" --format '{{.Id}}')"
    echo "exported: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DEST/SEED-SOURCE"
chmod 644 "$DEST/SEED-SOURCE"

echo "==> done: $DEST"
du -sh "$DEST" | sed 's/^/  size: /'
du -sh "$DEST/usr/lib/debian-headers" "$DEST/usr/lib/gcc" "$DEST/usr/lib/python3.11" 2>/dev/null | sed 's/^/  /'

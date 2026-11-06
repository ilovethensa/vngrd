# glibc 2.44 -- the C library. Built here, not imported.
#
# This is the package that makes the rest of the project vngrd's own: the Arch
# tree this element replaces was a foreign sysroot, and AGENTS.md's "no
# compat" is meaningless while the libc is somebody else's. With
# packages/linux-headers.bst beside it, every later element links against a
# glibc this project built, at /usr/lib, with the merged-/usr interpreter
# baked in at link time.
#
# The element is a `manual` rather than an autotools kind on purpose. glibc's
# configure is pre-generated rather than autoconf-produced, the install needs
# four directory variables spelled out on the make command line, and the
# merged-/usr fixups are install-time surgery -- three things the plugin's
# conf-global/make-install would each override only half of. Say them once,
# here, where vngrd-rootfs's packages/glibc/build says them.
#
# The build runs against the SEED, and only the seed: Debian's gcc/binutils,
# which AGENTS.md allows for exactly this one package ("only glibc may use gcc
# to bootstrap"), compiling with Debian's C library headers from
# /usr/lib/debian-headers and the vngrd kernel headers the
# linux-headers.bst build-dependency staged at /usr/include. The result is
# linked with the merged-/usr interpreter because lld's default
# /lib64/ld-linux-x86-64.so.2 must not be baked in: verify.bst rejects
# anything else, and /lib64 does not exist in the image.
kind: manual

build-depends:
- seed.bst
- packages/linux-headers.bst

environment:
  # Confirmed per-package rather than inherited, and the WHOLE GNU set rather
  # than just CC: the project environment names clang and llvm-* for every
  # other element (AGENTS.md: LLVM only), and glibc is the one documented
  # exception -- "only glibc may use gcc to bootstrap". vngrd-rootfs builds
  # this package inside the Debian builder, where the defaults are GNU, so
  # spelling them out here is what reproduces that build exactly.
  #
  # CPP is not decoration. glibc's configure checks
  #   `#if !defined __clang__ || __clang_major__ < 18 -> #error`
  # with the preprocessor in $CPP, and with the project's `clang -E` the seed's
  # clang 17 fails it: "checking if gcc is sufficient to build libc... no" and
  # "critical programs are missing or too old: compiler", from a build whose
  # compiler is a perfectly good gcc 12.2. gcc -E is the driver this element
  # drives; it is the one that has to answer.
  CC: gcc
  CXX: g++
  CPP: gcc -E
  AR: ar
  AS: as
  NM: nm
  RANLIB: ranlib
  LD: ld
  STRIP: strip
  OBJCOPY: objcopy
  READELF: readelf
  KISS_KERNEL: '7.2'

config:
  build-commands:
  - |
    set -eu

    # vngrd-rootfs/packages/glibc/build, in order, with the /out paths this
    # sandbox supplies differently:
    #
    #   -I/out/usr/include  ->  the vngrd kernel headers, staged at
    #                           /usr/include by the linux-headers.bst
    #                           build-dependency. --with-headers names the
    #                           same place, exactly as vngrd-rootfs's
    #                           --with-headers=/out/usr/include did.
    #   Debian's headers    ->  /usr/lib/debian-headers, where export-seed.sh
    #                           relocated them so they cannot collide with
    #                           this element's own install.
    #
    # -idirafter, NOT -I, and that is the whole reason glibc's configure once
    # failed with "whether g++ can link programs... no": Debian's C++ headers
    # reach stdlib.h through `#include_next`, which skips every directory the
    # -I list holds and searches the SYSTEM paths. Relocated headers are not
    # on any system path, so the C++ conftests died and the C++ compiler was
    # declared unusable. -idirafter appends after the system dirs, which is
    # both what include_next needs and what "the host libc is the fallback"
    # means. The vngrd kernel headers keep -I, prepended, exactly as
    # vngrd-rootfs's -I/out/usr/include did: headers here must resolve to the
    # kernel's, not the host's.
    #
    # Both directories, because Debian splits them: the arch-specific C
    # library headers live in the <triplet> subdirectory (sys/types.h is not
    # in /usr/include at all).
    export CFLAGS="-O2 -pipe -march=x86-64 -I/usr/include -idirafter /usr/lib/debian-headers -idirafter /usr/lib/debian-headers/x86_64-linux-gnu"
    export CXXFLAGS="$CFLAGS"
    export CPPFLAGS="-I/usr/include -idirafter /usr/lib/debian-headers -idirafter /usr/lib/debian-headers/x86_64-linux-gnu"
    export LDFLAGS="-Wl,-O1 -Wl,--as-needed -fuse-ld=lld -Wl,--dynamic-linker=/usr/lib/ld-linux-x86-64.so.2"
    export PKG_CONFIG_SYSROOT_DIR="" PKG_CONFIG_LIBDIR="" PKG_CONFIG_PATH=""

    # The interpreter lld is told to bake in does not exist while this build
    # runs -- glibc is the package that installs it -- so the seed's staging
    # integration-commands point /usr/lib/ld-linux-x86-64.so.2 at the seed's
    # own loader for the duration of every sandbox (see elements/seed.bst).
    # That is also why the symlink is NOT created here: a build element's
    # commands run with the sandbox root read-only
    # (buildelement.py: `sandbox.run(..., root_read_only=True)`), and the
    # installed tree gets its own loader at install time below.
    mkdir build
    cd build

    # Why configparms exists at all: with --prefix=/usr, glibc's own
    # sysdeps/unix/sysv/linux/x86_64/64/configure fragment runs
    #
    #     case "$prefix" in /usr|/usr/) libc_cv_slibdir='/lib64'; ...
    #
    # i.e. it hardcodes slibdir=/lib64 into config.make, because glibc was
    # written for a distro with a real /lib64 -- and Makeconfig then derives
    # rtlddir from it, so every program glibc links is baked with
    # -Wl,-dynamic-linker=/lib64/ld-linux-x86-64.so.2. vngrd-rootfs shipped
    # that: its out/ has seventeen ELFs (iconvconfig, zic, localedef, getconf,
    # libc.so.6, ...) pointing at a path the merged-/usr tree does not have,
    # and nothing runs them at boot.
    #
    # configparms is glibc's documented mechanism for exactly this ("these are
    # the configuration variables. You can define values for the variables
    # below in the file configparms" -- Makeconfig), and Makeconfig reads it
    # AFTER config.make, so it wins. The source tree's own configparms is
    # read-only in the sandbox; the build directory's is the same mechanism,
    # and it is writable.
    printf 'slibdir = /usr/lib\nrtlddir = /usr/lib\n' > configparms

    ../configure \
        --prefix=/usr \
        --libdir=/usr/lib \
        --libexecdir=/usr/lib \
        --with-headers=/usr/include \
        --enable-kernel="$KISS_KERNEL" \
        --enable-bind-now \
        --enable-stack-protector=strong \
        --disable-nscd \
        --disable-profile \
        --disable-werror \
        --without-selinux \
        CC=gcc \
        CXX=g++ \
        AR=ar \
        RANLIB=ranlib \
        LD=ld

    # sbindir: iconvconfig/zic. rootsbindir: ldconfig/sln -- Makeconfig's
    # default for the latter is $(exec_prefix)/sbin, separate from sbindir, so
    # both are forced into /usr/bin and no top-level /sbin appears in the
    # artifact (AGENTS.md, and verify.bst's top-level check).
    make -j"$(nproc)" slibdir=/usr/lib sbindir=/usr/bin rootsbindir=/usr/bin

  install-commands:
  - |
    set -eu
    cd build
    make DESTDIR="%{install-root}" slibdir=/usr/lib sbindir=/usr/bin rootsbindir=/usr/bin install

    dest=%{install-root}

    # Unified /usr: glibc installs its loader under lib64. Move the file, not
    # just the directory, so the tree that lands in the image has no top-level
    # /lib64 at all.
    if [ -d "$dest/lib64" ]; then
        mkdir -p "$dest/usr/lib"
        mv "$dest/lib64"/* "$dest/usr/lib/" 2>/dev/null || true
        rmdir "$dest/lib64" 2>/dev/null || true
    fi
    if [ -d "$dest/lib" ] && [ ! -L "$dest/lib" ]; then
        mkdir -p "$dest/usr/lib"
        if [ -n "$(ls -A "$dest/lib" 2>/dev/null)" ]; then
            mv "$dest/lib"/* "$dest/usr/lib/" 2>/dev/null || true
        fi
        rmdir "$dest/lib" 2>/dev/null || true
    fi

    # glibc installs usr/bin/ld.so as a relative link into ../lib64, which the
    # move above removed: repoint it at where the loader now lives.
    if [ -L "$dest/usr/bin/ld.so" ] || [ -L "$dest/usr/lib/ld.so" ]; then
        ln -sfn ../lib/ld-linux-x86-64.so.2 "$dest/usr/lib/ld.so" 2>/dev/null || true
        rm -f "$dest/usr/bin/ld.so" 2>/dev/null || true
    fi

    # The libc.so linker script still names /lib64: the sysroot is /usr/lib.
    if [ -f "$dest/usr/lib/libc.so" ]; then
        sed -i 's|/lib64/ld-linux|/usr/lib/ld-linux|g' "$dest/usr/lib/libc.so"
    fi

    # Safety net rather than a hope: a top-level /sbin is a verify.bst failure,
    # so it may not be allowed to survive the install silently.
    if [ -d "$dest/sbin" ]; then
        mkdir -p "$dest/usr/bin"
        mv "$dest/sbin"/* "$dest/usr/bin/" 2>/dev/null || true
        rmdir "$dest/sbin"
    fi

    # glibc installs five shell helpers, and every one of them needs an
    # interpreter this image does not ship: ldd, sotruss, tzselect and xtrace
    # start "#!/bin/bash" (there is no bash in a fish-only image), and mtrace
    # starts "#!/bin/sh" (this image's /usr/bin/sh IS fish, which would
    # misparse a POSIX script -- vngrd-rootfs's own verify.sh explains exactly
    # this and rejects the shebang rewrite rather than lying about it).
    #
    # They are dropped, not repaired, exactly as vngrd-rootfs's recipe drops
    # zstdgrep/zstdless for the same reason: a script whose first command
    # cannot run is worse than one that is not there. Nothing in the boot path
    # calls any of them -- systemd resolves libraries itself, and the image is
    # UKI-based with no zoneinfo selector to pick.
    for helper in ldd mtrace sotruss tzselect xtrace; do
        rm -f "$dest/usr/bin/$helper"
    done
    for helper in ldd mtrace sotruss tzselect xtrace; do
        if [ -e "$dest/usr/bin/$helper" ]; then
            echo "glibc.bst: $helper should have been pruned but is present" >&2
            exit 1
        fi
    done

    # Assert the merged-/usr shape the rest of the project depends on. These
    # are the paths verify.bst will fail on later; failing here names the
    # package instead of the assembled tree.
    for d in bin sbin lib lib64; do
        if [ -e "$dest/$d" ] || [ -L "$dest/$d" ]; then
            echo "glibc.bst: top-level /$d in the install tree" >&2
            exit 1
        fi
    done
    [ -x "$dest/usr/lib/ld-linux-x86-64.so.2" ] || {
        echo "glibc.bst: no loader at usr/lib/ld-linux-x86-64.so.2" >&2
        exit 1
    }
    # The interpreter every later element will bake in. Checked on an ELF
    # (iconvconfig), not on ldd: glibc's ldd is a shell script, which
    # readelf reads as nothing at all -- the first version of this check
    # compared an empty string and failed a build that was correct.
    interp=$(llvm-readelf -p .interp "$dest/usr/bin/iconvconfig" 2>/dev/null \
                | sed -n 's/.*\][[:space:]]*//p' | head -1)
    [ "$interp" = /usr/lib/ld-linux-x86-64.so.2 ] || {
        echo "glibc.bst: ldd carries PT_INTERP '$interp'" >&2
        exit 1
    }

  strip-commands: []

sources:
- kind: tar
  url: https://ftp.gnu.org/gnu/glibc/glibc-2.44.tar.xz
  ref: 37f600f2bef3c5e8300147059568b2a2e40a7ad6ccc65ce942556d49429cc667

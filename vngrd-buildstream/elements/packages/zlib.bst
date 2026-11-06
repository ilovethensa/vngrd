# zlib, provided by zlib-ng in --zlib-compat mode.
#
# Same choice as vngrd-rootfs/packages/zlib: zlib-ng with --zlib-compat ships
# libz.so / libz.h / zlib.pc, so openssl, curl and systemd link against it with
# no source changes. (AGENTS.md prefers the modern replacement; this one is
# already recorded there.)
#
# The sha256 is mandatory -- BuildStream hard-fails on a mismatch, which is the
# whole reason for moving here. vngrd-rootfs ships `SKIP` in all 35 checksums
# files; this is the first input in the project whose integrity is guaranteed.
kind: autotools

#
# This is the one deliberate overlap in the project, and it is safe precisely
# because neither file reaches the rootfs.
build-depends:
- seed.bst
- base.bst

# The overlap, precisely stated: base.bst's real zlib stays for the *loader*
# (libLLVM requires ZLIB_1.2.0, verified with `readelf --version-info`), while
# this element is the *linker's* choice (-lz resolves these aliases, and a
# clang+lld link records no zlib verneed, so our packages bind zlib-ng
# unversioned). They collide on one path -- the linker alias -- and only that
# path is whitelisted. The runtime image carries only zlib-ng: base's real
# base's zlib is not in `runtime-keep`, and nothing the image keeps binds ZLIB
# versions (checked: libcrypto, libmagic, zstd).
#
# Caveat recorded, not hidden: a package build that *dlopens* libz.so.1 with
# LD_BIND_NOW or runs a real-zlib-linked host binary would find zlib-ng under
# that soname and miss the ZLIB_1.2.0 version. Nothing does today; verify.bst
# would catch the failure as an unresolved version reference in the artifact.
public:
  bst:
    overlap-whitelist:
    - /usr/lib/libz.so

sources:
- kind: tar
  url: https://github.com/zlib-ng/zlib-ng/archive/refs/tags/2.3.3.tar.gz
  ref: f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1
  # No base-dir: a GitHub tag archive has no top-level directory, so the
  # sources land directly in the build root. Setting base-dir here makes
  # `base-dir` a *number of components to strip*, which deletes configure.

variables:
  # zlib-ng ships a hand-written configure, not an autoconf one, so it rejects
  # the plugin's standard argument set:
  #
  #     unknown option: --exec-prefix=/usr
  #
  # --prefix/--libdir are the only path knobs it understands; everything else it
  # derives itself. Overriding conf-args rather than conf-local is deliberate:
  # conf-local appends to the default list, and the default list is the problem.
  #
  # Nor --disable-static: it only knows --static/--shared. --zlib-compat is not
  # in that list either, but it is accepted because the configure script checks
  # for it separately; grepping the script for --<flag> is the way to find out
  # what a non-autoconf configure accepts.
  conf-args: >-
    --prefix=%{prefix}
    --libdir=%{libdir}
    --zlib-compat
    --shared

  # zlib-ng installs zlib.pc under share/pkgconfig; vngrd's sysroot expects
  # everything in lib/pkgconfig. Mirrors packages/zlib/build.
  post-install-commands: |
    if [ -f "%{install-root}/usr/share/pkgconfig/zlib.pc" ]; then
      mkdir -p "%{install-root}/usr/lib/pkgconfig"
      mv "%{install-root}/usr/share/pkgconfig/zlib.pc" \
         "%{install-root}/usr/lib/pkgconfig/"
    fi

  # vngrd is merged-/usr with no separate sbin: a /usr/sbin here would be a
  # build failure in verify.bst, not a warning.
  strip-commands: |
    rm -f "%{install-root}"/usr/sbin/* 2>/dev/null || true

  # libtool archives reference the build-time sysroot and are useless on target.
  remove-libtool-libraries: "true"
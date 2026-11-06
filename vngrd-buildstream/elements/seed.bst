# The vngrd seed: the one prebuilt input to this project.
#
# Why there is a seed at all: a compiler cannot compile itself from nothing.
# The first toolchain of any source-built distribution has to arrive as a
# binary, and that is the shape every project of this kind settles on --
# freedesktop-sdk has elements/bootstrap/base-sdk/binary-seed.bst, a `kind:
# import` of a docker image pinned by sha256 `ref`, and nothing below it is
# source-built either. What can be empty-folder is everything ABOVE the seed,
# and here that is: linux-headers, glibc, systemd and every other package are
# elements built from source on top of it.
#
# Produced by ../vngrd-rootfs/scripts/export-seed.sh out of the vngrd-builder
# image, which pins its toolchain by digest (see elements/seed/SEED-SOURCE).
# Not committed, not the image: no element ever lists this as a runtime
# dependency, so none of it reaches rootfs.bst.
#
# What it is, exactly: Debian's clang/lld and GNU binutils, gcc for the glibc
# bootstrap (AGENTS.md: glibc is the one package allowed to drive gcc), the
# build tools every configure and Makefile drives itself with, and Debian's
# multiarch libc so the seed's own binaries can run. The glibc that SHIPS is
# built by packages/glibc.bst; this one exists so that build has something to
# compile with.
#
# Three properties the export script asserts and this element then relies on,
# because they are what let the seed be staged at / beside the vngrd libc in
# the same sandbox without either colliding:
#
#   * Debian's glibc headers are at /usr/lib/debian-headers, NOT /usr/include.
#     Left there they would collide with the headers packages/glibc.bst
#     installs, and a build could pick up Debian's headers for a vngrd library.
#     packages/glibc.bst is the only element that compiles against them; its
#     CFLAGS say so.
#   * Debian's libc lives at /usr/lib/x86_64-linux-gnu, not /usr/lib.
#     vngrd's merged-/usr glibc installs into /usr/lib, so neither file
#     shadows the other's.
#   * Debian's glibc binaries (ldd, ldconfig, localedef, getconf...) are absent
#     from the tree: vngrd's own glibc installs them.
#
# The seed's only declared dependency-in-domain is `audit`, used by
# elements/audit-tools.bst: it names the handful of tools the rootfs audit
# needs, so that check never has to stage coreutils' own find/grep on top of
# the tree it is auditing.
kind: import

sources:
- kind: local
  path: elements/seed

public:
  bst:
    # The one thing the seed does to the sandbox it is staged into rather than
    # through the files it ships.
    #
    # packages/glibc.bst builds glibc with the merged-/usr interpreter baked
    # in at link time -- vngrd-rootfs/packages/glibc/build explains why
    # relocating the file afterwards is not an option -- and glibc's configure
    # COMPILES AND RUNS conftest programs, so that path has to resolve while
    # glibc is the thing installing it. BuildStream stages dependencies and
    # then runs a dependency's integration-commands in the build sandbox before
    # the build starts, which is the hook for exactly this: point the merged
    # path at the seed's own loader for the duration.
    #
    # The guard is load-bearing. In every OTHER sandbox -- anything built
    # against base.bst -- the real vngrd loader IS staged at that path, and
    # overwriting it with a symlink to Debian's would run vngrd's binaries on
    # Debian's libc and produce the loader's GLIBC_PRIVATE handshake failure
    # ("undefined symbol: __pointer_chk_guard"). So: only if it does not exist.
    integration-commands:
    - |
      if [ ! -e /usr/lib/ld-linux-x86-64.so.2 ]; then
        ln -s /lib64/ld-linux-x86-64.so.2 /usr/lib/ld-linux-x86-64.so.2
      fi

    split-rules:
      audit:
      - /bin
      - /bin/**
      - /usr/bin/sh
      - /usr/bin/bash
      - /usr/bin/cat
      - /usr/bin/dirname
      - /usr/bin/basename
      - /usr/bin/find
      - /usr/bin/grep
      - /usr/bin/head
      - /usr/bin/ls
      - /usr/bin/readlink
      - /usr/bin/sed
      - /usr/bin/llvm-readelf
      # The library closure of the above, at their real path. /bin/sbin's
      # libselinux/libpcre2 (Debian grep/sed/find link them) and llvm-readelf's
      # libLLVM all live here.
      - /usr/lib/x86_64-linux-gnu/**
      # ...and the loader those binaries ask for by their PT_INTERP,
      # /lib64/ld-linux-x86-64.so.2, which the seed keeps as a symlink to
      # usr/lib64. Without it execve fails with ENOENT and bwrap reports the
      # interpreter as a missing command: "execvp sh: No such file or
      # directory", which reads like a missing shell rather than a missing
      # loader.
      - /lib64
      - /lib64/**
      - /usr/lib64
      - /usr/lib64/**

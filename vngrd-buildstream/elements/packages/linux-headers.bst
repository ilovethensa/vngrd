# Linux kernel headers -- what every userspace element compiles against.
#
# A `make` element, and the whole build is one line upstream: the kernel's own
# headers_install target. Nothing vngrd does to it survives a version bump
# elsewhere, so the element is deliberately tiny.
#
# The plugin's `make` and `make-install` variables are overridden rather than
# its `make-args`, because headers_install takes its destination from
# INSTALL_HDR_PATH (an absolute path -- it is not a DESTDIR-style install) and
# the plugin's defaults pass PREFIX and DESTDIR, neither of which
# headers_install reads. `install` is NOT a target here: the kernel's install
# target does far more than headers_install (modules, depmod scripts) and
# would fail in a sandbox with no kernel build tree.
kind: make

build-depends:
- seed.bst

environment:
  # headers_install compiles no kernel code, but it is a prerequisite of the
  # build's own host tools (scripts/basic/fixdep), and those need C library
  # headers. There is no vngrd libc in this sandbox -- one is being built, and
  # it is not this package -- and the seed's Debian headers are relocated to
  # /usr/lib/debian-headers, so name them the way the compiler itself does.
  # C_INCLUDE_PATH rather than -I, because a kernel Makefile does not take
  # CFLAGS from the command line without fighting its own KBUILD_CFLAGS.
  #
  # TWO directories, because on Debian the arch-specific C library headers are
  # in /usr/include/<triplet> and the compiler's system paths name it directly:
  # sys/types.h is not in /usr/include at all. The seed preserves that layout
  # under /usr/lib/debian-headers.
  #
  # Nothing compiled here is installed: headers_install copies headers from the
  # source tree, so the Debian headers never reach the artifact.
  C_INCLUDE_PATH: /usr/lib/debian-headers:/usr/lib/debian-headers/x86_64-linux-gnu

variables:
  # NOT %{make-args}, and that is not fussiness. project.conf's make-args carry
  # the autotools convention (`prefix=/usr libdir=... CC=clang AR=llvm-ar`),
  # GNU make exports command-line variables to the environment of everything
  # it runs, and this package's build consumes one of them for a completely
  # unrelated purpose: arch/x86/entry/syscalls/Makefile has
  #
  #     prefix :=
  #     cmd_syshdr = ... $(if $(prefix),--prefix $(prefix)) ...
  #
  # so `prefix=/usr` reach scripts/syscallhdr.sh as the PREFIX OF A MACRO NAME.
  # Every generated syscall number came out as `#define __NR_/usrread 0`, the
  # headers installed with /usr glued into 385 syscall names, and libcap and
  # libseccomp then failed with "use of undeclared identifier 'SYS_capset'" --
  # a kernel bug that was really a make-variable collision three elements away.
  #
  # The kernel needs none of the project's variables: headers_install compiles
  # no kernel code, the host tools it does build (fixdep, unifdef, rsync) use
  # their own HOSTCC default of gcc, and INSTALL_HDR_PATH is the only option
  # that decides where the headers land. SHELL= stays, because GNU make's
  # default is /bin/sh and this tree has no /bin (project.conf, make kind).
  make: make SHELL=/usr/bin/sh ARCH=x86_64 INSTALL_HDR_PATH=%{install-root}/usr headers_install
  make-install: make SHELL=/usr/bin/sh ARCH=x86_64 INSTALL_HDR_PATH=%{install-root}/usr headers_install

config:
  # vngrd-rootfs's packages/linux-headers/build deletes these after the
  # install: .install and ..install.cmd are kbuild's own bookkeeping, and
  # /usr/include/.install collides with glibc's headers for no gain.
  install-commands:
  - |
    %{make-install}
    set -eu
    find "%{install-root}/usr/include" -name '.install' -delete
    find "%{install-root}/usr/include" -name '..install.cmd' -delete

sources:
- kind: tar
  url: https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.7.tar.xz
  ref: 4ac34c47db2540ffb2713943f8d891ff1702e0ba6934525a493b7d1cad43145a

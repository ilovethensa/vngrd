# coreutils 9.7 -- the image's /usr/bin userland. This is THE package the whole
# revolution is about: it used to be built by vngrd-rootfs against a Debian
# builder, and it is now built here against vngrd's own libc.
#
# The flags are vngrd-rootfs's: --enable-no-install-program=arch,hostname,hostid
# (arch and hostname are busybox-isms; hostid is glibc's), plus the two
# gl_cv_func_working_mktime cache entries, which exist because coreutils'
# configure otherwise runs a mktime cross-check test that takes minutes and can
# hang on a slow clock.
#
# FORCE_UNSAFE_CONFIGURE=1 is load-bearing for a different reason: it allows the
# build to run as a uid that does not own the paths it writes.
#
# getconf is NOT excluded here even though vngrd's own glibc installs one: this
# element ships no /usr/bin/getconf of its own (coreutils' getconf is guarded
# by --enable-install-program and vngrd-rootfs's flag list leaves it out of the
# default set it installs), and the overlap check at rootfs.bst is what would
# catch it if that ever changed.
kind: autotools

build-depends:
- seed.bst
- base.bst

environment:
  # coreutils' configure refuses to run as a non-root build uid in a directory
  # it does not own; BuildStream builds as an unprivileged uid, and there is
  # nothing unsafe about it here (DESTDIR is a fresh install root).
  FORCE_UNSAFE_CONFIGURE: '1'

variables:
  conf-local: >-
    --libexecdir=/usr/lib
    --enable-no-install-program=arch,hostname,hostid
    gl_cv_func_working_mktime=yes
    gl_cv_func_working_mktime_internal=yes

config:
  install-commands:
  - |
    %{make-install}
    set -eu
    dest=%{install-root}
    # The binaries the rest of the image calls by name, and that the ported
    # recipes of other packages assume exist (install, dirname, cat, sort...).
    # Assert a representative set rather than trusting the install: a configure
    # change that drops a program would otherwise be discovered by an unrelated
    # package's build.
    for t in ls cat cp mv rm mkdir chmod ln ln readlink dirname basename sort \
             install env printf echo test [ true false head tail cut tr uname \
             id stat date touch sleep seq uniq comm wc mktemp comm od fold \
             paste join csplit expand unexpand fmt pr nl tac shuf sum cksum \
             md5sum b2sum sha1sum sha224sum sha256sum sha384sum sha512sum \
             split truncate timeout yes factor expr; do
      test -x "$dest/usr/bin/$t" || {
        echo "coreutils.bst: $t missing from the install" >&2
        exit 1
      }
    done
    for t in arch hostname hostid; do
      test ! -e "$dest/usr/bin/$t" || {
        echo "coreutils.bst: $t was installed but --enable-no-install-program says no" >&2
        exit 1
      }
    done
    # kill is this package's and not util-linux's: it follows util-linux.bst
    # in vngrd-rootfs's ORDER, so the rootfs's cumulative build shipped
    # coreutils' copy, and packages/util-linux.bst now prunes its own. The
    # shell's `kill` builtin and every recipe's `kill` land on this binary.
    test -x "$dest/usr/bin/kill" || {
      echo "coreutils.bst: kill missing; it is the shipped one (util-linux prunes its copy)" >&2
      exit 1
    }

sources:
- kind: tar
  url: https://ftp.gnu.org/gnu/coreutils/coreutils-9.7.tar.xz
  ref: e8bb26ad0293f9b5a1fc43fb42ba970e312c66ce92c1b0b16713d7500db251bf

# dbus-broker 37 -- the D-Bus implementation systemd's userspace clients use.
#
# Vngrd-rootfs's flags: -Dlauncher=true, no docs/audit/apparmor/selinux, no
# tests (its test suite links libsystemd, which is why this element must come
# after systemd.bst), -Dlinux-4-17=true for the pidfd APIs.
#
# CFLAGS carries -Wno-error=incompatible-pointer-types because vngrd-rootfs's
# recipe did: systemd's headers trip a clang 14+ strictness that is an error
# here and not there.
#
# The c-util subprojects are vendored, for the same reason fish's crates are:
# the build sandbox has no network. Upstream's meson.build resolves seven
# dependencies (libcdvar/libcini/libclist/libcrbtree/libcshquote/libcstdaux/
# libcutf8) whose only source is a wrap-git into github.com/c-util at the
# tags subprojects/*.wrap pins, and vngrd-rootfs's recipe worked by letting
# meson fetch them ("allow network for the wrapper downloads"). Here the
# wraps are matched by pre-cloned directories under files/subprojects/,
# staged beside them, and --wrap-mode=nodownload (project.conf) uses what is
# on disk and fetches nothing: meson resolves a wrap-named directory it finds
# already present, which is a configure that never touches the network.
# Regenerate with scripts/export-subprojects.sh.
kind: meson

build-depends:
- seed.bst
- base.bst
- packages/libcap.bst
- packages/expat.bst
- packages/systemd.bst

environment:
  CFLAGS: "%{cflags} -Wno-error=incompatible-pointer-types"

variables:
  # meson-local, NOT conf-local: conf-local is the autotools plugin's
  # variable and a meson element silently ignores it -- -Dmanpages=false was
  # dropped that way and kmod went looking for scdoc as if nothing had been
  # asked for.
  meson-local: >-
    -Dlauncher=true
    -Ddocs=false
    -Daudit=false
    -Dapparmor=false
    -Dselinux=false
    -Dlinux-4-17=true
    -Dtests=false

config:
  # Vngrd-rootfs's build script installs its own files/ payload over the
  # upstream tree (a dbus.socket enablement and the session/system
  # configuration the launcher reads). vngrd-rootfs had to copy it because the
  # upstream install does not provide it; here the payload is checked in under
  # elements/packages/dbus-broker/files and staged by the local source, and
  # install-commands only has to land it.
  install-commands:
  - |
    set -eu
    dest=%{install-root}
    env DESTDIR="$dest" ninja -C %{build-dir} install
    cp -a usr "$dest/"
    test -e "$dest/usr/bin/dbus-broker" || {
      echo "dbus-broker.bst: dbus-broker missing from the install" >&2
      exit 1
    }
    test -e "$dest/usr/bin/dbus-broker-launch" || {
      echo "dbus-broker.bst: dbus-broker-launch missing (it is the launcher" >&2
      echo "  systemd's dbus.service runs)" >&2
      exit 1
    }
    test -e "$dest/usr/lib/systemd/system/dbus.socket" || {
      echo "dbus-broker.bst: dbus.socket missing from the files payload" >&2
      exit 1
    }

sources:
- kind: tar
  url: https://github.com/bus1/dbus-broker/archive/refs/tags/v37.tar.gz
  ref: c842f844cd052ef1ffacb11da41812c5801c6d1e32450ce26410f1a5143d71bc
- kind: local
  path: elements/packages/dbus-broker/files

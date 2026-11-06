# Linux-PAM 1.7.2 -- the PAM module stack, for systemd-logind's consumers and
# any login path the image ever grows.
#
# Vngrd-rootfs's flags, ported as-is: everything optional off (docs, audit,
# econf, selinux, logind, elogind, openssl, examples, pam_userdb, nis,
# pwaccess) because each of those pulls a dependency the image does not carry.
# -Disadir=/usr/lib/security is merged-/usr: the modules live beside the rest
# of the libraries, not in a top-level /lib/security.
#
# meson, not autotools: upstream converted in 1.6. project.conf's meson plugin
# config already carries --libdir=/usr/lib and the interpreter/linker flags, so
# this element only names what vngrd-rootfs's recipe named.
kind: meson

build-depends:
- seed.bst
- base.bst
- packages/libxcrypt.bst

variables:
  # meson-local, NOT conf-local: conf-local is the autotools plugin's
  # variable and a meson element silently ignores it -- -Dmanpages=false was
  # dropped that way and kmod went looking for scdoc as if nothing had been
  # asked for.
  meson-local: >-
    -Ddocs=disabled
    -Daudit=disabled
    -Deconf=disabled
    -Dselinux=disabled
    -Dlogind=disabled
    -Delogind=disabled
    -Dopenssl=disabled
    -Dexamples=false
    -Dpam_userdb=disabled
    -Dnis=disabled
    -Dpwaccess=disabled
    -Disadir=/usr/lib/security

config:
  install-commands:
  - |
    %{meson-install}
    set -eu
    dest=%{install-root}
    # pam_namespace is dropped, as in vngrd-rootfs's recipe: it needs a
    # mount-namespace helper and a polyinstantiation policy this image has no
    # use for.
    rm -f "$dest/usr/bin/pam_namespace_helper"
    rm -f "$dest/usr/share/pam/security/namespace.init"
    rm -f "$dest/usr/lib/security/pam_namespace.so"
    for gone in usr/bin/pam_namespace_helper usr/lib/security/pam_namespace.so; do
      test ! -e "$dest/$gone" || {
        echo "libpam.bst: $gone should have been pruned but is present" >&2
        exit 1
      }
    done
    for t in pam_unix.so pam_deny.so pam_permit.so pam_env.so; do
      test -e "$dest/usr/lib/security/$t" || {
        echo "libpam.bst: $t missing from the install" >&2
        exit 1
      }
    done

sources:
- kind: tar
  url: https://github.com/linux-pam/linux-pam/releases/download/v1.7.2/Linux-PAM-1.7.2.tar.xz
  ref: 3d86b6383fb5fd9eb9578d2cd47d92801191f4bf3f9bc61419bfefc8aa1e531a

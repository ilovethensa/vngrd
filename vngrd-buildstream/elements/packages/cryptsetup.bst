# cryptsetup 2.8.8 -- LUKS2, the root volume's encryption (repart creates it
# with Encrypt=tpm2, and systemd-cryptsetup opens it).
#
# vngrd-rootfs's flags: --with-crypto_backend=openssl (no gcrypt, no kernel
# keyring backend), --enable-veritysetup because the image's /usr is
# dm-verity-protected and its roothash is verified at boot, --disable-udev
# because udev rules are systemd's business here (and this image uses
# systemd-udevd), --disable-ssh-token because there is no ssh.
#
# popt is a real dependency and not a transitive accident: cryptsetup's
# configure refuses to continue without 1.7 or newer ("You need popt 1.7 or
# newer to compile"), because its tool line is built on it. vngrd-rootfs's
# depends file did not record it -- the package order put popt earlier in the
# tree by accident of the ORDER list -- so here it is declared, which is the
# whole point of doing this in BuildStream.
#
# The DESTDIR/sbin/ move is merged-/usr: cryptsetup installs cryptsetup and
# veritysetup under sbin on some configure paths.
kind: autotools

build-depends:
- seed.bst
- base.bst
- packages/openssl.bst
- packages/json-c.bst
- packages/lvm2.bst
- packages/util-linux-libs.bst
- packages/popt.bst

variables:
  conf-local: >-
    --disable-asciidoc
    --disable-static
    --enable-cryptsetup
    --enable-veritysetup
    --disable-ssh-token
    --disable-udev
    --with-crypto_backend=openssl

config:
  install-commands:
  - |
    %{make-install}
    set -eu
    dest=%{install-root}
    if [ -d "$dest/sbin" ]; then
      mkdir -p "$dest/usr/bin"
      mv "$dest/sbin"/* "$dest/usr/bin/" 2>/dev/null || true
      rmdir "$dest/sbin"
    fi
    test -x "$dest/usr/bin/cryptsetup" || {
      echo "cryptsetup.bst: cryptsetup missing from the install" >&2
      echo "  systemd-cryptsetup@vngrd-root.service runs it to open the root." >&2
      exit 1
    }
    test -e "$dest/usr/bin/veritysetup" || {
      echo "cryptsetup.bst: veritysetup missing from the install" >&2
      echo "  The image's /usr is dm-verity-protected." >&2
      exit 1
    }

sources:
- kind: tar
  url: https://cdn.kernel.org/pub/linux/utils/cryptsetup/v2.8/cryptsetup-2.8.8.tar.xz
  ref: 3acfa685f2dd7fcc832e0b77bc7093aa7da554a51ce8dafbb4138eaa854eee35

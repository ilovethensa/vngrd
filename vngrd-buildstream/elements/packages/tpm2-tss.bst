# tpm2-tss 4.2.0 -- the TPM software stack (libtss2-*), which tpm2-tools
# links and which vngrd-provision.service's enrolment runs through.
#
# autotools with a bootstrap step: the release tarball has no configure, so
# ./bootstrap is run (and vngrd-rootfs's fallback is autoreconf, which the
# autotools plugin would do anyway -- the explicit path is kept because
# vngrd-rootfs's recipe had it and bootstrap is what upstream recommends).
#
# util-linux-libs rather than anything else for uuid: tpm2-tss's pkg-config
# probe requires uuid.pc, which is why vngrd-rootfs's util-linux-libs build
# asserted the file existed. Here it is a declared dependency instead of an
# ordering accident.
#
# --disable-fapi, as in the recipe: FAPI is an optional auto-detect and vngrd
# ships no tss2-fapi. --with-udevrulesdir=/usr/lib/udev/rules.d is merged-/usr
# (upstream's default is /lib/udev).
#
# The /usr/var -> /var move is the recipe's: tpm2-tss installs some things
# under /usr/var, which the tree must not have.
kind: autotools

build-depends:
- seed.bst
- base.bst
- packages/openssl.bst
- packages/json-c.bst
- packages/util-linux-libs.bst

variables:
  conf-local: >-
    --localstatedir=/var
    --runstatedir=/run
    --disable-static
    --enable-esys
    --disable-fapi
    --with-udevrulesdir=/usr/lib/udev/rules.d

config:
  build-commands:
  - |
    set -eu
    if [ ! -f configure ]; then
      ./bootstrap 2>/dev/null || autoreconf -fiv
    fi
    %{configure}
    make -j%{max-jobs} %{make-args}

  install-commands:
  - |
    set -eu
    dest=%{install-root}
    make install DESTDIR="$dest" %{make-args}
    if [ -d "$dest/sbin" ]; then
      mkdir -p "$dest/usr/bin"
      mv "$dest/sbin"/* "$dest/usr/bin/" 2>/dev/null || true
      rmdir "$dest/sbin"
    fi
    if [ -d "$dest/usr/var" ]; then
      mkdir -p "$dest/var"
      mv "$dest/usr/var"/* "$dest/var/" 2>/dev/null || true
      rmdir "$dest/usr/var"
    fi
    rm -rf "$dest/usr/local" 2>/dev/null || true
    test -f "$dest/usr/lib/libtss2-esys.so.0" || {
      echo "tpm2-tss.bst: libtss2-esys.so missing from the install" >&2
      echo "  tpm2-tools links it." >&2
      exit 1
    }

sources:
- kind: tar
  url: https://github.com/tpm2-software/tpm2-tss/releases/download/4.2.0/tpm2-tss-4.2.0.tar.gz
  ref: b53f0c5c8c4ce17f05701a410ca9688f725ca380c9bc4640eacd0eadb1fea124

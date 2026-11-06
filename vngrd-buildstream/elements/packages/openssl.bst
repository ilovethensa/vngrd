# openssl 3.6.4 -- the TLS and crypto library the image links against
# (systemd's -Dopenssl=enabled, cryptsetup's --with-crypto_backend=openssl,
# kmod's -Dopenssl=enabled, tpm2-tools).
#
# `manual` rather than the autotools kind: openssl's Configure is NOT autoconf,
# it takes its own "no-ssl3 no-tests" flag spelling, and the install target
# installs a pkgconfig directory the autotools plugin's defaults would fight.
# The flags are vngrd-rootfs's, verbatim, including the --libdir=lib spelling
# (openssl resolves a relative libdir against the prefix, so lib means
# /usr/lib).
#
# engines/ and the ossl-modules directory come out of the install because
# vngrd-rootfs's recipe left them in place and mkdir -p only asserted
# pkgconfig; this element is the same install, stated without the dead
# directory creation.
kind: manual

build-depends:
- seed.bst
- base.bst

config:
  build-commands:
  - |
    set -eu
    ./Configure --prefix=/usr --libdir=lib --openssldir=/etc/ssl no-ssl3 no-tests
    make -j"$(nproc)"

  install-commands:
  - |
    set -eu
    make DESTDIR="%{install-root}" install
    test -f "%{install-root}/usr/lib/libcrypto.so.3" || {
      echo "openssl.bst: libcrypto.so.3 missing from the install" >&2
      exit 1
    }
    test -f "%{install-root}/usr/include/openssl/ssl.h" || {
      echo "openssl.bst: openssl/ssl.h missing from the install" >&2
      exit 1
    }

  strip-commands: []

sources:
- kind: tar
  url: https://www.openssl.org/source/openssl-3.6.4.tar.gz
  ref: 9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef

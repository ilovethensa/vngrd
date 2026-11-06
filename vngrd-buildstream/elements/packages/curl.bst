# curl 8.22.0 -- present because systemd links libcurl: meson gates importd
# (and therefore systemd-import/systemd-pull, which systemd-sysupdate execs for
# every transfer) on HAVE_LIBCURL.
#
# Not used at runtime yet -- updates are staged from a local directory
# (Type=regular-file), which needs no network -- and the flags are deliberately
# minimal for that reason: TLS via openssl, deflate via zlib, nothing else. No
# nghttp2/libpsl/brotli/zstd/idn2/ssh2/brotli: none is reachable through the
# systemd import path, and each would drag its own closure into a runtime
# dependency tree nothing calls.
#
# The LD_LIBRARY_PATH sed is NOT ported. It existed for vngrd-rootfs's builder,
# where curl's configure exported LD_LIBRARY_PATH=$CURL_LIBRARY_PATH around a
# --sysroot link test and then every later host command -- cat, sed, sort, sh
# -- resolved libc through the sysroot and died on the loader's private-symbol
# handshake. In this sandbox there is no sysroot: the vngrd libc is staged at
# /usr/lib alongside the seed's, and LDFLAGS names it once. Kept as a comment
# because the failure it describes is the same one this whole arrangement was
# built to avoid, and the next person to add a --sysroot will meet it again.
#
# Merged-/usr: curl installs wcurl and curl-config with #!/bin/sh shebangs,
# which this image has no POSIX shell to run -- but unlike zstdgrep/ldd these
# are *development helpers* whose interpreter path is the only thing wrong, so
# they are rewritten rather than dropped, as vngrd-rootfs's recipe did.
kind: autotools

build-depends:
- seed.bst
- base.bst
- packages/openssl.bst
- packages/zlib.bst

variables:
  conf-local: >-
    --with-openssl
    --with-zlib
    --without-nghttp2
    --without-libpsl
    --without-brotli
    --without-zstd
    --without-libidn2
    --without-libssh2
    --without-librtmp
    --without-gssapi
    --without-libgsasl
    --without-hyper
    --disable-ldap
    --disable-ldaps
    --disable-rtsp
    --disable-dict
    --disable-telnet
    --disable-tftp
    --disable-pop3
    --disable-imap
    --disable-smtp
    --disable-gopher
    --disable-mqtt
    --disable-manual
    --disable-docs
    --disable-static
    --enable-shared

config:
  install-commands:
  - |
    %{make-install}
    set -eu
    dest=%{install-root}
    for s in usr/bin/wcurl usr/bin/curl-config; do
      if [ -f "$dest/$s" ]; then
        sed -i '1s|^#!/bin/|#!/usr/bin/|' "$dest/$s"
      fi
    done
    if [ -d "$dest/sbin" ]; then
      mkdir -p "$dest/usr/bin"
      mv "$dest/sbin"/* "$dest/usr/bin/" 2>/dev/null || true
      rmdir "$dest/sbin"
    fi
    test -f "$dest/usr/lib/libcurl.so.4" || {
      echo "curl.bst: libcurl.so.4 missing from the install" >&2
      echo "  systemd.bst links libcurl for importd." >&2
      exit 1
    }

sources:
- kind: tar
  url: https://curl.se/download/curl-8.22.0.tar.xz
  ref: f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7

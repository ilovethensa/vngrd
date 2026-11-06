# ca-certificates -- Mozilla's root store, as published by curl.se.
#
# Why a package: the base system carried no trust anchors, so every TLS client
# in the tree would fail verification. That matters for systemd-sysupdate once
# its source is url-file, which is downloaded with libcurl.
#
# The bundle is a `remote` source with a sha256 ref: this is the one element in
# the project whose input is a live upstream certificate file rather than a
# release tarball, so it is pinned the way the tarballs are -- the old
# checksums file said SKIP, and "a file that changes under you" is exactly what
# a ref is for.
#
# The rest is data from elements/packages/ca-certificates/files, copied
# verbatim: a tmpfiles rule that exposes the store under /etc at boot, because
# /etc on a running system is the writable root populated from the factory
# tree rather than anything in this package's own output.
kind: manual

build-depends:
- seed.bst

sources:
- kind: remote
  url: https://curl.se/ca/cacert.pem
  ref: a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505
- kind: local
  path: elements/packages/ca-certificates/files

config:
  build-commands: []

  install-commands:
  - |
    set -eu
    dest=%{install-root}
    bundle=cacert.pem

    # Sanity check: a truncated download, or an HTML error body, must fail
    # here rather than at some unrelated TLS handshake later. The count is
    # vngrd-rootfs's floor.
    n=$(grep -c 'BEGIN CERTIFICATE' "$bundle")
    [ "$n" -gt 50 ] || {
      echo "ca-certificates.bst: only $n certificates in $bundle, refusing" >&2
      exit 1
    }
    echo "ca-certificates.bst: $n CA certificates ($(wc -c < "$bundle") bytes)"

    # A local source that points at a directory is staged by its CONTENTS
    # (the same staging that puts a kernel tarball at the build root rather
    # than under linux-7.2.7/), so the payload arrives as usr/ here.
    # `cp -a usr "$dest/"` and not `cp -a usr/. "$dest/"`: the first copies the
    # directory itself ($dest/usr/), the second copies its *contents*
    # ($dest/lib/), which is the difference between the payload landing in the
    # right place and a tmpfiles rule nobody can find. vngrd-rootfs's recipe
    # said `files/.` because there the payload root was files/ and the staging
    # prefix it stripped was the package directory, not the tree root.
    cp -a usr "$dest/"
    install -Dm644 "$bundle" "$dest/usr/share/ca-certificates/mozilla.crt"

    test -s "$dest/usr/share/ca-certificates/mozilla.crt" || {
      echo "ca-certificates.bst: mozilla.crt missing from the install" >&2
      exit 1
    }
    test -e "$dest/usr/lib/tmpfiles.d/10-ca-certificates.conf" || {
      echo "ca-certificates.bst: the tmpfiles rule that exposes /etc/ssl is missing" >&2
      exit 1
    }

  strip-commands: []

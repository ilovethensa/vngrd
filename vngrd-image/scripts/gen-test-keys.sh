#!/usr/bin/env bash
# gen-test-keys.sh — create the signing key pairs a fresh checkout needs.
#
# Produces, under keys/local/ (gitignored via .gitignore: keys/local/ is listed there):
#   secureboot.key / secureboot.crt   PK/KEK/db signing pair for the UKI + sd-boot
#   pcr.key       / pcr.crt           RSA pair the .pcrsig is signed with
#
# The PCR pair must be RSA: systemd's PolicyAuthorize hardcodes
# TPM2_ALG_RSASSA/SHA256, and lib/image.sh refuses anything else.
#
# These are test/WIP keys. For a production key set, generate the pairs on the
# machine that will keep them, enrol PK/KEK/db from trusted media (see the
# README "Secure Boot key lifecycle"), and keep the private halves off the
# build and target machines at rest. Nothing here makes that decision for you.
#
# Refuses to overwrite any existing pair: keys are the identity of every image
# signed with them, and replacing one silently strands every provisioned root
# sealed to the old .pcrpkey.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")/.." && pwd)
KEYDIR=$HERE/keys/local

mkdir -p "$KEYDIR"

for name in secureboot pcr; do
    for ext in key crt; do
        if [ -s "$KEYDIR/$name.$ext" ]; then
            echo "gen-test-keys: $KEYDIR/$name.$ext already exists — not overwriting." >&2
            echo "  Delete it by hand if you are sure; replacing a key strands every" >&2
            echo "  root sealed to it. See the header of this script." >&2
            exit 1
        fi
    done
done

echo "==> generating Secure Boot key pair (RSA 2048, 10y) in keys/local/"
openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj '/CN=vngrd Secure Boot/' \
    -keyout "$KEYDIR/secureboot.key" -out "$KEYDIR/secureboot.crt"

echo "==> generating PCR signing key pair (RSA 2048, 10y) in keys/local/"
openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj '/CN=vngrd PCR Signing/' \
    -keyout "$KEYDIR/pcr.key" -out "$KEYDIR/pcr.crt"

chmod 0600 "$KEYDIR"/*.key

cat <<EOF

Done. keys/local/ now holds:

  secureboot.key / secureboot.crt
  pcr.key        / pcr.crt          (RSA — required by the TPM PolicyAuthorize)

mkosi.conf defaults SignExpectedPcrKey/Certificate to keys/local/, so no
mkosi.conf.d/50-local-keys.conf is needed for the PCR pair. If you kept
SecureBootKey in mkosi.conf.d/50-local-keys.conf, point it at
keys/local/secureboot.key or leave your existing paths.

Next steps:
  1. ./build.sh              (fails in lib/image.sh if anything is still missing)
  2. Enrol PK/KEK/db from trusted media with the machine in setup mode
     (output/image/secureboot/PK.auth, KEK.auth, db.auth — never from the
     image's own ESP):

       efi-updatevar -f PK.auth PK
       efi-updatevar -f KEK.auth KEK
       efi-updatevar -f db.auth db
       efi-readvar -v db

Re-running this script is a no-op while the files exist.
EOF

#!/bin/sh -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Podman is a drop-in for everything used here: set DOCKER=podman.
DOCKER=${DOCKER:-docker}

${DOCKER} run --rm \
    -v "$ROOT:/vngrd" \
    vngrd-kernel-builder \
    sh -c 'rm -rf /vngrd/out /vngrd/work /vngrd/sources 2>/dev/null || true' \
    2>/dev/null || true

rm -rf "$ROOT/out" "$ROOT/work" "$ROOT/cache" "$ROOT/.cache"
rm -rf "$ROOT/../output/kernel"

echo "Cleaned out/, work/, cache/, ../output/kernel/"

#!/bin/sh -e

# Podman is a drop-in for everything used here: set DOCKER=podman.
DOCKER=${DOCKER:-docker}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

${DOCKER} run --rm \
    -v "$ROOT:/vngrd" \
    vngrd-builder \
    sh -c 'rm -rf /vngrd/out /vngrd/work /vngrd/sources /vngrd/bin /vngrd/cache /vngrd/.cache 2>/dev/null || true'

rm -rf \
    "$ROOT/out" \
    "$ROOT/work" \
    "$ROOT/sources" \
    "$ROOT/bin" \
    "$ROOT/cache" \
    "$ROOT/.cache" \
    "$ROOT/../output/rootfs" 2>/dev/null || true

echo "Cleaned out/, work/, sources/, bin/, .cache/, ../output/rootfs/"

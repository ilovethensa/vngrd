#!/bin/sh -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$ROOT/toolchain"

mkdir -p "$TOOLCHAIN"

ARCH="${ARCH:-x86-64}"
BOOTLIN_URL="https://toolchains.bootlin.com/releases/${ARCH}/toolchain.tar.bz2"

if [ ! -d "$TOOLCHAIN/bootlin" ]; then
    echo "Fetching Bootlin toolchain for $ARCH..."
    curl -L "$BOOTLIN_URL" -o /tmp/toolchain.tar.bz2
    mkdir -p "$TOOLCHAIN/bootlin"
    tar -xjf /tmp/toolchain.tar.bz2 -C "$TOOLCHAIN/bootlin" --strip-components=1
    rm -f /tmp/toolchain.tar.bz2
    echo "Toolchain installed to $TOOLCHAIN/bootlin"
else
    echo "Toolchain already present."
fi

echo "Done."

#!/bin/bash
# build.sh — build the vngrd disk image. No arguments.

set -euo pipefail
cd "$(dirname "$0")"
source lib/common.sh
source lib/initrd.sh
source lib/image.sh

main() {
    check_inputs
    build_initrd
    mkosi_build
    verify_uki
    extend_gpt
    refresh_raw_checksum
    sweep_stale
    note "done: $IMAGE_DIR/vngrd_$(image_version).raw"
}

main "$@"

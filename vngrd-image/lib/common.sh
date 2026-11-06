# shellcheck shell=bash
# Shared path constants and helpers. Sourced, never executed.

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT=$HERE/../output
ROOTFS=$OUT/rootfs
KERNEL=$OUT/kernel
INITRD_ROOT=$OUT/initrd-root
IMAGE_DIR=$OUT/image
TOOLS=$HERE/mkosi.tools/usr

note() { printf '%s: %s\n' "${0##*/}" "$*" >&2; }
die()  { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }
require() { [[ -e $1 ]] || die "missing $1${2:+ — $2}"; }

# read_list <file> — one path per line, '#' starts a comment. Path lists only:
# the reason-bearing allowlists are grepped directly.
read_list() {
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^[[:space:]]*$' || true
}

# mkosi_setting <key> — same resolution order as mkosi itself; last non-empty wins.
mkosi_setting() {
    local key=$1 val="" f v
    if [[ -f $HERE/mkosi.conf ]]; then
        val=$(sed -n "s/^$key=//p" "$HERE/mkosi.conf" | tail -n 1 || true)
    fi
    for f in "$HERE"/mkosi.conf.d/*.conf; do
        [[ -f $f ]] || continue
        v=$(sed -n "s/^$key=//p" "$f" | tail -n 1 || true)
        [[ -n $v ]] && val=$v
    done
    printf '%s' "$val"
}

# image_version — $IMAGE_VERSION overrides the configured ImageVersion.
image_version() { printf '%s' "${IMAGE_VERSION:-$(mkosi_setting ImageVersion)}"; }

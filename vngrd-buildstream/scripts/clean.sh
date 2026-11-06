#!/bin/sh
# Remove the four generated trees.
#
# They are ordinary files owned by the caller -- the exports run as this user,
# not as root in a container, which is the one way this is simpler than the
# old arch-base bootstrap it replaces. --all also drops the BuildStream caches
# the builds wrote, which is the "wipe the workspace" answer for a from-scratch
# build check; the trees alone are the "regenerate the inputs" answer.
set -eu

cd "$(dirname "$0")/.."

all=0
[ "${1:-}" = "--all" ] && { all=1; shift; }

# One well-formed probe file per tree, matching scripts/build.sh's checks: a
# half-deleted tree fails those checks too, so regenerating is always an option.
for tree in \
    elements/seed \
    elements/toolchain/rust \
    elements/packages/fish/files/vendor \
    elements/packages/dbus-broker/files/subprojects
do
    if [ -e "$tree" ]; then
        echo "==> removing $tree"
        rm -rf "$tree"
    fi
done

if [ "$all" = 1 ]; then
    for cache in ~/.cache/buildstream .cache; do
        if [ -e "$cache" ]; then
            echo "==> removing $cache"
            rm -rf "$cache"
        fi
    done
else
    echo "==> (caches kept; clean.sh --all removes them too)"
fi

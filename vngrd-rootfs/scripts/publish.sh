#!/bin/sh -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
OUTPUT="$ROOT/../output/rootfs"

[ -d "$OUT" ] || { echo "No $OUT — run scripts/01-build.sh first" >&2; exit 1; }

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

tar -C "$OUT" \
    --exclude=./.stamps \
    --exclude=./var/db \
    --exclude=./etc/credstore \
    --exclude=./etc/credstore.encrypted \
    -cf - . | tar -C "$OUTPUT" -xf -

for d in bin sbin lib lib64; do
    [ -e "$OUTPUT/$d" ] || [ -L "$OUTPUT/$d" ] || continue
    if [ "$d" = lib ] && [ -d "$OUTPUT/lib/modules" ]; then continue; fi  # kernel modules
    echo "ERROR: $OUTPUT/$d violates the hermetic layout — no top-level /bin, /sbin, /lib, /lib64 (AGENTS.md)" >&2
    exit 1
done
# /usr must contain only bin, include, lib, share (catches dotfiles too)
strays="$(find "$OUTPUT/usr" -mindepth 1 -maxdepth 1 \
    ! -name bin ! -name include ! -name lib ! -name share \
    -printf '%f\n' 2>/dev/null || true)"
if [ -n "$strays" ]; then
    echo "ERROR: forbidden entries under /usr (only bin, include, lib, share allowed) — AGENTS.md:" >&2
    echo "$strays" | sed 's/^/  usr\//' >&2
    exit 1
fi

bad_refs="$(grep -r --exclude-dir=credstore --exclude-dir=credstore.encrypted -l '"/\(bin\|sbin\|lib\)/' "$OUTPUT" 2>/dev/null | grep -E '\.(service|socket|target|mount|conf|sh|py)$' | head -n 20 || true)"
hard_bad="$(grep -R -n 'ExecStart=.*/sbin/\(agetty\|modprobe\|ldconfig\)' "$OUTPUT" 2>/dev/null | head -n 20 || true)"
hard_bad2="$(grep -R -n '"/sbin/\|"/bin/\| /sbin/\| /bin/' "$OUTPUT/usr/lib/systemd" 2>/dev/null | grep -v '/usr/bin' | grep -v '/usr/lib' | head -n 20 || true)"
if [ -n "$hard_bad" ] || [ -n "$hard_bad2" ]; then
    echo "ERROR: found references to /sbin or /bin outside /usr in OUTPUT (package must fix, not publish.sh):" >&2
    echo "$hard_bad" >&2
    echo "$hard_bad2" >&2
    echo "hint: systemd units/*.in hardcode /sbin/agetty — patch in packages/systemd/build to /usr/bin/agetty" >&2
    exit 1
fi

echo "Published $OUT -> $OUTPUT (hermetic layout verified)"
du -sh "$OUTPUT" | sed 's/^/  size: /'

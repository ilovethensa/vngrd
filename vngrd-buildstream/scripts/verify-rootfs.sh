#!/bin/sh
# Verify a vngrd rootfs against the filesystem contract.
#
# Usage: verify-rootfs.sh <tree>          (e.g. a bst artifact checkout)
#
# Environment overrides, so the same script runs on a host and inside a
# BuildStream sandbox whose tools have different names:
#
#   READELF  (host default: readelf; sandbox: /usr/bin/llvm-readelf)
#   FIND     (both: find)
#   GREP     (both: grep)
#
# Invoked by elements/verify.bst with the rootfs at /staged and the unfiltered
# base at / (which supplies the tools; the runtime image rightly has none of
# them). Rules come from AGENTS.md and vngrd-rootfs/scripts/verify.sh:

set -eu

root=${1:?usage: verify-rootfs.sh <tree>}
fail=0
note() { printf '  %-58s %s\n' "$1" "$2"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }

READELF=${READELF:-readelf}
FIND=${FIND:-find}
GREP=${GREP:-grep}

printf 'verifying %s\n' "$root"

# A tree with no populated /usr/bin is a staging bug, not a pass. This guard
# exists because an earlier version of the verify element checked its own
# empty install tree, printed "ELF files inspected: 0" and passed vacuously.
[ -d "$root/usr/bin" ] && [ -n "$(ls -A "$root/usr/bin")" ] || {
  echo "$root has no populated /usr/bin; not verifying anything" >&2
  exit 1
}

# --- merged /usr -----------------------------------------------------------
for d in bin sbin lib lib64 lib32; do
  if [ -e "$root/$d" ] || [ -L "$root/$d" ]; then
    bad "top-level /$d exists (AGENTS.md forbids it, symlink or not)"
  else
    note "/$d absent" ok
  fi
done

# --- what is allowed directly under /usr ------------------------------------
for e in "$root"/usr/*; do
  [ -e "$e" ] || continue
  case "$(basename "$e")" in
    bin|lib|include|share) ;;
    *) bad "unexpected entry under /usr: $(basename "$e")" ;;
  esac
done

# --- ELF invariants ----------------------------------------------------------
nelf=0
for f in $("$FIND" "$root" -type f); do
  head -c 4 "$f" 2>/dev/null | "$GREP" -q $'\x7fELF' || continue
  nelf=$((nelf + 1))

  interp=$("$READELF" -p .interp "$f" 2>/dev/null \
           | sed -n 's/.*\[ *0\? *\] *//p' | head -1)
  if [ -n "$interp" ]; then
    [ "$interp" = /usr/lib/ld-linux-x86-64.so.2 ] || \
      bad "${f#$root/} has PT_INTERP $interp"
    [ -e "$root$interp" ] || bad "${f#$root/}: interpreter $interp not in the tree"
  fi

  # An unresolvable DT_NEEDED is a binary that will not start.
  #
  # Resolved the way the loader resolves it, not the way a simple "$root/usr/lib"
  # check does, because glibc's gconv modules link their SIBLINGS by soname
  # (libKSC.so, libJISX0213.so, ...) with DT_RUNPATH=/usr/lib/gconv. A
  # $root/usr/lib-only check reports eleven of them as missing on a tree that
  # loads every one of them at boot; what actually matters is that every soname
  # resolves somewhere inside the tree, whether that is /usr/lib, the file's own
  # directory (which is how gconv finds its siblings), or a runpath entry.
  dir=$(dirname "$f")
  rpaths=$("$READELF" -d "$f" 2>/dev/null \
             | sed -n 's/.*(\(RPATH\|RUNPATH\)).*\[\(.*\)\]/\2/p')
  for n in $("$READELF" -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'); do
    case "$n" in
      linux-vdso.so.*) continue ;;
    esac
    found=0
    for d in "$root/usr/lib" "$root/lib" "$dir" $(printf '%s\n' "$rpaths" | while IFS= read -r rp; do
              case "$rp" in
                '') ;;
                /*) echo "$root$rp" ;;
                '$ORIGIN'*) echo "${dir}/${rp#'$ORIGIN'}" ;;
                *) echo "$dir/$rp" ;;
              esac
            done); do
      if [ -e "$d/$n" ]; then found=1; break; fi
    done
    [ "$found" = 1 ] || bad "${f#$root/} needs $n, which is not in the tree"
  done

  # A runpath is allowed when it points INSIDE the image, and forbidden when
  # it escapes it. Two shapes exist in this tree, both load-bearing:
  #
  #   $ORIGIN            glibc's gconv modules find their sibling charset
  #                       modules that way -- the file's own directory, inside
  #                       the tree by construction;
  #   /usr/lib/systemd   upstream systemd's install_rpath (meson.build:
  #                       executable_template), on the 135 tools that link
  #                       libsystemd-shared. The image runs no ldconfig and
  #                       /usr/lib/systemd is not a loader default, so this is
  #                       the ONLY thing that resolves those DT_NEEDED at
  #                       runtime -- every distro ships it.
  #
  # What the rule exists to catch is the other shape: an absolute path baked
  # from the BUILD. vngrd-rootfs's fish shipped RUNPATH=/out/usr/lib, the
  # staging root of that build, which is not a path any shipped machine has.
  # Resolving to a missing inside-the-tree directory fails for the same
  # reason: the runpath is a promise about where a library lives, and it is
  # not true here.
  #
  # Word-split through `for`, because the load path is colon-separated and the
  # auditor's tool set has no tr: sed turns the colons into spaces and the
  # unquoted expansion splits on them. A runpath containing whitespace is not
  # a path this image can have.
  for rp in $("$READELF" -d "$f" 2>/dev/null \
              | sed -n 's/.*(\(RPATH\|RUNPATH\)).*\[\(.*\)\]/\2/p' \
              | sed 's/:/ /g'); do
    case "$rp" in
      '') ;;
      '$ORIGIN'*) ;;
      /*) [ -d "$root$rp" ] || bad "${f#$root/} runpath $rp is not in the tree" ;;
      *) [ -d "$dir/$rp" ] || bad "${f#$root/} runpath $rp is not in the tree" ;;
    esac
  done
done
note "ELF files inspected" "$nelf"
[ "$nelf" -gt 0 ] || bad "no ELF files found; the tree has no binaries"

# --- symlinks ----------------------------------------------------------------
# -e rather than -L, so a dangling link is a failure: it points at something
# the image does not contain. One exception: a link into a kernel mountpoint
# that exists only once the image is booted. /etc/mtab -> /proc/self/mounts
# and /var/lock -> /run/lock are correct as shipped; the directories appear
# when the kernel mounts proc, sysfs, devtmpfs and tmpfs on /run.
for l in $("$FIND" "$root" -type l); do
  t=$(readlink "$l")
  case "$t" in
    /out/*|/work/*|/build/*|/nix/store/*)
      bad "symlink into the build host: ${l#$root/} -> $t" ;;
  esac
  if [ ! -e "$l" ]; then
    case "$t" in
      /*) target=$t ;;
      *)  target="$(dirname "$l")/$t" ;;
    esac
    case "$target" in
      /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) ;;
      *) bad "dangling symlink: ${l#$root/} -> $t" ;;
    esac
  fi
done

# --- shebangs ----------------------------------------------------------------
# vngrd has no POSIX shell at all (its /usr/bin/sh is fish), so a #!/bin/sh
# script can never run. Anchored on the shebang: a bare \b/(bin|sbin)/ also
# matches inside /usr/bin/env, which flags every script whose interpreter
# merely lives under /usr/bin.
for f in $("$FIND" "$root" -type f); do
  head -c 128 "$f" 2>/dev/null | head -1 | "$GREP" -qE '^#! */(bin|sbin)/' && \
    bad "${f#$root/} has a shebang under /bin or /sbin"
done

# --- no foreign paths --------------------------------------------------------
if "$GREP" -rlI --exclude='*.a' -e '/nix/store' -e '/out/usr' "$root" 2>/dev/null \
    | "$GREP" -q .; then
  bad "build-host paths present in the tree"
else
  note "no /nix/store or /out/usr references" ok
fi

if [ "$fail" -ne 0 ]; then
  echo "rootfs verification FAILED" >&2
  exit 1
fi
echo "rootfs verification passed"

# tpm2-tools 5.8 -- pruned to the five subcommands the image actually runs.
#
# The suite is ~90 tools and several of them are attacker-reachable paths to
# the same TPM (tpm2_createloadedpolicy, tpm2_import, tpm2_setprimarypolicy)
# that nothing here needs, so the install is reduced to an explicit allow-list
# rather than a prefix glob -- a future rename then shows up as a build failure
# here instead of a missing binary in the initrd.
#
#   tpm2_nvdefine/read/write/undefine   the fixate hash
#   tpm2_eventlog                        the PCR 5 self-report, run once by
#                                       vngrd-provision.service
#
# The libcurl dependency edge is real: tpm2-tools' configure links curl
# unconditionally. tpm2_eventlog is not part of the fixate mechanism -- it is
# kept because vngrd-provision.service runs it to report whether the TPM still
# answers, which is the difference between a sealed volume that will not open
# and a sealed volume that does not know why.
kind: autotools

build-depends:
- seed.bst
- base.bst
- packages/tpm2-tss.bst
- packages/openssl.bst
- packages/curl.bst
- packages/popt.bst
# zlib.bst is not a library tpm2-tools links directly -- it is the pkg-config
# closure. tpm2-tools finds libcurl via libcurl.pc, whose Requires.private
# names zlib, and pkg-config then resolves THAT against what is staged. A
# BuildStream element stages its dependencies' artifacts, not their
# dependencies, so without zlib.bst here the configure's pkg-config probe
# fails on "Package 'zlib', required by 'libcurl', not found". vngrd-rootfs
# never saw this: its cumulative out/ had every .pc in the tree by the time
# anything configured.
- packages/zlib.bst

variables:
  conf-local: >-
    --localstatedir=/var
    --runstatedir=/run
    --disable-static
    --disable-fapi
    --disable-unit
    --disable-dependency-tracking

config:
  install-commands:
  - |
    set -eu
    dest=%{install-root}
    make install DESTDIR="$dest" %{make-args}

    keep="tpm2 tpm2_nvdefine tpm2_nvread tpm2_nvwrite tpm2_nvundefine tpm2_eventlog"
    # tpm2 is in the list because it IS the binary: upstream installs one
    # executable and an install-exec-hook symlinks every subcommand name at
    # it. Pruning the target while keeping the symlinks dangles all five, and
    # a dangling symlink is a verify.bst failure.
    for t in $keep; do
      test -x "$dest/usr/bin/$t" || {
        echo "tpm2-tools.bst: $t missing from the install" >&2
        exit 1
      }
    done
    # Everything else goes. Kept as an allow-list, not a prefix glob, so a
    # rename upstream fails the build rather than dropping a tool silently.
    #
    # The per-file flag is `wanted`, NOT `keep`: an earlier version reused the
    # list variable as the flag, so `keep=0` emptied the allow-list on the
    # first file and the prune then deleted every binary in the install --
    # including tpm2 itself, which the keep symlinks point at -- and failed
    # one loop later with a literal `*` and no explanation of why.
    for f in "$dest"/usr/bin/*; do
      b=$(basename "$f")
      wanted=0
      for t in $keep; do [ "$b" = "$t" ] && wanted=1; done
      [ "$wanted" = 1 ] || rm -f "$f"
    done
    for f in "$dest"/usr/bin/*; do
      b=$(basename "$f")
      wanted=0
      for t in $keep; do [ "$b" = "$t" ] && wanted=1; done
      [ "$wanted" = 1 ] || {
        echo "tpm2-tools.bst: $b survived the prune; update the allow-list if it is needed" >&2
        exit 1
      }
    done

  strip-commands: []

sources:
- kind: tar
  url: https://github.com/tpm2-software/tpm2-tools/releases/download/5.8/tpm2-tools-5.8.tar.gz
  ref: 1cb73185cae814b4e15c7c2d0b22642d640faf48775f4156a1fd92edf84bef73

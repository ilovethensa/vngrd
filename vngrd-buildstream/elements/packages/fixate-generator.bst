# vngrd-fixate-generator -- the initrd systemd generator that binds the root
# volume's TPM-released key to this volume.
#
# It is its own element rather than part of base-files because it is its own
# repository with its own build: ../vngrd-fixate-generator, built against
# tpm2-tss, producing the initrd generator and the helper binaries that
# base-files' units drive (vngrd-fixate.service and its enablement ship in
# base-files' payload). The upstream Makefile is used as-is; the two deviations
# are below and both are forced by this project's rules.
#
# The source is vendored under elements/packages/fixate-generator/source rather
# than read from the sibling repository ../vngrd-fixate-generator, because
# BuildStream refuses a `..` component in a local source path and an element
# cannot read outside the project. scripts/export-fixate.sh performs the copy
# and records the revision it came from; the element's cache key moves when the
# copy does, so the rootfs rebuilds with the generator rather than silently
# shipping last month's. The copy deliberately leaves the repository's build/
# behind: its objects are from a hand-built run, and make(1) would find them
# newer than the sources and install them without compiling anything.
#
# What this closes, in one sentence: the TPM's policy attests the boot, not the
# volume, so a substituted root partition with the same PCRs would open. The
# generator makes systemd-cryptsetup check the released key against the digest
# repart froze into a TPM NV register on the boot that created the volume.
kind: manual

build-depends:
- seed.bst
- base.bst
# tpm2-tss for the headers and libraries: the generator is an ESAPI client
# (tss2-esys, tss2-tctildr, tss2-mu, tss2-rc), found through pkg-config, so the
# element that installs those .pc files is the one named here.
- packages/tpm2-tss.bst

sources:
- kind: local
  path: elements/packages/fixate-generator/source

config:
  build-commands:
  - |
    set -eu
    # The repository's build/ carries objects from whenever it was last built
    # by hand; make(1) would treat them as current and produce nothing.
    rm -rf build
    mkdir -p build

    # SYSROOT=/: the sandbox root IS the tree -- BuildStream stages the glibc
    # and tpm2-tss at /, so the --sysroot and -L this Makefile would otherwise
    # point at a copy of the image root are already the root. What does NOT
    # survive that change is the Makefile's LDFLAGS, which writes
    # -Wl,-rpath,$(SYSROOT)/usr/lib: an RPATH of /usr/lib is exactly the
    # artifact verify.bst refuses ("no runpath that escapes the image" exists
    # because a baked-in absolute build path is how the rootfs's fish shipped
    # RUNPATH=/out/usr/lib), and here it is not even needed -- the loader finds
    # /usr/lib by default. So LDFLAGS is the project's, and the tss2 libraries
    # still arrive because the Makefile appends $(TSS2_LIBS) to the link line
    # separately.
    make \
      CC=clang \
      PKG_CONFIG=pkg-config \
      SYSROOT=/ \
      LDFLAGS="%{ldflags}" \
      all

  install-commands:
  - |
    set -eu
    dest=%{install-root}
    # PREFIX=/, not /usr: the Makefile's own BINDIR is
    # $(DESTDIR)$(PREFIX)/usr/lib/systemd/system-generators, so the prefix is
    # the / that the merged-/usr path already contains. PREFIX=/usr spells
    # /usr/usr/lib, which is how a typo'd install looks like a missing binary.
    make \
      CC=clang \
      PKG_CONFIG=pkg-config \
      SYSROOT=/ \
      LDFLAGS="%{ldflags}" \
      PREFIX=/ \
      DESTDIR="$dest" \
      install

    # The generator, at the path systemd compiles in (there is no environment
    # variable for it), plus the helpers under /usr/lib/vngrd so nothing runs
    # them as a generator.
    for f in usr/lib/systemd/system-generators/vngrd-fixate-generator \
             usr/lib/vngrd/vngrd-fixate-nvwrite \
             usr/lib/vngrd/vngrd-fixate-pcr \
             usr/lib/vngrd/vngrd-cmdline-guard \
             usr/lib/vngrd/vngrd-rollback-guard \
             usr/lib/vngrd/vngrd-rollback-commit \
             usr/lib/vngrd/vngrd-gpt-guard \
             usr/lib/vngrd/vngrd-gpt-freeze \
             usr/lib/vngrd/vngrd-esp-guard \
             usr/lib/vngrd/vngrd-esp-freeze \
             usr/lib/vngrd/vngrd-fixate-guard \
             usr/lib/vngrd/vngrd-bootloader-sync \
             usr/lib/vngrd/vngrd-passphrase \
             usr/lib/vngrd/vngrd-secureboot-update; do
      test -x "$dest/$f" || {
        echo "fixate-generator.bst: $f is not installed" >&2
        exit 1
      }
    done

    # Merged-/usr interpreter, like every ELF in the image, and no RPATH.
    for f in usr/lib/systemd/system-generators/vngrd-fixate-generator \
             usr/lib/vngrd/vngrd-fixate-nvwrite \
             usr/lib/vngrd/vngrd-cmdline-guard; do
      readelf -l "$dest/$f" | grep -q 'interpreter: /usr/lib/ld-linux-x86-64.so.2' || {
        echo "fixate-generator.bst: $f has the wrong PT_INTERP" >&2
        exit 1
      }
      if readelf -d "$dest/$f" | grep -qE '\((RPATH|RUNPATH)\)'; then
        echo "fixate-generator.bst: $f carries an RPATH/RUNPATH" >&2
        exit 1
      fi
    done

# xz 5.8.4 -- liblzma and the xz tools. Every xz path in runtime-keep moves
# here with this element: the library and the four names coreutils-era scripts
# still reach for (`xz`, `xzcat`, `xzdec`, `unxz`), the LZMA Utils 4.32
# compatibility links (`lzma`, `unlzma`, `lzcat` -- an install-exec-hook in
# src/xz/Makefile.am), and `lzmadec`/`lzmainfo`.
#
# configure's directory arguments come from the project's conf-global/conf-args
# (--prefix, --libdir, --bindir=/usr/bin, --sbindir, --disable-static); there
# is nothing xz-specific to add.
kind: autotools

# Two paths the seed also stages, and the whitelist is what says vngrd's xz
# wins over the seed's build-time xz in any sandbox that has both. The seed
# needs xz for autopoint, which unpacks gettext's own infrastructure tarball
# with it, and exporting it made the overlap real the moment any element
# depended on this package. Whitelisting on the element whose files are staged
# over is the mechanism BuildStream documents; the alternative it suggests --
# ordering this element above the seed -- does nothing, because staging order
# comes from the resolved graph rather than the declaration.
public:
  bst:
    overlap-whitelist:
    - /usr/bin/xz
    - /usr/bin/unxz

build-depends:
- seed.bst
- base.bst

variables:
  # The fourteen shell wrappers go, as in vngrd-rootfs's recipe. They are
  # pipelines around cmp, diff, egrep, grep, less and more -- and this image
  # carries none of those (the runtime-keep list is coreutils plus a handful
  # of families, deliberately), so `xzgrep` would be a program that fails on
  # its first call. Dropping them at the install step is also where the
  # package proves its own tool set: the assertions below name every path
  # runtime-keep is about to stop carrying, so a release that renamed one
  # fails here rather than by silently emptying the image.
  #
  # The wrappers are listed individually rather than by pattern because the
  # two prefixes (lz*/xz*) and the eight verbs are a closed set -- if a future
  # xz adds a fifteenth, it should show up in the install listing first.
  make-install: |
    make -j1 %{make-install-args}
    rm -f "%{install-root}/usr/bin/lzcmp" "%{install-root}/usr/bin/lzdiff" \
          "%{install-root}/usr/bin/lzegrep" "%{install-root}/usr/bin/lzfgrep" \
          "%{install-root}/usr/bin/lzgrep" "%{install-root}/usr/bin/lzless" \
          "%{install-root}/usr/bin/lzmore" \
          "%{install-root}/usr/bin/xzcmp" "%{install-root}/usr/bin/xzdiff" \
          "%{install-root}/usr/bin/xzegrep" "%{install-root}/usr/bin/xzfgrep" \
          "%{install-root}/usr/bin/xzgrep" "%{install-root}/usr/bin/xzless" \
          "%{install-root}/usr/bin/xzmore"
    for t in xz unxz xzcat xzdec lzmadec lzmainfo lzma unlzma lzcat; do
      test -e "%{install-root}/usr/bin/$t" || {
        echo "xz: $t missing from the install" >&2; exit 1; }
    done
    for t in lzcmp lzdiff lzegrep lzfgrep lzgrep lzless lzmore \
             xzcmp xzdiff xzegrep xzfgrep xzgrep xzless xzmore; do
      test ! -e "%{install-root}/usr/bin/$t" || {
        echo "xz: $t should have been pruned but is present" >&2; exit 1; }
    done

sources:
- kind: tar
  url: https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.xz
  ref: 4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b

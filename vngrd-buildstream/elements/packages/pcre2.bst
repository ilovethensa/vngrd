# pcre2 10.48 -- Perl-compatible regular expressions. Nothing in the image
# links it yet; it is ported here because its `depends` file is glibc only, which
# is what makes it a leaf.
#
# All three code widths and the JIT, as in vngrd-rootfs's recipe. With no
# consumer to satisfy, the widest build is the one that cannot fail the first
# one later, and --enable-unicode is what the 8-bit build needs to match
# UTF-8 expectations rather than byte semantics.
kind: autotools

build-depends:
- seed.bst
- base.bst

variables:
  conf-local: >-
    --enable-pcre2-8
    --enable-pcre2-16
    --enable-pcre2-32
    --enable-jit
    --enable-unicode

  # Two files leave the install, matching vngrd-rootfs's recipe:
  #
  #   pcre2-config  a *build* helper that prints link flags for programs that
  #                 want to compile against pcre2. This image does not build
  #                 anything, and the recipe would rather drop it than claim an
  #                 interpreter it does not have a use for.
  #   pcre2test     an interactive driver for poking at a compiled regex, run
  #                 against the uninstalled .la files in the tree.
  #
  # pcre2grep stays, and its presence is asserted: it is the one program in the
  # package the image could run, and a release that renamed it should fail here
  # rather than three packages later in verify.
  make-install: |
    make -j1 %{make-install-args}
    rm -f "%{install-root}/usr/bin/pcre2-config" "%{install-root}/usr/bin/pcre2test"
    test -x "%{install-root}/usr/bin/pcre2grep" || {
      echo "pcre2: pcre2grep missing from the install" >&2; exit 1; }
    for gone in pcre2-config pcre2test; do
      test ! -e "%{install-root}/usr/bin/$gone" || {
        echo "pcre2: $gone should have been pruned but is present" >&2; exit 1; }
    done

sources:
- kind: tar
  url: https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.48/pcre2-10.48.tar.gz
  ref: ebcc25aadf2a51fa1fefa9b8bc9e7a79b3dae86870a0f1152a22e42befd46888

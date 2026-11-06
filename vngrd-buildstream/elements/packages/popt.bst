# popt 1.19 -- the option parser tpm2-tools links against.
#
# An autotools element with one twist: the release tarball from GitHub is
# autogen-less, so configure is generated first (vngrd-rootfs ran autogen.sh
# when present and fell back to autoreconf). The autotools plugin already runs
# autoreconf for a source tree with no configure (autotools.yaml's
# configure-commands), and this tarball ships neither autogen.sh nor configure,
# so the plugin's own path takes it. There is nothing to add beyond the flags.
kind: autotools

build-depends:
- seed.bst
- base.bst

variables:
  conf-local: >-
    --disable-static

# autotools.yaml runs `autoreconf -ivf %{conf-root}` when the source tree has
# no configure, which is the recipe's documented fallback for a release tarball
# that ships autogen.sh but no configure. The seed carries libtool, so the
# autogen path would work too; the plugin's path is the one that runs.

sources:
- kind: tar
  url: https://github.com/rpm-software-management/popt/archive/refs/tags/popt-1.19-release.tar.gz
  ref: 6eb40d650526cb9fe63eb4415bcecdf9cf306f7556e77eff689abc5a44670060

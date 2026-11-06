# kmod 34 -- modprobe, and the libkmod systemd uses for module loading.
#
# meson, with the same flags vngrd-rootfs used: openssl for module signature
# verification (the kernel is built with module signing enabled), xz/zlib/zstd
# for compressed modules, no tests, no manpages.
#
# One build-time edit, which is not optional: kmod's source hardcodes
# /lib/modules everywhere, and the merged-/usr tree has no /lib. vngrd-rootfs
# did the same sed over the extracted tree; here it runs in build-commands
# before configure, and the paths it rewrites are the module directory and the
# depmod.d configuration directory, both of which must resolve under /usr/lib
# for the image to find any module at all.
kind: meson

build-depends:
- seed.bst
- base.bst
- packages/openssl.bst
- packages/xz.bst
- packages/zlib.bst
- packages/zstd.bst

config:
  # The meson plugin runs its configure-commands first, which is `%{meson}` --
  # so anything that has to happen BEFORE meson (the /lib/modules rewrite, the
  # scdoc optionality) must live in a build-commands that also configures,
  # with the plugin's own configure emptied. Configure is not a separate
  # phase here; it is the first three lines of the build.
  configure-commands: []

  build-commands:
  - |
    set -eu
    find . -type f -exec sed -i 's|/lib/modules|/usr/lib/modules|g' {} + 2>/dev/null || true

    # kmod's man/meson.build looks for scdoc UNCONDITIONALLY and defines a
    # custom_target per man page that runs it, even with -Dmanpages=false: the
    # option only sets build_by_default, and meson validates a target's command
    # when it is defined, so the build stops at
    #
    #     man/meson.build:19:2: ERROR: Tried to use not-found external program
    #                             in "command"
    #
    # The fix is the one upstream would accept: make scdoc optional AND skip
    # defining the targets that use it when the option is off. This element
    # therefore rewrites the find_program line and wraps both foreach loops in
    # `if get_option('manpages')`. vngrd-rootfs never met the problem because
    # its builder container happened to have scdoc installed.
    sed -i "s|scdoc = find_program('scdoc')|scdoc = find_program('scdoc', required: false)|" \
      man/meson.build
    #
    # Only the scdoc loop gets wrapped: the alias loop below it runs `echo`,
    # needs no scdoc, and is already inert with the option off.
    sed -i "/^foreach tuple : _man_pages/i if get_option('manpages')" man/meson.build
    sed -i "0,/^endforeach/s//endforeach\nendif/" man/meson.build

    %{meson}
    ninja -C %{build-dir} -j%{max-jobs}

  install-commands:
  - |
    set -eu
    dest=%{install-root}
    env DESTDIR="$dest" ninja -C %{build-dir} install
    for t in modprobe depmod insmod rmmod lsmod modinfo; do
      test -e "$dest/usr/bin/$t" || {
        echo "kmod.bst: $t missing from the install" >&2
        exit 1
      }
    done

variables:
  # -Dmanpages=false is the one flag from vngrd-rootfs's recipe that must be
  # present for the build to work at all rather than merely slim: kmod's meson
  # runs scdoc to generate them, and with the flag off it does not need to find
  # it. It failed that way first ("Program 'scdoc' not found or not
  # executable"), which is upstream's way of saying the same thing.
  # meson-local, NOT conf-local: conf-local is the autotools plugin's
  # variable and a meson element silently ignores it -- -Dmanpages=false was
  # dropped that way and kmod went looking for scdoc as if nothing had been
  # asked for.
  meson-local: >-
    -Dmanpages=false
    -Dopenssl=enabled
    -Dxz=enabled
    -Dzlib=enabled
    -Dzstd=enabled
    -Dbuild-tests=false

sources:
- kind: tar
  url: https://cdn.kernel.org/pub/linux/utils/kernel/kmod/kmod-34.tar.xz
  ref: 12e7884484151fbd432b6a520170ea185c159f4393c7a2c2a886ab820313149a

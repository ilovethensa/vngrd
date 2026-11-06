# fish 4.9.0 -- the image's interactive shell, and its /usr/bin/sh.
#
# The image ships no POSIX shell by design (AGENTS.md's fish rule), which is
# why glibc's ldd, mtrace and friends are dropped rather than rewritten in
# packages/glibc.bst and why verify.bst rejects a #!/bin/sh shebang: /usr/bin/sh
# IS fish here, and fish does not parse a POSIX script.
#
# C++ through clang++, and it links libstdc++ DYNAMICALLY unless told otherwise
# -- which is precisely what the pruned pzstd in packages/zstd.bst would have
# needed. Vngrd-rootfs's recipe built fish with the seeded pcre2 and dropped
# the /etc and /bin trees the cmake install creates (they are sysusers' and
# tmpfiles' business at boot); both are kept here. The sh symlink is asserted
# to point at fish, because a /usr/bin/sh that is anything else is a POSIX
# script that will not run.
#
# The Rust half, and the two prebuilt inputs it needs:
#
#   * toolchain/rust.bst, because fish 4.x is written in Rust and
#     cmake/Rust.cmake runs find_package(Rust REQUIRED) before anything else.
#   * the vendored crate tree, because the build sandbox has no network
#     (BuildStream builds under bwrap --unshare-net) and cargo cannot fetch
#     crates.io or fish's three git dependencies. `cargo vendor` over the
#     tarball's own Cargo.lock produces the tree; the configure step below
#     installs the source-replacement config that makes cargo read it instead
#     of the network. Both are regenerable, neither is committed, and the
#     regeneration script records what it came from.
kind: cmake

build-depends:
- seed.bst
- base.bst
- packages/ncurses.bst
- packages/pcre2.bst
- packages/libgcc.bst
- toolchain/rust.bst

sources:
- kind: tar
  url: https://github.com/fish-shell/fish-shell/releases/download/4.9.0/fish-4.9.0.tar.xz
  ref: 49d86d655cfcc82c7d13d66c6c30a3351600d44b40fb2b6218fbb8fb0e635122
- kind: local
  path: elements/packages/fish/files

environment:
  # The project's Rust link line: lld, the merged-/usr interpreter, and the
  # library search order that puts vngrd's pcre2 and libgcc_s ahead of the
  # seed's Debian copies. Defined once in project.conf for the same reason
  # %{ldflags} is.
  RUSTFLAGS: "%{rustflags}"

  # cargo's own parallelism, because make's -j does not reach it: fish's build
  # runs cargo through a cmake custom target, and a make -j3 wrapping a cargo
  # that forks 4 codegen threads would take the machine back. %{max-jobs} is
  # the same count the cmake plugin puts in JOBS, so the "leave a core free"
  # setting in the user config governs all of it.
  CARGO_BUILD_JOBS: "%{max-jobs}"

  # Fail loudly rather than hang: the sandbox has no network at all, so a
  # vendored source that is missing must be a configuration error here and not
  # a connection timeout that only manifests on a machine that is also offline.
  CARGO_NET_OFFLINE: "true"

variables:
  # cmake-local, NOT conf-local: conf-local belongs to the autotools plugin.
  cmake-local: >-
    -DFISH_USE_SYSTEM_PCRE2=ON

config:
  configure-commands:
  # Before cmake, not after: fish's cmake runs `cargo build` as an ALL target
  # at BUILD time, and by then the config it reads must already be in place.
  - |
    set -eu

    # The tarball ships a .cargo/config.toml (an xtask alias). Append rather
    # than replace: cargo parses one file per directory, so the alias survives
    # and the source-replacement tables join it.
    test -f .cargo/config.toml ||
      { echo "fish.bst: the tarball no longer ships .cargo/config.toml" >&2
        exit 1; }

    # cargo's own vendored-source config, verbatim from `cargo vendor` for this
    # Cargo.lock. Every source the lock names is replaced -- crates.io and all
    # three git dependencies (fluent-rs, fluent-ftl-tools, rust-pcre2), keyed
    # by the exact URL+rev/tag the lock pins. Keep in step with the vendor tree
    # when fish is upgraded: `cargo vendor` prints this block again.
    #
    # `directory = "vendor"` is relative to the source root, where the local
    # source above staged the tree and where cargo runs (WORKING_DIRECTORY of
    # the custom target is the source dir).
    cat >> .cargo/config.toml <<'VENDOR-EOF'
    [source.crates-io]
    replace-with = "vendored-sources"

    [source."git+https://codeberg.org/danielrainer/fluent-ftl-tools?rev=5917664c8f2e4928ef1e480ff5c13bbe1e226066"]
    git = "https://codeberg.org/danielrainer/fluent-ftl-tools"
    rev = "5917664c8f2e4928ef1e480ff5c13bbe1e226066"
    replace-with = "vendored-sources"

    [source."git+https://github.com/danielrainer/fluent-rs?rev=cf712bced280b217b6307edabc2089b3e57204ab"]
    git = "https://github.com/danielrainer/fluent-rs"
    rev = "cf712bced280b217b6307edabc2089b3e57204ab"
    replace-with = "vendored-sources"

    [source."git+https://github.com/fish-shell/rust-pcre2?tag=0.2.9-utf32"]
    git = "https://github.com/fish-shell/rust-pcre2"
    tag = "0.2.9-utf32"
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "vendor"
    VENDOR-EOF

    # Every crate in the lock, present with its checksum. A vendor tree
    # regenerated against a different lock is a silently different build.
    test -d vendor ||
      { echo "fish.bst: the vendored crates are missing" >&2; exit 1; }
    test -f vendor/pcre2-sys/.cargo-checksum.json ||
      { echo "fish.bst: vendor/ has no checksums; regenerate it" >&2; exit 1; }

  - |
    %{cmake}

  install-commands:
  - |
    set -eu
    dest=%{install-root}
    env DESTDIR="$dest" make -C %{build-dir} install SHELL=/usr/bin/sh

    # cmake installs an /etc tree and, on some versions, a /bin; both are
    # sysusers'/tmpfiles' business at boot, and a top-level /bin is a
    # verify.bst failure.
    rm -rf "$dest/etc" "$dest/bin" "$dest/usr/etc" 2>/dev/null || true
    for d in bin sbin lib lib64 etc; do
      test ! -e "$dest/$d" || {
        echo "fish.bst: top-level /$d survived the install" >&2
        exit 1
      }
    done

    ln -sfn fish "$dest/usr/bin/sh"
    test -L "$dest/usr/bin/sh" || {
      echo "fish.bst: /usr/bin/sh is not a symlink" >&2
      exit 1
    }
    test "$(readlink "$dest/usr/bin/sh")" = fish || {
      echo "fish.bst: /usr/bin/sh must point at fish" >&2
      exit 1
    }
    for t in fish fish_indent fish_key_reader; do
      test -x "$dest/usr/bin/$t" || {
        echo "fish.bst: $t missing from the install" >&2
        exit 1
      }
    done

  strip-commands: []

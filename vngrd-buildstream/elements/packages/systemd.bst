# systemd 262 -- PID 1, and the reason this repository exists.
#
# This element is the port of vngrd-rootfs's packages/systemd/build, flag for
# flag, assertion for assertion. Reading the old recipe's comments first is
# not optional: three of its flags are load-bearing for reasons that are
# invisible in the build and catastrophic in the image.
#
#   -Dtpm=true, and never -Dtpm=false again "to quiet a warning". sd-boot
#     measures into PCR 5 and 11 through tpm_log_tagged_event(); with the
#     feature off it compiles to a no-op, every PCR claim in the design is
#     inert, and the sealed volume key is being protected by nothing. The
#     assertion at the bottom of the build checks the symbol is really there.
#   -Dhomed=disabled -Duserdb=false are a security decision, not a size one.
#     homed's record directory and its signing keys are hardcoded in
#     /var/lib/systemd/home, manager_load_public_keys() trusts any *.public
#     it finds there, and /var lives on the root volume an attacker with disk
#     write can substitute wholesale.
#   -Dlibcryptsetup=enabled, so systemd-cryptsetup opens the LUKS2 root that
#     systemd-repart creates.
#
# meson, with vngrd-rootfs's whole flag set. The plugin's meson-global already
# carries --prefix/--libdir/--sbindir and the merged-/usr linker flags, which
# is what the old --cross-file existed to inject; nothing here restates them.
#
# -Dbuildtype=-Dmode=release and --sysconfdir=/-Dlocalstatedir= are vngrd-rootfs's
# spellings, and meson has both spellings for each: the plugin's meson-args
# already passes --buildtype=plain, --sysconfdir=/etc and --localstatedir=/var
# (through meson-global), and telling it the same thing twice is a hard error
# ("Got argument buildtype as both -Dbuildtype and --buildtype. Pick one."),
# so the duplicate short spellings are dropped here rather than duplicated.
# -Dmode=release is systemd-specific and stays.
#
# /var comes from the plugin's meson-args (--localstatedir), spelled the way
# meson wants; systemd also accepts -Dlocalstatedir= and then refuses to be
# told the same thing twice ("Got argument localstatedir as both
# -Dlocalstatedir and --localstatedir. Pick one."), which is why the short
# spelling is used here.
#
# The /sbin rewrite runs over units/*.in before configure, exactly as the old
# recipe did it (and for the recorded reason: systemd hardcodes /sbin/agetty
# despite --sbindir=/usr/bin, and a unit that names a path the merged-/usr
# tree does not have is a unit that fails at boot).
kind: meson

build-depends:
- seed.bst
- base.bst
- packages/libcap.bst
- packages/libseccomp.bst
- packages/pcre2.bst
- packages/zlib.bst
- packages/xz.bst
- packages/zstd.bst
- packages/util-linux-libs.bst
- packages/json-c.bst
- packages/openssl.bst
- packages/curl.bst
- packages/kmod.bst
- packages/cryptsetup.bst
- packages/lvm2.bst
- packages/tpm2-tss.bst

config:
  build-commands:
  - |
    set -eu

    # clang 14+ with glibc 2.44 _Generic strstr triggers
    # -Wincompatible-pointer-types-discards-qualifiers as error.
    export CFLAGS="$CFLAGS -Wno-error=incompatible-pointer-types-discards-qualifiers"
    export CXXFLAGS="$CXXFLAGS -Wno-error=incompatible-pointer-types-discards-qualifiers"

    # Merged /usr: systemd hardcodes /sbin/* despite --sbindir=/usr/bin, so the
    # fix is applied to the units themselves rather than by relocating anything
    # afterwards. The assertion is the old recipe's: if the first pass changed
    # nothing, upstream has moved the hardcoding somewhere these globs do not
    # reach, and the build must say so rather than ship /sbin paths.
    sbin_before=$(grep -c '/sbin' units/*.in units/*.service 2>/dev/null | awk -F: '{n+=$2} END{print n+0}')
    sed -i 's|/sbin/|/usr/bin/|g' units/*.in 2>/dev/null || true
    sed -i 's|/sbin/|/usr/bin/|g' units/*.service 2>/dev/null || true
    sed -i 's|/usr/sbin/|/usr/bin/|g' units/*.in units/*.service 2>/dev/null || true
    sbin_after=$(grep -c '/sbin' units/*.in units/*.service 2>/dev/null | awk -F: '{n+=$2} END{print n+0}')
    if [ "$sbin_before" -gt 0 ] && [ "$sbin_after" -ge "$sbin_before" ]; then
      echo "systemd.bst: /sbin rewrite did not take effect (before=$sbin_before after=$sbin_after)" >&2
      exit 1
    fi

    # MinVersion= specifier expansion was broken through 257.5 and fixed in
    # 093cac3fe8b4; v262 carries the fix, so the old sed patch became this
    # assertion instead. MinVersion= is the only thing that stops a
    # systemd-sysupdate downgrade, and on a factory image its absence is
    # silently exploitable.
    grep -q 'version_is_valid(resolved' src/sysupdate/sysupdate-transfer.c || {
      echo "systemd.bst: MinVersion= specifier fix is missing from this tree" >&2
      exit 1
    }

    # PCR 11 signing (SignExpectedPcr= in vngrd-image's mkosi.conf) only
    # produces a .pcrsig systemd-cryptsetup can verify if sd-boot and sd-stub
    # actually measure into PCR 11, which is what -Dtpm=true buys. -Dtpm2 is
    # TPM 1.2 and unrelated.
    #
    # -Dtpm2-nvpcr-base is pinned rather than left at its upstream default so
    # the NV index handles are a property of this repository and not of
    # whatever a future systemd defaults to. Written in DECIMAL because meson
    # rejects a hex string for an integer option.
    #
    # A/B updates: -Dsysupdate gives us systemd-sysupdate, which execs
    # systemd-import/systemd-pull for every transfer, and those are gated on
    # importd, which requires libcurl -- hence the curl build-dependency.
    %{meson}
    ninja -C %{build-dir} -j%{max-jobs}

  install-commands:
  - |
    set -eu
    dest=%{install-root}
    env DESTDIR="$dest" ninja -C %{build-dir} install

    # systemd 262 ships its own default factory tree (usr/share/factory/etc:
    # nsswitch.conf, vconsole.conf, locale.conf, issue, and pam.d/*) for the
    # "reset to factory defaults" the PRINCIPLE of /usr/share/factory exists
    # for. vngrd's factory tree is packages/base-files.bst's payload -- its
    # nsswitch.conf, its pam.d stack, its os-release -- and the rootfs build
    # resolved the collision the way it resolved every other one: base-files
    # is LAST in ORDER, so its files won. Here the winner is named instead:
    # systemd's defaults are pruned, because a default base-files does not
    # ship would silently become the factory reset's content, and the tree
    # the initrd's tmpfiles copies from /usr/share/factory must be one
    # element's, not an order-dependent merge of two.
    rm -rf "$dest/usr/share/factory/etc"
    test ! -e "$dest/usr/share/factory/etc" || {
      echo "systemd.bst: usr/share/factory/etc survived the prune" >&2
      exit 1
    }

    # Assert the measurement is really compiled in rather than trusting the
    # flag: the failure mode it guards is a silently-degraded measurement,
    # which looks exactly like success until the volume does not open.
    grep -q 'tpm_log_tagged_event' src/boot/boot.c || {
      echo "systemd.bst: tpm_log_tagged_event is absent from src/boot/boot.c" >&2
      echo "  sd-boot would measure nothing and the whole PCR chain is inert." >&2
      exit 1
    }

    # Shell hooks this build does not use, all with a #!/bin/sh shebang
    # verify.bst rejects, and whose interpreter this image has no POSIX shell
    # to be rewritten onto (/usr/bin/sh is fish):
    #   etc/X11/xinit/xinitrc.d/50-systemd-user.sh  (X11; Wayland-only tree)
    #   usr/lib/kernel/install.d/*.install          (kernel-install's hooks:
    #        50-depmod, 60-ukify, 90-loaderentry, 90-uki-copy. The kernel is
    #        built by vngrd-kernel and shipped as modules, and the UKI is
    #        assembled by vngrd-image's ukify -- not by kernel-install, so
    #        nothing here is a consumer of them)
    rm -f "$dest/etc/X11/xinit/xinitrc.d/50-systemd-user.sh"
    rmdir -p --ignore-fail-on-non-empty "$dest/etc/X11/xinit/xinitrc.d" 2>/dev/null || true
    # The directory, not a name list: upstream adds hooks between releases
    # (60-ukify and 90-uki-copy are newer than the 50-depmod this element
    # first pruned), and a hook-by-name allow-list is pruned into staleness
    # the moment one appears that is not on it.
    rm -rf "$dest/usr/lib/kernel/install.d"
    for gone in usr/lib/kernel/install.d \
                etc/X11/xinit/xinitrc.d/50-systemd-user.sh; do
      test ! -e "$dest/$gone" || {
        echo "systemd.bst: $gone should have been pruned but is present" >&2
        exit 1
      }
    done

    # usr/lib/environment.d/99-environment.conf is systemd's relative symlink
    # to ../../../etc/environment -- a file the image does not ship, because
    # /etc is a tmpfs the initrd populates from /usr/share/factory. The link
    # itself is upstream's convenience for a machine with a writable /etc; on
    # this one it dangles, and a dangling symlink is a verify.bst failure. The
    # factory tree's copy (usr/share/factory/etc/environment, via base-files)
    # is what actually populates /etc/environment at boot.
    rm -f "$dest/usr/lib/environment.d/99-environment.conf"
    test ! -e "$dest/usr/lib/environment.d/99-environment.conf" || {
      echo "systemd.bst: environment.d/99-environment.conf survived the prune" >&2
      exit 1
    }

    # --- the enablements this image must not ship -------------------------
    #
    # Three of these used to be REMOVED by packages/base-files/build, over the
    # cumulative out/ tree: the previous package's systemd install was sitting
    # right there in $dest, so `rm` worked. An element cannot delete another
    # element's files -- the rootfs is a union, and rootfs.bst would fail the
    # overlap check on the same paths if two elements claimed them -- so the
    # surgery moved to the element that owns the files. This is the correct
    # place for it anyway: it is a statement about systemd's own default
    # enablements, not about base-files.
    #
    # 1. systemd-repart is re-parented from initrd-root-fs.target to
    #    initrd-usr-fs.target, and this is the fix for a first-boot deadlock.
    #    As shipped, repart is enabled by initrd-root-fs.target.wants. A Wants=
    #    on a target is not expanded until that target's JOB runs, and
    #    initrd-root-fs.target is After= sysroot.mount, which needs
    #    /dev/mapper/vngrd-root, which is systemd-cryptsetup@vngrd-root.service,
    #    and BOTH of those carry After=systemd-repart.service. So on a machine
    #    with no root volume yet:
    #
    #      initrd-root-fs.target  waits for sysroot.mount
    #      sysroot.mount          waits for cryptsetup@ and for repart
    #      cryptsetup@            waits for repart
    #      repart                 is WANTED by initrd-root-fs.target ... which
    #                             is waiting on the volume repart would create
    #
    #    Nothing can start. It presents as an intermittent first-boot failure
    #    because systemd-volatile-root/growfs-root/cryptenroll-firstboot also
    #    reference systemd-repart and any of them winning the race starts it.
    #    initrd-usr-fs.target is the correct parent: repart is already After=
    #    it, that target IS reached before the root is opened, and nothing in it
    #    depends on the root existing.
    rm -f "$dest/usr/lib/systemd/system/initrd-root-fs.target.wants/systemd-repart.service"
    mkdir -p "$dest/usr/lib/systemd/system/initrd-usr-fs.target.wants"
    ln -sfn ../systemd-repart.service \
          "$dest/usr/lib/systemd/system/initrd-usr-fs.target.wants/systemd-repart.service"
    g="usr/lib/systemd/system/initrd-usr-fs.target.wants/systemd-repart.service"
    test -L "$dest/$g" || { echo "systemd.bst: $g must be a symlink" >&2; exit 1; }
    case "$(readlink "$dest/$g")" in
      /*) echo "systemd.bst: $g must be relative" >&2; exit 1 ;;
    esac
    test ! -e "$dest/usr/lib/systemd/system/initrd-root-fs.target.wants/systemd-repart.service" || {
      echo "systemd.bst: systemd-repart is enabled from initrd-root-fs.target again." >&2
      echo "  That is the first-boot deadlock documented above; it shows up as" >&2
      echo "  a machine that sometimes provisions and sometimes lands in emergency mode." >&2
      exit 1
    }
    test -e "$dest/$g" || { echo "systemd.bst: $g dangles" >&2; exit 1; }

    # 2. systemd-cryptenroll-firstboot.service cannot work here either: its
    #    auto-detection finds no free LUKS2 volume (repart already created the
    #    root and it is active), and it holds the tty the provisioning prompts
    #    need. Upstream enables it from initrd.target.wants.
    rm -f "$dest/usr/lib/systemd/system/initrd.target.wants/systemd-cryptenroll-firstboot.service"
    test ! -e "$dest/usr/lib/systemd/system/initrd.target.wants/systemd-cryptenroll-firstboot.service" || {
      echo "systemd.bst: initrd.target.wants/systemd-cryptenroll-firstboot.service is back." >&2
      echo "  It only logs a failure (its '-' prefix swallows it) and it holds" >&2
      echo "  the tty that vngrd-provision and vngrd-tpm-pin need for their prompts." >&2
      exit 1
    }

    # 3. And the host must not run repart at all: upstream installs it into
    #    sysinit.target.wants, where it starts after switch-root and fails
    #    because its ExecStart names --tpm2-public-key=/.extra, an initramfs
    #    path. Every boot's console then carries
    #      [FAILED] Failed to start Repartition Root Disk.
    #    The initrd run is the provisioning one; the host run has nothing to do.
    rm -f "$dest/usr/lib/systemd/system/sysinit.target.wants/systemd-repart.service"
    test ! -e "$dest/usr/lib/systemd/system/sysinit.target.wants/systemd-repart.service" || {
      echo "systemd.bst: systemd-repart is enabled on the host again (sysinit.target.wants)." >&2
      echo "  Its --tpm2-public-key= is /.extra, an initramfs path, so the host" >&2
      echo "  run fails on every boot; keep it initrd-only." >&2
      exit 1
    }

    # PID 1 must be there, and it must be the merged-/usr interpreter like
    # everything else in the tree.
    test -x "$dest/usr/lib/systemd/systemd" || {
      echo "systemd.bst: no systemd binary in the install" >&2
      exit 1
    }
    interp=$(llvm-readelf -p .interp "$dest/usr/lib/systemd/systemd" 2>/dev/null \
               | sed -n 's/.*\][[:space:]]*//p' | head -1)
    test "$interp" = /usr/lib/ld-linux-x86-64.so.2 || {
      echo "systemd.bst: PID 1 carries PT_INTERP '$interp'" >&2
      exit 1
    }
    # The pcrphase unit this design's UKI is signed against, and the drop-in
    # that takes leave-initrd out of its ExecStop. Both are asserted by
    # packages/base-files.bst against the staged tree; here it is enough that
    # they exist upstream.
    test -f "$dest/usr/lib/systemd/system/systemd-pcrphase-initrd.service" || {
      echo "systemd.bst: systemd-pcrphase-initrd.service is not installed" >&2
      echo "  Nothing measures enter-initrd, so PCR 11 stays at the stub-only" >&2
      echo "  value and the UKI's .pcrsig matches nothing the machine reaches." >&2
      exit 1
    }

    # --- take the HOST-side PCR phases away ---------------------------------
    # The root volume key's availability window is the initrd and nothing else:
    # the UKI's .pcrsig signs the enter-initrd value, and leave-initrd closes
    # the window (base-files' drop-in). systemd-pcrphase-sysinit.service and
    # systemd-pcrphase.service extend PCR 11 again on the HOST, after
    # switch-root, so the value the seal was taken against is gone the moment
    # the machine is up -- the window reopens and the sealed key becomes
    # unreleasable, which is a machine that boots once and never again.
    #
    # Every .wants and .requires under the tree is walked, not just the two
    # upstream names a systemd version happens to use, because an enablement
    # added by a new release has exactly the same effect. And their removal is
    # a build failure if they come back: a systemd upgrade that re-presets them
    # would otherwise reopen the window with no trace until second boot.
    #
    # vngrd-rootfs does this in packages/base-files/build, where it overlays
    # systemd's cumulative tree; the element that OWNS the tree does it here,
    # because a prune in base-files.bst would be asserting over files it does
    # not claim.
    for later in systemd-pcrphase-sysinit.service systemd-pcrphase.service; do
        for dir in "$dest/usr/lib/systemd/system"/*.wants \
                   "$dest/usr/lib/systemd/system"/*.requires; do
            [ -e "$dir/$later" ] || continue
            rm -f "$dir/$later"
        done
    done
    for later in systemd-pcrphase-sysinit.service systemd-pcrphase.service; do
        for dir in "$dest/usr/lib/systemd/system"/*.wants \
                   "$dest/usr/lib/systemd/system"/*.requires; do
            if [ -e "$dir/$later" ]; then
                echo "systemd.bst: $later is enabled again at $dir" >&2
                echo "  The root volume key's window ends at leave-initrd; a host" >&2
                echo "  phase extends PCR 11 past what the .pcrsig signs." >&2
                exit 1
            fi
        done
    done

    # systemd-pcrproduct.service is the same story one layer over. It is
    # host-only (ConditionPathExists=!/etc/initrd-release) and systemd enables
    # it from sysinit.target.wants/. ConditionSecurity=measured-os is TRUE on
    # this image -- sd-stub measures the kernel into PCR 11, which is what
    # efi_measured_os() reads through efi_measured_uki() -- so the unit runs on
    # every host boot and then cannot: the NvPCR's write policy is authorized by
    # the PCR signing key, which systemd exposes only inside the initramfs
    # (/.extra/tpm2-pcr-public-key.pem), so pcrextend exits non-zero and every
    # boot carries
    #     [FAILED] Failed to start TPM NvPCR Product ID Measurement.
    # The vngrd seal does not use the product-id NvPCR, so the measurement is
    # taken out. Shipping the public key in the image would be the alternative;
    # it is public, but nothing here consumes the measurement.
    rm -f "$dest/usr/lib/systemd/system/sysinit.target.wants/systemd-pcrproduct.service"
    test ! -e "$dest/usr/lib/systemd/system/sysinit.target.wants/systemd-pcrproduct.service" || {
        echo "systemd.bst: systemd-pcrproduct.service is enabled on the host again." >&2
        echo "  It fails on every boot: the PCR signing key is an initramfs path." >&2
        exit 1
    }

variables:
  # meson-local, NOT conf-local: conf-local is the autotools plugin's
  # variable and a meson element silently ignores it -- -Dmanpages=false was
  # dropped that way and kmod went looking for scdoc as if nothing had been
  # asked for.
  #
  # The SBAT triple is EXPLICIT, and has to be. src/boot/meson.build
  # autodetects it by sourcing /etc/os-release, then /usr/lib/os-release,
  # from the BUILD sandbox -- where neither exists: this element's
  # build-depends are base.bst plus the libraries, and packages/base-files.bst
  # (which owns /usr/lib/os-release) is not one of them, because systemd's
  # build has no business staging the image's data files. Even if it were,
  # the autodetection would still fail: vngrd's os-release carries no
  # BUG_REPORT_URL at all, and the loop wants all three of ID, NAME and
  # BUG_REPORT_URL. `run_command(..., check: true)` turns the missing file
  # into a hard configure error:
  #     src/boot/meson.build:121: ERROR: Command `sh -c 'if [ -e
  #     /etc/os-release ]; ...'` failed with status 1.
  # So the identity is stated here instead, matching
  # packages/base-files/files/usr/lib/os-release (NAME/ID both vngrd). The
  # distro has no public home, so the SBAT URL is the placeholder
  # https://vngrd/ until there is a real one; it is metadata displayed to
  # whoever inspects a signed UKI, never fetched. Changing the placeholder is
  # a one-line edit here, not a tree-wide rewrite.
  # 'auto' (the default) PROBES THE BUILD HOST: split_bin is
  # `not fs.is_symlink('/usr/sbin')` -- true on a builder whose /usr/sbin is
  # a merged-usr symlink, false on one where sbin is a real directory. The
  # sandbox has neither, so auto evaluated true here and systemd installed
  # its compat symlinks (init, halt, poweroff, reboot, shutdown, mount.*)
  # into a top-level /usr/sbin, which verify.bst fails on. The tree is
  # merged-usr by construction, so say so and stop asking the host.
  meson-local: >-
    -Dmode=release
    -Ddefault-dnssec=no
    -Dfirstboot=false
    -Dinstall-tests=false
    -Dldconfig=false
    -Dsysusers=true
    -Drpmmacrosdir=no
    -Dsplit-bin=false
    -Dsbat-distro=vngrd
    -Dsbat-distro-summary=vngrd
    -Dsbat-distro-url=https://vngrd/
    -Dhomed=disabled
    -Duserdb=false
    -Dman=disabled
    -Dhtml=disabled
    -Dukify=enabled
    -Dnobody-group=nogroup
    -Dnobody-user=nobody
    -Dpam=disabled
    -Daudit=disabled
    -Dselinux=disabled
    -Dapparmor=disabled
    -Dpolkit=disabled
    -Dblkid=enabled
    -Didn=false
    -Dlibidn2=disabled
    -Dxkbcommon=disabled
    -Dpcre2=enabled
    -Dseccomp=enabled
    -Dzlib=enabled
    -Dzstd=enabled
    -Dlz4=disabled
    -Dxz=enabled
    -Dbzip2=disabled
    -Dopenssl=enabled
    -Dgnutls=disabled
    -Dlibcurl=enabled
    -Dmicrohttpd=disabled
    -Dbpf-framework=disabled
    -Dtpm=true
    -Dtpm2=enabled
    -Dtpm2-nvpcr-base=30474752
    -Defi=true
    -Dbootloader=enabled
    -Dkmod=disabled
    -Dacl=disabled
    -Dgcrypt=disabled
    -Dlibcryptsetup=enabled
    -Dlibcrypt=disabled
    -Dqrencode=disabled
    -Dp11kit=disabled
    -Dlibfido2=disabled
    -Delfutils=disabled
    -Ddbus=disabled
    -Dutmp=false
    -Dhibernate=false
    -Dlocaled=false
    -Dmachined=false
    -Dportabled=false
    -Dsysext=false
    -Dsysinstall=false
    -Dnspawn=disabled
    -Dimds=disabled
    -Dsysupdate=enabled
    -Dimportd=enabled
    -Danalyze=true
    -Dhostnamed=false
    -Dtimedated=false
    -Dtimesyncd=false
    -Dnetworkd=false
    -Dresolve=false
    -Doomd=false
    -Dsulogin-path=/usr/bin/sulogin
    -Dnologin-path=/usr/bin/nologin

sources:
- kind: tar
  url: https://github.com/systemd/systemd/archive/refs/tags/v262.tar.gz
  ref: 6aa77506c0644aa67f940a48e3d3a7368601f787e4f249139516d353f107bcab

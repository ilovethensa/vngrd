# base-files -- the image's /etc policy, sysusers/tmpfiles rules, and the
# vngrd-* units the boot runs: the boot gate, provisioning, the PCR 11 barrier,
# the leave-initrd split.
#
# No upstream sources: everything here is the payload in
# elements/packages/base-files/files, installed verbatim. vngrd-rootfs's
# packages/base-files/build was the keep-first ordering position -- last, after
# systemd, because its assertions check units that only systemd installs -- and
# in a dependency graph that is simply what the build-depends say. The ordering
# reasoning is now load-bearing in the graph rather than in a comment.
#
# The assertions below are ports of vngrd-rootfs's, with one systematic
# difference: they used to read $dest, the cumulative out/ tree, which held the
# previous package's systemd. Here $install-root holds only THIS package's
# payload, and systemd's files are at / (staged by the build-dependency), so the
# checks that were "is it in the tree?" become "is it in my payload, and does it
# resolve against the tree?" -- which is the same question, answered without
# depending on build order inside one element.
kind: manual

build-depends:
- seed.bst
- packages/systemd.bst
# The fixate generator's binaries: base-files ships the units and the
# enablement, and the staged tree below is where the assertions read them from.
- packages/fixate-generator.bst

sources:
- kind: local
  path: elements/packages/base-files/files

config:
  build-commands: []

  install-commands:
  - |
    set -eu
    dest=%{install-root}

    # The payload is staged as usr/ (a local source stages its CONTENTS).
    cp -a usr "$dest/"

    # --- the /etc policy, asserted on the payload ---------------------------
    #
    # This package ships NO /etc payload, and that is the design rather than an
    # accident: /etc is a tmpfs, mounted by the initrd before switch_root, and
    # everything in it is produced by usr/lib/tmpfiles.d/10-vngrd-etc.conf from
    # /usr/share/factory/etc -- which is inside the dm-verity'd /usr, so a
    # substituted root cannot change what gets copied in.
    #
    # Checked on the SOURCE tree rather than $dest, because $dest here is this
    # element's fresh install root and is legitimately /etc-free; what must not
    # exist is an /etc in the payload, where it would ship into the image and
    # then be SHADOWED by the tmpfs -- dead weight that reads as live.
    if [ -d usr/etc ] || [ -d etc ]; then
      echo "base-files.bst: files/usr/etc must be empty; /etc is a tmpfs now." >&2
      echo "  Files there would ship into the image and then be shadowed by" >&2
      echo "  the tmpfs. Move them to files/usr/share/factory/etc/ and add a" >&2
      echo "  C line to usr/lib/tmpfiles.d/10-vngrd-etc.conf." >&2
      find usr/etc etc -type f 2>/dev/null | sed 's/^/    /' >&2
      exit 1
    fi

    # os-release is systemd's (usr/lib/os-release from its build-dependency);
    # the factory copy is the reference a factory reset has to diff against.
    # /etc/os-release itself is a *symlink* to /usr/lib/os-release at boot (see
    # files/usr/lib/tmpfiles.d/00-vngrd-factory.conf), so the two files win or
    # lose together -- but they are kept in step here, as vngrd-rootfs did.
    if [ -f /usr/lib/os-release ]; then
      mkdir -p "$dest/usr/share/factory/etc"
      cp /usr/lib/os-release "$dest/usr/share/factory/etc/os-release"
    fi

    # The overlay root for the factory reset lives in /var.
    mkdir -p "$dest/var"

    # --- the boot gate, enabled by a committed *relative* symlink -----------
    #
    # boot-complete.target is a static upstream unit with no [Install] to run,
    # and /etc is rebuilt at every boot, so there is no enable step to put in
    # a build: the symlink is the enablement. vngrd-rootfs checked it here
    # because neither mistake shows up as a build error otherwise -- systemd
    # resolves such an entry by readlink() and uses only the basename of the
    # target (load-dropin.c), so an absolute path would silently point at the
    # build host, and a dangling one would still be honoured (the link simply
    # stops pulling the gate in, and slots go on being blessed unchecked).
    for l in boot-complete.target.requires/vngrd-boot-gate.service \
             initrd-root-fs.target.wants/vngrd-provision.service; do
      g="usr/lib/systemd/system/$l"
      test -L "$dest/$g" || { echo "base-files.bst: $g must be a symlink" >&2; exit 1; }
      case "$(readlink "$dest/$g")" in
        /*) echo "base-files.bst: $g must be relative, not $(readlink "$dest/$g")" >&2; exit 1 ;;
      esac
      test -e "$dest/$g" || { echo "base-files.bst: $g dangles" >&2; exit 1; }
    done

    # vngrd-provision.service is asserted *linked*, from initrd-root-fs.target.
    # It was previously asserted NOT linked, on the reasoning that Before= is
    # enough. It is not: Before= orders a unit, it does not start one. With no
    # .wants symlink and no [Install], nothing pulled it into the transaction
    # at all, so the recovery key was never enrolled and the entire recovery
    # posture was absent while the build and the tests looked healthy. It
    # showed up as a test failing to see "vngrd: firmware event log follows".
    # initrd-root-fs.target only exists inside the initrd, so a .wants entry for
    # it cannot be honoured on the host -- the placement is initrd-only by
    # construction, and it is the only point at which the TPM will still unseal.

     # --- the PCR 11 phase barrier -------------------------------------------
     #
     # systemd enables the phase units itself; the two HOST-side ones are taken
     # away in packages/systemd.bst (where files live that can be removed), and
     # what remains here is the contract this package relies on: the initrd unit
     # is enabled, and the drop-in that splits leave-initrd out of its ExecStop
     # exists. The full argument for why the host phases must be gone lives in
     # vngrd-rootfs's recipe: with them, the shipped .pcrsig carried four
     # cumulative entries and PolicyAuthorize accepted any signed value PCR 11
     # currently held -- so the volume key was releasable for the entire boot,
     # and the problem looked most like success because every "does the TPM
     # unseal?" test passed.
     #
     # Read from the STAGED tree, not $dest: vngrd-rootfs's cumulative out/
     # meant its check of $dest saw systemd's enablement, but a BuildStream
     # element's $dest holds only what it installs itself. systemd.bst is a
     # build-dependency, so its artifact is staged at / here, and that is
     # where the unit and the enablement being relied on live. The drop-in
     # below IS this package's file and is checked in $dest.
     i="usr/lib/systemd/system/initrd.target.wants/systemd-pcrphase-initrd.service"
     test -L "/$i" || {
       echo "base-files.bst: /$i is missing or is not a symlink." >&2
       echo "  Without it enter-initrd is never measured, PCR 11 stays at the" >&2
       echo "  stub-only value, and the UKI's .pcrsig matches nothing the machine" >&2
       echo "  ever reaches. The root then never opens at all." >&2
       exit 1
     }
     case "$(readlink "/$i")" in
       /*) echo "base-files.bst: /$i must be relative" >&2; exit 1 ;;
     esac
     test -e "/$i" || { echo "base-files.bst: /$i dangles" >&2; exit 1; }

     # The phase names are the contract between the .pcrsig and the measurement,
     # and nothing else in the build connects them: ukify signs whatever
     # --phases says, and systemd-pcrextend extends whatever its unit says. A
     # systemd upgrade that reworded either side would produce a correctly signed
     # UKI whose signature matches no PCR value the machine ever reaches -- a brick
     # on first boot, with a passphrase keyslot as the only way out. The unit is
     # systemd's, staged at / (build-dependency), so this reads the staged copy.
     pp_unit=/usr/lib/systemd/system/systemd-pcrphase-initrd.service
    grep -q "systemd-pcrextend --graceful enter-initrd" "$pp_unit" || {
      echo "base-files.bst: systemd-pcrphase-initrd.service does not extend 'enter-initrd'." >&2
      echo "  Expected 'systemd-pcrextend --graceful enter-initrd' in ExecStart=." >&2
      exit 1
    }
    # FailureAction=reboot-force is what makes a *present but broken* TPM fail
    # the extend loudly: --graceful only covers absence, so without this a TPM
    # that errors is indistinguishable from one that is merely missing.
    grep -q '^FailureAction=reboot-force' "$pp_unit" || {
      echo "base-files.bst: systemd-pcrphase-initrd.service lacks FailureAction=reboot-force." >&2
      exit 1
    }

    # --- leave-initrd, split out of the ExecStop ------------------------------
    #
    # The vendor unit extends leave-initrd from its ExecStop, fired by
    # Conflicts=initrd-switch-root.target. That races vngrd-provision.service,
    # which is also Before=initrd-switch-root.target, and the race is not
    # fixable with ordering: systemd orders a shutdown before a concurrent
    # start-up whenever the two units have any ordering dependency between
    # them. It is a real failure -- it extended PCR 11 while
    # systemd-cryptenroll held a policy session open over PCR 11, the TPM
    # answered TPM2_RC_PCR_CHANGED, and the passphrase keyslot was never
    # enrolled. So the two halves live in two units and the drop-in clears the
    # vendor ExecStop.
    pp_dropin="$dest/usr/lib/systemd/system/systemd-pcrphase-initrd.service.d/10-vngrd.conf"
    test -f "$pp_dropin" || {
      echo "base-files.bst: $pp_dropin is missing." >&2
      echo "  Without it the vendor ExecStop is still in force, leave-initrd is" >&2
      echo "  still extended at the first opportunity, and vngrd-provision loses" >&2
      echo "  the race again." >&2
      exit 1
    }
    # [Service], specifically. ExecStop= in [Unit] is IGNORED, not rejected: the
    # vendor ExecStop stays in force, the provisioning failure comes back, and
    # the drop-in in the tree is indistinguishable from one that works.
    grep -q '^\[Service\]' "$pp_dropin" || {
      echo "base-files.bst: $pp_dropin has no [Service] section." >&2
      exit 1
    }
    # The three checks below strip comments before matching, because the
    # drop-in's header quotes the two Exec lines it is replacing -- verbatim,
    # in order to document what is being taken over -- and a grep over the raw
    # file matches its own explanation and then refuses a build that is correct.
    pp_service=$(sed -n '/^\[Service\]/,$p' "$pp_dropin" | sed 's/^[[:space:]]*#.*//')
    pp_body=$(sed 's/^[[:space:]]*#.*//' "$pp_dropin")
    printf '%s\n' "$pp_service" | grep -q '^ExecStop=$' || {
      echo "base-files.bst: $pp_dropin does not reset ExecStop= inside [Service]." >&2
      exit 1
    }
    # ExecStart must survive: an empty ExecStart= in a drop-in clears the vendor
    # list rather than leaving it alone, so enter-initrd would silently stop
    # being measured and the root would never unseal at all.
    if printf '%s\n' "$pp_service" | grep -q '^ExecStart=$'; then
      echo "base-files.bst: $pp_dropin clears ExecStart=, so enter-initrd would never be measured." >&2
      exit 1
    fi
    if printf '%s\n' "$pp_body" | grep -q 'systemd-pcrextend --graceful leave-initrd'; then
      echo "base-files.bst: $pp_dropin re-extends leave-initrd itself." >&2
      echo "  That is the race it is here to remove. vngrd-leave-initrd.service" >&2
      echo "  owns leave-initrd; this drop-in only clears the vendor ExecStop." >&2
      exit 1
    fi

    lv="usr/lib/systemd/system/vngrd-leave-initrd.service"
    test -f "$dest/$lv" || {
      echo "base-files.bst: $lv is missing, so leave-initrd is never measured." >&2
      exit 1
    }
    lv_body=$(sed 's/^[[:space:]]*#.*//' "$dest/$lv")
    printf '%s\n' "$lv_body" | grep -q '^After=vngrd-provision.service' || {
      echo "base-files.bst: $lv is not ordered after vngrd-provision.service." >&2
      echo "  That ordering is the entire reason this unit exists." >&2
      exit 1
    }

    # --- the lock the first-boot anchor installs -----------------------------
    # (see the vngrd-tpm-pin.service file itself: a typed passphrase, enrolled
    # on the boot that creates the volume, which the later boots require)
    for u in vngrd-boot-gate.service vngrd-provision.service \
              vngrd-leave-initrd.service vngrd-tpm-pin.service; do
      test -f "$dest/usr/lib/systemd/system/$u" || {
        echo "base-files.bst: $u is missing from the payload" >&2
        exit 1
      }
    done

    # --- the fixate units, and the binaries they run -------------------------
    # The units are this package's payload; the binaries are
    # packages/fixate-generator.bst's, staged at / by the build-dependency, and
    # the two halves assert each other here: vngrd-fixate.service drives
    # vngrd-fixate-nvwrite on the boot that creates the volume, and the
    # generator checks the released key against the digest that write froze
    # into a TPM NV register. Lose either half and the volume-substitution
    # defence silently stops running -- the root still opens, every "does it
    # unseal?" test still passes, and nothing says the check is gone.
    for u in vngrd-fixate.service; do
      test -f "$dest/usr/lib/systemd/system/$u" || {
        echo "base-files.bst: $u is missing from the payload" >&2
        exit 1
      }
    done
    test -L "$dest/usr/lib/systemd/system/initrd-root-fs.target.wants/vngrd-fixate.service" || {
      echo "base-files.bst: vngrd-fixate.service is not enabled in the payload." >&2
      echo "  The digest only exists on the boot that creates the volume, so an" >&2
      echo "  unrun unit is indistinguishable from a never-provisioned machine." >&2
      exit 1
    }
    for f in /usr/lib/systemd/system-generators/vngrd-fixate-generator \
             /usr/lib/vngrd/vngrd-fixate-nvwrite; do
      test -x "$f" || {
        echo "base-files.bst: $f is not staged (packages/fixate-generator.bst)." >&2
        echo "  The fixate check would not run; a substituted root would open." >&2
        exit 1
      }
    done

    # --- the pcrlock policy's ride to the ESP ---------------------------------
    # The initrd creates the policy INSIDE the volume it opens, and the next
    # boot's initrd needs it before that volume is open -- systemd's tpm2-util.c
    # documents the problem ("During boot we'll not have access to the pcrlock
    # .json file in /var/") and the answer: the policy rides on the ESP as a
    # credential that systemd-stub picks up into /run/credentials/@encrypted.
    # This unit is that step, and without it the observed failure was
    #     Failed to find TPM2 pcrlock policy file 'pcrlock.json'
    #     No encrypted system credentials passed.
    #     Token 2: TPM policy does not match current system state, skipping.
    # i.e. the root only ever opens with the recovery key, again.
    test -L "$dest/usr/lib/systemd/system/sysinit.target.wants/vngrd-pcrlock-esp.service" || {
      echo "base-files.bst: vngrd-pcrlock-esp.service is not enabled in the payload." >&2
      echo "  The ESP credential is the only copy of the policy the next initrd" >&2
      echo "  can read, and a unit that exists but is not enabled writes nothing." >&2
      exit 1
    }
    grep -q '^ExecStart=/usr/bin/systemd-creds encrypt --name=pcrlock\.%m --with-key=tpm2 --tpm2-pcrs=7 ' \
        "$dest/usr/lib/systemd/system/vngrd-pcrlock-esp.service" || {
      echo "base-files.bst: vngrd-pcrlock-esp.service no longer writes the ESP credential." >&2
      echo "  The initrd would find no pcrlock policy at unlock time and the root" >&2
      echo "  could never be opened again without the recovery key." >&2
      exit 1
    }
    # --with-key=tpm2, not null/auto: the SRK/NV handle match is not
    # authenticity, because both handles are readable from the LUKS2 header.
    case " $(grep -h '^ExecStart=/usr/bin/systemd-creds encrypt' \
            "$dest/usr/lib/systemd/system/vngrd-pcrlock-esp.service")" in
      *" --with-key=null "*|*" --with-key=auto "*|*" --with-key=auto-initrd "*)
        echo "base-files.bst: vngrd-pcrlock-esp.service must seal with --with-key=tpm2." >&2
        exit 1 ;;
    esac
    # A torn ESP write becomes a failed unit now, not a bad unseal next boot.
    grep -q '^ExecStartPost=/usr/bin/systemd-creds decrypt /efi/loader/credentials/pcrlock\.%m\.cred ' \
        "$dest/usr/lib/systemd/system/vngrd-pcrlock-esp.service" || {
      echo "base-files.bst: vngrd-pcrlock-esp.service does not decrypt-verify its credential." >&2
      exit 1
    }
    grep -q '^ExecStartPost=/usr/bin/cmp -s /run/vngrd-pcrlock-verify ' \
        "$dest/usr/lib/systemd/system/vngrd-pcrlock-esp.service" || {
      echo "base-files.bst: vngrd-pcrlock-esp.service does not compare the decrypted credential." >&2
      exit 1
    }
    grep -q '/efi/loader/credentials/pcrlock\.%m\.cred$' \
        "$dest/usr/lib/systemd/system/vngrd-pcrlock-esp.service" || {
      echo "base-files.bst: vngrd-pcrlock-esp.service writes the wrong ESP path." >&2
      echo "  systemd-stub only picks up *.cred under the ESP's \\loader\\credentials," >&2
      echo "  and the token handler only scans for the 'pcrlock.' prefix there." >&2
      exit 1
    }
    # And the ESP is an automount, mounted on ACCESS: every conditional or
    # indirect spelling of "be mounted" (ConditionPathIsMountPoint, Requires=
    # against the late-generated efi.mount, RequiresMountsFor) let this unit
    # run before the mount, which writes the credential to /efi on the ROOT
    # volume, where the ESP's mount then hides it. So the mount is explicit
    # and the mountpoint check after it is what makes the difference visible.
    grep -q '^ExecStartPre=-/usr/bin/mount -t vfat /dev/disk/by-partlabel/vngrd-esp /efi$' \
        "$dest/usr/lib/systemd/system/vngrd-pcrlock-esp.service" || {
      echo "base-files.bst: vngrd-pcrlock-esp.service must mount the ESP itself." >&2
      exit 1
    }
    grep -q '^ExecStartPre=/usr/bin/mountpoint -q /efi$' \
        "$dest/usr/lib/systemd/system/vngrd-pcrlock-esp.service" || {
      echo "base-files.bst: vngrd-pcrlock-esp.service must verify the ESP mount landed." >&2
      echo "  Without the check a failed mount writes the credential onto the root" >&2
      echo "  volume, where the ESP's mount hides it and the initrd finds nothing." >&2
      exit 1
    }
    # Runs on the host, not in the initrd: the policy is created inside the
    # volume, so the copy has to happen once the root is mounted.
    grep -q '^ConditionPathExists=!/etc/initrd-release$' \
        "$dest/usr/lib/systemd/system/vngrd-pcrlock-esp.service" || {
      echo "base-files.bst: vngrd-pcrlock-esp.service is not gated to the host." >&2
      exit 1
    }
    # And the initrd flow that creates what this pushes: asserted for the same
    # reason as the fixate pair -- the enrollment writes the token and the policy
    # together, and losing either half strands the machine.
    test -f "$dest/usr/lib/systemd/system/vngrd-tpm-pcrlock.service" || {
      echo "base-files.bst: vngrd-tpm-pcrlock.service is missing from the payload." >&2
      exit 1
    }
     # The refresh is enabled here, and the reason it was not is written out below
     # because it is the whole difference between a policy and a souvenir.
     #
     # Upstream's host-side refresh runs on every boot. The enrollment and the
     # refresh read different event logs (initrd vs host) and therefore land on
     # different protection masks -- measured, two consecutive boots of one
     # provisioned machine: enrollment {15} vs refresh {0,1,2,3,7,13,14} -- and the
     # refresh's NV update must satisfy the policy session pinned to the
     # enrollment's prediction. It did not: the enrollment's {15} was bound to the
     # value PCR 15 holds in the initrd, the host's systemd-pcrmachine.service
     # measured the machine ID into PCR 15 after the volume was open, and the TPM
     # answered TPM2_RC_PCR_CHANGED (no retry on that step, unlike the unseal path).
     # The unit failed on every boot, so it was disabled.
     #
     # The cause was the window, not the two logs. make-policy's default
     # --location= is "760-:940-", which SKIPS every component before 760- -- and
     # every firmware and separator component sorts before 760-. Skipped components
     # leave their records unmapped, which drops the PCR; PCR 15 survived only
     # because nothing claims it and nothing measures it in the initrd. So the
     # enrollment's policy was "PCR 15 and nothing else", which is the one policy a
     # host-side refresh can never reproduce.
     #
     # Both runs now pass --location=850-sysinit (vngrd-tpm-pcrlock.service and
     # systemd-pcrlock-make-policy.service.d/10-vngrd.conf), which requires every
     # component up to and including 800-leave-initrd and permits everything from
     # 850-sysinit on to be absent. Neither run binds PCR 15 (the host's record is
     # unrecognized; the enrollment's component is absent) and neither binds PCR
     # 11 (unmapped stub record). On the boot that provisions the two predictions
     # agree, so the host's first run is a no-op. The differences that appear from
     # the second boot on -- the one-off nvpcr-init record that unmaps PCR 9, the
     # GPT record that becomes stable only once repart has run -- are differences
     # this unit can write, because the session it must satisfy is built from the
     # old policy, whose PCRs have not moved.
     #
     # The systemd-pcrlock-make-policy.service.d/10-vngrd.conf drop-in is part of
     # the payload and carries the window; without it the unit runs with
     # upstream's 770, which skips 770-nvpcr-separator and drops PCR 9 from every
     # policy it computes.
     test -f "$dest/usr/lib/systemd/system/systemd-pcrlock-make-policy.service.d/10-vngrd.conf" || {
       echo "base-files.bst: systemd-pcrlock-make-policy.service.d/10-vngrd.conf is missing." >&2
       echo "  The host's make-policy would run with upstream's --location=770," >&2
       echo "  which skips 770-nvpcr-separator and silently drops PCR 9." >&2
       exit 1
     }
     grep -q '^ExecStart=/usr/lib/systemd/systemd-pcrlock --components=/var/lib/pcrlock.d --components=/usr/lib/pcrlock.d --pcr=7,13,14 --location=850-sysinit make-policy$' \
         "$dest/usr/lib/systemd/system/systemd-pcrlock-make-policy.service.d/10-vngrd.conf" || {
       echo "base-files.bst: make-policy drop-in is not pinned to --components=/usr/lib/pcrlock.d." >&2
       echo "  Without it the host computes a policy from /var/lib/pcrlock.d definitions" >&2
       echo "  the initrd cannot have, which is the second-boot failure." >&2
       exit 1
     }
     # And the enrollment's own line, asserted with the window in it: it decides
     # which components are required and therefore which PCRs the token is sealed
     # against.
     grep -q '^ExecStartPre=/usr/lib/systemd/systemd-pcrlock --components=/var/lib/pcrlock.d --components=/sysusr/usr/lib/pcrlock.d --pcr=7,13,14 --location=850-sysinit make-policy --policy=/sysroot/var/lib/systemd/pcrlock.json$' \
         "$dest/usr/lib/systemd/system/vngrd-tpm-pcrlock.service" || {
       echo "base-files.bst: the enrollment does not pin --components=/sysusr/usr/lib/pcrlock.d." >&2
       echo "  The initrd has no /usr/lib/pcrlock.d (it is seeded from an allow list" >&2
       echo "  that never included it), so a bare path loads no components: every" >&2
       echo "  record is unrecognized and the policy is PCR 15 alone." >&2
       exit 1
     }
     # The four definitions that make the policy cover anything must BE generated
     # here, at the same instant the prediction is computed. Measured: the host's
     # 240-secureboot-policy did not match the next initrd's log, and regenerating
     # it from that log moved the mask from "2, 3, 13, 14" to "0, 1, 2, 3, 7, ...".
     for c in lock-firmware-code lock-firmware-config lock-secureboot-policy \
              lock-secureboot-authority; do
       grep -q "^ExecStartPre=/usr/lib/systemd/systemd-pcrlock $c$" \
           "$dest/usr/lib/systemd/system/vngrd-tpm-pcrlock.service" || {
         echo "base-files.bst: the enrollment no longer runs $c." >&2
         echo "  The component and the prediction would then be computed from" >&2
         echo "  different points in the boot, and the PCR would go unrecognized." >&2
         exit 1
       }
     done
     # The rest stay out: they write into a /var the initrd cannot see at unseal
     # time, or claim a PCR no shipped component can cover.
     for bad in lock-gpt lock-file-system lock-machine-id lock-uki lock-pe; do
       if grep -q "systemd-pcrlock $bad" "$dest/usr/lib/systemd/system/vngrd-tpm-pcrlock.service"; then
         echo "base-files.bst: $bad is in the enrollment and must not be." >&2
         echo "  It writes to a /var the initrd cannot read, or claims a PCR no" >&2
         echo "  component can cover." >&2
         exit 1
       fi
     done
     # The two other paths the host can recompute a policy through: the
     # socket-activated varlink server (which inherits its location AND its
     # component search path from systemd-pcrlock@.service's command line) and
     # sysupdate's completion notify. Three paths, one window and one search
     # path; get either wrong in one of them and the policy changes shape
     # depending on which code path happened to run.
     for g in systemd-pcrlock@.service.d/10-vngrd.conf \
              systemd-sysupdate-notify-pcrlock@.service.d/10-vngrd.conf; do
       test -f "$dest/usr/lib/systemd/system/$g" || {
         echo "base-files.bst: $g is missing from the payload." >&2
         exit 1
       }
       grep -q '^ExecStart=/usr/lib/systemd/systemd-pcrlock --components=/var/lib/pcrlock.d --components=/usr/lib/pcrlock.d --pcr=7,13,14 --location=850-sysinit$' \
           "$dest/usr/lib/systemd/system/$g" || {
         echo "base-files.bst: $g is not pinned to --components=/usr/lib/pcrlock.d" >&2
         echo "  --location=850-sysinit." >&2
         exit 1
       }
     done
     # The host-side GPT lock is gone: its component lived in the host's
     # /var/lib/pcrlock.d, which no make-policy path reads any more, so it could
     # not contribute to the policy while still making the host's prediction
     # differ from the initrd's. Assert it stays out rather than trusting that.
     for g in usr/lib/systemd/system/vngrd-pcrlock-gpt.service \
              usr/lib/systemd/system/sysinit.target.wants/vngrd-pcrlock-gpt.service; do
       test -e "$dest/$g" && {
         echo "base-files.bst: $g is still in the payload." >&2
         echo "  Its component is invisible to the initrd and reaches nothing." >&2
         exit 1
       }
     done
     # The lock-* units stay enabled, and only the LINK is asserted: in this
    # element's own install root the target (a systemd unit) is absent, so the
    # link dangles here and only resolves in the published tree where
    # packages/systemd.bst is layered beside it. vngrd-rootfs's recipe asserts
    # the same links with -e, which works there because its install root is the
    # cumulative out/. The evidence these are about is the enablement, and that
    # is the link.
    for u in firmware-code firmware-config secureboot-policy secureboot-authority; do
      g="usr/lib/systemd/system/sysinit.target.wants/systemd-pcrlock-$u.service"
      [ -L "$dest/$g" ] || { echo "base-files.bst: $g must be a symlink" >&2; exit 1; }
    done

  strip-commands: []

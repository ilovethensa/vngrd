# shellcheck shell=bash
# mkosi hook bodies. Thin wrappers mkosi.finalize and mkosi.postoutput source
# this; both run on the host with mkosi-provided environment.

finalize_main() {
for d in bin sbin lib lib64; do
    if [ -e "$BUILDROOT/$d" ] || [ -L "$BUILDROOT/$d" ]; then
        echo "mkosi.finalize: ERROR: unexpected top-level /$d in image root (merged /usr only)" >&2
        ls -R "$BUILDROOT/$d" >&2 | head -n 20
        echo "hint: vngrd-kernel must install to /usr/lib/modules (INSTALL_MOD_PATH=/out/usr), not /lib/modules" >&2
        exit 1
    fi
done

if [ -d "$BUILDROOT/lib/modules" ]; then
    echo "mkosi.finalize: ERROR: stray /lib/modules found — package should install to /usr/lib/modules" >&2
    exit 1
fi

# mkosi expects /usr/lib/modules/<kver>/vmlinuz; vngrd-kernel ships /boot/vmlinuz.
if [ -f "$BUILDROOT/boot/vmlinuz" ]; then
    for kdir in "$BUILDROOT"/usr/lib/modules/*; do
        [ -d "$kdir" ] || continue
        if [ ! -f "$kdir/vmlinuz" ] && [ ! -f "$kdir/vmlinux" ]; then
            cp -a "$BUILDROOT/boot/vmlinuz" "$kdir/vmlinuz"
            echo "mkosi.finalize: copied /boot/vmlinuz -> ${kdir#"$BUILDROOT"}/vmlinuz"
        fi
    done
fi

# mkosi signs sd-boot to *.efi.signed before bootctl installs it; the host's
# vngrd-bootloader-sync copies that exact file. Fail loudly rather than let the
# unit fail on every boot. The unsigned .efi is deliberately not a fallback:
# Secure Boot would refuse it.
if [ ! -f "$BUILDROOT/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed" ]; then
    echo "mkosi.finalize: ERROR: the signed sd-boot is missing" >&2
    echo "  expected $BUILDROOT/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed" >&2
    echo "  vngrd-bootloader-sync copies it to the ESP on the host." >&2
    exit 1
fi

# mkosi writes only IMAGE_ID=/IMAGE_VERSION= into usr/lib/os-release. repart
# expands %A from IMAGE_VERSION for the slot labels, and sysupdate's
# ProtectVersion=%A reads it on the device, so VERSION_ID/PRETTY_NAME must be kept
# in step. The factory copy needs the same value: the image has no /etc, so the
# running system's /etc/os-release is seeded from usr/share/factory/etc. Missing
# IMAGE_VERSION makes %A expand empty and sysupdate drops ProtectVersion= with only
# a warning. Must run before step 5, which copies os-release to initrd-release.
# (vngrd-fixate-generator/include/rollback.h). It collides for two-digit minor or
# patch (0.10 == 1.0), so refuse such versions at build time instead of letting
# every installed machine loop on reboot. Grammar is MAJOR[.MINOR[.PATCH]].
if [ -n "${IMAGE_VERSION:-}" ]; then
    case "$IMAGE_VERSION" in
        *[!0-9.]*|.*|*.|*..*|*.*.*.*)
            echo "mkosi.finalize: IMAGE_VERSION='$IMAGE_VERSION' is not MAJOR[.MINOR[.PATCH]]" >&2
            echo "  rollback.h parses only dotted decimals with no suffix and at most" >&2
            echo "  three components; anything else would make every installed machine" >&2
            echo "  refuse its own version and fail to boot." >&2
            exit 1
            ;;
    esac
    IFS=. read -r _maj _min _pat <<<"$IMAGE_VERSION"
    : "${_min:=0}"
    : "${_pat:=0}"
    if [ "$_min" -gt 9 ] || [ "$_pat" -gt 9 ]; then
        echo "mkosi.finalize: IMAGE_VERSION='$IMAGE_VERSION' has a two-digit minor or patch" >&2
        echo "  The packing is major*100 + minor*10 + patch, so 0.10 collides with 1.0" >&2
        echo "  and 0.1.10 collides with 0.2.0. Widen the encoding in rollback.h (a" >&2
        echo "  deliberate change to the NV format) before shipping a version like this." >&2
        exit 1
    fi
    if [ "$((_maj * 100 + _min * 10 + _pat))" -le 0 ]; then
        echo "mkosi.finalize: IMAGE_VERSION='$IMAGE_VERSION' packs to index 0" >&2
        echo "  Zero is the value a missing rollback counter reads as, so a version" >&2
        echo "  that packs to it would be treated as 'never provisioned'." >&2
        exit 1
    fi
fi

if [ -n "${IMAGE_VERSION:-}" ] && [ -f "$BUILDROOT/usr/lib/os-release" ]; then
    # Rewrite via a temp file: /etc/os-release is a symlink into this one, and an
    # in-place edit would break the link or write through it.
    name=$(sed -n 's/^NAME=//p' "$BUILDROOT/usr/lib/os-release" | head -n 1)
    [ -n "$name" ] || name=vngrd
    tmp="$(mktemp)"
    sed -e '/^VERSION_ID=/d' -e '/^PRETTY_NAME=/d' "$BUILDROOT/usr/lib/os-release" > "$tmp"
    printf 'VERSION_ID=%s\nPRETTY_NAME="%s %s"\n' \
        "$IMAGE_VERSION" "$name" "$IMAGE_VERSION" >> "$tmp"
    cat "$tmp" > "$BUILDROOT/usr/lib/os-release"
    rm -f "$tmp"
    if [ -d "$BUILDROOT/usr/share/factory/etc" ]; then
        cp "$BUILDROOT/usr/lib/os-release" "$BUILDROOT/usr/share/factory/etc/os-release"
        echo "mkosi.finalize: $IMAGE_VERSION -> usr/lib/os-release and the factory copy"
    else
        echo "mkosi.finalize: $IMAGE_VERSION -> usr/lib/os-release (no factory/etc to mirror)"
    fi
else
    echo "mkosi.finalize: WARNING: IMAGE_VERSION unset or usr/lib/os-release missing," >&2
    echo "mkosi.finalize: VERSION_ID/PRETTY_NAME left alone and %A will expand empty." >&2
fi

# MakeInitrd=yes pre-creates /etc/initrd-release as a dangling absolute symlink
# before finalize. Test with -e/-L (not -f) and never cp through the symlink:
# GNU cp refuses a dangling target. Only create a real file when nothing is there.
if [ ! -e "$BUILDROOT/etc/initrd-release" ] && [ ! -L "$BUILDROOT/etc/initrd-release" ] \
   && [ -f "$BUILDROOT/usr/lib/os-release" ]; then
    cp -a "$BUILDROOT/usr/lib/os-release" "$BUILDROOT/etc/initrd-release"
fi

echo "mkosi.finalize: finalize complete (BUILDROOT=$BUILDROOT)"
}

postoutput_main() {
command -v xz >/dev/null 2>&1 || { echo "mkosi.postoutput: xz not found" >&2; exit 1; }

# Tools from the mkosi tools tree by absolute path: two of them are load-bearing
# for checks that must not be foolable, so do not resolve by search order.
mtools="$SRCDIR/mkosi.tools/usr/bin"

# Published next to the image for offline enrolment. Deliberately not copied to
# loader/keys/auto: SecureBootAutoEnroll=no closes the pre-first-boot ESP window,
# and these files are the replacement procedure.
# The key directory is mounted read-only by build.sh's mkosi_build() and named via
# the environment; postoutput's sandbox does not otherwise see it.
sb_dir="$OUTPUTDIR/secureboot"
sb_key=${VNGRO_SB_KEY:-}
sb_cert=${VNGRO_SB_CERT:-}
sb_work="$OUTPUTDIR/.sb-auth-work"
rm -rf "$sb_dir" "$sb_work"
mkdir -p "$sb_dir" "$sb_work"

if [ -r "$sb_key" ] && [ -r "$sb_cert" ]; then
    sb_owner=00000000-0000-0000-0000-000000000000
    openssl x509 -in "$sb_cert" -outform DER -out "$sb_work/vngrd.der" || {
        echo "mkosi.postoutput: ERROR: cannot DER-encode $sb_cert" >&2
        exit 1
    }
    "$mtools/sbsiglist" --owner "$sb_owner" --type x509 \
        --output "$sb_work/vngrd.esl" "$sb_work/vngrd.der" || exit 1

    # db is a concatenation of ESLs, one per certificate. PK and KEK contain
    # only the vngrd certificate: Microsoft may sign a boot component, but it
    # may not rewrite db or replace the platform key.
    cat "$sb_work/vngrd.esl" >"$sb_work/db.esl"
    for c in "$SRCDIR"/keys/*.der; do
        [ -f "$c" ] || continue
        base=$(basename "$c" .der)
        "$mtools/sbsiglist" --owner "$sb_owner" --type x509 \
            --output "$sb_work/$base.esl" "$c" || exit 1
        cat "$sb_work/$base.esl" >>"$sb_work/db.esl"
    done
    cp "$sb_work/vngrd.esl" "$sb_work/PK.esl"
    cp "$sb_work/vngrd.esl" "$sb_work/KEK.esl"

    for var in PK KEK db; do
        "$mtools/sbvarsign" \
            --key "$sb_key" --cert "$sb_cert" \
            --attr NON_VOLATILE,BOOTSERVICE_ACCESS,RUNTIME_ACCESS \
            --output "$sb_dir/$var.auth" "$var" "$sb_work/$var.esl" || {
            echo "mkosi.postoutput: ERROR: could not sign $var.auth" >&2
            exit 1
        }
    done
else
    echo "mkosi.postoutput: ERROR: no Secure Boot key in the sandbox" >&2
    echo "  -> run ./build.sh, which mounts the key directory for this hook;" >&2
    echo "     a bare 'mkosi build' cannot produce signed enrolment updates" >&2
    exit 1
fi
rm -rf "$sb_work"
for var in PK KEK db; do
    [ -s "$sb_dir/$var.auth" ] || {
        echo "mkosi.postoutput: ERROR: $var.auth was not produced" >&2
        exit 1
    }
    printf 'mkosi.postoutput: published secureboot/%s.auth (%s bytes)\n' \
        "$var" "$(stat -c %s "$sb_dir/$var.auth")"
done

: "${IMAGE_VERSION:?mkosi.postoutput: \$IMAGE_VERSION is not set}"
ver="$IMAGE_VERSION"
prefix="vngrd_${ver}"
published=""

# $OUTPUTDIR is the staging tree mkosi rebuilds every build; $out_dir is
# OutputDirectory=, where published artifacts accumulate. mkosi does not export
# the latter, so read it back out of the config, using the same concatenation
# mkosi reads (mkosi.conf then mkosi.conf.d/*.conf, later wins).
od=$(cat "$SRCDIR/mkosi.conf" "$SRCDIR"/mkosi.conf.d/*.conf 2>/dev/null |
    sed -n 's/^OutputDirectory=//p' | tail -n 1)
[ -n "$od" ] || { echo "mkosi.postoutput: cannot find OutputDirectory= in mkosi.conf" >&2; exit 1; }
case "$od" in /*) out_dir="$od" ;; *) out_dir="$SRCDIR/$od" ;; esac

# The sweep lives in lib/image.sh sweep_stale(), outside the sandbox: here
# $OUTPUTDIR is the staging tree, and OutputDirectory=../output/image does not
# resolve. `mkosi build --force` also only removes mkosi's declared outputs, not
# the renamed .usr.xz/.verity.xz payloads.

# Two settings, written as one file. The first is about booting at all; the
# second is about the command line that carries usrhash=, i.e. about dm-verity
# staying meaningful. Detail, and why there is deliberately no `timeout' line,
# at the heredoc.
# secure-boot-enroll force is the most important line in the image for whether a
# fresh install boots on bare metal at all. It is not a security control, and
# saying so matters: the security anchor is usrhash= inside the signed .cmdline,
# plus lockdown=integrity in that same line. Force is a 100%-failure-rate
# availability fix, and it is not here by default.
# What actually makes it work is two independent gates, and only the first one is
# usually written down. secure_boot_discover_keys() at src/boot/boot.c:2698-2704:
#     static EFI_STATUS secure_boot_discover_keys(Config *config, EFI_FILE *root_dir) {
#             if (!IN_SET(secure_boot_mode(), SECURE_BOOT_SETUP, SECURE_BOOT_AUDIT))
#                     return EFI_SUCCESS;
# is the load-bearing one. loader/keys/auto/ is never even opened unless the
# platform reports setup or audit mode, whatever secure-boot-enroll= says. A
# retail laptop in *user* mode with an OEM-signed PK and Microsoft's db enrolled
# reads this line, declines to look at the keys, and never reaches the second
# gate. Installation therefore requires the user to enter firmware setup and
# clear the Secure Boot keys; README.md documents that as a deliberate,
# user-visible step, and edk2's AuthService.c:720-724 is the other half of it --
# it routes every one of the four writes through VerifyTimeBasedPayloadAndUpdate,
# which demands a signature by the current PK or KEK, and the vngrd cert is
# neither, so the write is refused with EFI_SECURITY_VIOLATION.
# The second gate is the one force overrides, at src/boot/secure-boot.c:80-85:
#     /* Enrolling secure boot keys is safe to do in virtualized environments as
#      * there is nothing we can brick there. */
#     bool is_safe = in_hypervisor();
#     if (!is_safe && !force)
#             return EFI_SUCCESS;
# That is a silent no-op returning success, not an error: in setup mode on bare
# metal without force, the keys sit unread, the firmware rejects the UKI (it is
# not signed by anything in the retail db), and the machine stops with the OEM's
# own "Invalid signature" screen. The default is silent because it is right for a
# development VM and catastrophic for a distribution; every test in tests/ runs
# under KVM, where in_hypervisor() is true, so the default path is the only path
# that has ever been exercised -- which is exactly why this looked like it worked.
# Values in 257.5 are off / manual / if-safe / force (parser at boot.c:1279-1290,
# default ENROLL_IF_SAFE at boot.c:1586, enum at src/boot/secure-boot.h:5-9).
# `force' is what this file writes and it is correct as written.
# WHAT IS STILL OPEN, and is not closed by anything in this image: in setup mode
# the three platform keys are files on the ESP, and secure_boot_enroll_at() at
# src/boot/secure-boot.c:145-159 will read a PK with no signature in it
# (sigsize <= 24, i.e. header plus type GUID and nothing more), print "PK is not
# signed (need custom mode)", auto-enable CustomMode at :162-169, and then write
# the PK *unauthenticated*. So anyone who can write the image before its first
# boot permanently replaces the root of trust -- silently, and the machine then
# looks completely normal afterwards. This window is inherent to shipping
# unenrolled keys on the image; do not describe the image as closing it.
# Written here rather than in mkosi.finalize because mkosi runs `bootctl
# install' to populate the ESP, and bootctl writes loader/loader.conf from its
# own template *after* finalize -- byte for byte the two commented lines
# "#timeout 3" / "#console-mode keep". Whatever finalize put there would be
# overwritten. postoutput runs last.
# Nothing else in the ESP is touched: the UKI is left byte-identical, so the
# .efi split artifact published below and the copy inside the image stay the same
# file. The ESP is not verity'd, so this does not affect any hash.
if [ -n "${SKIP_LOADER_CONF:-}" ]; then
    # Skipping is allowed but it is no longer a bare flag with an `echo' next to
    # it. Two settings are being skipped and one of them is a security control
    # whose absence is completely silent -- a bootctl template loader.conf
    # produces looks exactly like a correct one apart from a missing line, and
    # the machine boots either way. So: an unrecognised value is a build failure
    # (a typo must not silently disable `editor no'), and a recognised one is a
    # loud multi-line warning on stderr that names what is missing and what it
    # costs. Only these two values are accepted; both mean the same thing.
    case "$SKIP_LOADER_CONF" in
        yes|force)
            cat >&2 <<EOF
================================================================
  mkosi.postoutput: SKIP_LOADER_CONF=$SKIP_LOADER_CONF
  The ESP loader/loader.conf was NOT patched. This image will
  carry whatever 'bootctl install' wrote instead, i.e. almost
  certainly neither of the two lines this script exists to write.

  editor no missing     ->  the 'e' key handler is live on a
                             command line carrying usrhash=.

  enroll force missing  ->  on bare metal the firmware rejects
                             the UKI and the machine stops at
                             the OEM's own "Invalid signature"
                             screen.

  Both absences are silent. Nothing downstream will notice.
================================================================
EOF
            ;;
        *)
            echo "mkosi.postoutput: ERROR: SKIP_LOADER_CONF=$SKIP_LOADER_CONF is not a recognised value" >&2
            echo "mkosi.postoutput: it must be 'yes' or 'force' (both skip the ESP patch deliberately)," >&2
            echo "mkosi.postoutput: or unset it to have loader/loader.conf written and verified." >&2
            exit 1
            ;;
    esac
else
    # Where the built image is right now. mkosi runs postoutput *before* it moves
    # the staging tree to OutputDirectory=, so $OUTPUTDIR is the reliable answer
    # and the final directory usually does not exist yet -- trying it first is
    # what made the first version of this fail with
    # "/work/src/../output/image not found". $out_dir is the real
    # OutputDirectory= and is only a fallback for the case where mkosi ever
    # changes the order.
    img=""
    for dir in "$OUTPUTDIR" "$out_dir"; do
        [ -n "$dir" ] && [ -f "$dir/$prefix.raw" ] || continue
        img="$dir/$prefix.raw"
        echo "mkosi.postoutput: patching the ESP in $dir"
        break
    done
    [ -n "$img" ] || { echo "mkosi.postoutput: cannot find $prefix.raw in \$OUTPUTDIR or $out_dir" >&2; exit 1; }

    [ -x "$mtools/mcopy" ] || { echo "mkosi.postoutput: $mtools/mcopy missing" >&2; exit 1; }
    [ -x "$mtools/sfdisk" ] || { echo "mkosi.postoutput: $mtools/sfdisk missing" >&2; exit 1; }

    # This used to be `skip=2048' and `320 * 1024 * 1024 / 512' literals, i.e.
    # the first-partition alignment convention and the size in 00-esp.conf,
    # hardcoded in a script that rewrites the image. A repart change -- a bigger
    # ESP, an added partition ahead of it, a different alignment -- would leave
    # both numbers silently wrong, and the failure mode is the worst available:
    # dd with count= reads whatever happens to be at that offset and writes it
    # back over whatever now lives there, so a stale LBA corrupts a partition
    # that was perfectly fine one build earlier and the image still boots.
    # Read the table instead. Same idiom as verify_geometry() in
    # tests/lib/common.sh, which exists for the same reason.
    esp_gpt=$("$mtools/sfdisk" -d "$img" 2>/dev/null | tr 'A-F' 'a-f')
    [ -n "$esp_gpt" ] || { echo "mkosi.postoutput: ERROR: sfdisk -d read no partition table from $img" >&2; exit 1; }
    # An unreadable layout is a failure, not something to guess at.
    case "$esp_gpt" in
        *"sector-size: 512"*) ;;
        *)
            echo "mkosi.postoutput: ERROR: $img is not 512-byte-sector, or sfdisk changed its output" >&2
            echo "mkosi.postoutput: the dd below hardcodes bs=512 and would corrupt it" >&2
            printf '%s\n' "$esp_gpt" | sed 's/^/  /' >&2
            exit 1
            ;;
    esac
    # C12A7328-F81F-11D2-BA4B-00A0C93EC93B is the GPT type of an EFI system
    # partition. Match on the type rather than on Label=vngrd-esp, so renaming
    # the label does not break this, and match it more than once is an error
    # rather than a coin flip on which ESP to rewrite.
    esp_rows=$(printf '%s\n' "$esp_gpt" | grep -c 'type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b' || :)
    [ "$esp_rows" -eq 1 ] || {
        echo "mkosi.postoutput: ERROR: expected exactly one ESP in the GPT, found $esp_rows" >&2
        printf '%s\n' "$esp_gpt" | sed 's/^/  /' >&2
        exit 1
    }
    esp_row=$(printf '%s\n' "$esp_gpt" | grep 'type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b')
    # sfdisk right-aligns its numbers and separates fields with ", ", so both the
    # leading whitespace and the trailing comma have to come off.
    esp_lba=$(printf '%s\n' "$esp_row" | sed 's/,/ /g' |
        sed -n 's/.*[^[:space:]]*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    esp_sectors=$(printf '%s\n' "$esp_row" | sed 's/,/ /g' |
        sed -n 's/.*[^[:space:]]*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    case "$esp_lba:$esp_sectors" in
        *[!0-9:]*|:|*:)
            echo "mkosi.postoutput: ERROR: could not read start/size of the ESP out of sfdisk -d" >&2
            echo "  row: $esp_row" >&2
            exit 1
            ;;
    esac
    [ "$esp_sectors" -gt 0 ] || { echo "mkosi.postoutput: ERROR: ESP size is 0 sectors" >&2; exit 1; }
    echo "mkosi.postoutput: ESP at LBA $esp_lba, $esp_sectors sectors (read from the GPT)"

    esp_tmp=$(mktemp /tmp/vngrd-esp-XXXXXX.img)
    trap 'rm -f "$esp_tmp" "$esp_tmp.loaderconf"' EXIT INT TERM
    dd if="$img" of="$esp_tmp" bs=512 skip="$esp_lba" count="$esp_sectors" status=none

    # Two settings. Only the second is security; the first is a 100%-failure-rate
    # fix for bare metal.
    # secure-boot-enroll force
    #   See the block comment above. Without it the machine does not boot on
    #   bare metal and does not say so.
    # editor no
    #   Removes the 'e' key handler outright (boot.c:995-998, config->editor,
    #   default true at boot.c:1583), for every entry type, whether or not
    #   Secure Boot is on. It currently changes nothing for the shipped image:
    #   boot.c:1002-1010 already refuses to edit a LOADER_UNIFIED_LINUX entry
    #   that carries embedded options while secure_boot_enabled(), which is
    #   exactly what the factory entry is (type #2 auto-detected UKI with a
    #   .cmdline section). That refusal is load-bearing and worth stating here
    #   rather than relying on:
    #     * it only applies because the UKI has an embedded .cmdline. An entry
    #       with no embedded options takes its command line from the loader and
    #       would be editable.
    #     * it only applies to the auto-detected entry. A type #1
    #       loader/entries.d/*.conf entry is not covered by boot.c:1002-1010's
    #       refusal, and this comment used to say the reason that directory must
    #       stay empty is that such a file "hands the kernel a different usrhash=
    #       with nothing but ESP write access". That is wrong, and it is worth
    #       being precise about, because the wrong reason is the easy one to
    #       re-derive and the hard one to check. The loader cannot reach the
    #       kernel with its own options at all here: src/boot/stub.c:1135-1148
    #           if (!isempty(*cmdline)) {
    #                   if (secure_boot_enabled() && (PE_SECTION_VECTOR_IS_SET(sections + UNIFIED_SECTION_CMDLINE) || is_confidential_vm()))
    #                           *cmdline = mfree(*cmdline);   /* Drop the custom cmdline */
    #       and the shipped UKI does embed a .cmdline (objdump -h lists it), so
    #       Secure Boot is on, so anything sd-boot passed in -- the `options='
    #       line, or the whole of an entry's type #2 entry->options -- is dropped
    #       by the stub before the kernel is entered. On the sd-boot side there
    #       is a second layer that does not even depend on the stub: reading an
    #       embedded .cmdline sets entry->options_implied (boot.c:2356-2357), and
    #       boot.c:2584 then passes NULL rather than the entry's options. `efi='
    #       is not a way around any of this either -- the image goes through
    #       shim_load_image() (boot.c:2557-2558), so the firmware still validates
    #       it; `initrd=' is parsed for LOADER_LINUX only (boot.c:1504-1510), so
    #       systemd-stub has no external-initrd path to abuse; and `devicetree='
    #       is skipped outright while Secure Boot is on (boot.c:2565).
    #       So the directory still has to stay empty, but for the reasons that
    #       actually hold: it is unsigned plaintext boot configuration, and
    #       changing WHICH image boots is still open. An `efi=' pointing at a
    #       *different UKI that vngrd signed* -- the previous slot's, after an
    #       update -- passes Secure Boot and rolls the machine back to a slot
    #       with its own, different usrhash=, with no boot counter consumed
    #       (those live in the EFI/Linux file name, which loader/entries.d/ does
    #       not manage: InstancesMax= in 70-uki.transfer only reaches
    #       EFI/Linux/*.efi). That is the A/B rollback control being bypassed, and
    #       it is a real risk even though usrhash= is not what is at stake.
    #       Entries there can also set console-mode=, timeout= and entry titles,
    #       which is a user-deception surface. One correction to a claim that
    #       used to sit here: loader/entries.srel is NOT a sd-boot input. sd-boot
    #       has no reference to it anywhere in src/boot/; it is a kernel-install
    #       layout selector (src/kernel-install/kernel-install.c:745-764,
    #       man/kernel-install.xml:492), where content `type1' selects LAYOUT_BLS
    #       -- and BLS is what writes .conf files. So the file is inert at boot
    #       and cannot cause auto-discovery by itself; a .conf still has to be
    #       written by hand. Keep the directory empty anyway, for the reasons
    #       above.
    #       There are no such files in the image -- loader/entries.d/ is not
    #       created at all -- and the check below reads loader.conf back so a
    #       silent no-op cannot pass. Keep it that way.
    #   README.md:230-247 repeats the refuted version of this claim ("a single
    #       such file hands the kernel a different usrhash= with nothing but ESP
    #       write access -- which is to say, without breaking one signature",
    #       and "Adding a loader/entries.d/ entry gives up dm-verity's root
    #       hash"). It is correct that the directory must stay empty and that
    #       nothing in the tree manages it; the sentence explaining why is wrong
    #       for the reason above. It also cites boot.c:1002-1010 as the protection,
    #       which is the sd-boot-side half only and is true but not the reason.
    #       README.md:248-256 credits lockdown with refusing bpf(2) and
    #       perf_event_open(2) and stopping unsigned kexec: kexec is closed by
    #       CONFIG_KEXEC=n (there is no /proc/kexec node), CONFIG_BPF_SYSCALL is
    #       not set so there is no bpf(2), and perf_event_open(2) is not refused
    #       wholesale. mkosi.conf's own comment block has been corrected; the
    #       README text has not and is owned elsewhere.
    #   ON TPM2 AND THE ESP: this comment used to say sd-boot logs the command
    #   line to the TPM (true: boot.c:2611 calls tpm_log_load_options()) and that
    #   is "why the ESP carries tpm2-pcr-public-key.pem and tpm2-pcr-signature.json",
    #   and that the seal is PCR 7. Three separate errors. The ESP carries
    #   neither file -- it holds EFI/{Linux,systemd,BOOT}/, `config', `vmlinuz',
    #   loader/{entries/,entries.srel,keys/auto/,loader.conf}, the UKI and
    #   sd-boot. systemd-stub never put them on the ESP: it wraps the .pcrsig and
    #   .pcrpkey PE sections in a cpio at /.extra/ *inside the initrd*
    #   (stub.c:880-915) and tmpfiles.d/20-systemd-stub.conf.in copies them to
    #   /run/systemd/ afterwards, and only if those sections exist at all -- the
    #   shipped UKI has neither (its sections are .sdmagic .osrel .cmdline .uname
    #   .linux .initrd .sbat), so there is nothing to copy. And the PCR extended
    #   by tpm_log_load_options() is TPM2_PCR_KERNEL_CONFIG = 12
    #   (src/boot/measure.c:304-312, src/fundamental/tpm2-pcr.h:33), not PCR 7;
    #   PCR 7 is the secure-boot policy.
    #   THE ACTUAL ANSWER, and it is worse than the claim it replaces: there is no
    #   detection of a rewritten or replaced ESP anywhere in this design. The ESP
    #   is not verity'd (see above), nothing measures it, nothing seals it, and
    #   no PCR signature is carried. Secure Boot authenticates exactly one thing
    #   in it -- the UKI it is asked to load -- and says nothing about
    #   loader/loader.conf, loader/entries.srel, an entries.d/*.conf dropped
    #   afterwards, or the FAT filesystem itself. So ESP write access is enough to
    #   change the boot configuration and to roll back to another signed slot, and
    #   there is no attestation that would show it happened. Do not describe this
    #   image as detecting ESP tampering.
    # NO `timeout' LINE, ON PURPOSE. This file previously carried `timeout 0',
    # on the reasoning that boot.c:1226 maps 0 to TIMEOUT_MENU_DISABLED and
    # boot.c:2907 then skips the menu loop, so the menu -- and with it the 'e'
    # key -- would be gone. The source does say that. It was still wrong to
    # ship, for two reasons that only the commit history makes visible:
    #   1. `timeout 3' was tried in this same file once already and it bricked
    #      the headless case: sd-boot takes the interactive path on every boot
    #      and the machine stopped after "Custom Secure Boot keys successfully
    #      enrolled, rebooting the system now!", measured at 480s and a 416-byte
    #      serial log against a login prompt in 20s with no timeout set. The
    #      failure was in the enrolment *reboot*, not in the countdown, and
    #      nothing in the source distinguishes a value that trips it from one
    #      that does not. `timeout 0' was therefore an untested value in an
    #      untested class, on the one path that has already broken once.
    #   2. The menu is not what protects usrhash= -- `editor no' plus
    #      boot.c:1002-1010 do that, and the boot menu is systemd's default on
    #      this image. So `timeout 0' bought nothing that `editor no' does not
    #      buy more safely, and cost a change to the riskiest line in the file.
    # If the menu ever does need to go, the way to do it is a measured change
    # with a full provision-to-login run behind it, not a source-reading
    # argument. The 416-byte log is what a failure here looks like, and it is
    # easy to mistake for the firmware failing to find a boot option.
    # The autoenroll profile makes mkosi generate its own PK/KEK/db.auth from
    # the signing certificate alone. Replace them with the published set so the
    # disposable VM enrols the same db (including the Microsoft 2023 CAs) that
    # an offline install would. Production has no such directory and this is a
    # no-op.
    if MTOOLS_SKIP_CHECK=1 "$mtools/mtype" -i "$esp_tmp" \
        ::/loader/keys/auto/PK.auth >/dev/null 2>&1; then
        for var in PK KEK db; do
            MTOOLS_SKIP_CHECK=1 "$mtools/mcopy" -i "$esp_tmp" -o \
                "$sb_dir/$var.auth" "::/loader/keys/auto/$var.auth" || {
                echo "mkosi.postoutput: ERROR: could not replace $var.auth on the ESP" >&2
                exit 1
            }
        done
        echo "mkosi.postoutput: replaced the autoenroll ESP keys with secureboot/*.auth"
    fi

    # Does this build carry its own enrolment keys? Production does not
    # (SecureBootAutoEnroll=no): loader/keys/auto is absent, and the honest
    # setting is `off', not `force'. Force with no keys would look like an
    # enrolment path while doing nothing, and it invites someone to drop keys on
    # the ESP later, which is the trust window this default closes. The
    # autoenroll profile is the only build that should say `force'.
    if MTOOLS_SKIP_CHECK=1 "$mtools/mtype" -i "$esp_tmp" \
        ::/loader/keys/auto/PK.auth >/dev/null 2>&1; then
        enroll_line="secure-boot-enroll force"
    else
        enroll_line="secure-boot-enroll off"
    fi

    cat > "$esp_tmp.loaderconf" <<EOF
# Written by mkosi.postoutput. Replaces what \`bootctl install' writes here, which
# is a template with both of its own settings commented out; see that script for
# why this file has to exist at all.
$enroll_line
editor no
EOF

    # -o is mandatory on overwrite and mcopy exits 1 *silently* without it, which
    # would leave the template in place and produce a machine that does not boot
    # with no indication of why. MTOOLSRC is mtools' config-file variable, not
    # the image, so it must not be set.
    MTOOLS_SKIP_CHECK=1 "$mtools/mcopy" -i "$esp_tmp" -o \
        "$esp_tmp.loaderconf" ::/loader/loader.conf \
        || { echo "mkosi.postoutput: ERROR: could not write loader/loader.conf" >&2; exit 1; }
    rm -f "$esp_tmp.loaderconf"

    # Read it back rather than trusting the exit status. Both lines, not just the
    # enroll one: `editor no' is a security control whose absence is completely
    # silent, and a partially-written loader.conf is the exact shape of "the
    # build looked fine".
    if MTOOLS_SKIP_CHECK=1 "$mtools/mdir" -i "$esp_tmp" ::/loader/loader.conf >/dev/null 2>&1; then
        got_conf="$(MTOOLS_SKIP_CHECK=1 "$mtools/mtype" -i "$esp_tmp" ::/loader/loader.conf 2>/dev/null)"
        missing=""
        for want in "$enroll_line" 'editor no'; do
            printf '%s\n' "$got_conf" | grep -qx "$want" || missing="$missing
  $want"
        done
        if [ -z "$missing" ]; then
            echo "mkosi.postoutput: wrote loader/loader.conf ($enroll_line, editor off)"
        else
            echo "mkosi.postoutput: ERROR: loader/loader.conf is missing:$missing" >&2
            printf '%s\n' "$got_conf" | grep -qx 'editor no' || {
                echo "  The image will boot, but the 'e' command-line editor is enabled" >&2
                echo "  on a command line that carries usrhash=." >&2
            }
            printf '%s\n' "$got_conf" | grep -qx "$enroll_line" || {
                echo "  Secure Boot enrolment is not in the state this build intended." >&2
                echo "  An autoenroll image needs 'force'; a production image needs 'off'." >&2
            }
            exit 1
        fi
    else
        echo "mkosi.postoutput: ERROR: loader/loader.conf did not take" >&2
        exit 1
    fi

    # conv=sparse, not a plain write. The ESP slice is ~320M of mostly-NUL FAT
    # (whatever repart sized it to; that number is now read, not assumed), and dd
    # without conv=sparse allocates all of it: the image went from consuming
    # 177M to 454M on disk, for a 28-byte file. mkosi's own raw is sparse
    # throughout, so the hole-punching has to be preserved across this write.
    # $esp_lba, not the 2048 that used to be hardcoded here. This is the write
    # that actually destroys data when the number is wrong, and it is the reason
    # the read above hard-fails rather than warning: an unreadable or ambiguous
    # partition table must stop the build, not fall back to a convention.
    dd if="$esp_tmp" of="$img" bs=512 seek="$esp_lba" count="$esp_sectors" \
        conv=sparse,notrunc status=none
    rm -f "$esp_tmp"
    trap - EXIT INT TERM
fi

# The sweep of the previous build's artifacts happens at the top of this file, right
# after $out_dir is resolved: it has to be at the top level and able to fail, and it
# used to sit here, inside conditional code, where it printed nothing while sixteen
# orphaned payload sets accumulated in output/image/.

# This used to be optional, and optional is the whole bug. The design's
# invariant is that the UKI's signed .cmdline carries usrhash= and that the
# payload partitions are addressed by the two halves of that same hash; the
# published filenames and the manifest below are all derived from it. So a build
# that produced a validly signed UKI with no usrhash= in it is a build whose
# entire security argument is absent, and nothing downstream can tell: /usr still
# mounts, the machine still boots, and the only symptom is that /usr is not
# verified at all.
# mkosi will not tell us either. It is not reachable in this repo's committed
# configuration -- mkosi only ever defers esp,xbootldr (__init__.py:4162),
# Priority= defaults to 0 and is never dropped, and 10-usr.conf pins a fixed size
# with no Minimize= -- but that is an accident of four independent defaults.
# Add Minimize= to 10-usr.conf and the verity hash partition is sized from the
# data partition instead, repart reports its roothash as the literal "TBD", and:
#   mkosi/partition.py:50-71   finalize_roothash() returns None on "TBD"
#   mkosi/__init__.py:1962-1973 finalize_cmdline()  `if roothash: cmdline += [roothash]`
#   mkosi/__init__.py:3591-3598 the only verity die() in the build path, and it
#                              is gated on `verity == Verity.signed'. Verity=hash
#                              (what this image uses) has no counterpart, and
#                              there is no config knob that makes it fatal.
# The check below is the design's invariant, not a proxy for it: the file has to
# be there, and it has to be the same value the signed UKI commits to.
[ -e "$OUTPUTDIR/$prefix.roothash" ] || {
    echo "mkosi.postoutput: ERROR: $prefix.roothash not found in \$OUTPUTDIR" >&2
    echo "mkosi.postoutput: without it the UKI's .cmdline has no usrhash=, /usr is not" >&2
    echo "mkosi.postoutput: verified, and the payload filenames below cannot be derived." >&2
    echo "mkosi.postoutput: check [Output] Verity= and SplitArtifacts=roothash in mkosi.conf," >&2
    echo "mkosi.postoutput: and the Type=/Verity= settings in mkosi.repart/." >&2
    exit 1
}
roothash=$(cat "$OUTPUTDIR/$prefix.roothash")
case "$roothash" in
    *[!0-9a-fA-F]*|"")
        echo "mkosi.postoutput: ERROR: $prefix.roothash is not a bare hex digest: '$roothash'" >&2
        exit 1
        ;;
esac
[ "${#roothash}" -eq 64 ] || {
    echo "mkosi.postoutput: ERROR: $prefix.roothash is ${#roothash} characters, expected 64" >&2
    echo "mkosi.postoutput: sha256 is 256 bits; a 128-bit verity hash would not be signed .cmdline material" >&2
    exit 1
}
# The two partition UUIDs, and they are not decoration: repart derives the data
# partition's UUID from the first 128 bits of this hash and the verity
# partition's from the last 128, which is why initrd-usr-fs can resolve both
# devices from usrhash= alone (veritysetup-generator.c:255-279 memcpy's the
# first and last 16 bytes of the hash into the two sd_id128_t's and builds
# /dev/disk/by-partuuid from them). Checked against the shipped image:
#   17d06f614cb03a87af0aca26ab106f913da44e5d13974a0b38f2831b8b00837d
#   data   17D06F61-4CB0-3A87-AF0A-CA26AB106F91
#   verity 3DA44E5D-1397-4A0B-38F2-831B8B00837D
# So the published filenames are a function of this file and nothing else, and
# asserting them here closes the run#1-vs-run#3 gap: the UKI's usrhash= comes
# from repart run #1 (install_kernel, before the ESP is formatted) while the
# .verity.xz and this .roothash come from run #3 ("Extracting partitions").
first32=$(printf '%s' "$roothash" | cut -c1-32)
last32=$(printf '%s' "$roothash" | cut -c33-64)
echo "mkosi.postoutput: verity root hash $roothash (usr uuid $first32, verity uuid $last32)"

found_usr=0
found_verity=0
for f in "$OUTPUTDIR"/*.usr.raw "$OUTPUTDIR"/*.verity.raw; do
    [ -e "$f" ] || continue
    case "$f" in
        *.usr.raw)   kind=usr ;;
        *.verity.raw) kind=verity ;;
    esac
    # Take the UUID and the kind off the end of the name. Anchoring on the
    # trailing "-<uuid>.<kind>" rather than on the version keeps this working for
    # any version string (0.2 has a dot, which [^.]* cannot span) and doubles as
    # a shape check: if repart's naming ever changes, this fails loudly instead
    # of publishing something sysupdate cannot match.
    #   vngrd_0.1.vngrd-0.1-<uuid>.usr.raw -> <uuid> usr
    # %U renders as 32 hex characters with no separators (sd_id128 without UUID),
    # not the dashed form the GPT shows. systemd-sysupdate's
    # sd_id128_from_string() accepts both, so the compact form is fine to keep in
    # the filename; it is the same 128 bits either way.
    ident=$(basename "$f" .raw | sed -n \
        's/^.*[^0-9a-fA-F]\([0-9a-fA-F]\{32\}\)\.\(usr\|verity\)$/\1 \2/p')
    if [ -z "$ident" ]; then
        echo "mkosi.postoutput: ERROR: unexpected split filename '$(basename "$f")'" >&2
        echo "mkosi.postoutput: expected '...-<32 hex digits>.$kind.raw' -- check SplitName= in mkosi.repart/" >&2
        exit 1
    fi
    # The UUID on the filename is the one systemd-sysupdate fixates onto the
    # partition it writes, so it has to be the half of the root hash that the
    # UKI's usrhash= will make the initrd look that partition up by. This is
    # where that is checked rather than assumed: a mismatch here is an update
    # that installs cleanly and then fails to mount on the next boot, and the
    # build says nothing.
    case "$kind" in
        usr)    want_uuid="$first32" ;;
        verity) want_uuid="$last32" ;;
    esac
    new="${prefix}_${ident% *}.${ident#* }"
    if [ "${ident% *}" != "$want_uuid" ]; then
        echo "mkosi.postoutput: ERROR: $(basename "$f") carries partition UUID ${ident% *}" >&2
        echo "mkosi.postoutput: but the root hash says the $kind partition is $want_uuid" >&2
        echo "  roothash: $roothash" >&2
        echo "mkosi.postoutput: publishing this would produce a payload sysupdate installs and" >&2
        echo "mkosi.postoutput: the new UKI cannot find. Refusing to publish." >&2
        exit 1
    fi
    [ "$new" = "${prefix}_${want_uuid}.${kind}" ] || {
        echo "mkosi.postoutput: ERROR: computed name '$new' does not have the expected shape" >&2
        exit 1
    }
    xz -T0 -f "$f"
    mv "$f.xz" "$OUTPUTDIR/$new.xz"
    published="$published $new.xz"
    # Counters, not flags. These were `found_usr=1' / `found_verity=1', so two
    # .usr.raw files both set the same variable to 1, the `!= 1' guard below
    # passed, and both were published and entered SHA256SUMS -- while the error
    # message claimed it expected "exactly one". The invariant being asserted is
    # uniqueness, so it has to be counted.
    case "$kind" in
        usr)    found_usr=$((found_usr + 1)) ;;
        verity) found_verity=$((found_verity + 1)) ;;
    esac
    echo "mkosi.postoutput: published $new.xz"
done

# Both halves of a slot are useless alone, and their absence is the difference
# between "updates are available" and "the system silently never updates".
if [ "$found_usr" -ne 1 ] || [ "$found_verity" -ne 1 ]; then
    echo "mkosi.postoutput: ERROR: expected exactly one .usr.raw and one .verity.raw split artifact" >&2
    echo "mkosi.postoutput: found usr=$found_usr verity=$found_verity -- check [Output] SplitArtifacts" >&2
    echo "mkosi.postoutput: and the SplitName= settings in mkosi.repart/" >&2
    exit 1
fi

if [ -e "$OUTPUTDIR/$prefix.efi" ]; then
    uki="$OUTPUTDIR/$prefix.efi"

    # Everything above depends on the UKI's .cmdline carrying usrhash=<this exact
    # digest>. If it does not, the build still succeeds, the image still boots,
    # /usr still mounts -- unverified -- and the three published artifacts are a
    # set that can never be installed into a machine whose UKI names a different
    # hash. Nothing in mkosi catches it for Verity=hash (see the block above), and
    # the two values are produced by *different* repart runs, so comparing them
    # here is the only place the pair is ever in the same process.
    # READ-ONLY EXTRACTION, and this is not a stylistic choice:
    #   objcopy --dump-section .cmdline=/dev/stdout <uki>
    # rewrites its input file in place. Measured against the shipped UKI, whose
    # sha256 is e66c6431d7e3c365277311676edd724d8599b4785b6752d1fc829fc6e9ccecb8:
    # objcopy leaves a different file behind and `sbverify' goes from "Signature
    # verification failed" to "No signature table present". A check written the
    # obvious way would publish the artifact it just destroyed, and the corruption
    # would be invisible because the .efi split artifact is the same bytes.
    # So: objdump -h for the offset and the size, dd to read. Same idiom as
    # uki_section_offset() in tests/lib/common.sh.
    # Three traps, all load-bearing:
    #   (a) the size must come from objdump, never be hardcoded. The UKI is
    #       rebuilt by systemd-ukify and its sections move whenever the kernel,
    #       the initrd or the command line changes length.
    #   (b) objdump -h prints every section twice for a PE built by ukify: once
    #       for the stub's own image and once for the payload. awk has to `exit'
    #       on the first match or it prints two offsets and `skip' gets a string
    #       that dd rejects.
    #   (c) .cmdline is a single NUL-terminated UTF-16-ish blob, so it has to be
    #       NUL-split into lines before it can be pattern-matched at all.
    [ -x "$mtools/objdump" ] || { echo "mkosi.postoutput: ERROR: $mtools/objdump missing" >&2; exit 1; }
    _ukisec=$("$mtools/objdump" -h "$uki" 2>/dev/null |
        awk '$2 == ".cmdline" { print strtonum("0x" $3), strtonum("0x" $6); exit }')
    _ukisize=${_ukisec%% *}      # objdump -h field 3
    _ukioff=${_ukisec#* }        # objdump -h field 6
    # Both are decimal by now; objdump prints them as bare hex and dd does not
    # parse that. An empty or non-numeric one means awk matched nothing, which
    # means there is no .cmdline section at all.
    _cmdline_bad=0
    case "$_ukisize" in ''|*[!0-9]*) _cmdline_bad=1 ;; esac
    case "$_ukioff"  in ''|*[!0-9]*) _cmdline_bad=1 ;; esac
    if [ "$_cmdline_bad" -ne 0 ]; then
        echo "mkosi.postoutput: ERROR: no usable .cmdline section in $uki" >&2
        echo "mkosi.postoutput: (objdump -h gave: '$_ukisec')" >&2
        echo "mkosi.postoutput: a UKI with no embedded command line has no usrhash= to verify." >&2
        echo "mkosi.postoutput: either ukify did not get one, or objdump cannot read the file." >&2
        exit 1
    fi
    [ "$_ukioff" -gt 0 ] && [ "$_ukisize" -gt 0 ] || {
        echo "mkosi.postoutput: ERROR: .cmdline offset/size out of range: '$_ukisec'" >&2
        exit 1
    }
    _cmdline=$(dd if="$uki" bs=1 skip="$_ukioff" count="$_ukisize" status=none | tr '\0' '\n')
    # Exactly one usrhash=, and it is this build's. The count matters: the kernel
    # and systemd-veritysetup-generator both take the *last* usrhash= on the
    # command line (the generator's parse loop overwrites, veritysetup-
    # generator.c:193-197), so a second one would be the one that counted and a
    # naive "does it contain the right hash" grep would pass an image whose
    # effective root hash is somebody else's.
    _n=$(printf '%s\n' "$_cmdline" | tr ' ' '\n' | awk '/^usrhash=/{n++} END{print n+0}')
    if [ "$_n" -ne 1 ]; then
        echo "mkosi.postoutput: ERROR: $uki .cmdline carries $_n usrhash= parameters, expected 1" >&2
        echo "mkosi.postoutput: .cmdline was: $_cmdline" >&2
        exit 1
    fi
    _ukihash=$(printf '%s\n' "$_cmdline" | tr ' ' '\n' | sed -n 's/^usrhash=//p')
    if [ "$_ukihash" != "$roothash" ]; then
        echo "mkosi.postoutput: ERROR: the UKI and the verity tree disagree" >&2
        echo "  $prefix.roothash : $roothash" >&2
        echo "  $uki .cmdline  : usrhash=$_ukihash" >&2
        echo "mkosi.postoutput: one of these did not come from this build's repart run. Publishing a" >&2
        echo "mkosi.postoutput: UKI that names a hash nobody has a verity tree for is worse than not" >&2
        echo "mkosi.postoutput: publishing: it looks like a complete, signed, updateable slot set." >&2
        exit 1
    fi
    # Note what this check does and does not establish. It does NOT verify the
    # Authenticode signature: sbverify from the tools tree rejects even the
    # pristine shipped UKI ("Signature verification failed") because it has no
    # chain to validate against, so a gate here would fail every build while
    # proving nothing. What it does establish is that the value in the signed
    # region is the value repart computed for this build. Authenticode covers the
    # whole PE container rather than any individual section, so .cmdline is inside
    # the signed region by construction, and [Validation] SecureBoot=yes
    # (mkosi.conf) plus lib/image.sh check_inputs() is what makes the signature exist.
    echo "mkosi.postoutput: UKI .cmdline usrhash= matches $prefix.roothash"

    # This is the gate that makes scripts/ukify load-bearing rather than merely
    # present. The wrapper restricts ukify to --phases=enter-initrd, and if it
    # ever stops taking effect -- mkosi resolves a different ukify, the tools tree
    # is regenerated, ExtraSearchPaths= is dropped from mkosi.conf -- the build
    # still succeeds and still produces a correctly signed, correctly booting UKI.
    # It would just be signed for every boot phase, and nothing downstream would
    # ever notice.
    # Why that is a security failure rather than a cosmetic one. The root's TPM2
    # policy is PolicyAuthorize over PCR 11 plus PolicyPCR over PCR 7, and
    # PolicyAuthorize asks "did this key sign the value PCR 11 holds *right
    # now*". The signed entries ARE the set of PCR 11 values that release the
    # volume key. systemd-pcrphase-initrd.service walks PCR 11 from
    # `stub_only' to `stub_only|enter-initrd' (cryptsetup runs here) to
    # `...|leave-initrd' (the ExecStop, at switch-root). Ship all four default
    # entries and the first two of those three are signed: the key is released
    # in the initrd, and then released AGAIN for the rest of the boot, from a
    # TPM that the design says must refuse. Ship one entry and only the middle
    # value is signed, so the window is the initrd and nothing else.
    # Measured on the UKI this repository shipped before the wrapper existed:
    # the .pcrsig was {"sha256": [ four entries, all pcrs [11] ]}. Four is the
    # failure this check exists to catch.
    [ -x "$mtools/python3" ] || { echo "mkosi.postoutput: ERROR: $mtools/python3 missing" >&2; exit 1; }
    _pcrsig_sec=$("$mtools/objdump" -h "$uki" 2>/dev/null |
        awk '$2 == ".pcrsig" { print strtonum("0x" $3), strtonum("0x" $6); exit }')
    _pcrsig_size=${_pcrsig_sec%% *}
    _pcrsig_off=${_pcrsig_sec#* }
    _pcrsig_bad=0
    case "$_pcrsig_size" in ''|*[!0-9]*) _pcrsig_bad=1 ;; esac
    case "$_pcrsig_off"  in ''|*[!0-9]*) _pcrsig_bad=1 ;; esac
    if [ "$_pcrsig_bad" -ne 0 ]; then
        echo "mkosi.postoutput: ERROR: no usable .pcrsig section in $uki" >&2
        echo "mkosi.postoutput: (objdump -h gave: '$_pcrsig_sec')" >&2
        echo "mkosi.postoutput: a UKI with no .pcrsig cannot satisfy PolicyAuthorize, so the TPM" >&2
        echo "mkosi.postoutput: would never unseal the root at all. Check [Validation]" >&2
        echo "mkosi.postoutput: SignExpectedPcr=yes and SignExpectedPcrKey= in mkosi.conf." >&2
        exit 1
    fi
    dd if="$uki" bs=1 skip="$_pcrsig_off" count="$_pcrsig_size" status=none > "$OUTPUTDIR/.pcrsig.json"
    # JSON, not counting braces. The section is {"<bank>": [ {entry}, ... ]} and a
    # malformed or differently-shaped one has to be a loud failure rather than a
    # miscount, so this parses and reports rather than grepping.
    if ! _pcrsig_report=$("$mtools/python3" - "$OUTPUTDIR/.pcrsig.json" <<'PCRSIG_EOF'
import json, sys

try:
    with open(sys.argv[1]) as f:
        doc = json.load(f)
except OSError as ex:
    print(f"FAIL: cannot read .pcrsig: {ex}")
    sys.exit(0)
except json.JSONDecodeError as ex:
    print(f"FAIL: .pcrsig is not valid JSON: {ex}")
    print("  A truncated or empty section means ukify did not finish writing it.")
    sys.exit(0)

if not isinstance(doc, dict):
    print("FAIL: .pcrsig is not a {bank: [entries]} object")
    sys.exit(0)

for bank, entries in sorted(doc.items()):
    if not isinstance(entries, list):
        print(f"FAIL: .pcrsig[{bank!r}] is not a list")
        sys.exit(0)
    if bank != "sha256":
        print(f"FAIL: .pcrsig carries bank {bank!r}; this image seals with sha256 only")
        sys.exit(0)
    if len(entries) != 1:
        pols = ", ".join(
            str(e.get("pcrs")) for e in entries if isinstance(e, dict)
        )
        print(f"FAIL: .pcrsig[{bank}] has {len(entries)} entries (pcrs: {pols}); expected 1")
        print("  Only the enter-initrd phase may be signed. The others name PCR 11 values the")
        print("  machine reaches after systemd-pcrphase-initrd.service's leave-initrd ExecStop,")
        print("  which would keep the root volume key releasable for the whole boot instead of")
        print("  the whole initrd. Check that mkosi.conf still has ExtraSearchPaths=scripts and")
        print("  that scripts/ukify is executable.")
        sys.exit(0)
    e = entries[0]
    if not isinstance(e, dict):
        print(f"FAIL: .pcrsig[{bank}][0] is not an object")
        sys.exit(0)
    if e.get("pcrs") != [11]:
        print(f"FAIL: .pcrsig[{bank}][0].pcrs is {e.get('pcrs')!r}; expected [11]")
        sys.exit(0)
    for k in ("pkfp", "pol", "sig"):
        if not e.get(k):
            print(f"FAIL: .pcrsig[{bank}][0] has no {k!r}")
            sys.exit(0)

print(f"OK sha256 1 entry pcrs=[11] pkfp={e['pkfp'][:16]}… pol={e['pol'][:16]}…")
PCRSIG_EOF
    ); then
        echo "mkosi.postoutput: ERROR: could not parse the .pcrsig section of $uki" >&2
        rm -f "$OUTPUTDIR/.pcrsig.json"
        exit 1
    fi
    rm -f "$OUTPUTDIR/.pcrsig.json"
    case "$_pcrsig_report" in
        OK*)
            echo "mkosi.postoutput: UKI .pcrsig $_pcrsig_report (enter-initrd only)"
            ;;
        *)
            echo "mkosi.postoutput: ERROR: $uki .pcrsig is not restricted to the enter-initrd phase" >&2
            printf 'mkosi.postoutput: %s\n' "$_pcrsig_report" >&2
            echo "mkosi.postoutput: Refusing to publish. The root volume key would stay releasable" >&2
            echo "mkosi.postoutput: after leave-initrd, which is the property this seal exists for." >&2
            exit 1
            ;;
    esac

    xz -T0 -f "$uki"
    published="$published $prefix.efi.xz"
    echo "mkosi.postoutput: published $prefix.efi.xz"
else
    echo "mkosi.postoutput: ERROR: $prefix.efi not found in \$OUTPUTDIR" >&2
    exit 1
fi

# Not consumed by systemd-sysupdate for Type=regular-file sources (it does no
# integrity checking for those, and needs no signature). This exists for the
# future url-file source, which enumerates versions from SHA256SUMS and verifies
# SHA256SUMS.gpg, and for anything that wants to check the artifacts against the
# build that claims to have produced them. Note [Validation] Checksum=no (it is
# in [Validation], not [Output]): mkosi's own manifest is stale by the time this
# runs.
# WHY THIS IS HAND-WRITTEN RATHER THAN [Validation] Sign=YES
# Sign= is a [Validation] setting (mkosi config.py:3798-3804) and calculate_signature()
# returns immediately unless Checksum= is also on (__init__.py:2537-2539). Turning
# it on here would therefore mean Checksum=yes as well -- and that signs mkosi's
# manifest, which calculate_sha256sum() writes at __init__.py:2520-2534 over the
# *staging* directory, i.e. over the pre-rename, pre-compression
# vngrd_<ver>.vngrd-<ver>-<uuid>.usr.raw names, before this script has done
# anything. A detached GPG signature over that file would be a cryptographically
# valid signature over a manifest that does not describe the published artifacts,
# which is strictly worse than an unsigned correct one: it makes the wrong answer
# look authoritative. It would also need a GNUPGHOME that exists
# (__init__.py:2557-2559 dies otherwise) and a private key, and this project has
# no OpenPGP key of any kind -- SecureBootKey= is an X.509 key for sbsign. So
# Sign= is deliberately left unset, and signing is done here instead, over the
# finished manifest, on request. See SIGN_SHA256SUMS at the end of this file.
cd "$OUTPUTDIR"

# Coverage rule, and it is deliberately structural rather than a hand-kept list:
# every regular file in the staging directory except the manifest and its own
# signature. The previous version accumulated names in $published as it went, so
# anything mkosi produced that this script did not itself create was simply not
# covered. Enumerated against the shipped output/image/ that gap was four files:
#   vngrd_0.1.raw         743M  the installer image
#   vngrd_0.1.vmlinuz      16M  SplitArtifacts=kernel
#   vngrd_0.1.initrd       11M  SplitArtifacts=initrd
#   initrd.cpio.zst        11M  mkosi's own initrd output, byte-identical to
#                              vngrd_0.1.initrd (cmp says so)
# The last two are a duplicate pair, and the other two are matched by no
# MatchPattern= in /usr/lib/sysupdate.d/*.transfer, so all four sat in the
# published directory looking authoritative while being in no manifest at all.
# Enumerating the directory means a new SplitArtifacts= entry cannot land
# unverified by omission.
# The installer image is therefore COVERED, not excused. scripts/run-vm.sh:274-277
# states that vngrd_0.1.raw "has to stay byte-identical to what
# output/image/SHA256SUMS covers", and it was not covered at all, so that sentence
# described a check that did not happen. Hashing 743M costs about a second.
# symlinks are excluded, and are not a coverage hole: mkosi leaves
# `vngrd_0.1' -> `vngrd_0.1.raw' and `initrd' -> `initrd.cpio.zst' in the staging
# tree, and both targets are covered under their own names.
manifest_files=$(find . -maxdepth 1 -type f \
    ! -name SHA256SUMS ! -name SHA256SUMS.gpg -print |
    sed 's|^\./||' | sort)
[ -n "$manifest_files" ] || {
    echo "mkosi.postoutput: ERROR: no files to cover in $OUTPUTDIR" >&2
    exit 1
}
# shellcheck disable=SC2086
printf '%s\n' "$manifest_files" | xargs -r sha256sum > SHA256SUMS
# And say so, because a manifest that quietly omits the biggest file in the
# directory is the failure mode this whole block exists to remove.
for must in "$prefix.raw" "$prefix.roothash" "$prefix.efi.xz" \
            "${prefix}_${first32}.usr.xz" "${prefix}_${last32}.verity.xz"; do
    grep -q "  $must\$" SHA256SUMS || {
        echo "mkosi.postoutput: ERROR: $must exists but is not covered by SHA256SUMS" >&2
        exit 1
    }
done

# The repart definitions are a directory, which sha256sum will not take; include
# them so the manifest describes the whole build output.
# `sh' has no pipefail, so the original one-liner could not distinguish "found
# the definitions" from "found nothing and xargs -r silently did nothing": a
# missing or unreadable repart.d directory produced a complete, short, successful
# manifest. Check the directory exists, then materialise the list before hashing
# it so an empty result is still an error.
[ -d "$prefix.repart.d" ] || {
    echo "mkosi.postoutput: ERROR: $prefix.repart.d is missing from \$OUTPUTDIR" >&2
    echo "mkosi.postoutput: check [Output] SplitArtifacts=repart-definitions in mkosi.conf" >&2
    exit 1
}
repart_files=$(find "./$prefix.repart.d" -type f -print | sed 's|^\./||' | sort)
[ -n "$repart_files" ] || {
    echo "mkosi.postoutput: ERROR: $prefix.repart.d contains no files" >&2
    exit 1
}
printf '%s\n' "$repart_files" | xargs -r sha256sum >> SHA256SUMS

# The published enrolment updates are an input to a security operation, so they
# are covered by the same manifest as the image. They are not boot components
# and are never read from the image itself.
[ -d secureboot ] || {
    echo "mkosi.postoutput: ERROR: secureboot/ is missing from \$OUTPUTDIR" >&2
    exit 1
}
sb_files=$(find ./secureboot -type f -print | sed 's|^\./||' | sort)
[ -n "$sb_files" ] || {
    echo "mkosi.postoutput: ERROR: secureboot/ contains no files" >&2
    exit 1
}
printf '%s\n' "$sb_files" | xargs -r sha256sum >> SHA256SUMS

# The other direction of the coverage rule, from the list this script built up as
# it went. $published is the set of names it decided to ship; anything in there
# that is not in the manifest means something published a file and did not record
# it, which is the same omission the enumeration above is meant to make impossible.
for p in $published; do
    grep -q "  $p\$" SHA256SUMS || {
        echo "mkosi.postoutput: ERROR: published $p but SHA256SUMS does not cover it" >&2
        exit 1
    }
done

# Off by default, and loud about being off. Set SIGN_SHA256SUMS to an OpenPGP
# key id or fingerprint and the finished manifest is detached-signed with the
# gpg from the tools tree, producing SHA256SUMS.gpg -- the filename and format
# that 50-usr.transfer already documents for the future url-file source, and that
# the sweep above now clears when signing is turned off.
# This is not [Validation] Sign=; see the comment above for why that one cannot
# be used here. It also differs in the only way that matters for correctness: the
# signature covers the manifest *after* the rename and the compression, i.e. the
# names that actually ship.
if [ -z "${SIGN_SHA256SUMS:-}" ]; then
    echo "mkosi.postoutput: WARNING: SHA256SUMS is UNSIGNED (SIGN_SHA256SUMS is not set)."
    echo "mkosi.postoutput: WARNING: it is a tamper-evident listing, not an authenticated one --"
    echo "mkosi.postoutput: WARNING: anyone who can rewrite output/image/ can rewrite it to match."
    echo "mkosi.postoutput: WARNING: the artifacts' authenticity rests on the UKI's Authenticode" >&2
    echo "mkosi.postoutput: WARNING: signature plus dm-verity, not on this file."
else
    [ -x "$mtools/gpg" ] || { echo "mkosi.postoutput: ERROR: $mtools/gpg missing" >&2; exit 1; }
    # gpg-agent has to create sockets, a random_seed and S.gpg-agent in GNUPGHOME,
    # and mkosi runs this script in a bwrap sandbox where /home -- so the operator's
    # ~/.gnupg -- is bound read-only. Signing therefore runs against a private
    # copy taken with umask 077 and removed by the same trap. It is a copy of a
    # secret key on local disk, which is why it is opt-in, why it is not the
    # default, and why the key must not live in the repository.
    [ -n "${SIGN_GNUPGHOME:-}" ] || {
        echo "mkosi.postoutput: ERROR: SIGN_SHA256SUMS is set but SIGN_GNUPGHOME is not" >&2
        echo "mkosi.postoutput: SIGN_GNUPGHOME must name a gpg homedir holding the secret key for" >&2
        echo "mkosi.postoutput: '$SIGN_SHA256SUMS'. It must be reachable from this sandbox (mkosi" >&2
        echo "mkosi.postoutput: binds /home read-only, so a key under \$HOME works)." >&2
        exit 1
    }
    [ -d "$SIGN_GNUPGHOME" ] || {
        echo "mkosi.postoutput: ERROR: SIGN_GNUPGHOME='$SIGN_GNUPGHOME' is not a directory" >&2
        exit 1
    }
    _gnupg=$(mktemp -d /tmp/vngrd-gnupg-XXXXXX)
    chmod 700 "$_gnupg"
    trap 'rm -rf "$_gnupg"' EXIT INT TERM
    (umask 077 && cp -a "$SIGN_GNUPGHOME"/. "$_gnupg"/) || {
        echo "mkosi.postoutput: ERROR: could not copy $SIGN_GNUPGHOME" >&2
        exit 1
    }
    if GNUPGHOME="$_gnupg" "$mtools/gpg" --batch --yes --pinentry-mode loopback \
            --default-key "$SIGN_SHA256SUMS" \
            --detach-sign --output SHA256SUMS.gpg SHA256SUMS 2>&1; then
        echo "mkosi.postoutput: wrote SHA256SUMS.gpg (key $SIGN_SHA256SUMS)"
    else
        rm -rf "$_gnupg"
        trap - EXIT INT TERM
        echo "mkosi.postoutput: ERROR: could not sign SHA256SUMS with key '$SIGN_SHA256SUMS'" >&2
        echo "mkosi.postoutput: signing was requested, so publishing an unsigned manifest is a build" >&2
        echo "mkosi.postoutput: failure rather than a silent downgrade. Fix the key, or unset" >&2
        echo "mkosi.postoutput: SIGN_SHA256SUMS to publish unsigned on purpose." >&2
        exit 1
    fi
    rm -rf "$_gnupg"
    trap - EXIT INT TERM
fi

echo "mkosi.postoutput: wrote SHA256SUMS ($(wc -l < SHA256SUMS) entries)"
sed 's/^/  /' SHA256SUMS

}

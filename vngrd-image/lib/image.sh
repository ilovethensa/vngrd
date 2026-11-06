# shellcheck shell=bash

# _check_present <path> <label> <hint> — sets the caller's $fail (bash dynamic
# scoping) so one run lists every missing input.
_check_present() {
    if [[ -e $1 ]]; then
        printf '  ok   %s\n' "$2"
    else
        printf '  MISS %s\n       -> %s\n' "$2" "$3" >&2
        fail=1
    fi
}

# check_inputs — sibling trees and signing material are present and usable;
# every failure here would otherwise surface deep inside mkosi or on first boot.
check_inputs() {
    local fail=0 kver_dir k p pair key val KEYUTIL _ku tmp
    local PCR_KEY PCR_CERT PCR_MODE
    tmp=$(mktemp "${TMPDIR:-/tmp}/vngrd-pcrpub.XXXXXX")

    note "checking $OUT/ ..."
    _check_present "$ROOTFS/usr" "rootfs tree" \
        "(cd ../vngrd-buildstream && ./scripts/build.sh rootfs.bst verify.bst && ./scripts/publish.sh)"
    # Host tool for signed-variable updates; installed by the fixate step.
    _check_present "$ROOTFS/usr/lib/vngrd/vngrd-secureboot-update" \
        "secureboot update host tool" \
        "(run ./build.sh from the repo root; the fixate step installs it)"
    _check_present "$KERNEL/boot/vmlinuz" "kernel image" \
        "(cd ../vngrd-kernel && ./scripts/build.sh [--prebuilt <path>])"

    # The kver directory is empty by design (CONFIG_MODULES=n) but must exist:
    # it is how mkosi.finalize and ukify find the kernel.
    kver_dir=$(ls -d "$KERNEL"/usr/lib/modules/*/ 2>/dev/null | head -1 || true)
    if [[ -n $kver_dir ]]; then
        printf '  ok   kernel version dir (%s)\n' "$(basename "$kver_dir")"
    else
        printf '  MISS kernel version dir under kernel/usr/lib/modules/\n' >&2
        printf '       -> (cd ../vngrd-kernel && ./scripts/build.sh --clean)\n' >&2
        fail=1
    fi

    # A CONFIG_MODULES=y tree would load unsigned modules silently.
    if [[ -d $KERNEL/usr/lib/modules ]] &&
        find "$KERNEL/usr/lib/modules" \( -name '*.ko' -o -name '*.ko.*' \) -print -quit 2>/dev/null |
        grep -q .; then
        printf '  MISS kernel tree has .ko files; this kernel is CONFIG_MODULES=n\n' >&2
        printf '       -> (cd ../vngrd-kernel && ./scripts/build.sh --clean)\n' >&2
        fail=1
    else
        printf '  ok   no modules (CONFIG_MODULES=n)\n'
    fi

    if grep -q '^CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y' "$KERNEL/boot/config" 2>/dev/null; then
        printf '  ok   kernel lockdown floor (CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY)\n'
    else
        printf '  MISS kernel lockdown floor (CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY)\n' >&2
        printf '       -> a kernel built before lockdown boots identically with none of it.\n' >&2
        printf '       -> (cd ../vngrd-kernel && ./scripts/build.sh --clean)\n' >&2
        fail=1
    fi

    # repart mkfs's the root on first boot; also a check on the initrd closure.
    _check_present "$ROOTFS/usr/bin/mkfs.ext4" "mkfs.ext4 in rootfs (initrd needs it)" \
        "(cd ../vngrd-buildstream && ./scripts/build.sh rootfs.bst verify.bst && ./scripts/publish.sh)"
    # Read from the verified /usr, so it must be in the rootfs and must not be
    # seeded into the initrd (build_initrd asserts that).
    _check_present "$ROOTFS/usr/lib/repart.d/10-root.conf" "root partition definition" \
        "(cd ../vngrd-buildstream && ./scripts/build.sh rootfs.bst verify.bst && ./scripts/publish.sh)"
    _check_present "$ROOTFS/usr/lib/os-release" "os-release in the rootfs tree" \
        "(cd ../vngrd-buildstream && ./scripts/build.sh rootfs.bst verify.bst && ./scripts/publish.sh)"

    # The spare A/B slot ships empty so no machine-side definition can adopt the
    # live slot; sysupdate fills it on first update.
    _check_present "$HERE/mkosi.repart/13-usr-b.conf" "slot B spare definition" \
        "(git checkout mkosi.repart/13-usr-b.conf)"
    _check_present "$HERE/mkosi.repart/14-usr-b-verity.conf" "slot B spare verity definition" \
        "(git checkout mkosi.repart/14-usr-b-verity.conf)"

    # A signed UKI is required: without the keys ukify aborts or emits an unsigned
    # image that passes every check except the one that matters.
    for k in SecureBootKey SecureBootCertificate; do
        p=$(mkosi_setting "$k")
        if [[ -z $p ]]; then
            printf '  MISS %s not set in mkosi.conf.d/*.conf\n' "$k" >&2
            fail=1
        elif [[ ! -r $p ]]; then
            printf '  MISS %s -> %s unreadable\n' "$k" "$p" >&2
            fail=1
        else
            printf '  ok   %s\n' "$k"
        fi
    done

    # repart seals the root with PolicyAuthorize against this key. A volume sealed
    # against a key whose signature never ships is a brick.
    #
    # Keys may be set repo-relative (mkosi resolves settings relative to the
    # directory of mkosi.conf, i.e. $HERE); normalize so the checks below and
    # mkosi agree on one path. Absolute paths pass through unchanged, so a
    # 50-local-keys.conf pointing anywhere on the host still works.
    PCR_KEY=$(mkosi_setting SignExpectedPcrKey)
    PCR_CERT=$(mkosi_setting SignExpectedPcrCertificate)
    PCR_MODE=$(mkosi_setting SignExpectedPcr)
    [[ -n $PCR_KEY && $PCR_KEY != /* ]] && PCR_KEY=$HERE/$PCR_KEY
    [[ -n $PCR_CERT && $PCR_CERT != /* ]] && PCR_CERT=$HERE/$PCR_CERT

    # `auto` is a trap: it signs only if systemd-measure is present AND both key
    # settings are non-empty, so a typo silently downgrades the seal to PolicyPCR.
    case $PCR_MODE in
        yes|true|enabled) printf '  ok   SignExpectedPcr=%s\n' "$PCR_MODE" ;;
        *)
            printf '  MISS SignExpectedPcr is %s, want yes/enabled\n' "${PCR_MODE:-<unset>}" >&2
            printf '       -> auto signs only when systemd-measure and both key settings\n' >&2
            printf '          are present, so a typo in a path silently downgrades the seal.\n' >&2
            fail=1
            ;;
    esac

    for pair in "SignExpectedPcrKey:$PCR_KEY" "SignExpectedPcrCertificate:$PCR_CERT"; do
        key=${pair%%:*}
        val=${pair#*:}
        if [[ -z $val ]]; then
            printf '  MISS %s not set in mkosi.conf or mkosi.conf.d/*.conf\n' "$key" >&2
            fail=1
        elif [[ ! -f $val ]]; then
            printf '  MISS %s -> %s does not exist\n' "$key" "$val" >&2
            printf "       -> openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \\\\\n" >&2
            printf "            -subj '/CN=vngrd PCR Signing/' -keyout pcr.key -out pcr.crt\n" >&2
            fail=1
        elif [[ ! -s $val ]]; then
            # -s, not -e: a zero-length key shows up as an RSA error or a refusal
            # to unseal, neither of which names the file.
            printf '  MISS %s -> %s is empty\n' "$key" "$val" >&2
            fail=1
        else
            printf '  ok   %s\n' "$key"
        fi
    done

    # A mismatched pair or a non-RSA cert is fatal on target:
    # tpm2_calculate_policy_authorize() hardcodes TPM2_ALG_RSASSA.
    if [[ -n $PCR_KEY && -s $PCR_KEY && -n $PCR_CERT && -s $PCR_CERT ]]; then
        if ! openssl x509 -in "$PCR_CERT" -noout -modulus >/dev/null 2>&1; then
            printf '  MISS SignExpectedPcrCertificate -> %s is not a readable X.509 cert\n' "$PCR_CERT" >&2
            fail=1
        elif ! openssl rsa -in "$PCR_KEY" -noout -modulus >/dev/null 2>&1; then
            printf '  MISS SignExpectedPcrKey -> %s is not a readable RSA private key\n' "$PCR_KEY" >&2
            fail=1
        elif [[ $(openssl x509 -in "$PCR_CERT" -noout -modulus 2>/dev/null) != \
                $(openssl rsa -in "$PCR_KEY" -noout -modulus 2>/dev/null) ]]; then
            printf '  MISS the PCR key and certificate do not match (different moduli)\n' >&2
            printf '       -> ukify signs the .pcrsig with the key and publishes the\n' >&2
            printf "          certificate's public half in .pcrpkey, so a mismatch is a brick.\n" >&2
            fail=1
        elif ! openssl x509 -in "$PCR_CERT" -noout -text 2>/dev/null |
            grep -q 'Public Key Algorithm: rsaEncryption'; then
            printf '  MISS the PCR certificate is not RSA.\n' >&2
            printf '       -> tpm2_calculate_policy_authorize() hardcodes TPM2_ALG_RSASSA; RSA only.\n' >&2
            fail=1
        else
            # The public key repart is pointed at is extracted by ukify with
            # systemd-keyutil, from /usr/lib/systemd as well as /usr/bin.
            KEYUTIL=""
            for _ku in "$TOOLS/bin/systemd-keyutil" \
                "$HERE/mkosi.tools/usr/lib/systemd/systemd-keyutil" \
                "$ROOTFS/usr/lib/systemd/systemd-keyutil" \
                "$(command -v systemd-keyutil 2>/dev/null || true)"; do
                [[ -n $_ku && -x $_ku ]] || continue
                # Run, don't merely find: mkosi.tools' keyutil has
                # RUNPATH=/usr/lib/systemd and only resolves against a matching
                # host libsystemd-shared, while the rootfs copy has its libs adjacent.
                if "$_ku" extract-public --certificate "$PCR_CERT" >"$tmp" 2>/dev/null &&
                   [[ -s $tmp ]]; then
                    KEYUTIL=$_ku
                    break
                fi
            done
            if [[ -n $KEYUTIL ]]; then
                printf '  note using %s for the .pcrpkey round-trip\n' "$KEYUTIL"
                if ! "$KEYUTIL" extract-public --certificate "$PCR_CERT" >/dev/null 2>&1 ||
                   [[ ! -s $tmp ]]; then
                    printf '  MISS systemd-keyutil could not extract a public key from %s\n' "$PCR_CERT" >&2
                    fail=1
                elif ! openssl pkey -pubin -in "$tmp" -noout >/dev/null 2>&1; then
                    printf '  MISS the extracted .pcrpkey is not a readable PEM public key\n' >&2
                    fail=1
                else
                    printf '  ok   PCR key/cert pair is RSA, matched, and yields a usable .pcrpkey\n'
                fi
            else
                printf '  note systemd-keyutil not found; the .pcrpkey round-trip is unchecked\n'
            fi
        fi
    fi
    # mkosi's configure_initrd() symlinks etc/initrd-release -> /etc/os-release,
    # and symlink(2) fails with ENOENT when <root>/etc is missing. The published
    # rootfs has no /etc, so provide it on every build (publish.sh rebuilds rootfs).
    mkdir -p "$ROOTFS/etc"

    # Bootable=yes installs sd-boot into the image root's /efi, and 00-esp.conf
    # copies it into the ESP; bootctl dies if /efi is missing. Create it per build.
    mkdir -p "$ROOTFS/efi"

    # repart reads it in the initramfs (/.extra/tpm2-pcr-public-key.pem), which is
    # gone after switch-root; host-side re-enrolment needs the same public half.
    # $ROOTFS is a BaseTree, so it lands in /usr and reaches the initrd via seed.
    if [[ -n $PCR_CERT && -s $PCR_CERT ]]; then
        if [[ ! -s $tmp ]]; then
            openssl x509 -in "$PCR_CERT" -pubkey -noout >"$tmp" 2>/dev/null || :
        fi
        if [[ -s $tmp ]] && openssl pkey -pubin -in "$tmp" -noout >/dev/null 2>&1; then
            install -D -m 0644 "$tmp" "$ROOTFS/usr/lib/systemd/tpm2-pcr-public-key.pem"
            printf '  ok   staged usr/lib/systemd/tpm2-pcr-public-key.pem\n'
        else
            printf '  MISS could not derive the PCR public key for host-side re-enrolment\n' >&2
            printf '       -> vngrd-tpm-heal.service would be unable to re-seal the token.\n' >&2
            fail=1
        fi
    fi
    rm -f "$tmp"

    # Microsoft's CA certs are part of the db trust set; pin them by digest
    # (recorded in keys/README.md) rather than trusting the filename.
    for pair in \
        "microsoft-uefi-ca-2023.der:f6124e34125bee3fe6d79a574eaa7b91c0e7bd9d929c1a321178efd611dad901" \
        "microsoft-option-rom-uefi-ca-2023.der:e5be3e64c6e66a281457ecdece0d6d0787577aad2a3a0144262c10c14ba8d8f1"; do
        key=${pair%%:*}
        val=${pair#*:}
        p="$HERE/keys/$key"
        if [[ ! -s $p ]]; then
            printf '  MISS %s\n' "$p" >&2
            fail=1
        elif [[ $(sha256sum "$p" | cut -d' ' -f1) != "$val" ]]; then
            printf '  MISS %s has an unexpected digest\n' "$p" >&2
            printf '       -> the db trust set must not drift silently; see keys/README.md\n' >&2
            fail=1
        else
            printf '  ok   %s\n' "keys/$key"
        fi
    done

    (( fail == 0 )) || die "missing inputs — build/publish the sibling repos first"
    note "inputs OK"
}

# mkosi_build — run mkosi with the Secure Boot key directory mounted read-only.
# postoutput's sandbox sees only the source and output trees, so the keys must be
# named as build sources; mapping them under /work/src avoids copying key material.
mkosi_build() {
    local key cert keydir certdir target
    local -a args=(build --force)

    key=$(mkosi_setting SecureBootKey)
    cert=$(mkosi_setting SecureBootCertificate)
    [[ -r $key ]] || die "SecureBootKey is not readable: ${key:-<unset>}"
    [[ -r $cert ]] || die "SecureBootCertificate is not readable: ${cert:-<unset>}"
    keydir=$(dirname -- "$key")
    certdir=$(dirname -- "$cert")

    # --build-sources replaces mkosi's implicit config-dir entry, so name the
    # source tree first. Keys need their own target or the second hides the first.
    args+=(--build-sources "$HERE")
    args+=(--build-sources "$keydir:vngrd-keys")
    args+=(--environment "VNGRO_SB_KEY=/work/src/vngrd-keys/$(basename -- "$key")")
    if [[ $certdir != "$keydir" ]]; then
        args+=(--build-sources "$certdir:vngrd-certs")
        args+=(--environment "VNGRO_SB_CERT=/work/src/vngrd-certs/$(basename -- "$cert")")
    else
        args+=(--environment "VNGRO_SB_CERT=/work/src/vngrd-keys/$(basename -- "$cert")")
    fi

    note "mkosi ${args[*]}"
    mkosi "${args[@]}"
}

# verify_uki — the usrhash= on the UKI cmdline must name partitions that exist
# and must be the real Merkle root for /usr.
#
# veritysetup-generator.c splits usrhash=: first 128 bits are the data PARTUUID,
# last 128 the verity one, and the same string is passed to systemd-veritysetup as
# the root hash. A wrong value fails later as "Failed to start Integrity Protection
# Setup for usr", which reads as a PCR 11 fault and is not one.
verify_uki() {
    (
        local ver raw imgdir sfdisk veritysetup_bin tmp cmdline wanted tok half
        local bad=0 checked=0 i data_lba hash_lba data_sz hash_sz candidate
        ver=$(image_version)
        imgdir=$IMAGE_DIR
        raw=$imgdir/vngrd_$ver.raw
        if [[ ! -f $raw ]]; then
            raw=$imgdir/vngrd_$(ls "$imgdir" 2>/dev/null |
                sed -n 's/^vngrd_[0-9.]*_\(.*\)\.usr\.xz$/\1/p' | head -1).usr.xz
        fi
        [[ -f $raw && -f $imgdir/vngrd_$ver.efi.xz ]] ||
            die "need both $raw and vngrd_$ver.efi.xz"

        sfdisk=$TOOLS/sbin/sfdisk
        [[ -x $sfdisk ]] || sfdisk=$(command -v sfdisk 2>/dev/null || true)
        [[ -x $sfdisk ]] || die "no sfdisk"

        tmp=$(mktemp -d "${TMPDIR:-/tmp}/vngrd-ukiverity.XXXXXX")
        trap 'rm -rf "$tmp"' EXIT INT TERM

        xz -dc "$imgdir/vngrd_$ver.efi.xz" >"$tmp/uki.efi"
        objcopy -O binary --only-section=.cmdline "$tmp/uki.efi" "$tmp/cmdline" 2>/dev/null || true
        cmdline=$(tr -d '\000' <"$tmp/cmdline")
        printf '  UKI .cmdline: %s\n' "$cmdline"

        "$sfdisk" -d "$raw" 2>/dev/null | tr 'A-F' 'a-f' >"$tmp/gpt.txt"
        printf '  image partitions:\n'
        sed -n 's/.*uuid=\([0-9a-f-]*\), name="\([^"]*\)".*/    \2  \1/p' "$tmp/gpt.txt" | sed 's/^/  /'

        # usrhash= carries the two UUIDs as bare 32-hex digits, concatenated.
        wanted=$(printf '%s' "$cmdline" | grep -oE '[0-9a-fA-F]{32,}' | tr 'A-F' 'a-f' || true)
        if [[ -z $wanted ]]; then
            printf '  ok no partition UUIDs named on the cmdline to check\n'
            exit 0
        fi

        sed -n 's/.*uuid=\([0-9a-f-]*\), name="\([^"]*\)".*/\1 \2/p' "$tmp/gpt.txt" |
            tr -d '-' >"$tmp/img.txt"

        bad=0
        checked=0
        for tok in $wanted; do
            if ((${#tok} % 32 != 0)); then
                printf "  SKIP: '%s' is not a whole number of 32-hex-digit UUIDs\n" "$tok" >&2
                bad=1
                continue
            fi
            i=1
            while [[ -n $tok ]]; do
                half=${tok:0:32}
                tok=${tok:32}
                if grep -q "^$half " "$tmp/img.txt"; then
                    printf '  ok half %d: %s is %s\n' "$i" "$half" \
                        "$(grep "^$half " "$tmp/img.txt" | cut -d' ' -f2-)"
                    checked=$((checked + 1))
                else
                    printf '  MISSING: the UKI names %s but no partition in the image has it\n' "$half" >&2
                    bad=1
                fi
                i=$((i + 1))
            done
        done
        printf '  checked %d partition UUID(s)\n' "$checked"
        ((bad == 0)) || die "the UKI and the image disagree about partition identity: the initrd derives /dev/disk/by-partuuid/<uuid> and nothing answers to that name"

        # The cmdline value must actually verify /usr, not just name two existing
        # partitions.
        printf '  checking the cmdline value against the actual verity data...\n'
        veritysetup_bin=$TOOLS/sbin/veritysetup
        [[ -x $veritysetup_bin ]] || veritysetup_bin=$(command -v veritysetup 2>/dev/null || true)
        if [[ -z $veritysetup_bin || ! -x $veritysetup_bin ]]; then
            printf '  SKIP: no veritysetup; cannot check the root hash\n' >&2
            exit 0
        fi

        data_lba=$(sed -n "s/.*start= *\([0-9]*\).*name=\"vngrd-usr_$ver\".*/\1/p" "$tmp/gpt.txt" | head -1)
        hash_lba=$(sed -n "s/.*start= *\([0-9]*\).*name=\"vngrd-usr_${ver}_verity\".*/\1/p" "$tmp/gpt.txt" | head -1)
        data_sz=$(sed -n "s/.*size= *\([0-9]*\).*name=\"vngrd-usr_$ver\".*/\1/p" "$tmp/gpt.txt" | head -1)
        hash_sz=$(sed -n "s/.*size= *\([0-9]*\).*name=\"vngrd-usr_${ver}_verity\".*/\1/p" "$tmp/gpt.txt" | head -1)

        if [[ -z $data_lba || -z $hash_lba ]]; then
            printf '  SKIP: could not locate the usr / usr_verity partitions in the image\n' >&2
            exit 0
        fi

        dd if="$raw" of="$tmp/usr.img" bs=512 skip="$data_lba" count="$data_sz" status=none
        dd if="$raw" of="$tmp/verity.img" bs=512 skip="$hash_lba" count="$hash_sz" status=none

        candidate=""
        for tok in $wanted; do
            ((${#tok} == 64)) && candidate=$tok
        done
        if [[ -z $candidate ]]; then
            printf '  SKIP: the cmdline has no 64-hex-digit hash to test\n' >&2
            exit 0
        fi

        if "$veritysetup_bin" verify "$tmp/usr.img" "$tmp/verity.img" "$candidate" >/dev/null 2>&1; then
            printf '  ok the cmdline value is a real verity root hash for /usr\n'
        else
            die "the value on the cmdline is NOT a verity root hash: usrhash= carries the two partition UUIDs for device identity, but systemd also passes it to systemd-veritysetup as the root hash, so /usr is checked against a value that is not its Merkle root"
        fi

        printf '  ok every partition UUID on the cmdline exists in the image\n'
    )
}

# extend_gpt — pad the raw image to IMAGE_DISK_SIZE and move the backup GPT header
# to the end of the device.
#
# mkosi's OutputSize= is inert because Format resolves to `directory`, not `disk`.
# Left alone the kernel reports "GPT:Primary header thinks Alt. header is not at the
# end of the disk" and systemd-repart refuses the device. The last-usable-LBA also
# has to grow, or there is no free space for the root partition.
extend_gpt() {
    local img want have bytes
    img=$IMAGE_DIR/vngrd_$(image_version).raw
    require "$img" "build the image first"
    want=${IMAGE_DISK_SIZE:-4G}
    case $want in
        *[Gg]i[Bb]) bytes=$(( ${want%[Gg]i[Bb]} * 1024 * 1024 * 1024 )) ;;
        *[Gg])      bytes=$(( ${want%[Gg]} * 1024 * 1024 * 1024 )) ;;
        *[Mm])      bytes=$(( ${want%[Mm]} * 1024 * 1024 )) ;;
        *) die "IMAGE_DISK_SIZE='$want' is not a size (try 4G)" ;;
    esac
    have=$(wc -c <"$img")
    if (( have < bytes )); then
        note "padding $(basename "$img"): $have -> $bytes bytes"
        truncate -s "$bytes" "$img"
    elif (( have > bytes )); then
        die "$img is $have bytes, larger than IMAGE_DISK_SIZE=$want; shrinking would truncate partitions"
    fi
    python3 "$HERE/scripts/fix-gpt.py" "$img"
}

# refresh_raw_checksum — mkosi.postoutput writes SHA256SUMS before extend_gpt()
# pads and rewrites the raw, so the manifest would list a hash the shipped file
# cannot match.
refresh_raw_checksum() {
    local ver img sums hash tmp
    ver=$(image_version)
    img=$IMAGE_DIR/vngrd_$ver.raw
    sums=$IMAGE_DIR/SHA256SUMS
    require "$img" "no built image"
    require "$sums" "the manifest mkosi.postoutput should have written"
    hash=$(sha256sum "$img" | awk '{print $1}')
    tmp=$sums.tmp
    if ! awk -v want="vngrd_$ver.raw" -v hash="$hash" '
            $2 == want { print hash "  " $2; found = 1; next }
            { print }
            END { if (!found) exit 1 }
        ' "$sums" >"$tmp"; then
        rm -f "$tmp"
        die "SHA256SUMS does not cover vngrd_$ver.raw"
    fi
    mv "$tmp" "$sums"
    note "updated the SHA256SUMS entry for vngrd_$ver.raw after extending the GPT"
}

# sweep_stale — remove the previous build's split payloads from $IMAGE_DIR.
#
# `mkosi build --force` only removes declared outputs; the renamed .usr.xz and
# .verity.xz survive. sysupdate pairs payloads by version alone, so two builds'
# sets could pair one build's /usr with another's verity tree. This cannot run in
# postoutput: there $OUTPUTDIR is the staging tree and OutputDirectory= does not
# resolve.
sweep_stale() {
    local dir=$IMAGE_DIR ver prefix roothash keep_usr keep_verity f base want swept=0
    ver=$(image_version)
    prefix=vngrd_$ver

    [[ -d $dir ]] || die "not a directory: $dir"
    if [[ ! -r $dir/$prefix.roothash ]]; then
        note "no $prefix.roothash in $dir; cannot tell which set is this build's, so nothing is swept"
        return 0
    fi
    roothash=$(tr -d ' \t\n\r' <"$dir/$prefix.roothash")
    [[ $roothash =~ ^[0-9a-f]{64}$ ]] || die "$roothash is not a 64-character lower-case hex root hash"

    # systemd and repart derive the payload names from the two halves of the hash.
    keep_usr=${roothash:0:32}
    keep_verity=${roothash:32:32}
    note "this build is $prefix (usr $keep_usr, verity $keep_verity)"

    for want in "$prefix"_"$keep_usr".usr.xz "$prefix"_"$keep_verity".verity.xz \
                "$prefix.efi.xz" "$prefix.roothash"; do
        [[ -e $dir/$want ]] || die "this build's $want is missing from $dir; nothing was removed"
    done

    # The .efi.xz name has no per-build discriminator, so it is not swept.
    for f in "$dir/$prefix"_*.usr.xz "$dir/$prefix"_*.verity.xz "$dir/SHA256SUMS.gpg"; do
        [[ -e $f ]] || continue
        base=$(basename "$f")
        case $base in
            "$prefix"_"$keep_usr".usr.xz|"$prefix"_"$keep_verity".verity.xz) continue ;;
        esac
        note "removing stale $base"
        rm -f "$f"
        swept=$((swept + 1))
    done
    (( swept > 0 )) || note "nothing stale; $dir holds only this build's set"
}

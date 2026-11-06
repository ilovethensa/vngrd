# lib/secureboot.sh — UKI signature pre-flight and host-side Secure Boot enrolment.
#
# Sourced by run-vm.sh, not executed. Expects from its caller:
#   $ROOT, $IMG_DIR, $IMG_VER, $STATE, $OVMF_VARS_TMPL, $VARS
#   $note()
#
# POSIX sh, no `local': every variable here is _-prefixed so it cannot
# collide with a caller's.
# --- UKI signature pre-flight ------------------------------------------------

# Fail here rather than in the firmware setup shell. The UKI on the ESP is the same
# file as output/image/vngrd_<ver>.efi.xz, so the published artifact is what to
# check. A convenience, not the authority: the firmware is what enforces it.
check_uki_signature() {
    uki="$IMG_DIR/vngrd_$IMG_VER.efi.xz"
    sbverify=$(command -v sbverify || true)
    if [ -z "$sbverify" ] && [ -x "$ROOT/mkosi.tools/usr/bin/sbverify" ]; then
        sbverify="$ROOT/mkosi.tools/usr/bin/sbverify"
    fi
    cert=$(signing_cert)

    if [ ! -f "$uki" ] || [ -z "$sbverify" ] || [ ! -r "$cert" ]; then
        note "no sbverify, no $uki, or no readable SecureBootCertificate —"
        note "skipping the UKI pre-flight. The firmware still enforces it."
        return 0
    fi

    tmp=$(mktemp /tmp/vngrd-UKI-XXXXXX.efi)
    if xz -dc "$uki" > "$tmp" 2>/dev/null && "$sbverify" --cert "$cert" "$tmp" >/dev/null 2>&1; then
        note "UKI $IMG_VER: signature verifies against $(basename "$cert")"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    note "UKI $IMG_VER ($uki) does not verify against $cert; OVMF will refuse it."
    note "Either it was modified after signing, or it was signed with a different key."
    return 1
}

# --- Secure Boot key enrolment, host-side ------------------------------------

# The tools tree is a full distribution tree, so its scripts carry shebangs that
# resolve against the host and `virt' only exists in its site-packages. Both halves
# have to be overridden. The shift and "$@" matter: without them the call runs with
# no arguments, virt-fw-vars prints usage and exits 0, and the store is left
# untouched — so the enrolment silently happens in the guest instead, minutes later.
tools_python() {
    _t_script="$1"; shift
    _t_pyver=$(ls "$ROOT/mkosi.tools/usr/lib" 2>/dev/null |
        sed -n 's/^python3\.\([0-9]*\).*/\1/p' | head -n 1)
    PYTHONPATH="$ROOT/mkosi.tools/usr/lib/python3.${_t_pyver:-14}/site-packages" \
        "$ROOT/mkosi.tools/usr/bin/python3.${_t_pyver:-14}" \
        "$ROOT/mkosi.tools/usr/bin/$_t_script" "$@"
}

signing_cert() {
    sed -n 's/^SecureBootCertificate=//p' \
        "$ROOT/mkosi.conf.d/50-local-keys.conf" 2>/dev/null | tail -n 1
}

# varstore_pcr7 <store> — the digest edk2's MeasureAllSecureVariables() would
# produce, according to virt-fw-measure. Empty if the tools cannot answer, and the
# caller reads that as "cannot check, leave it alone".
#
# This is a PREDICTION from the variable store, not the value the guest ends up
# measuring. Observed on this OVMF: an enrolled store predicts 0xcbadfd40... while
# the guest's event log reports PCR 7 as 0x5d0966ec.... They disagree because
# QEMU's edk2 measures variables this model does not reproduce.
#
# That is harmless where the result is compared against another varstore_pcr7()
# value -- reference_store() builds its reference the same way, so the check is
# model-to-model and consistent -- but it must never be presented as, or compared
# against, the sealed digest. The seal binds the *live* PCR 7 measured inside the
# guest (repart's TPM2PCRs=7); the authoritative value is `tpm2 pcrread sha256:7`
# there, or the last PCR 7 record in binary_bios_measurements.
varstore_pcr7() {
    tools_python virt-fw-measure --vars="$1" --digests 2>/dev/null |
        tr -d ' \n' | sed -n 's/.*"pcr":7,.*"digest":"\([0-9a-f]*\)".*/\1/p'
}

# PK and KEK get the signing certificate; db gets that certificate plus the
# Microsoft CA certificates published with the image. That mirrors the
# production db.auth built by mkosi.postoutput, so the harness exercises the
# same trust set the offline enrolment procedure installs. All use the nil
# SignatureOwner that bootctl writes. In and out are the same file because
# virt-fw-vars rewrites its input in place.
extra_db_certs() {
    for _c in "$ROOT"/keys/*.der; do
        [ -f "$_c" ] && printf '%s\n' "$_c"
    done
}

enrol_varstore() {
    _e_store="$1"; _e_cert="$2"
    _e_nil=00000000-0000-0000-0000-000000000000
    set -- -i "$_e_store" \
        --set-pk  "$_e_nil" "$_e_cert" \
        --add-kek "$_e_nil" "$_e_cert" \
        --add-db  "$_e_nil" "$_e_cert"
    while IFS= read -r _e_extra; do
        [ -n "$_e_extra" ] && set -- "$@" --add-db "$_e_nil" "$_e_extra"
    done <<EOF
$(extra_db_certs)
EOF
    set -- "$@" --set-true SecureBootEnable --set-false CustomMode -o "$_e_store"
    tools_python virt-fw-vars "$@" >/dev/null 2>&1
}

# The store a fresh enrolment would produce, from the same template and the same
# certificate. Built and thrown away rather than cached, because it is one cp and
# one call, and a cached copy would be a stale copy waiting to mislead.
reference_store() {
    _r="$STATE/.enrol-reference.vars"
    rm -f "$_r"
    cp "$OVMF_VARS_TMPL" "$_r" 2>/dev/null || return 1
    if enrol_varstore "$_r" "$1"; then
        varstore_pcr7 "$_r"; rm -f "$_r"; return 0
    fi
    rm -f "$_r"; return 1
}

# OVMF's own enrolment is the only thing it does that talks to the TPM, and under
# QEMU 11.1.1 that exchange stalls: swtpm answers the PCR_Extend and QEMU never
# reads the reply, so DATA_AVAILABLE is never set and the guest polls until edk2's
# 90s TIS timeout. An unfixed QEMU defect in tpm_emulator_unix_tx_bufs; tpm-crb
# stalls the same way, and it is KVM-specific (TCG 0/14, KVM 6/8). Nothing
# configures around it, so the store is enrolled here instead.
#
# PCR 7 is what is compared, not "is there a PK": a store in setup mode still has
# a PCR 7, because edk2 measures the absent variables as zero-size entries. The
# mode alone cannot tell "never enrolled" from "enrolled with a rotated key", and
# those need very different things said about them.
#
# --set-true/--set-false rather than virt-fw-vars' own --secure-boot, which adds a
# 76-byte empty dbx that edk2 measures as a non-empty entry and which moves PCR 7
# to f58a897f... — a real policy change, and a seal that would no longer match.
#
# This is test-side convenience. On real firmware the store is whatever the OEM
# shipped, sd-boot enrols and reboots, and none of this runs.
ensure_secure_boot_enrolled() {
    _store="$1"; _cert="$2"

    _in_setup_mode=1
    tools_python virt-fw-vars -i "$_store" --print 2>/dev/null | grep -q '^PK *:' && _in_setup_mode=0

    _want=$(reference_store "$_cert")
    if [ -z "$_want" ]; then
        note "no usable OVMF template or virt-fw-vars; leaving the store alone"
        note "(sd-boot will enrol on the first boot, which stalls ~150s there)"
        return 0
    fi
    [ "$(varstore_pcr7 "$_store")" = "$_want" ] && return 0

    if [ "$_in_setup_mode" = 0 ]; then
        # Enrolled with a different db/KEK policy. Re-enrolling changes PCR 7 and
        # the root is sealed to the old value, so this machine can no longer unseal.
        note "WARNING: $STATE has a different Secure Boot policy than the current"
        note "         vngrd + Microsoft 2023 certificate set."
        note "         Re-enrolling changes PCR 7, so this machine must be re-provisioned"
        note "         (--reset) for the LUKS2 root to unseal again."
    fi

    if enrol_varstore "$_store" "$_cert"; then
        note "enrolled the vngrd and Microsoft 2023 db certificates into $STATE host-side."
        note "         PCR 7 predicted as $(varstore_pcr7 "$_store")"
        note "         (a prediction from the varstore, not the digest the guest measures -- see varstore_pcr7)"
    else
        note "WARNING: virt-fw-vars could not enrol $STATE; sd-boot will enrol on the first boot."
    fi
}

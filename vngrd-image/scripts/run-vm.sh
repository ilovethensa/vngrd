#!/bin/sh -e
# run-vm.sh — boot the built disk image in QEMU (OVMF, q35).
#
# Secure Boot and the TPM2 are on by default and both are load-bearing: the signed
# UKI is the root of the /usr trust chain, and the LUKS2 key is sealed to the
# Secure Boot policy. A run with neither tests a different design.
#
# Everything that makes a run a particular *machine* — variable store, TPM state,
# writable disk — lives in one state directory per (image, firmware) pair. Keep them
# together: the disk key is wrapped to the TPM, so keeping one and discarding the
# other gives a machine that cannot unseal itself.
#
# vngrd-tests/ drives this unattended and asserts on the serial log.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG_DIR="$ROOT/../output/image"

DISK_SIZE=4G
SECUREBOOT=1
TPM=1
GUI=0
SNAPSHOT=0
TPM_RESET=0
STATE_RESET=0
IMG_OVERRIDE=
VERSION_OVERRIDE=
SERIAL_FILE=
SERIAL_SOCK=
STATE_SUFFIX=

# KVM unless VNGRD_NO_KVM is set. It is an override rather than just --no-kvm
# because the test suite cannot pass --no-kvm per-case: it launches VMs from
# vngrd-tests/harness/qemu.py, and on a host where KVM makes TPM operations unusable the
# whole suite times out rather than failing informatively. QEMU 11.1.1's
# tpm_emulator_unix_tx_bufs never reads the reply, so with KVM the guest polls
# until edk2's 90s TIS timeout on every PCR_Extend; TCG does not (documented
# above: "TCG 0/14, KVM 6/8"). TPM tests need TCG on this QEMU.
if [ -n "${VNGRD_NO_KVM:-}" ]; then
    KVM=0
elif [ -c /dev/kvm ]; then
    KVM=1
else
    KVM=0
fi

# How long to let the guest shut itself down after a signal. Generous because
# swtpm writes tpm2-00.permall with O_TRUNC and no rename, so killing it mid-commit
# truncates the state and the next boot cannot start the TPM at all. Under TCG one
# TPM round trip costs ~50s (see the QEMU defect noted at the enrolment step), so
# 20s was not enough and the fallback was destroying the state it was protecting.
POWERDOWN_TIMEOUT=180

die()  { echo "$0: $*" >&2; exit 1; }
note() { echo "$0: $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 [options] [-- <extra qemu args>]

  --gui              GTK window, zoom-to-fit (default: headless serial)
  --snapshot         run with -snapshot; nothing is written to the disk
  --no-kvm           disable KVM (falls back to -cpu qemu64)
  --disk-size SIZE   virtual disk size (default: 4G)
  --image PATH       boot this disk instead of the highest vngrd_<ver>.raw
  --version VER      version to label the machine with. Required with --image for
                     a disk not named vngrd_<ver>.raw, e.g. a test case's copy.
  --reset-tpm        wipe this machine's TPM state before booting
  --reset            wipe TPM state, OVMF variables and disk, and re-provision

  --no-secure-boot   firmware built without Secure Boot, so unsigned UKIs are
                     accepted. Refused with --tpm: PCR 7 then carries no policy, so
                     the LUKS2 key sealed to it opens on any boot.
  --no-tpm           no TPM2 emulator. repart then fails with "TPM device not
                     found" and the LUKS2 root is never created.

  --serial-file PATH  write the serial console here instead of stdio
  --state-suffix TOK suffix the state directory, e.g. -test, so a test run cannot
                     touch your own provisioned machine

--secure-boot and --tpm are accepted as explicit forms of the defaults.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gui)            GUI=1; shift ;;
        --snapshot)       SNAPSHOT=1; shift ;;
        --no-kvm)         KVM=0; shift ;;
        --disk-size)      DISK_SIZE="$2"; shift 2 ;;
        --disk-size=*)    DISK_SIZE="${1#*=}"; shift ;;
        --image)          IMG_OVERRIDE="$2"; shift 2 ;;
        --image=*)        IMG_OVERRIDE="${1#*=}"; shift ;;
        --version)        VERSION_OVERRIDE="$2"; shift 2 ;;
        --version=*)      VERSION_OVERRIDE="${1#*=}"; shift ;;
        --serial-file)    SERIAL_FILE="$2"; shift 2 ;;
        --serial-file=*)  SERIAL_FILE="${1#*=}"; shift ;;
        --serial-sock)    SERIAL_SOCK="$2"; shift 2 ;;
        --serial-sock=*)  SERIAL_SOCK="${1#*=}"; shift ;;
        --state-suffix)   STATE_SUFFIX="$2"; shift 2 ;;
        --state-suffix=*) STATE_SUFFIX="${1#*=}"; shift ;;
        --secure-boot)    SECUREBOOT=1; shift ;;
        --no-secure-boot) SECUREBOOT=0; shift ;;
        --tpm)            TPM=1; shift ;;
        --no-tpm)         TPM=0; shift ;;
        --reset-tpm)      TPM_RESET=1; shift ;;
        --reset)          STATE_RESET=1; TPM_RESET=1; shift ;;
        --help|-h)        usage; exit 0 ;;
        --)               shift; break ;;
        -*)               die "unknown arg $1" ;;
        *)                break ;;
    esac
done

# A firmware without SecureBootDxe measures PCR 7 as empty records, which is a
# fixed constant on every boot of that machine. A key sealed to it would unseal on
# any boot, including one with an attacker-replaced UKI.
[ "$TPM" = 1 ] && [ "$SECUREBOOT" = 0 ] && die \
    "--no-secure-boot with a TPM: PCR 7 carries no Secure Boot policy, so the key sealed to it opens on any boot"

command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found"

# --- which image -------------------------------------------------------------

# By version, not mtime: booting an image and updating it both bump the mtime, so
# "newest file" tracks what was last run. The .roothash sibling is what
# distinguishes a real image from the split partitions mkosi also emits.
img_versions() {
    for img in "$IMG_DIR"/vngrd_*.raw; do
        [ -f "$img" ] || continue
        _v="${img##*/}"; _v="${_v#vngrd_}"; _v="${_v%.raw}"
        [ -f "$IMG_DIR/vngrd_$_v.roothash" ] || continue
        printf '%s\n' "$_v"
    done | sort -u -V
}

if [ -n "$IMG_OVERRIDE" ]; then
    # An explicit --image wins, so an update can be tested against the disk it is
    # meant to be applied to. --version wins over the filename, or a disk named
    # disk.raw yields the nonsense version "disk" — which is the state directory.
    case "$IMG_OVERRIDE" in
        /*) IMG="$IMG_OVERRIDE" ;;
        *)  IMG="$PWD/$IMG_OVERRIDE" ;;
    esac
    IMG_VER="${VERSION_OVERRIDE:-$(basename "$IMG" .raw)}"
    IMG_VER="${IMG_VER#vngrd_}"
else
    versions="$(img_versions)"
    [ -n "$versions" ] || die "no vngrd_<version>.raw with a .roothash beside it in $IMG_DIR; run mkosi build first"
    IMG_VER="$(printf '%s\n' "$versions" | tail -n 1)"
    IMG="$IMG_DIR/vngrd_$IMG_VER.raw"
    if [ "$(printf '%s\n' "$versions" | grep -c .)" -gt 1 ]; then
        echo "Images available (highest version boots):"
        printf '%s\n' "$versions" | while read -r v; do echo "  $IMG_DIR/vngrd_$v.raw"; done
        want="$(sed -n 's/^ImageVersion=//p' "$ROOT/mkosi.conf" 2>/dev/null | head -n 1)"
        [ -n "$want" ] && [ "$want" != "$IMG_VER" ] &&
            note "mkosi.conf declares ImageVersion=$want"
    fi
fi
[ -f "$IMG" ] || die "missing $IMG — run mkosi build first"

# --- firmware ----------------------------------------------------------------

# ${OVMF_CODE}/${OVMF_VARS} let a host with an unusual layout name its own files;
# without them this script knows the Arch and Fedora/edk2 install paths only.
# Debian/Ubuntu ship 4M firmware without the x64/ prefix, hence those candidates.
if [ "$SECUREBOOT" = 1 ]; then
    OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/x64/OVMF_CODE.secboot.4m.fd}"
    SB_FW=secboot
else
    OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/x64/OVMF_CODE.4m.fd}"
    SB_FW=plain
fi

# The *empty* variable template, not a pre-enrolled one. The store this script
# builds has to be the one a bare-metal first boot produces; starting from a store
# that already carries someone else's db would put extra certificates in PCR 7 and
# break the seal against it.
OVMF_VARS_TMPL="${OVMF_VARS:-/usr/share/OVMF/x64/OVMF_VARS.4m.fd}"
[ -f "$OVMF_VARS_TMPL" ] || for c in /usr/share/OVMF/x64/OVMF_VARS.ms.fd \
                                  /usr/share/edk2/x64/OVMF_VARS.4m.fd \
                                  /usr/share/OVMF/OVMF_VARS_4M.secboot.fd \
                                  /usr/share/OVMF/OVMF_VARS_4M.ms.fd; do
    [ -f "$c" ] && { OVMF_VARS_TMPL="$c"; break; }
done
for f in "$OVMF_CODE" "$OVMF_VARS_TMPL"; do
    [ -f "$f" ] || die "missing $f"
done

# --- state directory ---------------------------------------------------------

FW_STATE=$SB_FW
[ "$SECUREBOOT" = 1 ] || FW_STATE=insecureboot
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/vngrd/$IMG_VER-$FW_STATE$STATE_SUFFIX"

confirm_reset() {
    note "About to reset $STATE"
    note "  image: $IMG"
    # Wiping the TPM destroys its SRK, and the provisioned root has no passphrase,
    # so repart will not re-create it. The disk has to go with it.
    note "  Wiping the TPM destroys its SRK and the provisioned root has no"
    note "  passphrase, so repart cannot re-create it. The disk must go too."
    if [ "$STATE_RESET" = 1 ]; then
        note "  --reset: dropping TPM state, OVMF variables and disk; re-provisions."
    else
        note "  Use --reset to drop the variables and disk as well."
    fi
    printf '  Ctrl-c to abort in 5s... '
    sleep 5
}

if [ "$STATE_RESET" = 1 ]; then
    confirm_reset
    rm -rf "$STATE"
elif [ "$TPM_RESET" = 1 ]; then
    confirm_reset
    rm -rf "$STATE/tpm"
fi
mkdir -p "$STATE"
# 0700: this holds the sealed key material, and swtpm's default state file mode is
# 0640, so with the caller's umask the SRK would be group-readable.
chmod 700 "$STATE"

# PCR 7 depends on the firmware *build* as well as the variables, so the CODE hash
# is printed: it is what makes an OVMF upgrade visible when it invalidates a seal.
echo "Image:      $IMG"
echo "SecureBoot: $SECUREBOOT ($(basename "$OVMF_CODE"), $(sha256sum "$OVMF_CODE" | cut -c1-12))"
echo "TPM2:       $TPM"
echo "State:      $STATE"
[ -e "$STATE/disk.qcow2" ] ||
    note "first run for this (image, firmware): the disk will be provisioned"
[ -e "$STATE/OVMF_VARS.fd" ] ||
    note "first run: the UKI signing key will be enrolled before the real boot"

# --- the disk ----------------------------------------------------------------

want_size=$(numfmt --from=iec "$DISK_SIZE" 2>/dev/null) || want_size=
[ -n "$want_size" ] || die "bad --disk-size '$DISK_SIZE' (try 4G, 8192M, 1G)"

# A private overlay, never the artifact: mkosi recreates the .raw from scratch and
# it has to stay byte-identical to what output/image/SHA256SUMS covers. repart also
# needs room after the shipped partitions to create vngrd-root, and will not do it
# without ~1.7G free.
case "$IMG" in *.qcow2) BACKING_FMT=qcow2 ;; *) BACKING_FMT=raw ;; esac
create_overlay() { qemu-img create -f qcow2 -F "$BACKING_FMT" -b "$IMG" "$1" "$want_size" >/dev/null; }

if [ "$SNAPSHOT" = 1 ]; then
    DISK="$(mktemp /tmp/vngrd-disk-XXXXXX.qcow2)"
    create_overlay "$DISK"
else
    DISK="$STATE/disk.qcow2"
    # A QEMU killed rather than shut down leaves its image lock, and the next run
    # then fails with "Is another process using the image?", which reads like a
    # permissions problem and is not one.
    if [ -e "$DISK.lock" ] && ! pgrep -f "qemu-system-x86_64.*$DISK" >/dev/null 2>&1; then
        note "removing a stale QEMU lock on $DISK (no QEMU is running with it)"
        rm -f "$DISK.lock"
    fi
    # Plain text parsing: `qemu-img info -o json' is not valid in QEMU 11.x (--output
    # json is), and a query that fails silently reads as size 0, which would
    # recreate the overlay every run.
    if [ -f "$DISK" ]; then
        have=$(qemu-img info "$DISK" 2>/dev/null |
               sed -n 's/^virtual size:.*(\([0-9]*\) bytes).*/\1/p')
        if [ -n "$have" ] && [ "$have" -lt "$want_size" ]; then
            rm -f "$DISK"
            note "replacing $DISK ($have -> $want_size bytes): a bigger --disk-size needs a new overlay"
        fi
    fi
    [ -f "$DISK" ] || { create_overlay "$DISK"; note "created $DISK ($want_size bytes virtual, sparse; the artifact is untouched)"; }
fi
note "mkosi build recreates the image, and so does --reset."

# --- OVMF variable store -----------------------------------------------------

VARS="$STATE/OVMF_VARS.fd"
[ -f "$VARS" ] || { cp "$OVMF_VARS_TMPL" "$VARS"; chmod 600 "$VARS"; }

# --- Secure Boot ------------------------------------------------------------

. "$ROOT/scripts/lib/secureboot.sh"

# Neither step applies to a firmware built without SecureBootDxe.
if [ "$SECUREBOOT" = 1 ]; then
    check_uki_signature || exit 1
    _cert=$(signing_cert)
    if [ -z "$_cert" ] || [ ! -r "$_cert" ]; then
        note "no readable SecureBootCertificate; sd-boot will enrol on the first boot."
    else
        ensure_secure_boot_enrolled "$VARS" "$_cert"
    fi
fi

# --- TPM2 -------------------------------------------------------------------

. "$ROOT/scripts/lib/tpm.sh"

if [ "$TPM" = 1 ]; then
    # VNGRD_TPM_CRB=1 selects the CRB transport; see the note below on why TIS
    # is the default.
    TPM_DEV=tpm-tis
    [ -n "${VNGRD_TPM_CRB:-}" ] && TPM_DEV=tpm-crb
    start_tpm
    trap 'stop_tpm' EXIT INT TERM
else
    trap '[ "$SNAPSHOT" = 1 ] && rm -f "$DISK"; :' EXIT INT TERM
fi

# Signalling swtpm is not optional housekeeping: it holds the TPM state in memory
# and commits the blob on the way out, so a daemon that is never told to exit leaves
# the owner seed uncommitted -- and the next boot derives a different SRK and every
# sealed object fails TPM2_RC_INTEGRITY on load. It is also daemonised, so it
# outlives this script and keeps the state directory's lock, which makes the NEXT
# run's start fail until something else kills it.
#
# This function did not exist, while the EXIT trap below called it by name. So for as
# long as that trap has been there, the TPM daemon has been left running after every
# boot, and the state has been committed only when some later run happened to reclaim
# it.
stop_tpm() {
    [ -s "$TPM_STATE/swtpm.pid" ] || return 0
    _swtpm_pid=$(cat "$TPM_STATE/swtpm.pid")
    kill -TERM "$_swtpm_pid" 2>/dev/null || true
    # Give it the moment it needs to flush. Stopping short of this is how the state
    # ends up partially written.
    _n=0
    while kill -0 "$_swtpm_pid" 2>/dev/null && [ "$_n" -lt 60 ]; do
        sleep 0.5
        _n=$((_n + 1))
    done
    kill -KILL "$_swtpm_pid" 2>/dev/null || true
    rm -f "$TPM_STATE/swtpm.pid"
    rm -rf "$TPM_DIR"
}

# --- the QEMU command -------------------------------------------------------

# A monitor on a unix socket so a signal can become an orderly shutdown rather
# than a kill. Created here because $MONITOR is needed by the display branch
# below, and expanding an unset variable into $@ gives an option with an empty
# value. server=on,wait=off: qemu must not block at startup waiting for a client.
MON_DIR="$(mktemp -d /tmp/vngrd-mon-XXXXXX)"
MONITOR="unix:$MON_DIR/mon,server=on,wait=off"

# Built into $@ rather than a string so nothing is eval'd and paths with spaces
# survive.
set -- qemu-system-x86_64 \
    -machine q35 -m 2048 -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$DISK",format=qcow2,if=virtio

# -nic none: otherwise QEMU attaches a SLIRP NIC and the guest sits on
# 10.0.2.0/24 with whatever the host can reach. Nothing talks to it today only
# because no DHCP client is installed, which is an accident waiting to happen.
set -- "$@" -nic none

if [ "$KVM" = 1 ]; then
    set -- "$@" -enable-kvm -cpu host
else
    set -- "$@" -cpu qemu64
fi

if [ "$TPM" = 1 ]; then
    # tpm-tis, not tpm-crb: tpm-crb became a PCI device in QEMU 8.0 and this
    # kernel has no PCI transport for it, so the guest would see a bare 'TPM2' ACPI
    # table with no MSFT0101 node and nothing to bind. tpm-tis publishes MSFT0101
    # on the same QEMU. The kernel keeps CONFIG_TCG_CRB=y regardless, because CRB
    # is what real hardware exposes. Do not switch back without adding the
    # transport first.
    set -- "$@" -chardev socket,id=chrtpm,path="$TPM_SOCK" \
              -tpmdev emulator,id=tpm0,chardev=chrtpm \
              -device "$TPM_DEV",tpmdev=tpm0
fi

[ "$SNAPSHOT" = 1 ] && set -- "$@" -snapshot

if [ "$GUI" = 1 ]; then
    set -- "$@" -display gtk,zoom-to-fit=on -monitor "$MONITOR"
elif [ -n "$SERIAL_SOCK" ]; then
    # A bidirectional serial socket. -serial stdio on a pty stalls under KVM:
    # the guest writes its console far faster than emulation did, and the
    # pty-backed stdio path stops draining, which looks exactly like a hang
    # in whatever unit happened to be printing. This exists so the test
    # harness can drive prompts without that failure mode.
    rm -f "$SERIAL_SOCK"
    set -- "$@" -display none -serial "unix:$SERIAL_SOCK,server=on,wait=on" -monitor "$MONITOR"
    note "Serial socket: $SERIAL_SOCK"
elif [ -n "$SERIAL_FILE" ]; then
    # The serial log is the only high-fidelity record of a boot: kernel ring
    # buffer, every unit start/finish, OVMF output and sd-boot's log_error_status
    # all land there. The host has to both stop qemu and read this.
    set -- "$@" -display none -serial "file:$SERIAL_FILE" -monitor "$MONITOR"
    note "Serial log: $SERIAL_FILE"
else
    set -- "$@" -display none -serial stdio -monitor "$MONITOR"
fi

echo "Running: $*"
[ "$GUI" = 0 ] && [ -z "$SERIAL_FILE" ] && [ -z "$SERIAL_SOCK" ] && note "Exit: Ctrl-c to quit (serial on stdio)"

# --- run --------------------------------------------------------------------

. "$ROOT/scripts/lib/run.sh"

rm -rf "$MON_DIR"

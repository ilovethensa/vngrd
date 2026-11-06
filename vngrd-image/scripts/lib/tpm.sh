# lib/tpm.sh — start and stop the swtpm process for one machine.
#
# Sourced by run-vm.sh, not executed. Expects from its caller:
#   $STATE for the machine directory
#   sets TPM_STATE, TPM_DIR, TPM_SOCK for the qemu command
#   $note(), $die()
#
# POSIX sh, no `local': every variable here is _-prefixed so it cannot
# collide with a caller's.
# --- TPM2 emulator -----------------------------------------------------------

# The state directory is deliberately not a mktemp: a real TPM keeps its SRK across
# reboots and the disk key is sealed to it, so a throwaway state would make every
# run a different machine.
TPM_STATE=
TPM_DIR=
TPM_SOCK=

# Two things have to be true before swtpm starts, and both are about not having two
# owners of one state directory.
#
# swtpm holds the TPM state in memory and writes the whole blob on commit, so two
# instances sharing a directory do not fail safely — the second should be stopped by
# the backend's fcntl lock, and when they do coexist whichever exits last wins. A
# leaked daemon from an earlier run then replaces the current machine's state with
# its own older copy, and the symptom is whichever of these arrives first:
#
#   TPM2_RC_INTEGRITY   the disk key was sealed under an SRK that has been
#                       overwritten
#   CMD_INIT: 0x9       the file was truncated by an instance killed mid-write
#
# Leaks happen because this script does not exec qemu — deliberately, so its EXIT
# trap can reap swtpm — which means anything that kills the script without letting
# the trap finish leaves a booted orphan still holding the disk. So: refuse to start
# against a machine in use, and clear out stale swtpm for this state directory.
reclaim_machine() {
    for pid in $(pgrep -f "qemu-system-x86_64.*$STATE" 2>/dev/null); do
        note "another qemu ($pid) is already using $STATE"
        note "two VMs on one machine corrupt the TPM state irrecoverably; stop it"
        note "first (kill $pid) or use a different state directory"
        exit 1
    done

    for sig in TERM KILL; do
        for pid in $(pgrep -f "swtpm.*tpmstate dir=$TPM_STATE" 2>/dev/null); do
            [ "$pid" = "$$" ] && continue
            [ "$sig" = TERM ] && note "killing stale swtpm $pid holding $TPM_STATE"
            kill -"$sig" "$pid" 2>/dev/null || true
        done
        # Let a signalled instance flush and exit before the next signal, or the
        # new instance is the one racing it.
        n=0
        while pgrep -f "swtpm.*tpmstate dir=$TPM_STATE" >/dev/null 2>&1 && [ "$n" -lt 10 ]; do
            sleep 0.5; n=$((n + 1))
        done
    done
}

start_tpm() {
    command -v swtpm >/dev/null || die "swtpm not found, install swtpm (or pass --no-tpm)"

    TPM_STATE="$STATE/tpm"
    mkdir -p "$TPM_STATE"; chmod 700 "$TPM_STATE"
    TPM_DIR="$(mktemp -d /tmp/vngrd-tpm-XXXXXX)"
    TPM_SOCK="$TPM_DIR/swtpm.sock"
    reclaim_machine

    # No --flags: startup-clear makes swtpm send its own TPM2_Startup(CLEAR) and
    # OVMF then sends a second one and gets TPM2_RC_INITIALIZE. QEMU's CMD_INIT is
    # the initialisation to rely on.
    # No --terminate: documented as "TCP only", and this is a UnixIO data socket.
    # level=20 is the swtpm command trace, and it is the only place the actual TPM
    # command sequence exists — the guest reports a bare TPM2_RC and
    # systemd-cryptsetup's own errors go nowhere. In the state dir, not TPM_DIR, so
    # it survives to be read after the run.
    # --flags not-need-init is REQUIRED, not a tuning knob. Without it, under
    # KVM, QEMU blocks forever in tpm_emulator_unix_tx_bufs after swtpm answers a
    # control command with a bare 4-byte error: that is upstream QEMU's "tpm:
    # Resolve potential blocking forever issue" (qemu-devel, Oct 2024 -- some
    # commands expect more bytes than an error reply carries, so
    # qemu_chr_fe_read_all() waits for bytes that never come). The guest then
    # polls until edk2's 90s TIS timeout on every PCR_Extend, so a boot that
    # takes ~95s under TCG never finishes. Measured on this QEMU 11.1.1 +
    # swtpm 0.10.2: without the flag a KVM boot produced no serial output at
    # all in 180s; with it, provisioning starts at ~19s and there are zero TPM
    # timeouts. TCG happens to dodge the race, which is why the suite passed.
    # startup-clear stays off deliberately (see the note below).
    TPM_FLAGS="--flags ${VNGRD_TPM_FLAGS:-not-need-init}"
    swtpm socket --tpm2 --tpmstate dir="$TPM_STATE",mode=0600 \
        $TPM_FLAGS \
        --ctrl type=unixio,path="$TPM_SOCK" --daemon \
        --log "file=$TPM_STATE/swtpm.log,level=20" \
        --pid file="$TPM_STATE/swtpm.pid" 2>/dev/null ||
        die "failed to start swtpm"
}

# By pid, not by pattern: a pattern sweep cannot tell this run's swtpm from a
# leaked one, and killing the wrong one is the state clobbering above.
stop_tpm() {
    [ -s "$TPM_STATE/swtpm.pid" ] || return 0
    kill -TERM "$(cat "$TPM_STATE/swtpm.pid")" 2>/dev/null || true
    rm -f "$TPM_STATE/swtpm.pid"
    rm -rf "$TPM_DIR"
}

if [ "$TPM" = 1 ]; then
    start_tpm
    trap 'stop_tpm' EXIT INT TERM
else
    trap '[ "$SNAPSHOT" = 1 ] && rm -f "$DISK"; :' EXIT INT TERM
fi

# lib/run.sh — run qemu, and turn a signal into an orderly shutdown.
#
# Sourced by run-vm.sh, not executed. Expects from its caller:
#   $QEMU_PID, $MON_DIR, $POWERDOWN_TIMEOUT
#   defines on_signal, which run-vm.sh installs as its INT/TERM trap
#
# POSIX sh, no `local': every variable here is _-prefixed so it cannot
# collide with a caller's.
# --- run it ------------------------------------------------------------------

qemu_running() { [ -n "${QEMU_PID:-}" ] && kill -0 "$QEMU_PID" 2>/dev/null; }

# Ask the guest to power down rather than killing it. A TPM has to be committed by
# the firmware on the way out (TPM2_Shutdown, per the QEMU TPM device spec), and
# SIGTERM to qemu is immediate: OVMF never runs its ACPI shutdown path, the state is
# never committed, the next boot derives a different SRK from the owner seed, and
# every object sealed under the old one fails TPM2_RC_INTEGRITY on load. That is the
# difference between a machine that boots twice and one that does not.
powerdown() {
    qemu_running || return 0
    printf 'system_powerdown\n' | ncat -U -q1 "$MON_DIR/mon" >/dev/null 2>&1 || true
}

wait_for_exit() {
    _n=0
    while qemu_running && [ "$_n" -lt $((POWERDOWN_TIMEOUT * 2)) ]; do
        sleep 0.5; _n=$((_n + 1))
    done
}

on_signal() {
    powerdown
    wait_for_exit
    if qemu_running; then
        note "guest did not shut down within ${POWERDOWN_TIMEOUT}s; killing qemu."
        note "swtpm's state file may now be truncated, so the next boot can fail with"
        note "TPM2_RC_FAILURE. Re-run with --reset-tpm to rebuild it."
    fi
    qemu_running && kill -TERM "$QEMU_PID" 2>/dev/null || true
}

# Not exec: exec would replace this shell, so the EXIT trap would never run and
# swtpm and the temp sockets would leak.
#
# stdin is saved to fd 9 and handed over explicitly, and that is load-bearing
# rather than tidiness. POSIX gives an asynchronous list /dev/null on stdin when
# the shell is not interactive, so a plain `"$@" &' makes qemu's stdin /dev/null
# and `-serial stdio' becomes output-only: the guest prints the login prompt and
# then never sees a keystroke, which reads as "login is hung" and is
# indistinguishable from a dead console. An explicit redirection overrides the
# /dev/null default, so fd 9 is what keeps the terminal attached. (It also
# carries the terminal's reply to the shell's device-attribute query, without
# which an interactive shell stalls for its full query timeout on startup.)
exec 9<&0
"$@" <&9 &
QEMU_PID=$!
trap on_signal INT TERM
wait "$QEMU_PID" || true
# A signal can interrupt `wait' before qemu is really gone; waiting here is what
# makes this script's exit — and therefore its trap, and therefore swtpm's commit —
# happen after qemu rather than racing it.
wait_for_exit
qemu_running && kill -TERM "$QEMU_PID" 2>/dev/null || true
rm -rf "$MON_DIR"

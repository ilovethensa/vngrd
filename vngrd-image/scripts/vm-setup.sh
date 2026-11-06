#!/bin/bash
# vm-setup.sh — reset the interactive machine and let it provision itself.
#
# Wipes the machine's disk, OVMF variable store and TPM state, then boots it once
# so systemd-repart creates the sealed LUKS2 root, vngrd-provision asks for the
# recovery passphrase and vngrd-tpm-pin asks for the PIN -- a real first boot. The
# state (disk, TPM, varstore) is kept, so ./vm-boot.sh afterwards opens the same
# machine.
#
# This uses its own state directory (`-manual`), separate from the default
# machine and from the test suite's `-boottest` one. Nothing is a snapshot: every
# boot keeps what the last one wrote.
#
# INTERACTIVE, and it has to be: the first boot asks for a recovery passphrase
# and then a TPM2 PIN. repart creates the token PIN-less because it runs
# unattended, vngrd-provision.service asks for the passphrase in the initrd and
# vngrd-tpm-pin.service adds the PIN on the same console. Nothing can answer
# those prompts but a person, so the guest console is this terminal and stdin is
# left alone. The passphrase is not printed, so record what you type.
#
# When the login prompt appears, press Ctrl-C. run-vm.sh handles the signal by
# powering the guest down cleanly, which is what lets swtpm commit its state; a
# signal straight to qemu would skip that and can leave the TPM holding a
# half-written blob. The script then re-reads the log and reports success or
# emergency mode.
set -euo pipefail
cd "$(dirname "$0")/.."

state_root="${XDG_STATE_HOME:-$HOME/.local/state}/vngrd"
mkdir -p "$state_root"
log="$state_root/vm-setup.log"     # guest console + run-vm.sh's own output
rm -f "$log" "$log.txt"

image=$(ls -d ../output/image/vngrd_*.raw 2>/dev/null | sort -V | tail -1 || true)
cat <<EOF
==> wiping the interactive machine and re-provisioning it
    image: ${image:-<none; build the image first>}
    this is a full first boot (Secure Boot enrolment + repart, minutes).

    The guest console is THIS terminal. The first boot first asks for a recovery
    passphrase, then for a TPM2 PIN twice -- "Please enter TPM2 PIN:" and then
    "(repeat):". Choose both now. The PIN is hashed with Argon2id into the TPM2
    policy and stored nowhere; the recovery passphrase is a keyslot and is the
    only way back in if the PIN is forgotten. Neither is printed.

    When "login:" appears, press Ctrl-C. The machine then powers down cleanly.
    Console is also logged to:
      $log
EOF
echo

# No --serial-file: that would make the console output-only and the PIN prompt
# unanswerable. stdin is deliberately untouched -- run-vm.sh re-opens it for qemu
# (scripts/lib/run.sh does `exec 9<&0'), which is what makes typing at the serial
# console work at all.
set +e
./scripts/run-vm.sh --state-suffix -manual --reset 2>&1 | tee "$log"
set -e

sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b\][^\x07]*\x07//g' -e 's/\r//g' \
    "$log" >"$log.txt" 2>/dev/null || true

echo
if grep -aq 'You are in emergency mode\.' "$log.txt" 2>/dev/null; then
    echo "==> FAILED: the first boot ended in emergency mode." >&2
    echo "    console log: $log" >&2
    exit 1
fi
if ! grep -aq 'login:' "$log.txt" 2>/dev/null; then
    echo "==> FAILED: no login prompt, so provisioning did not complete." >&2
    echo "    (Ctrl-C before the boot finished will do this.)" >&2
    echo "    console log: $log" >&2
    exit 1
fi

echo "==> provisioned; boot it interactively with ./scripts/vm-boot.sh"

# The recovery passphrase is chosen at the prompt and deliberately not printed:
# there is no copy in the console log to pull out. This is a reminder, not a
# recovery mechanism.
echo "    root recovery passphrase: the value you typed at the first prompt."
echo
echo "    console log: $log"
echo "    cleaned log: $log.txt"

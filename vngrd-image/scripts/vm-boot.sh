#!/bin/bash
# vm-boot.sh — boot the interactive machine with its persistent data.
#
# Boots the machine that ./vm-setup.sh provisioned, reusing its disk, TPM state
# and OVMF variable store. The console is attached to this terminal, so the TPM2
# PIN prompt can be answered and you can log in -- and the same console goes
# through tee into a log, so an interactive session is still recorded.
#
# Ctrl-C asks the guest to power down through run-vm.sh's trap, so the TPM state
# is committed on the way out. A signal straight to qemu would skip that.
#
# Nothing is reset and nothing is snapshotted. If no machine has been set up yet,
# this boot provisions one from scratch -- run ./vm-setup.sh instead if you want
# the first boot handled end to end.
set -euo pipefail
cd "$(dirname "$0")/.."

state_root="${XDG_STATE_HOME:-$HOME/.local/state}/vngrd"
mkdir -p "$state_root"
log="$state_root/vm-boot.log"      # guest console + run-vm.sh's own output
rm -f "$log" "$log.txt"

cat <<EOF
==> booting the interactive machine; the console is THIS terminal
    the root token asks for the TPM2 PIN. After a firmware or dbx change it asks
    for the recovery passphrase instead, until systemd-pcrlock re-locks (see
    systemd-pcrlock-firmware-code.service).

    When "login:" appears, press Ctrl-C: run-vm.sh then powers the machine down
    cleanly, which is what lets swtpm commit its state.
      console log: $log
EOF
echo

# Interactive and logged at the same time. No --serial-file and no --serial-sock:
# either would take the console away from the terminal, and one of them makes it
# output-only, which is exactly what leaves a PIN prompt unanswerable.
set +e
./scripts/run-vm.sh --state-suffix -manual 2>&1 | tee "$log"
set -e

sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b\][^\x07]*\x07//g' -e 's/\r//g' \
    "$log" >"$log.txt" 2>/dev/null || true

echo
echo "    console log: $log"
echo "    cleaned log: $log.txt"

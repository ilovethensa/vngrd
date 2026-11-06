"""Tier 2: losing TPM state is a re-provisioning event, not a recovery unlock.

A TPM clear (or a replacement TPM, or a firmware reset that wipes NV) removes
every register the initrd guards depend on, while the disk and its LUKS2 header
remain. The recovery passphrase is still a valid key to the volume -- it is an
ordinary keyslot, independent of the TPM -- but it cannot recreate the frozen
GPT/ESP/fixate/rollback values. A normal boot therefore has to refuse before
`systemd-cryptsetup` ever asks for the volume key.

This case proves both halves:

  * the guest refuses with no cryptsetup start, which is the fail-closed path;
  * the same disk opens host-side with the recovery passphrase (and a wrong
    passphrase does not), so the refusal is not a destroyed volume.

The TPM state is replaced with an empty directory: swtpm then starts with a new
SRK and no NV indices, which is the observable shape of a TPM clear. The disk,
the OVMF variable store and the Secure Boot policy are untouched.
"""

from __future__ import annotations

import re
import subprocess

from harness import boot_case, luks2, tpm
from harness.console import TEST_RECOVERY_PASSPHRASE
from harness.disk import extract
from harness.qemu import normalise

GUARD_LINES = (
    "vngrd-rollback-guard:",
    "vngrd-gpt-guard:",
    "vngrd-esp-guard:",
    "vngrd-fixate-guard:",
)
RECOVERY_PROMPT = re.compile(r"Please enter passphrase for disk")


def _recovery_unlock(workdir, tools, vm) -> tuple[bool, bool]:
    """Open a copy of the LUKS header with the recovery and a wrong passphrase.

    `--test-passphrase` is the supported way to ask a keyslot a question without
    creating a mapper device or needing root. The extract only has to include
    the primary header; cryptsetup reads the keyslot material from it.
    """
    root = vm.gpt.require_label("vngrd-root")
    header = extract(
        vm.disk, root.offset, min(root.size, 64 << 20), workdir / "root-header.img"
    )
    cryptsetup = tools.require("cryptsetup")

    def attempt(passphrase: str) -> bool:
        result = subprocess.run(
            [cryptsetup, "open", "--test-passphrase", "--key-file=-", str(header)],
            input=passphrase.encode(),
            capture_output=True,
        )
        return result.returncode == 0

    # Also prove this is still a LUKS2 container with a TPM2 token: the seal was
    # not destroyed by the clear, it simply cannot be satisfied by the new TPM.
    document = luks2.header_at(header, 0)
    if luks2.tpm2_token(document) is None:
        raise AssertionError("the root partition no longer carries a TPM2 token")

    return attempt(TEST_RECOVERY_PASSPHRASE), attempt("wrong-recovery-passphrase")


@boot_case(id="t0-tpm-clear", timeout=600)
def t0_tpm_clear(vm, tools, report):
    """A fresh TPM leaves the guards absent; the recovery keyslot still opens."""
    # Vm._prepare has already copied the provisioned TPM. Replacing it here is
    # the clear: no NV indices, a new SRK, and consequently no policy state.
    tpm.wipe(vm.tpm_dir)

    boot = vm.start(terminal=GUARD_LINES, stop_on_reset=False)
    text = normalise(boot.log_path.read_text(errors="replace"))

    boot.require("tpm.bound")
    boot.require("boot.usr-mounted")
    boot.require_absent("cryptsetup.start")
    boot.require_absent("boot.root-unsealed")
    boot.require_absent("boot.login-ready")

    report.require(
        "tpm-clear:guard-refused",
        any(line in text for line in GUARD_LINES),
        "no NV guard reported a refusal after the TPM state was replaced",
    )
    report.require(
        "tpm-clear:before-cryptsetup",
        "Starting Cryptography Setup for vngrd-root" not in text,
        "cryptsetup started even though every frozen NV register was absent",
    )
    report.require(
        "tpm-clear:no-passphrase-prompt",
        not RECOVERY_PROMPT.search(text),
        "the boot asked for the recovery passphrase instead of refusing before "
        "the volume key; the passphrase cannot restore the missing guards",
    )

    opens, wrong_opens = _recovery_unlock(vm.state, tools, vm)
    report.require(
        "tpm-clear:recovery-keyslot-still-opens",
        opens,
        "the recovery passphrase no longer opens the volume; the case would "
        "otherwise pass on a destroyed disk rather than a refusal",
    )
    report.require(
        "tpm-clear:wrong-passphrase-rejected",
        not wrong_opens,
        "a wrong passphrase opened the volume; the positive result above proves "
        "nothing",
    )

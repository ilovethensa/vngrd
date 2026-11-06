"""Tier 2: a mistyped recovery passphrase is retried, not accepted or fatal.

Provisioning is the one interactive step where a person can make a typo and the
machine has no second recovery path until that step completes. The helper must
therefore reject a mismatch, say so, and ask both entries again without
exiting; a first-boot typo that failed the unit would leave a machine with no
passphrase keyslot and no way to recover from a later TPM failure.

This case provisions a scratch machine with a deliberate mismatch. The normal
machine cache cannot express it because its console rules answer every
passphrase prompt the same way, so the test runs run-vm.sh once itself and
checks the resulting disk as well as the console transcript.
"""

from __future__ import annotations

import shutil

from harness import boot_case, luks2
from harness.console import NEW_PASSPHRASE_PROMPT, TEST_RECOVERY_PASSPHRASE
from harness.disk import Gpt
from harness.machine import provision_scratch
from harness.qemu import normalise


def _mismatch_then_match(console) -> None:
    # The first pair is deliberately different: the helper compares them and
    # retries. The next pair is the real passphrase. The last answer repeats
    # only if provisioning ever asks a fifth time, which would itself be a bug.
    console.watch_sequence(
        NEW_PASSPHRASE_PROMPT,
        [
            "vngrd-mismatch-one",
            "vngrd-mismatch-two",
            TEST_RECOVERY_PASSPHRASE,
            TEST_RECOVERY_PASSPHRASE,
        ],
    )


@boot_case(id="t0-provision-passphrase-retry", timeout=1200, needs_machine=False)
def t0_provision_passphrase_retry(session, report):
    """A mismatched first pair is retried and the machine is still provisioned."""
    machine = provision_scratch(session, "-passphrase-retry", _mismatch_then_match)
    try:
        log = machine.state / "provision.log"
        report.require("provision:log", log.is_file(), "provisioning produced no console log")
        text = normalise(log.read_text(errors="replace"))

        report.require(
            "passphrase:mismatch-reported",
            "vngrd-passphrase: the two entries do not match; try again (1/3)" in text,
            "the helper did not report the mismatch and retry",
        )
        report.require(
            "passphrase:retry-succeeded",
            "no acceptable passphrase after three attempts" not in text,
            "the retry did not recover to an accepted passphrase",
        )
        report.require(
            "provision:reached-login",
            "login:" in text,
            "first boot did not finish after the retry",
        )
        report.require(
            "provision:secrets-not-echoed",
            all(
                secret not in text
                for secret in (
                    "vngrd-mismatch-one",
                    "vngrd-mismatch-two",
                    TEST_RECOVERY_PASSPHRASE,
                )
            ),
            "a passphrase was echoed to the serial log; ask-password must disable echo",
        )

        gpt = Gpt.load(machine.disk)
        root = gpt.require_label("vngrd-root")
        document = luks2.header_at(machine.disk, root.offset)
        slots = document.get("keyslots", {})
        report.require(
            "provision:recovery-keyslot",
            len(slots) >= 2,
            "the retried boot wrote %d keyslot(s); the recovery passphrase keyslot "
            "is missing" % len(slots),
        )
        report.require(
            "provision:tpm2-token",
            luks2.tpm2_token(document) is not None,
            "the retried boot did not write the TPM2 token",
        )
    finally:
        if not session.options.keep:
            shutil.rmtree(machine.state, ignore_errors=True)

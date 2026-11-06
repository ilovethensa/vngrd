"""Tier 2: a dbx-like PCR 7 change is recoverable without re-provisioning.

The scenario is the one every Secure Boot update creates:

  1. the machine is provisioned and its root opens with the TPM2 PIN;
  2. a certificate is added to db (as a dbx update or a key enrolment would),
     which changes PCR 7;
  3. the old token no longer unseals, so the recovery passphrase opens the root;
  4. `vngrd-reseal.service` replaces the token against the current PCR 7;
  5. the next boot opens with the TPM again and needs no passphrase.

The marker is written from the booted guest rather than by editing the encrypted
root from the host. That is the same path an operator uses:
`touch /var/lib/vngrd/reseal-requested` and reboot.
"""

from __future__ import annotations

import base64
import hashlib
import re
import subprocess
import time
from pathlib import Path

from harness import boot_case, varstore
from harness.console import TEST_RECOVERY_PASSPHRASE
from harness.qemu import normalise

LOGIN_PROMPT = re.compile(r"login:\s*$", re.MULTILINE)
RECOVERY_PASSPHRASE_PROMPT = re.compile(r"Please enter passphrase for disk")
CURRENT_RECOVERY_PROMPT = re.compile(r"Please enter current recovery passphrase")
POWERED_OFF = re.compile(r"reboot: Power down|Power down|System halted", re.IGNORECASE)


def _root_shell(console) -> None:
    """Log in on the serial console and wait for the command to come back."""
    if not console.wait_for(LOGIN_PROMPT, 240):
        raise AssertionError("the first boot never reached a login prompt")
    console.type("root")
    # The root account is deliberately passwordless on the factory image (see
    # usr/share/factory/etc/pam.d/login). Do not type the first command until fish
    # has finished: it probes the terminal with DA/DSR queries, waits ten seconds
    # for a reply the harness does not send, and consumes anything typed during
    # that window. The welcome banner is printed after that probe, so it is the
    # point at which a line is actually read by the shell.
    if not console.wait_for(re.compile("Welcome to fish"), 120):
        raise AssertionError("root login did not start a shell")
    time.sleep(2)
    # A newline gives the prompt a fresh line after the terminal-compatibility
    # warning; then the command is echoed back once the shell is reading.
    console.type("")
    console.type("echo VNGRO_SHELL_READY")
    if not console.wait_for(re.compile("VNGRO_SHELL_READY"), 60):
        raise AssertionError("root login did not reach a shell")


def _power_off(console) -> None:
    console.type("sync")
    console.type("systemctl poweroff")
    if not console.wait_for(POWERED_OFF, 180):
        raise AssertionError("the guest did not power off")


def _request_reseal(console) -> None:
    """Log in on the serial console, write the marker, and power off."""
    _root_shell(console)
    console.type("touch /var/lib/vngrd/reseal-requested")
    _power_off(console)


def _undefine_fixate(console) -> None:
    """Delete only the fixate register from the running machine."""
    _root_shell(console)
    console.type("tpm2_nvundefine 0x01C00000")
    _power_off(console)


def _signed_dbx_auth(tools, policy, state: Path) -> Path:
    """Build a real signed dbx.auth, signed by the image's KEK.

    The image's Secure Boot key is also its KEK (run-vm.sh enrols the same
    certificate into PK, KEK and db, matching the published PK/KEK/db.auth), so
    sbvarsign produces exactly the authenticated update a dbx payload would
    carry. The revoked entry is a
    deterministic hash of a string that is not an EFI binary: this test is about
    the update path and PCR 7, not about blocking a particular loader.
    """
    key = Path(policy.secureboot_key)
    cert = Path(policy.secureboot_cert)
    if not key.is_file() or not cert.is_file():
        from harness import skip

        skip("the local Secure Boot signing key/certificate are unavailable")

    revoked = state / "dbx-revoked.bin"
    esl = state / "dbx.esl"
    auth = state / "dbx.auth"
    revoked.write_bytes(hashlib.sha256(b"vngrd-test-dbx-entry").digest())

    subprocess.run(
        [
            tools.require("sbsiglist"),
            "--owner",
            "11111111-2222-3333-4444-555555555555",
            "--type",
            "sha256",
            "--output",
            str(esl),
            str(revoked),
        ],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        [
            tools.require("sbvarsign"),
            "--key",
            str(key),
            "--cert",
            str(cert),
            "--attr",
            "NON_VOLATILE,BOOTSERVICE_ACCESS,RUNTIME_ACCESS,APPEND_WRITE",
            "--output",
            str(auth),
            "dbx",
            str(esl),
        ],
        check=True,
        capture_output=True,
    )
    if not auth.is_file() or auth.stat().st_size == 0:
        raise AssertionError("sbvarsign produced no dbx.auth")
    return auth


def _install_and_apply_dbx(console, auth: Path) -> None:
    """Type the signed file into the guest and let the image's tool apply it.

    The console is the only bidirectional channel the harness has to a running
    guest, and the file is small (about 1.3 KB of auth plus the ESL). It is
    base64ed in chunks so no single serial line can hit the canonical-input
    limit, and each chunk is acknowledged before the next is sent.
    """
    encoded = base64.b64encode(auth.read_bytes()).decode("ascii")
    for number, offset in enumerate(range(0, len(encoded), 400), start=1):
        chunk = encoded[offset : offset + 400]
        marker = "VNGRO_DBX_CHUNK_%d" % number
        operator = ">" if number == 1 else ">>"
        console.type("printf '%%s' '%s' %s /tmp/dbx.b64; echo %s" % (chunk, operator, marker))
        if not console.wait_for(re.compile(marker), 60):
            raise AssertionError("the guest did not acknowledge dbx chunk %d" % number)

    console.type("base64 -d /tmp/dbx.b64 > /tmp/dbx.auth; echo VNGRO_DBX_READY $status")
    if not console.wait_for(re.compile(r"VNGRO_DBX_READY 0"), 60):
        raise AssertionError("base64 did not decode the auth file (see the serial log)")
    console.type("echo VNGRO_DBX_SIZE (stat -c %s /tmp/dbx.auth)")
    if not console.wait_for(re.compile(r"VNGRO_DBX_SIZE %d\b" % auth.stat().st_size), 60):
        raise AssertionError("the auth file in the guest is not the size of the signed file")

    # No --no-reboot: the tool's default is the operator path this case exists
    # to prove. It prints the success line after the marker is fsynced and then
    # calls reboot(); QEMU reports the reset and Vm.start returns on it.
    console.type("/usr/lib/vngrd/vngrd-secureboot-update /tmp/dbx.auth")
    if not console.wait_for(
        re.compile(r"dbx updated and /var/lib/vngrd/reseal-requested created"), 60
    ):
        raise AssertionError(
            "vngrd-secureboot-update failed; the serial log has its diagnose output"
        )


def _apply_dbx(console, auth: Path) -> None:
    _root_shell(console)
    _install_and_apply_dbx(console, auth)


@boot_case(id="t0-secureboot-update", timeout=1500)
def t0_secureboot_update(vm, tools, policy, report):
    """A signed dbx update is applied, marked, and resealed on the next boot."""
    auth = _signed_dbx_auth(tools, policy, vm.state)

    first = vm.start(interact=lambda console: _apply_dbx(console, auth))
    first_text = normalise(first.log_path.read_text(errors="replace"))
    report.require(
        "dbx-update-applied",
        "vngrd-secureboot-update: dbx updated and /var/lib/vngrd/reseal-requested created"
        in first_text,
        "the guest did not report the signed dbx update and the marker",
    )
    report.require(
        "dbx-update-rebooted",
        first.exit_reason == "reset",
        "the tool must reboot after creating the marker; boot ended with %r"
        % first.exit_reason,
    )

    # The dbx append moved PCR 7. The old token must fail, the recovery
    # passphrase must open the root, and vngrd-reseal must replace the token.
    second = vm.start(
        watch=(
            (RECOVERY_PASSPHRASE_PROMPT, TEST_RECOVERY_PASSPHRASE),
            (CURRENT_RECOVERY_PROMPT, TEST_RECOVERY_PASSPHRASE),
        )
    )
    second.require("tpm.bound")
    second.require("boot.root-unsealed")
    second.require("boot.login-ready")
    second_text = normalise(second.log_path.read_text(errors="replace"))
    report.require(
        "dbx-change-forces-recovery",
        "Please enter passphrase for disk" in second_text,
        "a real dbx update must make the old PCR 7 token fail",
    )
    report.require(
        "dbx-reseal-completed",
        "reseal complete" in second_text,
        "vngrd-reseal.service must replace the token after the dbx update",
    )

    third = vm.start()
    third.require("tpm.bound")
    third.require("boot.root-unsealed")
    third.require("boot.login-ready")
    third_text = normalise(third.log_path.read_text(errors="replace"))
    report.require(
        "dbx-resealed-token-works",
        "Please enter passphrase for disk" not in third_text,
        "the replacement token must unseal without the recovery passphrase",
    )


@boot_case(id="t0-reseal", timeout=1200)
def t0_reseal(vm, tools, report):
    """Recover from a PCR 7 change, then prove the TPM works again."""
    # Boot 1: establish the marker through the same interface an operator uses.
    first = vm.start(interact=_request_reseal)
    report.require(
        "first-boot.shell",
        "VNGRO_SHELL_READY" in normalise(first.log_path.read_text(errors="replace")),
        "root login on the first boot did not reach a shell",
    )

    # Change PCR 7 exactly as a dbx update would: a certificate added to db.
    der = varstore.self_signed_certificate(tools, vm.state, "vngrd-reseal-dbx")
    try:
        varstore.add_db_certificate(tools, vm.varstore, der)
    except Exception as exc:  # noqa: BLE001 - varstore editing is a capability
        from harness import skip

        skip("cannot edit the OVMF variable store: %s" % exc)

    # Boot 2: the old token fails, the recovery passphrase opens the root, and
    # the reseal unit asks for that passphrase once more to obtain the volume
    # key for the replacement token. The default PIN watcher answers the new PIN.
    second = vm.start(
        watch=(
            (RECOVERY_PASSPHRASE_PROMPT, TEST_RECOVERY_PASSPHRASE),
            (CURRENT_RECOVERY_PROMPT, TEST_RECOVERY_PASSPHRASE),
        )
    )
    second.require("tpm.bound")
    second.require("boot.root-unsealed")
    second.require("boot.login-ready")

    second_text = normalise(second.log_path.read_text(errors="replace"))
    report.require(
        "reseal-recovery-unlock",
        "Please enter passphrase for disk" in second_text,
        "the changed PCR 7 must force the recovery passphrase, not the old token",
    )
    report.require(
        "reseal-completed",
        "reseal complete" in second_text,
        "vngrd-reseal.service must report that it replaced the token",
    )

    # Boot 3: no watcher for the passphrase. The replacement token must open the
    # volume by itself, or the reseal only moved the prompt one boot later.
    third = vm.start()
    third.require("tpm.bound")
    third.require("boot.root-unsealed")
    third.require("boot.login-ready")

    third_text = normalise(third.log_path.read_text(errors="replace"))
    report.require(
        "reseal-token-works",
        "Please enter passphrase for disk" not in third_text,
        "the resealed token must unseal without the recovery passphrase",
    )
    report.require(
        "reseal-no-repeat",
        "Please enter current recovery passphrase" not in third_text,
        "the reseal marker must be gone, so a third boot must not reseal again",
    )


@boot_case(id="t0-fixate-undefine", timeout=600)
def t0_fixate_undefine(vm, report):
    """Deleting only the fixate register must refuse the next boot.

    The generator cannot fail a boot by exiting non-zero, so without the guard
    this is the one deletion that silently removes a check while the GPT, ESP and
    rollback guards all still pass. The guard runs before cryptsetup, so the
    assertion is not merely "the login prompt did not appear": the volume key must
    never have been requested.
    """
    first = vm.start(interact=_undefine_fixate)
    report.require(
        "first-boot.shell",
        "VNGRO_SHELL_READY" in normalise(first.log_path.read_text(errors="replace")),
        "root login on the first boot did not reach a shell",
    )

    # FailureAction=reboot-force would reset a real machine here. The harness
    # stops at the diagnostic instead, which is the evidence the guard, not a
    # later failure, is what refused the boot.
    second = vm.start(terminal=("fixate digest in NV is absent",), stop_on_reset=False)
    second.require("tpm.bound")
    second.require_absent("cryptsetup.start")
    second.require_absent("boot.root-unsealed")
    second.require_absent("boot.login-ready")

    text = normalise(second.log_path.read_text(errors="replace"))
    report.require(
        "fixate-guard-refused",
        "fixate digest in NV is absent" in text,
        "vngrd-fixate-guard must name the missing register rather than skip the check",
    )

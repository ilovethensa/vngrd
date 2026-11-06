"""Tier 2: the host replaces a signed loader with the verified /usr loader.

The ESP identity digest deliberately excludes ``EFI/systemd``, ``EFI/BOOT`` and
``EFI/Linux``: Secure Boot is the control for those paths, and the loader is
expected to change on update.  What is not automatic is that the copy on the ESP
matches the one in the verified image.  A newer image carries a new signed
sd-boot in /usr; the old ESP copy would otherwise remain until someone copied it.
``vngrd-bootloader-sync.service`` is that someone.

The case plants a *different signed* EFI application (the image's own UKI) at
both sd-boot paths, so the firmware still accepts the boot: this is an update,
not a garbage write.  The host then runs the real unit at boot-complete, and the
guest checks that both paths read back as the verified sd-boot.  A second boot
proves the restored sd-boot is accepted by the firmware and that the seal still
opens with the TPM alone.

The replacement is planted from the host, before the boot, through the same ESP
image the harness uses elsewhere.  The guest is not asked to copy a 29 MiB file
over a serial line, and the boot that follows is exactly the firmware path a
real loader update would take.

The case also answers the PCR 4 question.  Boot 1 loads the UKI where sd-boot
normally sits; boots 2 and 3 load the restored sd-boot.  The guest reads PCR 4
from its own TPM each time.  Equal values on 2 and 3 say PCR 4 is stable across
identical boots; a different value on 1 says it moves with the loader, which is
why it is not in the seal.
"""

from __future__ import annotations

import hashlib
import re
import time

from harness import boot_case
from harness.console import TEST_RECOVERY_PASSPHRASE
from harness.disk import replace_region
from harness.qemu import normalise

LOGIN_PROMPT = re.compile(r"login:\s*$", re.MULTILINE)
POWERED_OFF = re.compile(r"reboot: Power down|Power down|System halted", re.IGNORECASE)
RECOVERY_PASSPHRASE_PROMPT = re.compile(r"Please enter passphrase for disk")
PCR4 = re.compile(r"VNGRO_PCR4 ([0-9a-f]{64})")
RECOVERY_OR_LOGIN = re.compile(r"Please enter passphrase for disk|login:\s*$", re.MULTILINE)
LOADERS = (
    "EFI/systemd/systemd-bootx64.efi",
    "EFI/BOOT/BOOTX64.EFI",
)


def _digest(path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _plant_signed_uki_as_loader(vm):
    """Replace both sd-boot copies with the image's signed UKI.

    The UKI is a valid Secure Boot application and is already trusted by the
    firmware, so this is the "old, still signed loader" shape rather than a
    signature failure.  It is also much larger than sd-boot, which makes the
    read-back comparison unambiguous.
    """
    esp = vm.esp()
    original = esp.get("EFI/BOOT/BOOTX64.EFI", vm.state / "original-loader.efi")
    original_digest = _digest(original)

    uki_remote = esp.uki_path()
    uki = esp.get(uki_remote, vm.state / "replacement-loader.efi")
    uki_digest = _digest(uki)
    if uki_digest == original_digest:
        raise AssertionError("the planted loader and sd-boot are the same bytes")

    for remote in LOADERS:
        esp.put(uki, remote)
    replace_region(vm.disk, vm.gpt.esp().offset, esp.path)

    # Prove the disk the VM will boot really carries the UKI at both paths.  A
    # plant into the extracted image and a forgotten write-back is the classic
    # false pass for this kind of case.
    planted = vm.esp()
    for index, remote in enumerate(LOADERS):
        got = planted.get(remote, vm.state / ("planted-%d.efi" % index))
        if _digest(got) != uki_digest:
            raise AssertionError("%s does not carry the planted UKI" % remote)

    return original_digest, uki_digest


def _root_shell(console) -> None:
    if not console.wait_for(LOGIN_PROMPT, 240):
        raise AssertionError("the loader-update boot never reached a login prompt")
    console.type("root")
    if not console.wait_for(re.compile("Welcome to fish"), 120):
        raise AssertionError("root login did not start a shell")
    time.sleep(2)
    console.type("")
    console.type("echo VNGRO_SHELL_READY")
    if not console.wait_for(re.compile("VNGRO_SHELL_READY"), 60):
        raise AssertionError("root login did not reach a shell")


def _sha256(console, path: str, marker: str) -> str:
    console.type("sha256sum %s; echo %s $status" % (path, marker))
    status = re.compile(r"%s (\d+)" % re.escape(marker))
    if not console.wait_for(status, 60):
        raise AssertionError("sha256sum %s produced no status line" % path)
    match = re.search(r"([0-9a-f]{64})\s+%s" % re.escape(path), console.tail())
    if match is None:
        raise AssertionError("sha256sum %s produced no digest" % path)
    return match.group(1)


def _pcr4(console, seen: dict) -> None:
    """Read PCR 4 through the running guest's TPM, not the host's swtpm.

    `pcrread -o` writes the raw digest, which `od` turns into the same hex the
    serial log can carry.  The command output is deliberately a fixed marker so
    a case can pull the value out without parsing tpm2-tools' table format.
    """
    console.type(
        "tpm2 pcrread -o /tmp/pcr4.bin sha256:4 >/dev/null; "
        "echo VNGRO_PCR4 (od -An -v -tx1 /tmp/pcr4.bin | tr -d '[:space:]')"
    )
    if not console.wait_for(PCR4, 60):
        raise AssertionError("tpm2 pcrread sha256:4 produced no digest")
    seen["pcr4"] = PCR4.search(console.tail()).group(1)


def _read_pcr4_and_poweroff(console, seen: dict) -> None:
    _root_shell(console)
    _pcr4(console, seen)
    console.type("sync")
    console.type("systemctl poweroff")
    if not console.wait_for(POWERED_OFF, 180):
        raise AssertionError("the guest did not power off after reading PCR 4")


def _first_boot(console, seen: dict) -> None:
    """Answer the recovery prompt if the planted loader changed the PCR 11 phase.

    A watcher would also work, but this boot is the one case where the branch
    depends on the UKI's phase: a fixed sleep after a prompt that may not come
    is either a lost passphrase or a wasted timeout. Waiting for the prompt or
    the login prompt makes the branch explicit. The PIN prompts are still the
    console's built-in rule.
    """
    if console.wait_for(RECOVERY_OR_LOGIN, 300):
        if RECOVERY_PASSPHRASE_PROMPT.search(console.tail()):
            time.sleep(0.5)
            console.type(TEST_RECOVERY_PASSPHRASE)
    _verify_sync(console, seen)


def _verify_sync(console, seen: dict) -> None:
    """Log in after boot-complete, check the ESP, and power off cleanly."""
    _root_shell(console)

    _pcr4(console, seen)

    console.type(
        "systemctl show -p ActiveState -p Result -p ExecMainStatus "
        "vngrd-bootloader-sync; echo VNGRO_SYNC_STATUS $status"
    )
    marker = re.compile(r"VNGRO_SYNC_STATUS (\d+)")
    if not console.wait_for(marker, 60):
        raise AssertionError("systemctl show produced no status line")
    seen["sync_show"] = console.tail()
    seen["sync_status"] = int(marker.search(seen["sync_show"]).group(1))

    seen["source_hash"] = _sha256(
        console,
        "/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed",
        "VNGRO_HASH_SOURCE",
    )
    seen["systemd_hash"] = _sha256(
        console,
        "/efi/EFI/systemd/systemd-bootx64.efi",
        "VNGRO_HASH_SYSTEMD",
    )
    seen["boot_hash"] = _sha256(
        console,
        "/efi/EFI/BOOT/BOOTX64.EFI",
        "VNGRO_HASH_BOOT",
    )

    console.type("sync")
    console.type("systemctl poweroff")
    if not console.wait_for(POWERED_OFF, 180):
        raise AssertionError("the guest did not power off after the check")


@boot_case(id="t0-bootloader-sync", timeout=900)
def t0_bootloader_sync(vm, report):
    """A signed replacement loader is accepted, then replaced by verified /usr."""
    original_digest, uki_digest = _plant_signed_uki_as_loader(vm)

    # The replacement is signed, so the firmware runs it.  The recovery
    # passphrase is allowed here only because loading the UKI directly can
    # change the PCR 11 phase sd-boot would otherwise establish; the boot must
    # still reach userspace and let the host sync run.  The second boot, with
    # sd-boot restored, must not need the passphrase.
    seen: dict = {}
    first = vm.start(interact=lambda console: _first_boot(console, seen))
    first_text = normalise(first.log_path.read_text(errors="replace"))
    first.require("boot.usr-mounted")
    first.require("boot.root-unsealed")
    first.require_absent("boot.emergency")
    report.require(
        "sync:first-boot-no-esp-refusal",
        "vngrd-esp-guard:" not in first_text,
        "the ESP guard refused a loader update even though loader paths are excluded "
        "from its digest; the guard is over-covering the update path",
    )

    report.require(
        "sync:guest-shell",
        "VNGRO_SHELL_READY" in first_text,
        "the boot carrying a different loader did not reach a root shell",
    )
    report.require(
        "sync:unit-active",
        seen.get("sync_status") == 0
        and "ActiveState=active" in seen.get("sync_show", "")
        and "Result=success" in seen.get("sync_show", "")
        and "ExecMainStatus=0" in seen.get("sync_show", ""),
        "vngrd-bootloader-sync did not report a successful active state: %r"
        % (seen.get("sync_show", "")[-500:],),
    )
    report.require(
        "sync:source-is-build-loader",
        seen.get("source_hash") == original_digest,
        "the verified sd-boot in /usr is not the loader the image installed "
        "(source %s, installed %s)" % (seen.get("source_hash"), original_digest),
    )
    report.require(
        "sync:systemd-loader-restored",
        seen.get("systemd_hash") == original_digest,
        "EFI/systemd/systemd-bootx64.efi is not the verified sd-boot (got %s, "
        "expected %s)" % (seen.get("systemd_hash"), original_digest),
    )
    report.require(
        "sync:fallback-loader-restored",
        seen.get("boot_hash") == original_digest,
        "EFI/BOOT/BOOTX64.EFI is not the verified sd-boot (got %s, expected %s)"
        % (seen.get("boot_hash"), original_digest),
    )
    report.require(
        "sync:replaced-with-sd-boot",
        original_digest != uki_digest,
        "the planted UKI and sd-boot must differ for this case to prove anything",
    )
    report.require(
        "sync:first-boot-no-failure",
        "Failed to start vngrd-bootloader-sync.service" not in first_text,
        "vngrd-bootloader-sync failed; the serial log has its read-back diagnostic",
    )

    # Boot 2 uses the restored sd-boot.  Reaching the root without the recovery
    # passphrase is the proof that the firmware accepted the new bytes and that
    # the TPM seal still describes this boot.  It also measures PCR 4: boot 1
    # loaded the UKI where sd-boot normally sits, so a PCR 4 that is stable
    # across loaders would show the same value here.
    second_seen: dict = {}
    second = vm.start(interact=lambda console: _read_pcr4_and_poweroff(console, second_seen))
    second.require("tpm.bound")
    second.require("boot.root-unsealed")
    second.require("boot.multi-user")
    second.require_absent("boot.emergency")
    second_text = normalise(second.log_path.read_text(errors="replace"))
    report.require(
        "sync:second-boot-restored-loader",
        "Finished vngrd-bootloader-sync.service" in second_text,
        "the restored sd-boot booted but the host sync did not finish",
    )
    report.require(
        "sync:second-boot-no-passphrase",
        "Please enter passphrase for disk" not in second_text,
        "the restored loader boot still needed the recovery passphrase",
    )
    report.require(
        "sync:second-boot-no-esp-refusal",
        "vngrd-esp-guard:" not in second_text,
        "the ESP guard refused the restored loader",
    )

    # Boot 3 is the same sd-boot again.  Two identical boots are the control
    # for the PCR 4 measurement: if the value moves on its own, it cannot be
    # added to the seal.  Boots 1 and 2 are the treatment: a different signed
    # loader must move it.  The case records the result rather than assuming
    # either answer; TASKS/PLAN use the measured values.
    third_seen: dict = {}
    third = vm.start(interact=lambda console: _read_pcr4_and_poweroff(console, third_seen))
    third.require("tpm.bound")
    third.require("boot.root-unsealed")
    third.require("boot.multi-user")
    third_text = normalise(third.log_path.read_text(errors="replace"))
    report.require(
        "sync:third-boot-no-passphrase",
        "Please enter passphrase for disk" not in third_text,
        "the repeated restored-loader boot needed the recovery passphrase",
    )

    values = [seen.get("pcr4"), second_seen.get("pcr4"), third_seen.get("pcr4")]
    report.require(
        "pcr4:measured",
        all(value is not None and re.fullmatch(r"[0-9a-f]{64}", value) for value in values),
        "PCR 4 was not read on all three boots: %r" % (values,),
    )
    report.require(
        "pcr4:moves-with-loader",
        values[0] != values[1],
        "PCR 4 did not change when the firmware loaded a different signed EFI "
        "application (UKI loader %s, sd-boot %s)" % (values[0], values[1]),
    )
    report.require(
        "pcr4:stable-across-identical-boots",
        values[1] == values[2],
        "PCR 4 changed between two boots of the same sd-boot (%s then %s); it "
        "cannot be added to the seal" % (values[1], values[2]),
    )

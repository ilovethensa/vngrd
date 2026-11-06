"""Tier 2: an image below the committed rollback floor is refused before unseal.

The guard's decision has two inputs: the running image's IMAGE_VERSION and the
monotonic counter in TPM NV. There is no positive version below this image's
index, so the test creates the exact condition a newer image would have created:
it runs the image's own vngrd-rollback-commit against a synthetic os-release
whose version is the next one after the running image. That is the same write the
host commit performs after a newer image's boot-complete. The same disk is then
an "old image" relative to the floor, and the next boot must stop at
vngrd-rollback-guard before systemd-cryptsetup can ask the TPM for the root key.

This is deliberately not a second image build. What matters for the control is
the pair (running index, floor); building another UKI would exercise mkosi and
the signing path, not the guard, and it would still have to move the counter to
make the running version lower than the floor. Using the real commit binary also
keeps the test on the authority path: the counter is OWNERWRITE, and the host
already holds that authority, so the test cannot pass by writing a register a
real image could not write.
"""

from __future__ import annotations

import re
import time

from harness import boot_case
from harness.qemu import normalise

LOGIN_PROMPT = re.compile(r"login:\s*$", re.MULTILINE)
POWERED_OFF = re.compile(r"reboot: Power down|Power down|System halted", re.IGNORECASE)
INCREMENT_STATUS = re.compile(r"VNGRO_INCREMENT_STATUS (\d+)")


def _root_shell(console) -> None:
    if not console.wait_for(LOGIN_PROMPT, 240):
        raise AssertionError("the first boot never reached a login prompt")
    console.type("root")
    if not console.wait_for(re.compile("Welcome to fish"), 120):
        raise AssertionError("root login did not start a shell")
    time.sleep(2)
    console.type("")
    console.type("echo VNGRO_SHELL_READY")
    if not console.wait_for(re.compile("VNGRO_SHELL_READY"), 60):
        raise AssertionError("root login did not reach a shell")


def _newer_version(version: str) -> str:
    """The next version in the encoding rollback.c accepts.

    Tests should not hardcode 0.2: the image version is a build input, and a
    future 0.2 build would make a literal 0.2 floor a no-op instead of a
    downgrade. Increment the smallest component, carrying into the next one.
    """
    parts = [int(part) for part in version.split(".")][:3]
    while len(parts) < 3:
        parts.append(0)
    major, minor, patch = parts
    patch += 1
    if patch > 9:
        patch = 0
        minor += 1
    if minor > 9:
        minor = 0
        major += 1
    return "%d.%d" % (major, minor) if patch == 0 else "%d.%d.%d" % (major, minor, patch)


def _raise_floor(console, newer: str) -> None:
    """Commit a floor for a newer image, then power off cleanly.

    The running host can move the counter only upwards, and the real host commit
    is the program that does it. Pointing it at a temporary os-release with the
    next version is what that newer image's boot-complete would have written;
    nothing about the counter write is mocked.
    """
    _root_shell(console)
    console.type("echo IMAGE_VERSION=%s > /tmp/vngrd-newer-os-release" % newer)
    console.type(
        "/usr/lib/vngrd/vngrd-rollback-commit /tmp/vngrd-newer-os-release; "
        "echo VNGRO_INCREMENT_STATUS $status"
    )
    if not console.wait_for(INCREMENT_STATUS, 60):
        raise AssertionError("vngrd-rollback-commit produced no status line")
    console.type("sync")
    console.type("systemctl poweroff")
    if not console.wait_for(POWERED_OFF, 180):
        raise AssertionError("the guest did not power off")


def _rollback_index(version: str) -> int:
    """The same packing rollback_index_from_version() uses for the test image."""
    parts = [int(part) for part in version.split(".")][:3]
    while len(parts) < 3:
        parts.append(0)
    major, minor, patch = parts
    if minor > 9 or patch > 9:
        raise AssertionError("test image version %r is not a valid rollback encoding" % version)
    return major * 100 + minor * 10 + patch


def _status(console, command: str, marker: str, timeout: int = 60) -> int:
    console.type("%s; echo %s $status" % (command, marker))
    pattern = re.compile(r"%s (\d+)" % re.escape(marker))
    if not console.wait_for(pattern, timeout):
        raise AssertionError("%s produced no status line" % command)
    match = pattern.search(console.tail())
    return int(match.group(1))


def _read_counter(console) -> str:
    status = _status(
        console,
        "tpm2_nvread -C o -o /tmp/rollback.bin -s 8 0x01C00001",
        "VNGRO_NVREAD",
    )
    if status != 0:
        raise AssertionError("tpm2_nvread could not read the rollback counter")
    console.type("echo VNGRO_COUNTER (od -An -v -tx1 /tmp/rollback.bin | tr -d '[:space:]')")
    pattern = re.compile(r"VNGRO_COUNTER ([0-9a-f]{16})")
    if not console.wait_for(pattern, 60):
        raise AssertionError("the rollback counter did not print as eight bytes")
    return pattern.search(console.tail()).group(1)


def _rollback_matrix(console, expected: str, seen: dict) -> None:
    """Read, no-op commit, undefine, refuse-to-recreate, then power off."""
    _root_shell(console)
    seen["before"] = _read_counter(console)

    seen["commit_status"] = _status(
        console,
        "/usr/lib/vngrd/vngrd-rollback-commit /usr/lib/os-release",
        "VNGRO_COMMIT_SAME",
    )
    seen["after"] = _read_counter(console)

    seen["undefine_status"] = _status(
        console,
        "tpm2_nvundefine 0x01C00001",
        "VNGRO_UNDEFINE",
    )
    if seen["undefine_status"] != 0:
        raise AssertionError("tpm2_nvundefine could not remove the rollback counter")

    seen["absent_status"] = _status(
        console,
        "tpm2_nvread -C o -o /tmp/rollback-absent.bin -s 8 0x01C00001 >/dev/null 2>&1",
        "VNGRO_NVREAD_ABSENT",
    )
    seen["commit_absent_status"] = _status(
        console,
        "/usr/lib/vngrd/vngrd-rollback-commit /usr/lib/os-release",
        "VNGRO_COMMIT_ABSENT",
    )
    seen["absent_after_commit"] = _status(
        console,
        "tpm2_nvread -C o -o /tmp/rollback-absent2.bin -s 8 0x01C00001 >/dev/null 2>&1",
        "VNGRO_NVREAD_STILL_ABSENT",
    )

    console.type("sync")
    console.type("systemctl poweroff")
    if not console.wait_for(POWERED_OFF, 180):
        raise AssertionError("the guest did not power off")


@boot_case(id="t0-rollback-matrix", timeout=900)
def t0_rollback_matrix(vm, policy, report):
    """The counter is created, no-ops, refuses recreation, and is not re-armed."""
    expected = "%016x" % _rollback_index(policy.version)
    seen: dict = {}
    first = vm.start(interact=lambda console: _rollback_matrix(console, expected, seen))
    first_text = normalise(first.log_path.read_text(errors="replace"))

    report.require(
        "counter:created-at-image-index",
        seen.get("before") == expected,
        "first boot left counter %s, expected the image index %s"
        % (seen.get("before"), expected),
    )
    report.require(
        "counter:same-version-commit",
        seen.get("commit_status") == 0,
        "a normal host commit of the same version failed (status=%r)"
        % (seen.get("commit_status"),),
    )
    report.require(
        "counter:same-version-noop",
        seen.get("after") == expected,
        "a same-version commit changed the counter from %s to %s"
        % (expected, seen.get("after")),
    )
    report.require(
        "counter:deleted",
        seen.get("absent_status") not in (0, None),
        "tpm2_nvread still read the counter after undefine",
    )
    report.require(
        "counter:commit-refused-absent",
        seen.get("commit_absent_status") not in (0, None),
        "vngrd-rollback-commit succeeded with no counter; it must only define "
        "one on the provisioning boot",
    )
    report.require(
        "counter:commit-does-not-re-arm",
        seen.get("absent_after_commit") not in (0, None),
        "the failed commit recreated the counter; undefine would become a "
        "silent downgrade",
    )
    report.require(
        "counter:absent-diagnostic",
        "is absent, so this machine has no committed floor" in first_text,
        "the host commit must say why it refused instead of failing generically",
    )

    second = vm.start(terminal=("vngrd-rollback-guard:",), stop_on_reset=False)
    second.require("tpm.bound")
    second.require("boot.usr-mounted")
    second.require("rollback.refused")
    second.require_absent("cryptsetup.start")
    second.require_absent("boot.root-unsealed")
    second.require_absent("boot.login-ready")

    text = normalise(second.log_path.read_text(errors="replace"))
    report.require(
        "counter:absent-refuses-boot",
        "The rollback floor was deleted." in text,
        "a provisioned machine with no counter must fail closed, not boot with "
        "an unenforced anti-rollback check",
    )
    report.require(
        "counter:absent-before-cryptsetup",
        "Starting Cryptography Setup for vngrd-root" not in text,
        "the missing counter was detected only after the root key was requested",
    )


@boot_case(id="t0-rollback-old-image", timeout=600)
def t0_rollback_old_image(vm, policy, report):
    """A running image below the floor is refused before the root key is released."""
    newer = _newer_version(policy.version)
    first = vm.start(interact=lambda console: _raise_floor(console, newer))
    first_text = normalise(first.log_path.read_text(errors="replace"))
    match = INCREMENT_STATUS.search(first_text)
    report.require(
        "floor-committed",
        match is not None and match.group(1) == "0",
        "vngrd-rollback-commit did not succeed for %s, so the next boot would "
        "not be below the floor (status=%s)"
        % (newer, match.group(1) if match else "missing"),
    )

    # FailureAction=reboot-force would reset a real machine. The harness stops at
    # the guard's own diagnostic, which is the evidence that the refusal is the
    # rollback check and not a later cryptsetup failure.
    second = vm.start(terminal=("vngrd-rollback-guard:",), stop_on_reset=False)
    second.require("tpm.bound")
    second.require("boot.usr-mounted")
    second.require("rollback.refused")
    second.require_absent("cryptsetup.start")
    second.require_absent("boot.root-unsealed")
    second.require_absent("boot.login-ready")

    text = normalise(second.log_path.read_text(errors="replace"))
    report.require(
        "rollback-floor-message",
        "this image is rollback index" in text and "the floor is" in text,
        "the guard must name the running index and the floor; otherwise a refusal "
        "with no values could be any initrd failure",
    )
    report.require(
        "rollback-before-cryptsetup",
        "Starting Cryptography Setup for vngrd-root" not in text,
        "the root volume key was requested before the rollback check completed",
    )

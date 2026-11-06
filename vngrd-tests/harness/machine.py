"""The provisioned machine that every seal-related case boots.

Provisioning is expensive (Secure Boot enrolment plus repart creating the
encrypted root), so it happens once and is cached. The cache key is the image's
content identity plus the security policy: a rebuild or a policy change
re-provisions, and there is no mtime-only heuristic that a rebuild can slip
past.

The provisioning boot itself is delegated to the image's own run-vm.sh. That is
deliberate: enrolment and first boot are a build-like step, and the part this
suite replaces is the *observation* of a boot, not the firmware plumbing.
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from . import tpm
from .console import NEW_PASSPHRASE_PROMPT, PIN_PROMPT, TEST_PIN, TEST_RECOVERY_PASSPHRASE, SerialConsole
from .errors import ConfigError, SkipTest
from .image import ImageArtifact
from .policy import Policy

TERMINAL = re.compile(
    r"login:\s*$|You are in emergency mode\.|No such device|TPM device not found",
    re.MULTILINE,
)
TPM_BOUND = re.compile(r"tpm_tis MSFT|tpm_tis_core|tpm_crb|tpmrm0")


@dataclass
class Machine:
    disk: Path
    varstore: Path
    tpm: Path
    state: Path
    identity: str
    _session: object = None

    @classmethod
    def provision(cls, session) -> "Machine":
        tools = session.tools
        if not tools.qemu:
            raise SkipTest("qemu-system-x86_64 not found; cannot provision a machine")
        image = session.image()
        policy: Policy = session.policy

        machine_dir = session.state / "machine"
        identity = _identity(image, policy)
        id_file = machine_dir / "identity"

        if not session.options.provision and _is_reusable(machine_dir, id_file, identity):
            from . import log

            log.note("reusing the provisioned machine at %s" % machine_dir)
            return cls(
                disk=machine_dir / "disk.raw",
                varstore=machine_dir / "OVMF_VARS.fd",
                tpm=machine_dir / "tpm",
                state=machine_dir,
                identity=identity,
                _session=session,
            )

        if machine_dir.exists():
            shutil.rmtree(machine_dir)
        machine_dir.mkdir(parents=True, exist_ok=True)
        # _provision snapshots the machine itself: it flattens the overlay to
        # disk.raw, copies the enrolled varstore and seeds tpm/.
        _provision(session, image, machine_dir)
        for required in (machine_dir / "disk.raw", machine_dir / "OVMF_VARS.fd", machine_dir / "tpm"):
            if not required.exists():
                raise ConfigError("provisioning produced no %s" % required.name)
        id_file.write_text(identity + "\n")
        return cls(
            disk=machine_dir / "disk.raw",
            varstore=machine_dir / "OVMF_VARS.fd",
            tpm=machine_dir / "tpm",
            state=machine_dir,
            identity=identity,
            _session=session,
        )

    def cleanup(self) -> None:
        pass


def _identity(image: ImageArtifact, policy: Policy) -> str:
    raw = image.raw
    stat = raw.stat()
    return " ".join(
        [
            image.roothash,
            str(stat.st_size),
            str(stat.st_mtime_ns),
            policy.pcr_mask_text,
            ",".join(policy.phases),
            "sb" if policy.secureboot else "nosb",
        ]
    )


def _is_reusable(machine_dir: Path, id_file: Path, identity: str) -> bool:
    if not id_file.is_file() or id_file.read_text().strip() != identity:
        return False
    if not (machine_dir / "disk.raw").is_file():
        return False
    if not (machine_dir / "OVMF_VARS.fd").is_file():
        return False
    return any((machine_dir / "tpm").glob("*.permall"))


def provision_scratch(
    session,
    suffix: str,
    console_setup: Callable[[SerialConsole], None] | None = None,
) -> "Machine":
    """Provision a disposable machine with a case-supplied prompt handler.

    The normal provisioning path is cached because it is expensive. A case that
    has to vary an interaction (the passphrase mismatch retry) cannot use that
    cache, so this runs the same run-vm.sh boot into a separate state suffix and
    returns the flattened machine. The caller owns cleanup.
    """
    image = session.image()
    machine_dir = session.state / ("scratch" + suffix)
    if machine_dir.exists():
        shutil.rmtree(machine_dir)
    machine_dir.mkdir(parents=True, exist_ok=True)
    run_state = _provision(
        session,
        image,
        machine_dir,
        suffix=suffix,
        console_setup=console_setup,
    )
    if not session.options.keep:
        shutil.rmtree(run_state, ignore_errors=True)
    return Machine(
        disk=machine_dir / "disk.raw",
        varstore=machine_dir / "OVMF_VARS.fd",
        tpm=machine_dir / "tpm",
        state=machine_dir,
        identity="scratch" + suffix,
        _session=session,
    )


def _provision(
    session,
    image: ImageArtifact,
    machine_dir: Path,
    *,
    suffix: str = "-boottest",
    console_setup: Callable[[SerialConsole], None] | None = None,
) -> Path:
    from . import log

    run_vm = session.paths.image_src / "scripts" / "run-vm.sh"
    if not run_vm.is_file():
        raise ConfigError("no run-vm.sh at %s" % run_vm)

    env = dict(os.environ)
    env["XDG_STATE_HOME"] = str(session.state)
    serial = machine_dir / "provision.log"
    serial_sock = machine_dir / "serial.sock"
    banner = machine_dir / "provision.out"
    for path in (serial, serial_sock, banner):
        path.unlink(missing_ok=True)

    log.step("provisioning a machine (Secure Boot enrolment + repart, minutes)")
    process = subprocess.Popen(
        [
            str(run_vm),
            "--state-suffix",
            suffix,
            # A socket, not a file: the first boot asks for the TPM2 PIN on the
            # serial console and there is no one to type it but the harness.
            # run-vm.sh waits for a connection before booting (wait=on), so the
            # console attaches next, before _wait_for_terminal starts reading.
            "--serial-sock",
            str(serial_sock),
            "--secure-boot",
            "--tpm",
            # We are here because the machine's identity no longer matches the
            # image -- almost always because mkosi rebuilt the .raw. run-vm.sh
            # creates its qcow2 overlay ONLY if the state dir has none
            # ([ -e "$STATE/disk.qcow2" ] || create_overlay), so without this the
            # "provisioning" boot lands on an overlay allocated over the PREVIOUS
            # raw: every cluster the old provisioning touched still reads as old
            # data while the rest reads through to the new image, and the result
            # is a disk whose GPT, ESP FAT table and UKI names disagree with each
            # other. The observed symptom is BdsDxe "failed to load Boot0002 ...
            # Not Found" and "No bootable option or device was found" -- a boot
            # that cannot even locate its own bootloader, on an image whose ESP
            # verifies perfectly when read straight off the raw.
            #
            # --reset drops TPM state, OVMF variables and the disk overlay, so
            # the overlay is recreated over the raw that is actually there now.
            # That is what provisioning means: a machine that has never booted.
            "--reset",
        ],
        env=env,
        stdout=open(banner, "w"),
        stderr=subprocess.STDOUT,
    )
    console = SerialConsole(serial_sock, serial)
    try:
        console.connect()
        # vngrd-provision asks for the new recovery passphrase (twice: the
        # prompt and its repeat), then vngrd-tpm-pin asks for the PIN twice.
        # The answers are registered before the boot reaches the prompts; the
        # console answers each occurrence once. A case may replace the
        # passphrase rule with a sequence (the mismatch retry case), but the PIN
        # rule is the same on every first boot.
        if console_setup is None:
            console.watch(NEW_PASSPHRASE_PROMPT, TEST_RECOVERY_PASSPHRASE)
        else:
            console_setup(console)
        console.watch(PIN_PROMPT, TEST_PIN)
        _wait_for_terminal(serial, timeout=900)
    finally:
        console.close()
        _stop(process)

    if not TPM_BOUND.search(serial.read_text(errors="replace") if serial.is_file() else ""):
        log.bad("the guest kernel bound no TPM; provisioning cannot have completed")
        raise ConfigError("no TPM in the provisioning boot; see %s" % serial)

    # Take the state directory from run-vm.sh rather than recomputing its name:
    # the spelling (`secboot` vs `secureboot`) is run-vm.sh's business, and
    # hardcoding it here is how this harness silently looked in the wrong place.
    state = _state_from_banner(banner, session.state, image.version, suffix)

    # The disk is a qcow2 overlay; flatten it so cases can mutate it with plain
    # byte writes and no overlay lookup.
    overlay = state / "disk.qcow2"
    if not overlay.is_file():
        raise ConfigError("no qcow2 overlay at %s after provisioning" % overlay)
    from .qemu import clone_disk

    clone_disk(overlay, machine_dir / "disk.raw")
    shutil.copy(state / "OVMF_VARS.fd", machine_dir / "OVMF_VARS.fd")

    if not tpm.wait_for_permall(state / "tpm", timeout=30):
        raise ConfigError("swtpm never flushed its state to %s/tpm" % state)
    tpm.seed_from(state / "tpm", machine_dir / "tpm")
    return state


def _state_from_banner(banner: Path, state_root: Path, version: str, suffix: str) -> Path:
    """The state directory run-vm.sh reported, or a last-resort guess."""
    if banner.is_file():
        for line in banner.read_text(errors="replace").splitlines():
            if line.startswith("State:"):
                candidate = Path(line.split(None, 1)[1].strip())
                if candidate.is_dir():
                    return candidate
    for kind in ("secboot", "secureboot"):
        candidate = state_root / "vngrd" / ("%s-%s%s" % (version, kind, suffix))
        if (candidate / "disk.qcow2").is_file():
            return candidate
    raise ConfigError("run-vm.sh never reported its state directory; see %s" % banner)


def _wait_for_terminal(serial: Path, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if serial.is_file():
            text = serial.read_text(errors="replace")
            if TERMINAL.search(text):
                return
        time.sleep(1)


def _stop(process: subprocess.Popen, grace: float = 60.0) -> None:
    """Stop the wrapper and let its own EXIT trap reap qemu and swtpm.

    run-vm.sh installs that trap precisely so qemu commits the TPM state on the
    way out; signalling qemu directly would skip the commit. There is
    deliberately no blanket pgrep sweep here: a stray `qemu-system-*` on the
    host may belong to the user, and killing it would be worse than an orphan.
    """
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    deadline = time.monotonic() + grace
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.5)
    if process.poll() is None:
        process.kill()
        process.wait(timeout=10)

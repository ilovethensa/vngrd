"""swtpm lifecycle and per-case TPM state.

The TPM is a precondition for every seal-related case: with no TPM the root
cannot open whatever the policy says, so "the root stayed shut" is true for the
wrong reason. Cases must assert `tpm.bound` (a FAIL, not a skip) before drawing
any conclusion from a locked root.
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from . import log
from .errors import ConfigError
from .tools import Tools

PERMALL_GLOB = "*.permall"


@dataclass
class Swtpm:
    process: subprocess.Popen
    socket: Path
    state_dir: Path
    log_path: Path

    def stop(self, timeout: float = 20.0) -> None:
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            deadline = time.monotonic() + timeout
            while self.process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.2)
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait(timeout=5)
        wait_for_permall(self.state_dir, timeout=10)


def wait_for_permall(state_dir: Path, timeout: float = 20.0) -> bool:
    """swtpm is daemonised and flushes asynchronously; wait for the state file.

    Copying the state directory too early catches an empty one, and the machine
    then has no SRK.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any(state_dir.glob(PERMALL_GLOB)):
            return True
        time.sleep(0.5)
    return False


def start(state_dir: Path, tools: Tools, log_path: Path | None = None) -> Swtpm:
    if not tools.swtpm:
        raise ConfigError("swtpm not found; TPM-backed cases cannot run")
    state_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(state_dir, 0o700)
    socket = state_dir / "swtpm.sock"
    socket.unlink(missing_ok=True)
    log_path = log_path or (state_dir / "swtpm.log")

    process = subprocess.Popen(
        [
            tools.swtpm,
            "socket",
            "--tpm2",
            "--tpmstate",
            "dir=%s,mode=0600" % state_dir,
            "--ctrl",
            "type=unixio,path=%s" % socket,
            "--daemon",
            "--pid",
            "file=%s" % (state_dir / "swtpm.pid"),
            "--log",
            "file=%s,level=1" % log_path,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    # --daemon makes swtpm fork; the foreground process exits immediately.
    _, stderr = process.communicate(timeout=10)
    if process.returncode != 0:
        raise ConfigError("swtpm failed to start: %s" % (stderr or "").strip())

    deadline = time.monotonic() + 10
    while not socket.exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    if not socket.exists():
        raise ConfigError("swtpm started but never created %s" % socket)

    daemon = _PidProcess(state_dir / "swtpm.pid")
    return Swtpm(daemon, socket, state_dir, log_path)


class _PidProcess:
    """A Popen-like handle for the daemonised swtpm, driven by its pid file."""

    def __init__(self, pid_file: Path):
        self.pid_file = pid_file
        self._pid = _read_pid(pid_file)

    def poll(self):
        if not self._pid:
            return 0
        try:
            os.kill(self._pid, 0)
        except ProcessLookupError:
            return 0
        except PermissionError:
            return None
        return None

    def send_signal(self, sig: int) -> None:
        if self._pid:
            try:
                os.kill(self._pid, sig)
            except ProcessLookupError:
                pass

    def kill(self) -> None:
        self.send_signal(signal.SIGKILL)

    def wait(self, timeout: float | None = None) -> int:
        deadline = time.monotonic() + (timeout or 5)
        while time.monotonic() < deadline:
            if self.poll() == 0:
                return 0
            time.sleep(0.2)
        return 1


def _read_pid(pid_file: Path) -> int | None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if pid_file.is_file():
            text = pid_file.read_text().strip()
            if text.isdigit():
                return int(text)
        time.sleep(0.1)
    return None


def seed_from(source: Path, dest: Path) -> None:
    """Copy a machine's TPM state, loudly refusing an empty or torn copy.

    A silently empty tpm/ is a machine with a fresh SRK: every case that asserts
    the root did not open would pass for the wrong reason.
    """
    if not source.is_dir():
        raise ConfigError("no TPM state at %s to seed from" % source)
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    os.chmod(dest, 0o700)
    shutil.copytree(source, dest, dirs_exist_ok=True)
    if not any(dest.glob(PERMALL_GLOB)):
        raise ConfigError(
            "the copied TPM state has no .permall; swtpm writes it last, so this "
            "is a torn copy rather than an empty one"
        )
    for permall in dest.glob(PERMALL_GLOB):
        os.chmod(permall, 0o600)


def wipe(dest: Path) -> None:
    """Replace a state directory with an empty one: a TPM with a fresh SRK."""
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    os.chmod(dest, 0o700)
    log.note("wiped TPM state at %s: the SRK is new" % dest)

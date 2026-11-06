"""QEMU lifecycle driven over QMP.

The old harness started a shell wrapper, polled the serial log for a magic
string, then killed the process tree with pgrep. That is where the marker races,
the orphaned QEMU processes and the 240s stop timeouts came from. Here QEMU is a
child process we own, controlled over QMP: we know when it resets, when it shuts
down, and we ask it to quit rather than guessing at signals.

The boot is observed as an event stream (guest.py), not by grepping prose.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from . import guest, log, tpm
from .console import PIN_PROMPT, TEST_PIN, SerialConsole
from .disk import Esp, Gpt
from .errors import ConfigError, SkipTest
from .guest import EventStream
from .image import ImageArtifact
from .uki import Uki

ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
TERMINAL = re.compile(
    r"(?:login:\s*$)"
    r"|(?:You are in emergency mode\.)"
    r"|(?:VNGRO \S+ boot\.(?:login-ready|emergency|terminal))",
    re.MULTILINE,
)
OVMF_DIRS = ("/usr/share/OVMF/x64", "/usr/share/OVMF", "/usr/share/edk2/x64")


def normalise(text: str) -> str:
    # Serial output mixes CRLF with a bare CR for systemd's progress line. A bare
    # CR is a line separator, not something to delete: deleting it joins the
    # "Reached target ..." line to the text after it, and the boot anchors then
    # cannot see a target that the console plainly showed.
    return ANSI.sub("", text).replace("\r\n", "\n").replace("\r", "\n")


def find_ovmf(secureboot: bool) -> tuple[Path, Path]:
    codes = (
        ["OVMF_CODE.secboot.4m.fd", "OVMF_CODE.secboot.fd"]
        if secureboot
        else ["OVMF_CODE.4m.fd", "OVMF_CODE.fd"]
    )
    vars_templates = ["OVMF_VARS.4m.fd", "OVMF_VARS.fd"]
    for directory in OVMF_DIRS:
        base = Path(directory)
        code = next((base / name for name in codes if (base / name).is_file()), None)
        vars_template = next((base / name for name in vars_templates if (base / name).is_file()), None)
        if code and vars_template:
            return code, vars_template
    raise SkipTest("no OVMF firmware found in %s" % ", ".join(OVMF_DIRS))


def clone_disk(source: Path, dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.unlink(missing_ok=True)
    if not shutil.which("qemu-img"):
        raise ConfigError("qemu-img not found")
    result = subprocess.run(
        ["qemu-img", "convert", "-O", "raw", "-S", "4k", str(source), str(dest)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not dest.is_file():
        raise ConfigError("qemu-img convert failed: %s" % result.stderr.strip())
    return dest


class Qmp:
    """A minimal QMP client: capabilities, execute, and a background event drain."""

    def __init__(self, path: Path, timeout: float = 15.0):
        self.path = Path(path)
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self._file = None
        self._cond = threading.Condition()
        self._responses: deque[dict] = deque()
        self._events: list[dict] = []
        self._stop = False
        self._thread: threading.Thread | None = None

    def connect(self) -> None:
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if self.path.exists():
                try:
                    self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    self._sock.connect(str(self.path))
                    break
                except OSError:
                    self._sock = None
            time.sleep(0.1)
        if self._sock is None:
            raise ConfigError("could not connect to QMP socket %s" % self.path)
        self._file = self._sock.makefile("rwb")
        greeting = self._read_object()
        if "QMP" not in greeting:
            raise ConfigError("unexpected QMP greeting: %r" % greeting)
        self._thread = threading.Thread(target=self._reader, daemon=True)
        self._thread.start()
        self.execute("qmp_capabilities")

    def _read_object(self) -> dict:
        line = self._file.readline()
        if not line:
            raise ConfigError("QMP connection closed")
        return json.loads(line)

    def _reader(self) -> None:
        while not self._stop:
            try:
                line = self._file.readline()
            except (OSError, ValueError):
                break
            if not line:
                break
            try:
                message = json.loads(line)
            except ValueError:
                continue
            with self._cond:
                if "event" in message:
                    self._events.append(message)
                else:
                    self._responses.append(message)
                self._cond.notify_all()

    def execute(self, command: str, **arguments) -> dict:
        payload: dict = {"execute": command}
        if arguments:
            payload["arguments"] = arguments
        with self._cond:
            self._file.write((json.dumps(payload) + "\r\n").encode())
            self._file.flush()
            deadline = time.monotonic() + self.timeout
            while not self._responses:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not self._cond.wait(remaining):
                    raise ConfigError("QMP timed out on %s" % command)
            response = self._responses.popleft()
        if "error" in response:
            raise ConfigError("QMP %s failed: %s" % (command, response["error"]))
        return response.get("return", {})

    def drain_events(self) -> list[dict]:
        with self._cond:
            events, self._events = self._events, []
        return events

    def quit(self) -> None:
        try:
            self.execute("quit")
            time.sleep(0.3)
        except Exception:  # noqa: BLE001 - the VM may already be gone
            pass

    def close(self) -> None:
        self._stop = True
        try:
            if self._file:
                self._file.close()
        except OSError:
            pass
        try:
            if self._sock:
                self._sock.close()
        except OSError:
            pass


@dataclass
class Boot:
    """The result of one boot: the event stream plus how the boot ended."""

    vm: "Vm"
    events: EventStream
    log_path: Path
    timed_out: bool
    exit_reason: str
    seconds: float
    report: object = None
    _checked: int = field(default=0)


    def expect(self, name: str, **match) -> bool:
        found = self.events.saw(name, **match)
        detail = "event %s %s" % (name, match or "")
        if self.report:
            self.report.check("event:%s" % name, found, detail)
        return found

    def expect_absent(self, name: str, **match) -> bool:
        absent = self.events.missing(name, **match)
        if self.report:
            self.report.check("no-event:%s" % name, absent, "event %s must not occur" % name)
        return absent

    def require(self, name: str, **match) -> guest.Event:
        event = self.events.first(name, **match)
        if self.report:
            self.report.record("event:%s" % name, event is not None, str(match))
        if event is None:
            raise AssertionError(
                "expected event %s %s; saw: %s" % (name, match or "", ", ".join(self.events.names()))
            )
        return event

    def require_absent(self, name: str, **match) -> None:
        if self.events.saw(name, **match):
            if self.report:
                self.report.record("no-event:%s" % name, False, "present but forbidden")
            raise AssertionError("event %s %s must not occur, but did" % (name, match or ""))
        if self.report:
            self.report.record("no-event:%s" % name, True)

    def expect_before(self, first: str, second: str) -> bool:
        verdict = self.events.before(first, second)
        ok = verdict is True
        if self.report:
            self.report.check(
                "order:%s<%s" % (first, second), ok, "ordering undecidable or reversed"
            )
        return ok

    def require_producer(self, producer: str) -> None:
        if self.events.producer != producer:
            raise AssertionError(
                "this case needs the %r event producer; got %r"
                % (producer, self.events.producer)
            )

    def expect_no_parse_issues(self) -> bool:
        ok = not self.events.issues
        if self.report:
            self.report.check("events:parse", ok, "; ".join(i.reason for i in self.events.issues))
        return ok


class Vm:
    """One per-case virtual machine: a cloned disk, seeded state, and a boot."""

    def __init__(self, session, case, report):
        self.session = session
        self.case = case
        self.report = report
        self.tools = session.tools
        self.image: ImageArtifact = session.image()
        self.name = case.id
        self.state = session.state / "cases" / case.id
        self.disk = self.state / "disk.raw"
        self.serial = self.state / "serial.log"
        self.varstore = self.state / "OVMF_VARS.fd"
        self.tpm_dir = self.state / "tpm"
        # Kept so a case can assert that the knob it asked for actually reached
        # QEMU: an -smbios that silently does not make it onto the command line
        # makes a case pass for the wrong reason, and this is the only place that
        # can tell the difference.
        self.argv: list[str] = []
        self._prepare()


    def _prepare(self) -> None:
        if not self.session.options.keep and self.state.exists():
            shutil.rmtree(self.state)
        self.state.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state, 0o700)

        source = self.session.machine.disk if self.case.needs_machine else self.image.raw
        if not source.is_file():
            raise ConfigError("no source disk at %s" % source)
        clone_disk(source, self.disk)

        self._seed_varstore()
        if self.case.tpm:
            if self.case.needs_machine:
                tpm.seed_from(self.session.machine.tpm, self.tpm_dir)
            else:
                tpm.wipe(self.tpm_dir)

    def _seed_varstore(self) -> None:
        if self.case.secureboot:
            source = self.session.machine.varstore if self.case.needs_machine else None
            if source and source.is_file():
                shutil.copy(source, self.varstore)
                os.chmod(self.varstore, 0o600)
                return
            raise ConfigError(
                "a Secure Boot case needs an enrolled varstore; provision a machine first"
            )
        _, template = find_ovmf(False)
        shutil.copy(template, self.varstore)
        os.chmod(self.varstore, 0o600)


    @property
    def gpt(self) -> Gpt:
        return Gpt.load(self.disk)

    def poke(self, offset: int, payload: bytes) -> None:
        from .disk import write_at

        write_at(self.disk, offset, payload)

    def esp(self) -> Esp:
        return Esp.extract_from(self.disk, self.state / "esp.img", self.tools)

    def uki_path_on_esp(self) -> str:
        return self.esp().uki_path()

    def replace_uki(self, uki_path: Path) -> None:
        """Write a UKI back to the ESP and the ESP back to the disk.

        The read-back is deliberately by content, not by size: a silent
        failed copy that left the pristine UKI on disk would let the case report
        a plant that never happened, which is a false pass.
        """
        import hashlib

        def digest(path: Path) -> str:
            return hashlib.sha256(path.read_bytes()).hexdigest()

        esp = self.esp()
        remote = esp.uki_path()
        esp.put(uki_path, remote)
        from .disk import replace_region

        esp_partition = self.gpt.esp()
        replace_region(self.disk, esp_partition.offset, esp.path)
        back = self.esp().get(remote, self.state / "verify.efi")
        if digest(back) != digest(uki_path):
            raise ConfigError(
                "the UKI on the ESP is not the one that was planted (mcopy landed "
                "something else, or the write back to the disk did not land)"
            )

    def uki(self) -> Uki:
        """The UKI currently on the case disk, as a mutable copy."""
        esp = self.esp()
        path = esp.get(esp.uki_path(), self.state / "uki.efi")
        return Uki(path, self.tools)


    def start(
        self,
        timeout: int | None = None,
        terminal: tuple[str, ...] = (),
        watch: tuple[tuple[re.Pattern[str], str], ...] = (),
        interact: Callable[[SerialConsole], None] | None = None,
        stop_on_reset: bool = True,
    ) -> Boot:
        if not self.tools.qemu:
            raise SkipTest("qemu-system-x86_64 not found")
        timeout = timeout or self.case.timeout
        terminal_patterns = tuple(re.compile(re.escape(text)) for text in terminal)
        qmp_path = self.state / "qmp.sock"
        qmp_path.unlink(missing_ok=True)
        serial_sock = self.state / "serial.sock"
        serial_sock.unlink(missing_ok=True)
        # The console tee opens (and truncates) the log itself; this line
        # existed to clear a previous run's file before `-serial file:` took it.
        if self.serial.exists():
            self.serial.write_text("")

        swtpm = tpm.start(self.tpm_dir, self.tools) if self.case.tpm else None
        argv = self._argv(qmp_path)
        self.argv = argv
        log.note("qemu: %s" % " ".join(argv[:6]) + " ...")
        stderr_path = self.state / "qemu.stderr"
        process = subprocess.Popen(
            argv, stdout=subprocess.DEVNULL, stderr=open(stderr_path, "w"), text=True
        )
        # A serial socket, not a log file: the case's boots are of a machine
        # whose root carries a PIN-protected token, so every one of them asks
        # for the same PIN before the volume opens. The console attaches (qemu
        # waits for it: wait=on), answers that prompt, and tees the boot to
        # serial.log for the assertions to read exactly as before.
        console = SerialConsole(serial_sock, self.serial)
        qmp = Qmp(qmp_path)
        started = time.monotonic()
        exit_reason = "timeout"
        try:
            console.connect()
            console.watch(PIN_PROMPT, TEST_PIN)
            # Case-specific prompts. The default watchers deliberately do not
            # answer a later boot's passphrase prompt: t6a/t6b prove that the TPM
            # is required, and a broad recovery-passphrase watcher would answer
            # the fallback those cases are asserting must happen.
            for pattern, response in watch:
                console.watch(pattern, response)
            qmp.connect()
            # A synchronous hook for cases that have to act on the running guest
            # before the boot ends (for example, writing the reseal marker and
            # powering off from the root shell). It runs after the console is
            # attached, so nothing typed is lost to the wait=on window.
            if interact is not None:
                interact(console)
            exit_reason = self._wait(qmp, process, timeout, terminal_patterns, stop_on_reset)
        finally:
            console.close()
            qmp.quit()
            self._reap(process)
            qmp.close()
            if swtpm:
                swtpm.stop()

        text = normalise(self.serial.read_text(errors="replace")) if self.serial.is_file() else ""
        events = EventStream.from_log(text)
        if self.report:
            self.report.artifact(self.serial)
            self.report.artifact(stderr_path)
        return Boot(
            vm=self,
            events=events,
            log_path=self.serial,
            timed_out=exit_reason == "timeout",
            exit_reason=exit_reason,
            seconds=time.monotonic() - started,
            report=self.report,
        )

    def _wait(
        self,
        qmp: Qmp,
        process: subprocess.Popen,
        timeout: int,
        terminal_patterns: tuple[re.Pattern, ...] = (),
        stop_on_reset: bool = True,
    ) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if process.poll() is not None:
                return "process-exit"
            if self.serial.is_file():
                text = normalise(self.serial.read_text(errors="replace"))
                if TERMINAL.search(text):
                    return "terminal"
                if any(pattern.search(text) for pattern in terminal_patterns):
                    return "terminal"
            for event in qmp.drain_events():
                name = event.get("event", "")
                if name == "RESET" and stop_on_reset:
                    return "reset"
                if name in ("SHUTDOWN", "POWERDOWN"):
                    return "shutdown"
            time.sleep(0.5)
        return "timeout"

    @staticmethod
    def _reap(process: subprocess.Popen, grace: float = 10.0) -> None:
        deadline = time.monotonic() + grace
        while process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.2)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

    def _argv(self, qmp_path: Path) -> list[str]:
        code, _ = find_ovmf(self.case.secureboot)
        serial_sock = self.state / "serial.sock"
        argv = [
            self.tools.qemu,
            "-machine",
            "q35",
            "-m",
            "2048",
            "-smp",
            "2",
            "-drive",
            "if=pflash,format=raw,readonly=on,file=%s" % code,
            "-drive",
            "if=pflash,format=raw,file=%s" % self.varstore,
            "-drive",
            "file=%s,format=raw,if=virtio" % self.disk,
            "-nic",
            "none",
        ]
        if os.path.exists("/dev/kvm"):
            argv += ["-enable-kvm", "-cpu", "host"]
        else:
            argv += ["-cpu", "qemu64"]
        if self.case.smbios_cmdline_extra:
            # The host is the attacker, expressed in the one place the host owns:
            # an SMBIOS Type 11 OEM string. sd-stub appends the value of
            # io.systemd.stub.kernel-cmdline-extra= after the signed .cmdline,
            # unsigned, and every consumer of a repeated parameter takes the last
            # one -- which is why this is a real attack surface and not a menu
            # effect. Nothing in the harness can set it; a case has to ask.
            argv += [
                "-smbios",
                "type=11,value=io.systemd.stub.kernel-cmdline-extra=%s"
                % self.case.smbios_cmdline_extra,
            ]
        if self.case.tpm:
            argv += [
                "-chardev",
                "socket,id=chrtpm,path=%s" % (self.tpm_dir / "swtpm.sock"),
                "-tpmdev",
                "emulator,id=tpm0,chardev=chrtpm",
                "-device",
                "tpm-tis,tpmdev=tpm0",
            ]
        argv += [
            "-display",
            "none",
            "-serial",
            # A chardev socket, not a file: the console thread attaches to it,
            # answers the TPM2 PIN unlock prompt this disk's token requires,
            # and tees the boot to serial.log for _wait and the assertions.
            # `wait=on` means qemu does not boot until the console attaches,
            # which is why SerialConsole.connect() happens in start() before
            # anything polls the log.
            "unix:%s,server=on,wait=on" % serial_sock,
            "-qmp",
            "unix:%s,server=on,wait=off" % qmp_path,
        ]
        return argv

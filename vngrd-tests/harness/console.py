"""A serial console the harness answers prompts on.

The image's first boot is interactive by design, and deliberately so:
vngrd-provision.service asks for the root recovery passphrase, and
vngrd-tpm-pin.service asks for the TPM2 PIN that protects the root's token.
The cryptsetup unlock on every later boot asks for the same PIN.
systemd-cryptenroll has no non-interactive enrolment mode because both secrets
are only supplyable by a person -- the passphrase is a keyslot, and the PIN is
hashed into the token's policy, not stored anywhere.

So the harness is the operator: it watches the console for the prompt and
answers it on the same serial line a human would type on. Nothing here
bypasses a measurement, weakens a policy, or pre-seeds a secret: the test PIN
is typed into the same ask-password agent, the token still comes out
PIN-protected, and a later boot still refuses to open without it. The case
that asserts "the volume sealed by provisioning opens again with no re-seal and
no operator" (t0-second-boot) passes because the harness answered -- which is
what "no operator" means for an unattended test.

The mechanism is a QEMU serial chardev socket, not the log file the harness
used to read: `-serial file:` is write-only from the guest's side and there is
no way to type into it. run-vm.sh has carried `--serial-sock` for exactly this
("A bidirectional serial socket ... This exists so the test harness can drive
prompts without that failure mode"); the pty-backed stdio alternative stalls
under KVM, because the guest writes its console faster than emulation did and
the pty stops draining, which looks like a hang in whatever unit happened to
be printing.
"""

from __future__ import annotations

import re
import socket
import threading
import time
from pathlib import Path

# Fixed test-only PIN: later boots must be answerable, and this never reaches
# an image.
TEST_PIN = "147258369"

# Test-only recovery passphrase, long enough for cryptenroll's quality check.
TEST_RECOVERY_PASSPHRASE = "vngrd-test-recovery-passphrase-0123456789"

# All three systemd spellings of the PIN prompt: enrolment, TPM2 token unlock,
# and generic LUKS2 token unlock.
PIN_PROMPT = re.compile(r"Please enter (?:TPM2 PIN|LUKS2 token PIN)")

# Only the enrolment wording, never a later boot's passphrase fallback:
# t6a/t6b rely on that fallback remaining unattended.
NEW_PASSPHRASE_PROMPT = re.compile(r"Please enter new passphrase")

TAIL_BYTES = 65536


class SerialConsole:
    """A connected serial socket: tee'd to a log, and answering prompts.

    Not thread-safe for concurrent `type()` calls by design -- the answering
    is driven by the single reader thread, and the callers only read.
    """

    def __init__(self, sock_path: Path, log_path: Path):
        self.sock_path = Path(sock_path)
        self.log_path = Path(log_path)
        self._sock: socket.socket | None = None
        self._log = None
        self._lock = threading.Lock()
        self._tail = ""
        # (pattern, answers, occurrences consumed); the last answer repeats.
        self._rules: list[tuple[re.Pattern[str], list[str], list[int]]] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None


    def connect(self, timeout: float = 30.0) -> None:
        """Attach to the socket and start the reader thread.

        QEMU's chardev is `server=on,wait=on`: the socket file exists the
        moment qemu starts, and qemu does not boot until a client attaches.
        The retry loop covers the window between the file appearing and the
        listen actually being established.
        """
        deadline = time.monotonic() + timeout
        last: OSError | None = None
        while time.monotonic() < deadline:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(str(self.sock_path))
                self._sock = sock
                break
            except OSError as exc:
                last = exc
                sock.close()
                time.sleep(0.1)
        else:
            raise OSError("could not connect to %s: %s" % (self.sock_path, last))

        # Truncate: callers treat this log as the current boot only.
        self._log = open(self.log_path, "wb", buffering=0)
        self._thread = threading.Thread(target=self._read, daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        if self._sock is not None:
            try:
                self._sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None
        if self._log is not None:
            self._log.close()
            self._log = None


    def watch(self, pattern: re.Pattern[str], response: str) -> None:
        """Answer every occurrence of `pattern` with `response`.

        One answer per occurrence: a prompt line only exists because input is
        wanted, so an occurrence is a request and each request gets one
        answer. The enrolment's two occurrences (its prompt and the repeat)
        are therefore answered exactly twice, and cryptenroll re-asking after
        a mismatch is answered again and fails on its own terms instead of
        being fed the same line forever.
        """
        with self._lock:
            self._rules.append((pattern, [response], [0]))

    def watch_sequence(self, pattern: re.Pattern[str], responses: list[str]) -> None:
        """Answer the first occurrences with successive responses.

        The last response repeats after the list is exhausted. This is for the
        enrolment retry: the first two answers deliberately disagree, then the
        next pair is the real passphrase. A plain watch() cannot express that.
        """
        if not responses:
            raise ValueError("watch_sequence needs at least one response")
        with self._lock:
            self._rules.append((pattern, list(responses), [0]))

    def type(self, text: str) -> None:
        """Send a line to the guest's console."""
        if self._sock is None:
            return
        try:
            self._sock.sendall((text + "\n").encode())
        except OSError:
            pass


    def wait_for(self, pattern: re.Pattern[str], timeout: float) -> bool:
        """Whether `pattern` has appeared on the console."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._lock:
                if pattern.search(self._tail):
                    return True
            time.sleep(0.25)
        return False

    def tail(self) -> str:
        with self._lock:
            return self._tail


    def _read(self) -> None:
        while not self._stop.is_set():
            sock = self._sock
            if sock is None:
                return
            try:
                chunk = sock.recv(4096)
            except OSError:
                return
            if not chunk:
                return
            self._consume(chunk)

    def _consume(self, chunk: bytes) -> None:
        if self._log is not None:
            try:
                self._log.write(chunk)
            except OSError:
                pass
        text = chunk.decode("utf-8", errors="replace")
        pending: list[str] = []
        with self._lock:
            self._tail = (self._tail + text)[-TAIL_BYTES:]
            for pattern, responses, answered in self._rules:
                occurrences = len(pattern.findall(self._tail))
                fresh = occurrences - answered[0]
                if fresh > 0:
                    for _ in range(fresh):
                        pending.append(responses[min(answered[0], len(responses) - 1)])
                        answered[0] += 1
        # Send outside the lock so a burst of answers cannot stall the reader.
        for line in pending:
            # systemd-ask-password prints before turning echo off; wait for the
            # terminal mode to settle or the secret lands in the serial log.
            time.sleep(0.15)
            self.type(line)
            time.sleep(0.15)

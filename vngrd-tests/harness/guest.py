"""Observation of a boot: a structured event stream, with a marked fallback.

PRIMARY CONTRACT
    The image's own test reporter writes one line per event to the console:

        VNGRO 1 boot.usr-mounted fs=erofs
        VNGRO 1 tpm.pcr pcr=7 bank=sha256 value=<hex>
        VNGRO 1 assert id=etc-is-tmpfs ok=1 detail=tmpfs

    Fields are `key=value`, space separated. The `1` is the contract version; a
    line whose version the host does not know is a hard parse error, not a
    silently ignored line.

FALLBACK
    Until the reporter ships in the image, a small, explicitly delimited set of
    stable anchors is mapped to the same event names. This is a bridge and is
    labelled as one: it exists so the suite can be ported and run before the
    image changes, and `EventStream.derived` records which producer was used so
    a case can require the real one. Do not add anchors casually; each one is a
    piece of prose the suite is coupled to.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

CONTRACT_VERSION = "1"
EVENT_PREFIX = "VNGRO"

_LINE = re.compile(r"^(?P<prefix>VNGRO)\s+(?P<version>\S+)\s+(?P<name>\S+)\s*(?P<rest>.*)$")
_FIELD = re.compile(r"([A-Za-z0-9_.-]+)=(\S*)")


@dataclass(frozen=True)
class Event:
    seq: int
    name: str
    fields: dict[str, str]
    raw: str
    producer: str = "reporter"

    def matches(self, **match) -> bool:
        return all(self.fields.get(key) == value for key, value in match.items())


@dataclass(frozen=True)
class ParseIssue:
    line: int
    text: str
    reason: str


@dataclass
class EventStream:
    events: list[Event] = field(default_factory=list)
    issues: list[ParseIssue] = field(default_factory=list)
    producer: str = "reporter"


    def all(self, name: str, **match) -> list[Event]:
        return [event for event in self.events if event.name == name and event.matches(**match)]

    def saw(self, name: str, **match) -> bool:
        return bool(self.all(name, **match))

    def missing(self, name: str, **match) -> bool:
        return not self.saw(name, **match)

    def saw_any(self, *names: str) -> bool:
        return any(self.saw(name) for name in names)

    def first(self, name: str, **match) -> Event | None:
        found = self.all(name, **match)
        return found[0] if found else None

    def index(self, name: str, **match) -> int | None:
        event = self.first(name, **match)
        return event.seq if event else None

    def before(self, first: str, second: str) -> bool | None:
        """True if the first occurrence of *first* precedes that of *second*.

        None when either is absent: a missing event is a failure the caller
        should report, not an ordering verdict.
        """
        left = self.index(first)
        right = self.index(second)
        if left is None or right is None:
            return None
        return left < right

    def names(self) -> list[str]:
        seen: list[str] = []
        for event in self.events:
            if event.name not in seen:
                seen.append(event.name)
        return seen


    @classmethod
    def parse(cls, text: str) -> "EventStream":
        stream = cls()
        seq = 0
        for number, raw in enumerate(text.splitlines(), start=1):
            if EVENT_PREFIX not in raw:
                continue
            match = _LINE.match(raw.strip())
            if not match:
                stream.issues.append(ParseIssue(number, raw, "malformed VNGRO line"))
                continue
            if match.group("version") != CONTRACT_VERSION:
                stream.issues.append(
                    ParseIssue(
                        number,
                        raw,
                        "unknown contract version %r" % match.group("version"),
                    )
                )
                continue
            fields = {key: value for key, value in _FIELD.findall(match.group("rest"))}
            stream.events.append(Event(seq, match.group("name"), fields, raw))
            seq += 1
        return stream

    @classmethod
    def derived(cls, text: str) -> "EventStream":
        """The fallback producer: stable log anchors mapped to event names."""
        stream = cls(producer="anchors")
        seq = 0
        for number, raw in enumerate(text.splitlines(), start=1):
            for name, pattern in ANCHORS:
                hit = pattern.search(raw)
                if hit:
                    stream.events.append(
                        Event(seq, name, hit.groupdict(), raw, producer="anchors")
                    )
                    seq += 1
        return stream

    @classmethod
    def from_log(cls, text: str) -> "EventStream":
        """Prefer the reporter; fall back to anchors, and say which was used."""
        reported = cls.parse(text)
        if reported.events:
            return reported
        return cls.derived(text)


# Each entry is (event name, regex over the raw console line). Keep this list
# small and each pattern tied to a message that is stable API (a unit name, a
# kernel subsystem message), never to free-form prose.
ANCHORS: tuple[tuple[str, re.Pattern], ...] = (
    ("boot.enter-initrd", re.compile(r"Reached target Initrd Root File System\.")),
    ("boot.usr-mounted", re.compile(r"Mounted /sysusr/usr\.")),
    ("boot.root-unsealed", re.compile(r"Mounted /sysroot\.")),
    ("boot.switch-root", re.compile(r"Reached target Switch Root\.")),
    ("boot.multi-user", re.compile(r"Reached target Multi-User System\.")),
    ("boot.login-ready", re.compile(r"login:\s*$")),
    ("boot.emergency", re.compile(r"You are in emergency mode\.")),
    ("tpm.bound", re.compile(r"tpm_tis MSFT|tpm_tis_core|tpm_crb|tpmrm0")),
    # The vngrd fixate generator is what actually reports a missing TPM on this
    # image ("device:/dev/tpmrm0' unavailable, so there is no fixate check"),
    # because with no TPM the machine still reaches userspace. The kernel and
    # TCTI phrasings are kept for a guest that reports them first.
    (
        "tpm.absent",
        re.compile(r"TPM device not found|No TPM device|/dev/tpmrm0' unavailable|TPM is unavailable"),
    ),
    ("verity.corrupt", re.compile(r"device-mapper: verity: .*data block \d+ is corrupted")),
    ("verity.mount-failed", re.compile(r"Failed to mount /sysusr/usr\.")),
    ("cryptsetup.start", re.compile(r"Starting Cryptography Setup for vngrd-root")),
    ("cryptsetup.failed", re.compile(r"Failed to start Cryptography Setup for vngrd-root\.")),
    ("cryptsetup.unseal-failed", re.compile(r"Failed to unseal secret using TPM2")),
    (
        "cryptsetup.no-signature",
        re.compile(r"Couldn't find signature for this PCR bank"),
    ),
    ("ordering.skip-cryptsetup", re.compile(r"skipping Cryptography Setup for vngrd-root")),
    ("sb.denied", re.compile(r"Error loading .*EFI\\Linux.*: Access denied")),
    ("sb.no-bootable", re.compile(r"No bootable option or device was found\.")),
    ("lockdown.cmdline", re.compile(r"Kernel is locked down from command line")),
    ("lockdown.enforced", re.compile(r"Lockdown: [^:]+: .* is restricted")),
    ("lockdown.confidentiality", re.compile(r"Kernel is locked down from confidentiality")),
    ("lockdown.kconfig", re.compile(r"locked down from Kernel configuration")),
    ("kernel.started", re.compile(r"Linux version \d")),
    # What the kernel was actually handed. The line is the EFI stub's, printed
    # before ExitBootServices, so it is the assembled command line: signed
    # .cmdline plus anything an unsigned channel appended to it (SMBIOS Type 11,
    # ESP-resident .addon.efi .cmdline sections). The whole point of comparing
    # this against the UKI's .cmdline is that the addition is visible in it.
    ("kernel.cmdline", re.compile(r"Command line: (?P<cmdline>\S.*)$", re.MULTILINE)),
    ("initrd.started", re.compile(r"Booting initrd of")),
    ("initrd.barrier", re.compile(r"Started TPM PCR Barrier \(initrd\)\.")),
    ("initrd.barrier-stopping", re.compile(r"Stopping TPM PCR Barrier \(initrd\)")),
    ("host.barrier-sysinit", re.compile(r"Starting TPM PCR Barrier \(sysinit\)\.")),
    ("host.barrier-ready", re.compile(r"Starting TPM PCR Barrier \(User\)\.")),
    ("fixate.nv-sealed", re.compile(r"volume vngrd-root is sealed to TPM NV index")),
    ("fixate.applied", re.compile(r"fixate check applied")),
    # The pre-kernel bindings that sit beside the fixate digest, and the
    # reason each pattern is what it is:
    #
    #   - gpt.frozen and esp.frozen are printed once each, by vngrd-gpt-freeze
    #     and vngrd-esp-freeze, on the provisioning boot. The substring starts
    #     well inside the first 80 columns so a wrap cannot split it.
    #   - the three guards print NOTHING when they pass; every message they can
    #     produce ends in a non-zero exit and a reboot. So the presence of the
    #     program name and its colon is exactly "this guard refused", and the
    #     colon is what keeps it from matching systemd's own
    #     "Starting vngrd-gpt-guard.service..." line.
    ("gpt.frozen", re.compile(r"now holds the partition identity")),
    ("gpt.refused", re.compile(r"vngrd-gpt-guard:")),
    ("rollback.refused", re.compile(r"vngrd-rollback-guard:")),
    ("esp.frozen", re.compile(r"now holds the ESP identity")),
    ("esp.refused", re.compile(r"vngrd-esp-guard:")),
)

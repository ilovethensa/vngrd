"""Tier 0: the structured event stream and its fallback producer."""

from harness import test
from harness.guest import EventStream


REPORTER = """\
[    1.0] unrelated kernel line
VNGRO 1 boot.enter-initrd
VNGRO 1 boot.usr-mounted fs=erofs
VNGRO 1 assert id=etc-is-tmpfs ok=1 detail=tmpfs
VNGRO 1 tpm.pcr pcr=7 bank=sha256 value=deadbeef
"""


@test(tier="unit", id="guest.parse")
def reporter_lines_become_events_with_fields():
    stream = EventStream.parse(REPORTER)
    assert not stream.issues, stream.issues
    assert stream.names() == ["boot.enter-initrd", "boot.usr-mounted", "assert", "tpm.pcr"]
    assert stream.first("boot.usr-mounted").fields == {"fs": "erofs"}
    assert stream.first("tpm.pcr").fields["value"] == "deadbeef"
    assert stream.saw("assert", id="etc-is-tmpfs", ok="1")
    assert stream.missing("boot.emergency")


@test(tier="unit", id="guest.parse-errors")
def malformed_or_misversioned_lines_are_issues_not_silence():
    stream = EventStream.parse("VNGRO\nVNGRO 2 boot.login-ready\nVNGRO 1\n")
    assert len(stream.issues) == 3, stream.issues
    assert not stream.events


@test(tier="unit", id="guest.ordering")
def ordering_is_by_first_occurrence_and_undecidable_when_absent():
    stream = EventStream.parse(
        "VNGRO 1 cryptsetup.start\nVNGRO 1 boot.usr-mounted\nVNGRO 1 boot.root-unsealed\n"
    )
    assert stream.before("cryptsetup.start", "boot.root-unsealed") is True
    assert stream.before("boot.root-unsealed", "cryptsetup.start") is False
    assert stream.before("cryptsetup.start", "boot.emergency") is None


@test(tier="unit", id="guest.fallback")
def the_anchor_fallback_maps_stable_messages():
    log = (
        "[  OK  ] Mounted /sysusr/usr.\n"
        "[  OK  ] Reached target Multi-User System.\n"
        "localhost login: \n"
        "device-mapper: verity: 253:2: data block 0 is corrupted\n"
    )
    stream = EventStream.derived(log)
    assert stream.producer == "anchors"
    assert stream.saw("boot.usr-mounted")
    assert stream.saw("boot.multi-user")
    assert stream.saw("boot.login-ready")
    assert stream.saw("verity.corrupt")


@test(tier="unit", id="guest.prefers-reporter")
def from_log_uses_the_reporter_when_it_is_present():
    text = REPORTER + "[  OK  ] Mounted /sysusr/usr.\n"
    stream = EventStream.from_log(text)
    assert stream.producer == "reporter"
    assert stream.saw("boot.usr-mounted")

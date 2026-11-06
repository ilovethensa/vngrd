"""Tier 0: .pcrsig decoding, including the NUL padding that breaks json.loads."""

import json

from harness import pcrsig, test


def _section(doc: dict) -> bytes:
    return json.dumps(doc).encode() + b"\0" * 64


def _doc(entries: list[dict], bank: str = "sha256") -> dict:
    return {bank: entries}


@test(tier="unit", id="pcrsig.padding")
def pcrsig_ignores_nul_padding():
    """The section is JSON padded with NULs; load must not choke on it."""
    doc = _doc([{"pcrs": [11], "pol": "ab", "sig": "cd"}])
    loaded = pcrsig.load(_section(doc))
    assert loaded == doc, loaded


@test(tier="unit", id="pcrsig.pcr11")
def pcrsig_detects_pcr11_and_not_other_registers():
    assert pcrsig.has_pcr11(_doc([{"pcrs": [11]}]))
    assert not pcrsig.has_pcr11(_doc([{"pcrs": [7]}]))
    assert pcrsig.pcr_mask(_doc([{"pcrs": [7]}, {"pcrs": [5, 11]}])) == [5, 7, 11]


@test(tier="unit", id="pcrsig.phases-positional")
def pcrsig_assigns_phase_by_position_when_absent():
    """ukify omits the phase key, so position is the phase."""
    doc = _doc([{"pcrs": [11]}, {"pcrs": [11]}])
    assert pcrsig.phases(doc) == [
        ("sha256", "enter-initrd"),
        ("sha256", "enter-initrd:leave-initrd"),
    ]


@test(tier="unit", id="pcrsig.phases-explicit")
def pcrsig_prefers_an_explicit_phase():
    doc = _doc([{"pcrs": [11], "phase": "custom-phase"}])
    assert pcrsig.phases(doc) == [("sha256", "custom-phase")]


@test(tier="unit", id="pcrsig.count")
def pcrsig_counts_entries_across_banks():
    doc = {"sha256": [{"pcrs": [11]}], "sha1": [{"pcrs": [11]}, {"pcrs": [11]}]}
    assert pcrsig.count(doc) == 3
    assert pcrsig.banks(doc) == ["sha1", "sha256"]


@test(tier="unit", id="pcrsig.corrupt-pol")
def pcrsig_corrupts_one_hex_digit_in_place():
    """The mutation must flip exactly one hex digit and change nothing else."""
    doc = _doc([{"pcrs": [11], "pol": "abcdef", "sig": "1234"}])
    data = bytearray(_section(doc))
    offset, old, new = pcrsig.corrupt_pol(data, 0)
    assert data[offset] == ord(new)
    assert old != new
    assert new in "0123456789abcdef"
    reparsed = pcrsig.load(bytes(data))
    assert reparsed["sha256"][0]["sig"] == "1234"
    assert reparsed["sha256"][0]["pol"] != "abcdef"


@test(tier="unit", id="pcrsig.no-pol")
def pcrsig_reports_a_missing_pol():
    doc = _doc([{"pcrs": [11], "sig": "1234"}])
    try:
        pcrsig.pol_pos(_section(doc))
    except pcrsig.PcrsigError:
        return
    raise AssertionError("pol_pos accepted a section with no pol field")

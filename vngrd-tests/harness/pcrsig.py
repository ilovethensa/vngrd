"""Decode a UKI's .pcrsig section.

The section is JSON padded with NULs to the PE file alignment, so every entry
point decodes the first JSON value and ignores the padding. Anything that calls
json.loads() on the whole section fails with "Extra data" and reports a
perfectly good .pcrsig as broken.

This is the library form of the old tests/lib/pcrsig.py CLI; the functions are
the interface and the CLI is kept for ad-hoc debugging.
"""

from __future__ import annotations

import json
import sys

# The four phases systemd-measure signs by default, in the order it emits them.
# ukify writes the signed form without a "phase" key -- only pcrs/pkfp/pol/sig --
# so an entry's phase is its POSITION in the list.
KNOWN_PHASES = (
    "enter-initrd",
    "enter-initrd:leave-initrd",
    "enter-initrd:leave-initrd:sysinit",
    "enter-initrd:leave-initrd:sysinit:ready",
)

PCR11 = 11


class PcrsigError(ValueError):
    pass


def load(raw: bytes | str) -> dict:
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", "replace")
    if "{" not in raw:
        raise PcrsigError("no JSON object in the .pcrsig section")
    start = raw.index("{")
    value, _ = json.JSONDecoder().raw_decode(raw[start:].rstrip("\x00").strip())
    if not isinstance(value, dict):
        raise PcrsigError("expected {bank: [entries]}, got %s" % type(value).__name__)
    return value


def entries(doc: dict):
    for bank in sorted(doc):
        for entry in doc[bank]:
            yield bank, entry


def has_pcr11(doc: dict) -> bool:
    for _, entry in entries(doc):
        pcrs = entry.get("pcrs")
        if isinstance(pcrs, list) and PCR11 in pcrs:
            return True
    return False


def banks(doc: dict) -> list[str]:
    return sorted(doc)


def phases(doc: dict) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for bank, bank_entries in sorted(doc.items()):
        for index, entry in enumerate(bank_entries):
            name = entry.get("phase") or (KNOWN_PHASES[index] if index < len(KNOWN_PHASES) else None)
            if name:
                out.append((bank, name))
    return out


def count(doc: dict) -> int:
    return sum(len(v) for v in doc.values())


def pcr_mask(doc: dict) -> list[int]:
    found: set[int] = set()
    for _, entry in entries(doc):
        for pcr in entry.get("pcrs", []):
            found.add(int(pcr))
    return sorted(found)


def pol_pos(raw: bytes | str) -> int:
    """Byte offset of the first hex digit of the first "pol" value."""
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", "replace")
    index = raw.find('"pol"')
    if index < 0:
        raise PcrsigError('no "pol" field')
    quote = raw.find('"', index + len('"pol"'))
    if quote < 0:
        raise PcrsigError('"pol" field has no value')
    position = quote + 1
    while position < len(raw) and raw[position] not in "0123456789abcdefABCDEF":
        if raw[position] == '"':
            raise PcrsigError('"pol" field is empty')
        position += 1
    if position >= len(raw):
        raise PcrsigError('"pol" field has no hex digit')
    return position


def corrupt_pol(data: bytearray, section_offset: int) -> tuple[int, str, str]:
    """Flip one hex digit of the first "pol" in the section, in place.

    Returns (absolute_offset, old, new). One digit, same length and character
    class, so the section cannot resize and move every section's raw pointer --
    which would make the signature fail for the wrong reason.
    """
    raw = bytes(data[section_offset:])
    relative = pol_pos(raw)
    absolute = section_offset + relative
    old = chr(data[absolute])
    new = "0" if old != "0" else "1"
    data[absolute] = ord(new)
    return absolute, old, new


def _main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else ""
    raw = sys.stdin.buffer.read()
    if command == "pol-pos":
        print(pol_pos(raw))
        return 0
    doc = load(raw)
    if command == "has-pcr11":
        return 0 if has_pcr11(doc) else 1
    if command == "banks":
        print("\n".join(banks(doc)))
        return 0
    if command == "phases":
        for bank, name in phases(doc):
            print(bank, name)
        return 0
    if command == "count":
        print(count(doc))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))

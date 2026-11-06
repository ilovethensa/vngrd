"""Read the systemd-tpm2 token out of a raw disk image.

The LUKS2 header is not encrypted: keyslots, digests and tokens are in the
clear, so this reads them straight out of a disk file with no loop device, no
root and no cryptsetup. That is what lets a case assert on the SHAPE of the seal
rather than only on whether a boot happened to succeed.

Layout, measured on a cryptsetup-produced volume:

    0x0000  primary header: magic "LUKS\\xba\\xbe", version uint16be at +6,
            hdr_size uint64be at +8
    0x1000  the JSON, immediately
    hdr_size  secondary header, magic "SKUL\\xba\\xbe"

Library form of the old tests/lib/luks2.py CLI.
"""

from __future__ import annotations

import json
import struct
import sys

SECTOR = 512
SECTORS_TO_READ = 4096  # 2MiB, covers any hdr_size LUKS2 permits
MIN_HEADER = 4096

# Binary-header offsets. Both the primary and the secondary magic must be broken
# for a corruption case to be real: cryptsetup reads the secondary when the
# primary is unreadable and rewrites the primary on activation.
SECONDARY_HEADER_OFFSET = 0x4000


class Luks2Error(ValueError):
    pass


def decode(data: bytes) -> dict:
    if data[0:4] != b"LUKS" or data[4:6] != b"\xba\xbe":
        raise Luks2Error("no primary LUKS2 header (magic %r)" % data[0:6])
    (version,) = struct.unpack_from(">H", data, 6)
    if version != 2:
        raise Luks2Error("LUKS header version %d, not 2" % version)
    (hdr_size,) = struct.unpack_from(">Q", data, 8)
    if hdr_size <= MIN_HEADER or hdr_size > len(data):
        raise Luks2Error("implausible LUKS2 hdr_size %d" % hdr_size)

    blob = data[MIN_HEADER:hdr_size]
    if not blob.startswith(b"{"):
        raise Luks2Error("no JSON at 0x1000 (found %r)" % blob[:16])
    document, _ = json.JSONDecoder().raw_decode(blob.decode("utf-8"))
    if data[hdr_size : hdr_size + 4] != b"SKUL":
        raise Luks2Error("no SKUL secondary header at 0x%x; truncated read" % hdr_size)
    return document


def header_at(image, offset: int) -> dict:
    with open(image, "rb") as handle:
        handle.seek(offset)
        data = handle.read(SECTORS_TO_READ * SECTOR)
    if len(data) < MIN_HEADER:
        raise Luks2Error("partition at offset %d is too short for a LUKS2 header" % offset)
    return decode(data)


def tpm2_token(document: dict) -> dict | None:
    for token in document.get("tokens", {}).values():
        if token.get("type") == "systemd-tpm2":
            return token
    return None


def field(document: dict, name: str):
    token = tpm2_token(document)
    return (token or {}).get(name)


def keyslot_types(document: dict) -> list[str]:
    slots = document.get("keyslots", {})
    return [slots[slot].get("type", "?") for slot in sorted(slots)]


def has_recovery(document: dict) -> bool:
    """Whether the volume carries a systemd-recovery *token*.

    `systemd-recovery` is a token type, not a keyslot type: its keyslot is an
    ordinary `luks2` one. Looking at the keyslot types finds nothing and reports
    a recoverable volume as a brick.
    """
    return any(
        token.get("type") == "systemd-recovery"
        for token in document.get("tokens", {}).values()
    )


def _main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(__doc__)
        return 2
    offset = int(argv[1]) * SECTOR
    command = argv[2]
    document = header_at(argv[3], offset)
    if command == "raw":
        print(json.dumps(document, sort_keys=True))
        return 0
    if command == "keys":
        print("\n".join(keyslot_types(document)))
        return 0
    if command == "token":
        token = tpm2_token(document)
        if token is not None:
            print(json.dumps(token, sort_keys=True))
        return 0
    if command == "field":
        name = argv[4] if len(argv) > 4 else ""
        value = field(document, name)
        if value is None:
            print("")
        elif isinstance(value, str):
            print(value)
        else:
            print(json.dumps(value))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))

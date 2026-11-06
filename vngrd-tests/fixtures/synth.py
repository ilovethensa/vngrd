"""Synthetic artefacts for unit tests.

Unit tests must not depend on the built image, so the PE and LUKS2 containers
they exercise are constructed here from the format definitions.
"""

from __future__ import annotations

import json
import struct

PE32PLUS = 0x20B
NUM_DIRECTORIES = 16
CERT_TABLE_INDEX = 4
SECTION_HEADER_SIZE = 40


def _align(value: int, boundary: int) -> int:
    return (value + boundary - 1) // boundary * boundary


def make_pe32plus(sections: dict[str, bytes], cert: bytes | None = None) -> bytes:
    """Construct a minimal but structurally valid PE32+ image.

    Section keys longer than eight characters are truncated, matching the PE
    section-name limit.
    """
    names = list(sections)
    size_optional = 112 + 8 * NUM_DIRECTORIES
    optional_offset = 0x80 + 4 + 20
    section_table = optional_offset + size_optional
    data_start = _align(section_table + len(names) * SECTION_HEADER_SIZE, 0x200)

    headers = bytearray(data_start)
    headers[0:2] = b"MZ"
    struct.pack_into("<I", headers, 0x3C, 0x80)
    headers[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", headers, 0x84, 0x8664, len(names))
    struct.pack_into("<H", headers, 0x84 + 16, size_optional)
    struct.pack_into("<H", headers, 0x84 + 18, 0x0022)
    struct.pack_into("<H", headers, optional_offset, PE32PLUS)
    struct.pack_into("<I", headers, optional_offset + 108, NUM_DIRECTORIES)

    body = bytearray()
    cursor = data_start
    directory_entries = [(0, 0)] * NUM_DIRECTORIES
    for index, name in enumerate(names):
        payload = sections[name]
        raw_offset = cursor
        body += payload
        padding = _align(len(body), 0x200) - len(body)
        body += b"\0" * padding
        cursor += len(payload) + padding
        base = section_table + index * SECTION_HEADER_SIZE
        encoded = name.encode()[:8]
        headers[base : base + 8] = encoded + b"\0" * (8 - len(encoded))
        struct.pack_into("<IIII", headers, base + 8, len(payload), 0x1000, len(payload), raw_offset)

    if cert is not None:
        cert_offset = data_start + len(body)
        directory_entries[CERT_TABLE_INDEX] = (cert_offset, len(cert))
        body += cert
    for index, (va, size) in enumerate(directory_entries):
        struct.pack_into("<II", headers, optional_offset + 112 + index * 8, va, size)

    return bytes(headers) + bytes(body)


def make_luks2(document: dict) -> bytes:
    """Construct a minimal LUKS2 header whose magic, JSON and secondary header parse."""
    blob = json.dumps(document).encode()
    allocated = _align(len(blob), 4096)
    hdr_size = 4096 + allocated
    data = bytearray(hdr_size + 4)
    data[0:6] = b"LUKS\xba\xbe"
    struct.pack_into(">H", data, 6, 2)
    struct.pack_into(">Q", data, 8, hdr_size)
    data[4096 : 4096 + len(blob)] = blob
    data[hdr_size : hdr_size + 4] = b"SKUL"
    return bytes(data)


def default_tpm2_document(**overrides) -> dict:
    document = {
        "keyslots": {
            "0": {"type": "luks2"},
            # systemd-recovery is a TOKEN type, not a keyslot type: the recovery
            # keyslot is an ordinary `luks2` one and the token is what marks it
            # (harness/luks2.has_recovery looks at the tokens, and its docstring
            # is explicit about why). A keyslot literally typed "systemd-recovery"
            # is not a shape any systemd produces.
            "1": {"type": "luks2"},
        },
        "tokens": {
            "0": {
                "type": "systemd-tpm2",
                "tpm2-pcrs": [7],
                "tpm2-pcr-bank": "sha256",
                "tpm2-pubkey": "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n",
                "tpm2_pubkey_pcrs": [11],
                "tpm2-policy-hash": "abcd",
            },
            "1": {
                "type": "systemd-recovery",
                "keyslots": ["1"],
            },
        },
        "digests": {},
    }
    document["tokens"]["0"].update(overrides)
    return document

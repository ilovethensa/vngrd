#!/usr/bin/env python3
"""Extend a GPT's usable range to the whole device, and put the backup header at
the end. For the vngrd image, where the partitions occupy only the first ~709 MB
of a 4 GiB disk and systemd-repart has to be able to create the LUKS2 root in what
is left.

Why this exists rather than an sfdisk incantation:

  * `os.truncate` pads the file but leaves the table describing the old, smaller
    device. The kernel then reports
        GPT:Primary header thinks Alt. header is not at the end of the disk.
        GPT:1452064 != 8388607
    and systemd-repart refuses to operate on the device, so the first boot never
    creates the root volume.

  * `sfdisk --relocate gpt-bak-std` (the only relocation operation util-linux
    2.42 implements, disk-utils/sfdisk.c:1490-1507) does move the backup header to
    the last LBA. It does NOT extend the usable range.

  * `sfdisk -d` + rewrite does not help either: the dump carries `last-lba:` and
    sfdisk derives the header's last-usable from the partition list, so the value
    never grows. Editing the dump's `last-lba:` is also ignored.

So: patch the two GPT headers directly. The only fiddly part is the header CRC,
which is CRC-32 (IEEE) over header_size bytes with the CRC field zeroed. That is
what the spec says and what the kernel verifies, so we do exactly that and then
check the result by re-reading the headers.

Idempotent: a second run is a no-op. Exits non-zero with a reason rather than
writing a table it could not verify.
"""

import binascii
import os
import struct
import sys

GPT_SIGNATURE = b"EFI PART"
PRIMARY_LBA = 1
SECTOR = 512


def header_crc(hdr: bytes) -> int:
    """CRC-32 of the header with its own CRC field zeroed, per UEFI 2.10 5.2.3."""
    size = struct.unpack_from("<H", hdr, 12)[0]
    zeroed = bytearray(hdr[:size])
    zeroed[16:20] = b"\0\0\0\0"
    return binascii.crc32(bytes(zeroed)) & 0xFFFFFFFF


def read_header(f, lba):
    f.seek(lba * SECTOR)
    raw = f.read(SECTOR)
    if len(raw) < 92 or raw[:8] != GPT_SIGNATURE:
        return None
    return raw


def patch(f, lba, *, backup_lba, first_usable, last_usable, current_lba, seed=None):
    """Write the header at `lba`.

    `seed` supplies the bytes to start from when nothing is there yet. Padding a
    file with truncate() does not create a backup GPT header -- it just extends the
    file -- so on a freshly padded image the last LBA is zeros and the header has
    to be built from the primary's.
    """
    existing = read_header(f, lba)
    if existing is None:
        if seed is None:
            raise SystemExit(f"no GPT header at LBA {lba} and no seed to build one from")
        existing = seed
    hdr = bytearray(existing)
    struct.pack_into("<Q", hdr, 0x18, current_lba)   # current LBA
    struct.pack_into("<Q", hdr, 0x20, backup_lba)    # alternate LBA
    struct.pack_into("<Q", hdr, 0x28, first_usable)  # first usable LBA
    struct.pack_into("<Q", hdr, 0x30, last_usable)   # last usable LBA
    struct.pack_into("<I", hdr, 0x10, 0)             # zero the CRC field
    size = struct.unpack_from("<H", hdr, 12)[0]
    struct.pack_into("<I", hdr, 0x10, binascii.crc32(bytes(hdr[:size])) & 0xFFFFFFFF)
    f.seek(lba * SECTOR)
    f.write(bytes(hdr))
    return bytes(hdr)


def main(path):
    size = os.path.getsize(path)
    if size % SECTOR:
        raise SystemExit(f"image size {size} is not a multiple of {SECTOR}")
    total = size // SECTOR

    with open(path, "r+b") as f:
        primary = read_header(f, PRIMARY_LBA)
        if primary is None:
            raise SystemExit(f"{path}: no primary GPT header at LBA {PRIMARY_LBA}")

        first_usable = struct.unpack_from("<Q", primary, 0x28)[0]
        # The last LBA holds the backup header and is never allocatable.
        last_usable = total - 2
        backup_lba = total - 1

        cur_backup = struct.unpack_from("<Q", primary, 0x20)[0]
        cur_last = struct.unpack_from("<Q", primary, 0x30)[0]
        if cur_backup == backup_lba and cur_last == last_usable:
            print(f"already extended: backup={cur_backup} last_usable={cur_last}")
            return 0

        # The primary header's "alternate LBA" must be the last LBA, and the
        # header living there must point back at LBA 1. Writing the primary first
        # and the backup second means a crash in between leaves a device whose
        # primary header advertises a backup that is not yet there -- the same
        # state the kernel complains about. Writing the backup first is the safer
        # order: a device with a stale primary and a fresh backup is still
        # readable, because the kernel trusts the primary.
        patch(f, backup_lba, backup_lba=PRIMARY_LBA, first_usable=first_usable,
              last_usable=last_usable, current_lba=backup_lba, seed=primary)
        patch(f, PRIMARY_LBA, backup_lba=backup_lba, first_usable=first_usable,
              last_usable=last_usable, current_lba=PRIMARY_LBA)
        f.flush()
        os.fsync(f.fileno())

    # Verify from the written bytes rather than trusting the writes.
    with open(path, "rb") as f:
        for name, lba, want_cur, want_bak in (
            ("primary", PRIMARY_LBA, PRIMARY_LBA, backup_lba),
            ("backup", backup_lba, backup_lba, PRIMARY_LBA),
        ):
            raw = read_header(f, lba)
            if raw is None:
                raise SystemExit(f"{path}: {name} header missing at LBA {lba}")
            got_cur = struct.unpack_from("<Q", raw, 0x18)[0]
            got_bak = struct.unpack_from("<Q", raw, 0x20)[0]
            got_last = struct.unpack_from("<Q", raw, 0x30)[0]
            if (got_cur, got_bak, got_last) != (want_cur, want_bak, last_usable):
                raise SystemExit(
                    f"{path}: {name} header is current={got_cur} backup={got_bak} "
                    f"last_usable={got_last}, expected "
                    f"{want_cur}/{want_bak}/{last_usable}")
            stored = struct.unpack_from("<I", raw, 0x10)[0]
            if stored != header_crc(raw):
                raise SystemExit(f"{path}: {name} header CRC mismatch")
            print(f"ok {name:7} LBA {lba:<8} backup={got_bak} last_usable={got_last} crc=valid")

    print(f"free space: {last_usable - 1452031} sectors "
          f"(~{(last_usable - 1452031) * 512 // (1 << 20)} MiB) after the last partition")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else ""))

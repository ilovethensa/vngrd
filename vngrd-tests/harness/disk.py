"""Raw disk images: GPT reading, byte-level mutation, and the ESP via mtools.

Mutations are `dd seek=` equivalents in Python: no loop device, no root, and
every byte written is explicit. The ESP is exposed as a small wrapper over
mtools, with the two traps the shell harness documented baked in: `-o` on every
copy, and a recursive walk because a plain directory listing comes back empty
for the UKI's VFAT long name.
"""

from __future__ import annotations

import os
import struct
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .errors import ConfigError
from .tools import Tools

GPT_SIGNATURE = b"EFI PART"
ESP_TYPE_GUID = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"


def format_guid(raw: bytes) -> str:
    """A GPT GUID is mixed-endian: the first three fields are little-endian."""
    if len(raw) != 16:
        raise ValueError("a GUID is 16 bytes")
    d1, d2, d3 = struct.unpack_from("<IHH", raw, 0)
    d4 = raw[8:10]
    d5 = raw[10:16]
    return "%08x-%04x-%04x-%s-%s" % (d1, d2, d3, d4.hex(), d5.hex())


@dataclass(frozen=True)
class Partition:
    number: int
    type_guid: str
    unique_guid: str
    first_lba: int
    last_lba: int
    name: str

    @property
    def sectors(self) -> int:
        return self.last_lba - self.first_lba + 1

    @property
    def offset(self) -> int:
        return self.first_lba * 512

    @property
    def size(self) -> int:
        return self.sectors * 512


class Gpt:
    def __init__(self, partitions: list[Partition], disk_guid: str):
        self.partitions = partitions
        self.disk_guid = disk_guid

    @classmethod
    def load(cls, image: str | os.PathLike) -> "Gpt":
        with open(image, "rb") as handle:
            handle.seek(512)
            header = handle.read(92)
            if header[:8] != GPT_SIGNATURE:
                raise ConfigError("%s has no GPT header at LBA 1" % image)
            (entries_lba,) = struct.unpack_from("<Q", header, 72)
            (num_entries,) = struct.unpack_from("<I", header, 80)
            (entry_size,) = struct.unpack_from("<I", header, 84)
            disk_guid = format_guid(header[56:72])
            handle.seek(entries_lba * 512)
            table = handle.read(num_entries * entry_size)

        partitions: list[Partition] = []
        for index in range(num_entries):
            base = index * entry_size
            entry = table[base : base + entry_size]
            if len(entry) < 128:
                break
            type_guid = format_guid(entry[0:16])
            if type_guid == "00000000-0000-0000-0000-000000000000":
                continue
            unique_guid = format_guid(entry[16:32])
            first_lba, last_lba = struct.unpack_from("<QQ", entry, 32)
            name = entry[56:128].decode("utf-16-le", "replace").split("\0", 1)[0]
            partitions.append(
                Partition(index + 1, type_guid, unique_guid, first_lba, last_lba, name)
            )
        return cls(partitions, disk_guid)

    def by_label(self, label: str) -> Partition | None:
        for partition in self.partitions:
            if partition.name == label:
                return partition
        return None

    def require_label(self, label: str) -> Partition:
        partition = self.by_label(label)
        if partition is None:
            raise ConfigError(
                "no partition labelled %r (have: %s)"
                % (label, ", ".join(p.name or "<unnamed>" for p in self.partitions))
            )
        return partition

    def esp(self) -> Partition:
        for partition in self.partitions:
            if partition.type_guid == ESP_TYPE_GUID:
                return partition
        raise ConfigError("no ESP partition in the partition table")




def read_at(image: str | os.PathLike, offset: int, length: int) -> bytes:
    with open(image, "rb") as handle:
        handle.seek(offset)
        return handle.read(length)


def write_at(image: str | os.PathLike, offset: int, payload: bytes) -> None:
    with open(image, "rb") as handle:
        handle.seek(offset)
        original = handle.read(len(payload))
    if original == payload:
        raise ConfigError(
            "mutation at %d wrote the bytes already there; it would have been a no-op" % offset
        )
    with open(image, "r+b") as handle:
        handle.seek(offset)
        handle.write(payload)


def zero_at(image: str | os.PathLike, offset: int, length: int) -> None:
    write_at(image, offset, b"\0" * length)


def flip_at(image: str | os.PathLike, offset: int) -> None:
    (byte,) = read_at(image, offset, 1)
    write_at(image, offset, bytes([byte ^ 0x01]))


def extract(image: str | os.PathLike, offset: int, length: int, dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with open(image, "rb") as source, open(dest, "wb") as target:
        source.seek(offset)
        remaining = length
        while remaining > 0:
            chunk = source.read(min(remaining, 1 << 20))
            if not chunk:
                break
            target.write(chunk)
            remaining -= len(chunk)
    return dest


def replace_region(image: str | os.PathLike, offset: int, dest_region: str | os.PathLike) -> None:
    """Copy a file back over a region of the disk image."""
    with open(dest_region, "rb") as handle:
        payload = handle.read()
    with open(image, "r+b") as target:
        target.seek(offset)
        target.write(payload)




class Esp:
    """A FAT image (extracted from the disk, or a standalone file) read via mtools."""

    def __init__(self, path: Path, tools: Tools):
        self.path = Path(path)
        self.tools = tools

    @classmethod
    def extract_from(cls, disk: Path, dest: Path, tools: Tools) -> "Esp":
        gpt = Gpt.load(disk)
        esp = gpt.esp()
        extract(disk, esp.offset, esp.size, dest)
        return cls(dest, tools)

    def _run(self, program: str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        binary = self.tools.require(program)
        env = dict(os.environ)
        env["MTOOLS_SKIP_CHECK"] = "1"
        return subprocess.run(
            [binary, "-i", str(self.path), *args], env=env, capture_output=True, text=True, check=check
        )

    def walk(self) -> str:
        return self._run("mdir", "-/", "::").stdout

    def uki_path(self) -> str:
        """Path of the image UKI within the ESP.

        A plain `mdir ::/EFI/Linux` lists the directory as empty: the entry is a
        VFAT long name whose 8.3 alias only surfaces in a recursive walk.
        """
        for line in self.walk().splitlines():
            fields = line.split()
            if not fields:
                continue
            name = fields[-1]
            if name.endswith(".efi") and name.startswith("vngrd-"):
                return "EFI/Linux/%s" % name
        raise ConfigError("no vngrd-*.efi under ::/EFI/Linux on %s" % self.path)

    def any_efi(self) -> list[str]:
        found = []
        for line in self.walk().splitlines():
            name = line.split()[-1] if line.split() else ""
            if name.endswith(".efi"):
                found.append(name)
        return found

    def exists(self, remote: str) -> bool:
        return self._run("mdir", "::/%s" % remote, check=False).returncode == 0

    def get(self, remote: str, dest: Path) -> Path:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.unlink(missing_ok=True)
        self._run("mcopy", "::/%s" % remote, str(dest))
        if not dest.is_file() or dest.stat().st_size == 0:
            raise ConfigError("mcopy extracted nothing for ::/%s" % remote)
        return dest

    def put(self, local: Path, remote: str) -> None:
        # -o is not optional: without it mcopy exits 1 *silently* and leaves the
        # image untouched, which reads as a successful plant that never happened.
        self._run("mcopy", "-o", str(local), "::/%s" % remote)

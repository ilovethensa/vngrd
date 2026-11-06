"""A minimal, dependency-free PE32+ reader/writer.

Replaces the shell harness's `objdump -h` + `dd` + heredoc-Python dance with one
parser that reads sections by name, reads and clears the certificate table, and
mutates bytes without rewriting the file (the old `objcopy --dump-section`
rewrote its input and destroyed the signature it was only trying to read).

Only what a UKI needs is implemented: headers, section table and data
directories.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

DOS_MAGIC = b"MZ"
PE_MAGIC = b"PE\0\0"
PE32_MAGIC = 0x10B
PE32PLUS_MAGIC = 0x20B
CERT_TABLE_INDEX = 4


class PeError(ValueError):
    pass


@dataclass(frozen=True)
class Section:
    name: str
    virtual_size: int
    virtual_address: int
    raw_size: int
    raw_offset: int


@dataclass(frozen=True)
class DataDirectory:
    virtual_address: int
    size: int


class Pe:
    """A parsed PE image over an immutable bytes buffer."""

    def __init__(self, data: bytes):
        self.data = data
        self._parse()

    def _parse(self) -> None:
        if len(self.data) < 0x40 or self.data[:2] != DOS_MAGIC:
            raise PeError("not a PE image (no MZ)")
        (self.pe_offset,) = struct.unpack_from("<I", self.data, 0x3C)
        if self.data[self.pe_offset : self.pe_offset + 4] != PE_MAGIC:
            raise PeError("no PE signature at 0x%x" % self.pe_offset)

        coff = self.pe_offset + 4
        (self.machine, self.num_sections) = struct.unpack_from("<HH", self.data, coff)
        (self.size_of_optional_header,) = struct.unpack_from("<H", self.data, coff + 16)
        self.optional_offset = coff + 20

        (self.magic,) = struct.unpack_from("<H", self.data, self.optional_offset)
        if self.magic not in (PE32_MAGIC, PE32PLUS_MAGIC):
            raise PeError("unknown optional header magic 0x%x" % self.magic)
        self.is_pe32plus = self.magic == PE32PLUS_MAGIC

        dirs_offset = self.optional_offset + (112 if self.is_pe32plus else 96)
        num_dirs_offset = self.optional_offset + (108 if self.is_pe32plus else 92)
        (self.num_directories,) = struct.unpack_from("<I", self.data, num_dirs_offset)
        self.directories: list[DataDirectory] = []
        for index in range(self.num_directories):
            base = dirs_offset + index * 8
            va, size = struct.unpack_from("<II", self.data, base)
            self.directories.append(DataDirectory(va, size))

        self.sections: list[Section] = []
        table = self.optional_offset + self.size_of_optional_header
        for index in range(self.num_sections):
            base = table + index * 40
            raw = self.data[base : base + 8]
            name = raw.split(b"\0", 1)[0].decode("latin-1")
            virtual_size, virtual_address, raw_size, raw_offset = struct.unpack_from(
                "<IIII", self.data, base + 8
            )
            self.sections.append(Section(name, virtual_size, virtual_address, raw_size, raw_offset))


    def section_names(self) -> list[str]:
        return [section.name for section in self.sections]

    def section(self, name: str) -> Section:
        for section in self.sections:
            if section.name == name:
                return section
        raise PeError("no section %r (have: %s)" % (name, ", ".join(self.section_names())))

    def has_section(self, name: str) -> bool:
        return any(section.name == name for section in self.sections)

    def section_data(self, name: str) -> bytes:
        section = self.section(name)
        end = section.raw_offset + section.raw_size
        if end > len(self.data):
            raise PeError("section %s runs past the end of the image" % name)
        return self.data[section.raw_offset : end]

    def section_text(self, name: str) -> str:
        return self.section_data(name).rstrip(b"\0").decode("utf-8", "replace")


    def cert_table(self) -> DataDirectory:
        if len(self.directories) <= CERT_TABLE_INDEX:
            raise PeError("no certificate table data directory")
        return self.directories[CERT_TABLE_INDEX]

    def has_cert_table(self) -> bool:
        try:
            entry = self.cert_table()
        except PeError:
            return False
        return bool(entry.virtual_address) and entry.virtual_address + entry.size <= len(self.data)

    def strip_cert_table(self) -> bytes:
        """Return the image with the certificate table removed and dir[4] zeroed.

        systemd-sbsign appends a new table without updating dir[4], so re-signing
        an already-signed UKI silently keeps the *old* signature. Every re-sign
        goes through here first.
        """
        entry = self.cert_table()
        if not entry.virtual_address or entry.virtual_address + entry.size > len(self.data):
            raise PeError("no plausible certificate table to strip")
        data = bytearray(self.data[: entry.virtual_address])
        dirs_offset = self.optional_offset + (112 if self.is_pe32plus else 96)
        struct.pack_into("<II", data, dirs_offset + CERT_TABLE_INDEX * 8, 0, 0)
        return bytes(data)


def read(path) -> Pe:
    with open(path, "rb") as handle:
        return Pe(handle.read())


def mutate_section(path, section: str, offset: int, payload: bytes) -> None:
    """Overwrite *payload* at *offset* inside *section*, in place."""
    image = read(path)
    target = image.section(section)
    absolute = target.raw_offset + offset
    if offset < 0 or offset + len(payload) > target.raw_size:
        raise PeError("write of %d bytes at %s+%d is outside the section" % (len(payload), section, offset))
    with open(path, "r+b") as handle:
        handle.seek(absolute)
        handle.write(payload)

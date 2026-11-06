"""UKI manipulation: read sections, mutate one byte, strip and re-sign.

The PE parsing lives in pe.py; this is the UKI-shaped layer on top: named
sections, the embedded command line, .pcrsig access, and the signing path that
must strip the old certificate table first.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from . import pcrsig, pe
from .errors import ConfigError
from .tools import Tools

SECTIONS_OF_INTEREST = (".linux", ".initrd", ".cmdline", ".osrel", ".uname", ".pcrsig", ".pcrpkey")


class UkiError(ValueError):
    pass


@dataclass
class Uki:
    path: Path
    tools: Tools


    def _pe(self) -> pe.Pe:
        return pe.read(self.path)

    @property
    def sections(self) -> list[str]:
        return self._pe().section_names()

    def has_section(self, name: str) -> bool:
        return self._pe().has_section(name)

    def section_bytes(self, name: str) -> bytes:
        return self._pe().section_data(name)

    def section_text(self, name: str) -> str:
        return self._pe().section_text(name)

    def cmdline(self) -> str:
        text = self.section_text(".cmdline")
        return text.splitlines()[0] if text else ""

    def cmdline_entries(self) -> list[str]:
        return self.cmdline().split()

    def option(self, name: str) -> str | None:
        prefix = name + "="
        for entry in self.cmdline_entries():
            if entry.startswith(prefix):
                return entry[len(prefix) :]
        return None

    def usrhash(self) -> str | None:
        return self.option("usrhash")

    def pcrsig_doc(self) -> dict:
        if not self.has_section(".pcrsig"):
            raise UkiError("the UKI has no .pcrsig section")
        return pcrsig.load(self.section_bytes(".pcrsig"))

    def has_pcrsig(self) -> bool:
        return self.has_section(".pcrsig")


    def copy_to(self, dest: Path) -> "Uki":
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.path, dest)
        return Uki(dest, self.tools)

    def flip_byte(self, section: str, offset: int) -> None:
        target = self._pe().section(section)
        if offset < 0 or offset >= target.raw_size:
            raise UkiError("offset %d is outside %s" % (offset, section))
        absolute = target.raw_offset + offset
        with open(self.path, "r+b") as handle:
            handle.seek(absolute)
            (byte,) = handle.read(1)
            handle.seek(absolute)
            handle.write(bytes([byte ^ 0x01]))

    def replace_text(self, section: str, old: str, new: str) -> int:
        """Replace *old* with *new* of identical length inside a section.

        Returns the number of replacements. A length change would resize the
        section and move every other section's raw pointer, invalidating the
        signature for the wrong reason.
        """
        if len(old) != len(new):
            raise UkiError("replacement must be the same length (%d != %d)" % (len(old), len(new)))
        target = self._pe().section(section)
        with open(self.path, "rb") as handle:
            handle.seek(target.raw_offset)
            blob = bytearray(handle.read(target.raw_size))
        count = blob.count(old.encode())
        if count == 0:
            raise UkiError("%r not found in %s" % (old, section))
        blob = blob.replace(old.encode(), new.encode())
        with open(self.path, "r+b") as handle:
            handle.seek(target.raw_offset)
            handle.write(bytes(blob))
        return count

    def corrupt_pcrsig_pol(self) -> tuple[int, str, str]:
        section = self._pe().section(".pcrsig")
        with open(self.path, "rb") as handle:
            handle.seek(section.raw_offset)
            data = bytearray(handle.read(section.raw_size))
        _, old, new = pcrsig.corrupt_pol(data, 0)
        with open(self.path, "r+b") as handle:
            handle.seek(section.raw_offset)
            handle.write(bytes(data))
        return section.raw_offset, old, new


    def signature_ok(self, certificate: str | os.PathLike) -> bool:
        if not self.tools.sbverify:
            raise ConfigError("sbverify is not available")
        result = subprocess.run(
            [self.tools.sbverify, "--cert", str(certificate), str(self.path)],
            capture_output=True,
            text=True,
        )
        return result.returncode == 0

    def sign(self, key: str, certificate: str, dest: Path) -> "Uki":
        """Re-sign with the image's systemd-sbsign, stripping the old table first.

        Do NOT use sbsign from sbsigntools: it shifts every section's
        PointerToRawData by one and produces a kernel that will not load.
        """
        signer = self.tools.systemd_sbsign
        if not signer:
            raise ConfigError("systemd-sbsign not found in the built rootfs")
        if not (os.access(key, os.R_OK) and os.access(certificate, os.R_OK)):
            raise ConfigError("cannot read signing key or certificate")
        stripped = self._pe().strip_cert_table()
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "stripped.efi"
            source.write_bytes(stripped)
            dest.parent.mkdir(parents=True, exist_ok=True)
            result = subprocess.run(
                [
                    signer,
                    "sign",
                    "--private-key",
                    str(key),
                    "--certificate",
                    str(certificate),
                    str(source),
                    "--output",
                    str(dest),
                ],
                env=self.tools.sbsign_env(),
                capture_output=True,
                text=True,
            )
            if result.returncode != 0 or not dest.is_file() or dest.stat().st_size == 0:
                raise ConfigError(
                    "systemd-sbsign failed: %s" % (result.stderr.strip() or result.stdout.strip())
                )
        return Uki(dest, self.tools)


def tamper_linux_byte(uki: Uki) -> int:
    """Flip one byte in the middle of .linux, the mutation t1 and t5 share."""
    offset = 0x1000
    target = uki._pe().section(".linux")
    if offset >= target.raw_size:
        offset = max(1, target.raw_size // 2)
    uki.flip_byte(".linux", offset)
    return offset

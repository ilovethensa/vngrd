"""The built image: the artefact under test for the image tier.

Everything here is host-side and needs no VM: the raw disk's GPT, the UKI's
sections and embedded command line, the verity root hash, and the SPLIT
artefacts mkosi publishes alongside.
"""

from __future__ import annotations

import functools
import hashlib
import lzma
from dataclasses import dataclass
from pathlib import Path

from .disk import Esp, Gpt
from .errors import ConfigError
from .paths import Paths
from .tools import Tools
from .uki import Uki
from .util import writable_dir


def decompress_xz(source: Path, dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_file() and dest.stat().st_mtime >= source.stat().st_mtime and dest.stat().st_size:
        return dest
    with lzma.open(source, "rb") as src, open(dest, "wb") as out:
        while True:
            chunk = src.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
    if dest.stat().st_size == 0:
        raise ConfigError("%s decompressed to nothing" % source)
    return dest


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


@dataclass
class ImageArtifact:
    paths: Paths
    version: str
    tools: Tools
    cache_dir: Path

    @classmethod
    def load(cls, paths: Paths, version: str, tools: Tools, cache_dir: Path | None = None) -> "ImageArtifact":
        cache = cache_dir or writable_dir(paths.cache, paths.tests / ".cache")
        artifact = cls(paths=paths, version=version, tools=tools, cache_dir=cache)
        if not artifact.roothash_file.is_file():
            raise ConfigError("no %s; build the image first" % artifact.roothash_file)
        return artifact


    @property
    def name(self) -> str:
        return "vngrd_%s" % self.version

    @property
    def roothash_file(self) -> Path:
        return self.paths.roothash(self.version)

    @property
    def raw(self) -> Path:
        return self.paths.raw(self.version)

    @property
    def uki_xz(self) -> Path:
        return self.paths.uki_xz(self.version)

    @property
    def vmlinuz(self) -> Path:
        return self.paths.image_out / ("%s.vmlinuz" % self.name)

    @property
    def initrd(self) -> Path:
        return self.paths.image_out / ("%s.initrd" % self.name)

    @property
    def checksums_file(self) -> Path:
        return self.paths.image_out / "SHA256SUMS"


    @property
    def roothash(self) -> str:
        value = self.roothash_file.read_text().strip()
        if len(value) != 64:
            raise ConfigError("%s is not a 64-hex root hash" % self.roothash_file)
        return value

    @property
    def usr_partuuid(self) -> str:
        return _dashed(self.roothash[:32])

    @property
    def verity_partuuid(self) -> str:
        return _dashed(self.roothash[32:])

    @functools.cached_property
    def uki(self) -> Uki:
        if not self.uki_xz.is_file():
            raise ConfigError("no published UKI at %s" % self.uki_xz)
        decompressed = decompress_xz(self.uki_xz, self.cache_dir / ("%s.efi" % self.name))
        return Uki(decompressed, self.tools)

    @functools.cached_property
    def gpt(self) -> Gpt:
        return Gpt.load(self.raw)

    @functools.cached_property
    def checksums(self) -> dict[str, str]:
        sums: dict[str, str] = {}
        if not self.checksums_file.is_file():
            return sums
        for line in self.checksums_file.read_text().splitlines():
            parts = line.split()
            if len(parts) == 2:
                sums[parts[1]] = parts[0]
        return sums

    def verify_checksums(self, exclude: tuple[str, ...] = ()) -> list[str]:
        """Return the names of files whose published hash does not match.

        *exclude* exists for the 4GiB `.raw`, which is correct but slow to hash;
        the split artefacts are verified instead.
        """
        mismatches: list[str] = []
        for name, expected in self.checksums.items():
            if name in exclude:
                continue
            candidate = self.paths.image_out / name
            if candidate.is_file() and sha256(candidate) != expected:
                mismatches.append(name)
        return mismatches

    def esp(self, dest: Path) -> Esp:
        return Esp.extract_from(self.raw, dest, self.tools)


def _dashed(hex32: str) -> str:
    return "%s-%s-%s-%s-%s" % (
        hex32[0:8],
        hex32[8:12],
        hex32[12:16],
        hex32[16:20],
        hex32[20:32],
    )

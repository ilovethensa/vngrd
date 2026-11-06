"""Repository layout resolution.

Everything the suite needs to find is derived here, once, from the location of
this file. No case hardcodes a path: a case asks the Session for the artefact or
the tool it needs, and the Session asks Paths.

Environment overrides exist so the suite can be pointed at a different checkout
or a staged output tree without editing code:

    VNGRO_REPO        the monorepo root (parent of vngrd-image)
    VNGRO_IMAGE_OUT   the image output directory
    VNGRO_STATE       writable state root (provisioned machines, logs)
    VNGRO_CACHE       writable cache root (content-addressed fixtures)
    VNGRO_TOOLS       the mkosi.tools usr/ tree
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _env_path(name: str) -> Path | None:
    value = os.environ.get(name, "").strip()
    return Path(value).resolve() if value else None


def find_repo_root(start: Path) -> Path:
    """Walk up from *start* until a directory that looks like the monorepo."""
    for candidate in [start, *start.parents]:
        if (candidate / "vngrd-image").is_dir() and (candidate / "output").is_dir():
            return candidate
    raise RuntimeError(
        "could not find the vngrd monorepo root above %s; "
        "set VNGRO_REPO to the checkout that contains vngrd-image/" % start
    )


def _xdg(name: str, default: str) -> Path:
    value = os.environ.get(name, "").strip()
    return Path(value) if value else Path.home() / default


@dataclass(frozen=True)
class Paths:
    tests: Path
    repo: Path
    image_src: Path
    image_out: Path
    rootfs_out: Path
    kernel_out: Path
    initrd_out: Path
    tools: Path
    state: Path
    cache: Path

    @classmethod
    def load(cls) -> "Paths":
        tests = Path(__file__).resolve().parent.parent
        repo = _env_path("VNGRO_REPO") or find_repo_root(tests)
        image_out = _env_path("VNGRO_IMAGE_OUT") or repo / "output" / "image"
        tools = _env_path("VNGRO_TOOLS") or repo / "vngrd-image" / "mkosi.tools" / "usr"
        state = _env_path("VNGRO_STATE") or _xdg("XDG_STATE_HOME", ".local/state") / "vngrd" / "tests"
        cache = _env_path("VNGRO_CACHE") or _xdg("XDG_CACHE_HOME", ".cache") / "vngrd" / "tests"
        return cls(
            tests=tests,
            repo=repo,
            image_src=repo / "vngrd-image",
            image_out=image_out,
            rootfs_out=repo / "output" / "rootfs",
            kernel_out=repo / "output" / "kernel",
            initrd_out=repo / "output" / "initrd-root",
            tools=tools,
            state=state,
            cache=cache,
        )


    def versions(self) -> list[str]:
        """Image versions present, newest first, from the .roothash sidecars."""
        if not self.image_out.is_dir():
            return []
        found = []
        for entry in self.image_out.glob("vngrd_*.roothash"):
            found.append(entry.name[len("vngrd_") : -len(".roothash")])
        return sorted(found, key=_version_key, reverse=True)

    def roothash(self, version: str) -> Path:
        return self.image_out / f"vngrd_{version}.roothash"

    def raw(self, version: str) -> Path:
        return self.image_out / f"vngrd_{version}.raw"

    def uki_xz(self, version: str) -> Path:
        return self.image_out / f"vngrd_{version}.efi.xz"

    def tool(self, name: str) -> Path | None:
        candidate = self.tools / "bin" / name
        return candidate if candidate.exists() else None

    def ensure_state(self) -> Path:
        self.state.mkdir(parents=True, exist_ok=True)
        return self.state

    def ensure_cache(self) -> Path:
        self.cache.mkdir(parents=True, exist_ok=True)
        return self.cache


def _version_key(version: str) -> tuple:
    key: list[object] = []
    for part in version.replace("-", ".").split("."):
        key.append((0, int(part)) if part.isdigit() else (1, part))
    return tuple(key)

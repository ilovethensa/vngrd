"""Small shared helpers."""

from __future__ import annotations

from pathlib import Path

from . import log
from .errors import ConfigError


def writable_dir(preferred: Path, fallback: Path) -> Path:
    """Return the first of *preferred*/*fallback* that can actually be written.

    The fallback exists for sandboxed or CI runs where $XDG_* is read-only. The
    repository-local directory is gitignored.
    """
    for candidate in (preferred, fallback):
        try:
            candidate.mkdir(parents=True, exist_ok=True)
            probe = candidate / ".writable"
            probe.write_text("")
            probe.unlink()
            if candidate != preferred:
                log.note("%s is not writable; using %s" % (preferred, candidate))
            return candidate
        except OSError:
            continue
    raise ConfigError("no writable directory (%s or %s)" % (preferred, fallback))


def parse_scalars(text: str) -> list[int]:
    """Parse '7', '5,7', '5 7', '[5, 7]' into a sorted list of ints."""
    cleaned = text.strip().strip("[]")
    found: list[int] = []
    for chunk in cleaned.replace(",", " ").split():
        if chunk.isdigit():
            found.append(int(chunk))
    return sorted(set(found))

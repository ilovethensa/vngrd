"""Console output. Deliberately tiny and free of side effects.

The old harness routed diagnostics to stderr because helpers were called in
command substitutions. In Python a return value is a value, so that trap is
gone; stdout is for the report, stderr is for progress, and both are line
oriented.
"""

from __future__ import annotations

import os
import sys

_COLOR = os.environ.get("NO_COLOR", "") == "" and sys.stderr.isatty()

RED = "\033[31m" if _COLOR else ""
GREEN = "\033[32m" if _COLOR else ""
YELLOW = "\033[33m" if _COLOR else ""
BLUE = "\033[34m" if _COLOR else ""
DIM = "\033[2m" if _COLOR else ""
NONE = "\033[0m" if _COLOR else ""


def _emit(text: str, stream) -> None:
    print(text, file=stream, flush=True)


def say(message: str = "") -> None:
    _emit(message, sys.stdout)


def step(message: str) -> None:
    _emit(f"{BLUE}==>{NONE} {message}", sys.stderr)


def ok(message: str) -> None:
    _emit(f"  {GREEN}ok{NONE}   {message}", sys.stderr)


def bad(message: str) -> None:
    _emit(f"  {RED}FAIL{NONE} {message}", sys.stderr)


def note(message: str) -> None:
    _emit(f"  {DIM}note{NONE} {message}", sys.stderr)


def warn(message: str) -> None:
    _emit(f"  {YELLOW}warn{NONE} {message}", sys.stderr)

"""Exception types the runner treats specially."""

from __future__ import annotations


class HarnessError(Exception):
    """A harness or environment problem, not a property failure."""


class ConfigError(HarnessError):
    """The artefact or configuration under test is missing or unreadable."""


class SkipTest(Exception):
    """The case cannot run in this environment.

    Reserved for *missing capability* (no KVM, no swtpm, no signing key). A
    missing input the case was supposed to measure is a failure, not a skip: a
    skip is how a security property silently stops being measured.
    """


class AssertionFailure(AssertionError):
    """An assertion in a case failed. Alias with a stable name for reporting."""


def skip(reason: str) -> None:
    raise SkipTest(reason)

"""vngrd-tests — the vngrd boot and security test suite.

This package is the harness. Cases live in the unit/, image/ and boot/
directories at the repository root and import from here:

    from harness import boot_case, test
    from harness.guest import event as ev

Run it with:

    bin/vngrd-tests list
    bin/vngrd-tests run --tier unit image
    bin/vngrd-tests run --tier boot --case t8-luks2
"""

from .errors import AssertionFailure, ConfigError, HarnessError, SkipTest, skip
from .registry import Case, CASES, boot_case, by_tier, test

__all__ = [
    "AssertionFailure",
    "ConfigError",
    "HarnessError",
    "SkipTest",
    "skip",
    "Case",
    "CASES",
    "boot_case",
    "by_tier",
    "test",
]

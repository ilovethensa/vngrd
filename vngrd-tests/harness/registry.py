"""Case registration.

A case is a plain function registered by decorator. Registration is the only way
a case can exist, which is what makes "an assertion that never ran" impossible:
the runner enumerates the registry, so a case that is not registered is not
run, and a case that runs and asserts nothing is a failure (see runner.py).
"""

from __future__ import annotations

import inspect
from dataclasses import dataclass, field
from typing import Callable

TIERS = ("unit", "image", "boot")


@dataclass(frozen=True)
class Case:
    id: str
    func: Callable
    tier: str
    doc: str
    secureboot: bool = True
    tpm: bool = True
    needs_machine: bool = False
    timeout: int = 120
    tags: tuple[str, ...] = ()
    xfail: str = ""
    allow_empty: bool = False
    # Text placed in SMBIOS table 11 as io.systemd.stub.kernel-cmdline-extra=.
    # QEMU owns the host side of it, so this is how a case becomes "the machine's
    # owner injected a kernel command line option" -- the one input to the boot
    # that no signature covers. Empty means no such string.
    smbios_cmdline_extra: str = ""

    @property
    def fixtures(self) -> tuple[str, ...]:
        return tuple(inspect.signature(self.func).parameters)


CASES: dict[str, Case] = {}


def _register(case: Case) -> Case:
    if case.id in CASES:
        raise RuntimeError("duplicate case id %r" % case.id)
    if case.tier not in TIERS:
        raise RuntimeError("case %r has unknown tier %r" % (case.id, case.tier))
    CASES[case.id] = case
    return case


def test(
    *,
    tier: str,
    id: str | None = None,  # noqa: A002 - matches pytest's kwarg
    secureboot: bool = True,
    tpm: bool = True,
    needs_machine: bool = False,
    timeout: int = 120,
    tags: tuple[str, ...] = (),
    xfail: str = "",
    allow_empty: bool = False,
    smbios_cmdline_extra: str = "",
):
    """Register a case function.

    The function's parameter names are the fixtures it needs; the runner injects
    them by name and fails collection if one is unknown.
    """

    def decorate(func: Callable) -> Callable:
        doc = inspect.getdoc(func) or ""
        case = Case(
            id=id or func.__name__,
            func=func,
            tier=tier,
            doc=doc,
            secureboot=secureboot,
            tpm=tpm,
            needs_machine=needs_machine,
            timeout=timeout,
            tags=tags,
            xfail=xfail,
            allow_empty=allow_empty,
            smbios_cmdline_extra=smbios_cmdline_extra,
        )
        _register(case)
        return func

    return decorate


def boot_case(**kwargs):
    """A case that boots a VM. Shorthand for test(tier='boot', ...)."""
    kwargs.setdefault("tier", "boot")
    kwargs.setdefault("needs_machine", True)
    return test(**kwargs)


def by_tier(*tiers: str) -> list[Case]:
    wanted = set(tiers) or set(TIERS)
    return [case for case in CASES.values() if case.tier in wanted]

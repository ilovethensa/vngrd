"""Session and fixture injection.

A case function's parameter names are the fixtures it wants. The runner asks the
Session to build those arguments before calling the case, so a case reads as a
list of the things it needs and nothing is reached for through a global.
"""

from __future__ import annotations

import inspect
import os
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from . import log
from .errors import ConfigError, SkipTest
from .paths import Paths
from .registry import Case
from .result import CaseResult, Recorder


@dataclass
class Options:
    version: str | None = None
    provision: bool = False
    keep: bool = False
    force_boot: bool = False
    verbose: int = 0


class Session:
    """Owns the expensive, shared fixtures for one run."""

    def __init__(self, paths: Paths, options: Options) -> None:
        self.paths = paths
        self.options = options
        self._policy = None
        self._tools = None
        self._images: dict[str, object] = {}
        self._machine = None
        self._state: Path | None = None
        self._cache: Path | None = None

    def _writable(self, preferred: Path, fallback: Path) -> Path:
        """Create *preferred*, or fall back inside the repo if it is not writable.

        The fallback exists for sandboxed/CI runs where XDG_STATE_HOME is not
        writable. The repository-local directory is gitignored.
        """
        for candidate in (preferred, fallback):
            try:
                candidate.mkdir(parents=True, exist_ok=True)
                probe = candidate / ".writable"
                probe.write_text("")
                probe.unlink()
                if candidate != preferred:
                    log.note("state directory %s is not writable; using %s" % (preferred, candidate))
                return candidate
            except OSError:
                continue
        raise ConfigError("no writable state directory (%s or %s)" % (preferred, fallback))

    @property
    def state(self) -> Path:
        """Writable state root for provisioned machines, logs and scratch.

        Lazy: the unit and image tiers never touch it, so they stay runnable on a
        read-only checkout.
        """
        if self._state is None:
            self._state = self._writable(self.paths.state, self.paths.tests / ".state")
        return self._state

    @property
    def cache(self) -> Path:
        if self._cache is None:
            self._cache = self._writable(self.paths.cache, self.paths.tests / ".cache")
        return self._cache


    @property
    def version(self) -> str:
        if self.options.version:
            return self.options.version
        versions = self.paths.versions()
        if not versions:
            raise ConfigError(
                "no vngrd_*.roothash in %s; build the image first" % self.paths.image_out
            )
        return versions[0]

    @property
    def policy(self):
        if self._policy is None:
            from .policy import Policy

            self._policy = Policy.load(self.paths)
        return self._policy

    @property
    def tools(self):
        if self._tools is None:
            from .tools import Tools

            self._tools = Tools.load(self.paths)
        return self._tools

    def image(self, version: str | None = None):
        version = version or self.version
        if version not in self._images:
            from .image import ImageArtifact

            self._images[version] = ImageArtifact.load(self.paths, version, self.tools, self.cache)
        return self._images[version]

    @property
    def machine(self):
        if self._machine is None:
            from .machine import Machine

            self._machine = Machine.provision(self)
        return self._machine


    def _tmp(self, case: Case) -> Path:
        base = self.state / "cases" / case.id
        if base.exists():
            shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)
        return base

    def _vm(self, case: Case, report: Recorder):
        from .qemu import Vm

        if not self.tools.qemu:
            raise SkipTest("qemu-system-x86_64 not found")
        return Vm(session=self, case=case, report=report)

    def build_kwargs(self, case: Case, result: CaseResult) -> dict:
        report = Recorder(result)
        kwargs: dict = {}
        for name in case.fixtures:
            if name == "report":
                kwargs[name] = report
            elif name == "tmp":
                kwargs[name] = self._tmp(case)
            elif name == "policy":
                kwargs[name] = self.policy
            elif name == "image":
                kwargs[name] = self.image()
            elif name == "tools":
                kwargs[name] = self.tools
            elif name == "paths":
                kwargs[name] = self.paths
            elif name == "machine":
                kwargs[name] = self.machine
            elif name == "vm":
                kwargs[name] = self._vm(case, report)
            elif name == "session":
                kwargs[name] = self
            else:
                raise ConfigError(
                    "case %r asks for unknown fixture %r (known: policy, image, tools, "
                    "paths, machine, vm, session, report, tmp)" % (case.id, name)
                )
        return kwargs

    def cleanup(self) -> None:
        if self._machine is not None:
            self._machine.cleanup()

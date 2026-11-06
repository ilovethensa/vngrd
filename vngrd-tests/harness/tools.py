"""External program resolution.

Binaries are looked for in the image's own tools tree first (mkosi.tools) and
then on PATH, so the suite uses the exact mtools/sbverify/mkosi the image was
built with where those exist, and the host's qemu/swtpm where they do not.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .errors import ConfigError, SkipTest
from .paths import Paths


@dataclass
class Tools:
    paths: Paths
    bin_dir: Path

    @classmethod
    def load(cls, paths: Paths) -> "Tools":
        return cls(paths=paths, bin_dir=paths.tools / "bin")


    def which(self, name: str) -> str | None:
        candidate = self.bin_dir / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
        return shutil.which(name)

    def require(self, name: str) -> str:
        found = self.which(name)
        if not found:
            raise ConfigError(
                "%s not found in %s or on PATH" % (name, self.bin_dir)
            )
        return found

    def optional(self, name: str) -> str | None:
        return self.which(name)


    @property
    def python(self) -> str | None:
        for candidate in sorted((self.bin_dir).glob("python3.*")):
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return str(candidate)
        return shutil.which("python3")

    @property
    def pythonpath(self) -> str | None:
        lib = self.paths.tools / "lib"
        for candidate in sorted(lib.glob("python3.*")):
            site = candidate / "site-packages"
            if site.is_dir():
                return str(site)
        return None

    def script_env(self) -> dict[str, str]:
        env = dict(os.environ)
        pythonpath = self.pythonpath
        if pythonpath:
            env["PYTHONPATH"] = pythonpath + (":" + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
        return env

    def run_tools_script(self, name: str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        """Run a mkosi.tools script that needs the tools interpreter and site-packages.

        Their shebangs point at the host interpreter, which has none of the
        modules (virt, pefile), so they are run through the tree's own python.
        """
        script = self.require(name)
        python = self.python
        if not python:
            raise ConfigError("no python interpreter available for %s" % name)
        return subprocess.run(
            [python, script, *args],
            env=self.script_env(),
            capture_output=True,
            text=True,
            check=check,
        )


    def _prop(name: str):  # noqa: N805 - descriptor factory
        def getter(self: "Tools") -> str | None:
            return self.optional(name)

        return property(getter)

    qemu = _prop("qemu-system-x86_64")
    qemu_img = _prop("qemu-img")
    swtpm = _prop("swtpm")
    swtpm_ioctl = _prop("swtpm_ioctl")
    sfdisk = _prop("sfdisk")
    mcopy = _prop("mcopy")
    mdir = _prop("mdir")
    objdump = _prop("objdump")
    sbverify = _prop("sbverify")
    openssl = _prop("openssl")
    tpm2_pcrread = _prop("tpm2_pcrread")
    tpm2_eventlog = _prop("tpm2_eventlog")
    virt_fw_vars = _prop("virt-fw-vars")
    ukify = _prop("ukify")

    @property
    def systemd_sbsign(self) -> str | None:
        candidate = self.paths.rootfs_out / "usr/lib/systemd/systemd-sbsign"
        return str(candidate) if candidate.is_file() else None

    def sbsign_env(self) -> dict[str, str]:
        env = dict(os.environ)
        rootfs = self.paths.rootfs_out
        env["LD_LIBRARY_PATH"] = "%s/usr/lib/systemd:%s/usr/lib" % (rootfs, rootfs)
        return env

    # systemd-creds, from the image's own rootfs rather than the host's: the
    # credential format is the image's systemd's business (a 262 SRK-pinned
    # credential is not readable by an older one), and a forged pcrlock
    # credential has to be byte-compatible with the machine it is planted on.
    # Same LD_LIBRARY_PATH dance as sbsign_env(), same reason: these binaries
    # link the shared libs the rootfs builds.
    @property
    def systemd_creds(self) -> str | None:
        candidate = self.paths.rootfs_out / "usr/bin/systemd-creds"
        return str(candidate) if candidate.is_file() else None

    def systemd_creds_env(self) -> dict[str, str]:
        env = dict(os.environ)
        rootfs = self.paths.rootfs_out
        env["LD_LIBRARY_PATH"] = "%s/usr/lib/systemd:%s/usr/lib" % (rootfs, rootfs)
        return env

    def require_kvm(self) -> None:
        if not Path("/dev/kvm").exists():
            raise SkipTest("no /dev/kvm: hardware virtualisation is unavailable")

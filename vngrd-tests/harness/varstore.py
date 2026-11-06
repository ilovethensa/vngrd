"""Edit an OVMF variable store, host-side.

The only way to change PCR 7 in the QEMU harness is to change the firmware's
Secure Boot policy variables, and the supported tool for that is edk2's
`virt-fw-vars` (the tool OvmfPkg/QEMU_PV_VARS.md points at). It is a
mkosi.tools script whose shebang points at the host interpreter, so it must run
through the tools tree's python.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from .errors import ConfigError, SkipTest
from .tools import Tools

# A fixed, arbitrary owner GUID; the value is not interpreted, only its presence.
CERT_OWNER_GUID = "11111111-2222-3333-4444-555555555555"


def add_db_certificate(tools: Tools, varstore: Path, certificate_der: Path) -> None:
    """Add one certificate to db, in place, proving the write landed."""
    if not tools.virt_fw_vars:
        raise SkipTest("virt-fw-vars is not available in the tools tree")
    if varstore.read_bytes() == b"":
        raise ConfigError("%s is empty" % varstore)
    before = varstore.read_bytes()
    staging = varstore.with_suffix(".staged")
    try:
        tools.run_tools_script(
            "virt-fw-vars",
            "-i",
            str(varstore),
            "-o",
            str(staging),
            "--add-db",
            CERT_OWNER_GUID,
            str(certificate_der),
        )
    except (subprocess.CalledProcessError, ConfigError) as exc:
        raise SkipTest("virt-fw-vars cannot run here: %s" % exc) from exc

    after = staging.read_bytes()
    if after == before:
        raise ConfigError(
            "the varstore is byte-identical after --add-db; the certificate was not enrolled"
        )
    shutil.move(str(staging), str(varstore))


def self_signed_certificate(tools: Tools, directory: Path, common_name: str) -> Path:
    """Generate a throwaway RSA certificate and return its DER encoding."""
    openssl = tools.require("openssl")
    key = directory / ("%s.key" % common_name)
    pem = directory / ("%s.crt" % common_name)
    der = directory / ("%s.der" % common_name)
    directory.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [
            openssl,
            "req",
            "-new",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "3650",
            "-subj",
            "/CN=%s" % common_name,
            "-keyout",
            str(key),
            "-out",
            str(pem),
        ],
        capture_output=True,
    )
    if result.returncode != 0:
        raise ConfigError("openssl could not generate a certificate: %s" % result.stderr.decode())
    result = subprocess.run(
        [openssl, "x509", "-in", str(pem), "-outform", "DER", "-out", str(der)],
        capture_output=True,
    )
    if result.returncode != 0:
        raise ConfigError("openssl could not DER-encode the certificate")
    return der

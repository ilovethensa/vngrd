"""Tier 1: the published Secure Boot enrolment updates.

A production image does not carry keys on its ESP. The operator enrols a machine
in setup mode from `secureboot/{PK,KEK,db}.auth`, so these files are part of the
trust boundary: PK and KEK must contain only the vngrd certificate, and db must
contain that certificate plus the two pinned Microsoft CAs. A build that
silently changes this set changes what the machine will boot.
"""

import struct
from pathlib import Path

from harness import skip, test


def _auth(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) < 40:
        raise AssertionError("%s is too short to be an EFI auth descriptor" % path)
    # EFI_VARIABLE_AUTHENTICATION_2: EFI_TIME (16), then WIN_CERTIFICATE_UEFI_GUID.
    # dwLength covers the WIN_CERTIFICATE header and the PKCS#7 blob; the new
    # variable data follows the descriptor. efi-updatevar consumes exactly this.
    cert_length = struct.unpack_from("<I", data, 16)[0]
    descriptor = 16 + cert_length
    if descriptor >= len(data):
        raise AssertionError("%s has no variable payload after the auth descriptor" % path)
    return data


def _der(path: Path) -> bytes:
    return path.read_bytes()


def _certs(policy) -> tuple[Path, Path, Path]:
    image_src = policy.paths.image_src
    return (
        image_src / "keys" / "microsoft-uefi-ca-2023.der",
        image_src / "keys" / "microsoft-option-rom-uefi-ca-2023.der",
        Path(policy.secureboot_cert),
    )


@test(tier="image", id="secureboot.auth-published")
def the_enrolment_updates_are_published_and_checksummed(image):
    for var in ("PK", "KEK", "db"):
        path = image.paths.image_out / "secureboot" / ("%s.auth" % var)
        assert path.is_file(), "missing %s" % path
        assert path.stat().st_size > 40, "%s is empty" % path
        name = "secureboot/%s.auth" % var
        assert name in image.checksums, "%s is not covered by SHA256SUMS" % name


@test(tier="image", id="secureboot.db-contents")
def db_has_vngrd_and_only_the_pinned_microsoft_cas(policy):
    """db is the union the offline enrol procedure installs; PK/KEK are not."""
    ms_uefi, ms_rom, cert = _certs(policy)
    for path in (ms_uefi, ms_rom):
        assert path.is_file(), "pinned Microsoft certificate missing: %s" % path
    if not cert.is_file():
        skip("the local SecureBootCertificate is unavailable")

    # The signer certificate is embedded in the PKCS#7 and the ESL payload is
    # appended verbatim, so a DER certificate is a contiguous substring of the
    # .auth file when it is in that variable's trust set.
    vngrd_der = _openssl_der(cert)
    db = _auth(policy.paths.image_out / "secureboot" / "db.auth")
    assert vngrd_der in db, "db.auth does not contain the vngrd certificate"
    assert _der(ms_uefi) in db, "db.auth does not contain Microsoft UEFI CA 2023"
    assert _der(ms_rom) in db, "db.auth does not contain the Option ROM CA 2023"

    for var in ("PK", "KEK"):
        blob = _auth(policy.paths.image_out / "secureboot" / ("%s.auth" % var))
        assert vngrd_der in blob, "%s.auth does not contain the vngrd certificate" % var
        assert _der(ms_uefi) not in blob, (
            "%s.auth contains Microsoft's CA; only db may delegate loader trust" % var
        )
        assert _der(ms_rom) not in blob, "%s.auth contains Microsoft's CA" % var


def _openssl_der(pem: Path) -> bytes:
    import subprocess

    result = subprocess.run(
        ["openssl", "x509", "-in", str(pem), "-outform", "DER"],
        capture_output=True,
    )
    if result.returncode != 0 or not result.stdout:
        raise AssertionError("openssl could not DER-encode %s: %s" % (pem, result.stderr.decode()))
    return result.stdout

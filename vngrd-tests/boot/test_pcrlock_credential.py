"""Tier 2: the pcrlock policy that binds the volume-key shard is this machine's.

WHAT THIS IS ABOUT. A pcrlock-sealed root cannot be opened without the pcrlock
policy, and the initrd has no /var, so the policy rides on the ESP as a credential:
systemd-stub packs \\loader\\credentials\\*.cred into the initrd, and cryptsetup picks
the one whose name starts with "pcrlock." and whose SRK and NV handles byte-match
the LUKS2 token (tpm2_pcrlock_policy_from_credentials()).

The handle match is NOT an authenticity check, and this is the part that is easy to
get backwards. Both handles it compares sit in the LUKS2 header, which is
unauthenticated storage: any reader of the disk has them, with no volume key and no
TPM. So "an ESP write substitutes any policy naming them" was true, and it was
doubly true because the credential itself was encrypted with a NULL key
(--with-key=null in vngrd-pcrlock-esp.service), which is what upstream's
write_boot_policy_file() does and which cryptsetup decrypts with CREDENTIAL_ALLOW_NULL.

The fix is both halves at once, and this case asserts the pair:

  * vngrd-pcrlock-esp.service writes the credential with --with-key=tpm2, sealed to
    this machine's SRK;
  * packages/systemd/build patches pcrlock_policy_load_credential() to
    CREDENTIAL_REFUSE_NULL, so a null-key credential -- the only kind an attacker
    with an ESP write can produce -- is refused before it is parsed.

The forged credential below is exactly what that attacker produces: a well-formed
policy that names this machine's SRK and NV handles, taken off the LUKS2 header,
encrypted with the null key, dropped in under the name cryptsetup scans for. With
the fix in place cryptsetup refuses it, finds no policy, and the recovery key is the
only way in.

What this case does NOT prove, stated plainly: the forged policy here is deliberately
not one the machine's NV index authorises, so it would have failed on its own even
without the fix -- a substituted policy has to be *the right one* to be useful, and
the only way to know the right one was to read it off the ESP. That is what the
second half of the case checks, and it is the half that actually discriminates:
before the fix the ESP credential was encrypted with the null key, so any reader of
the disk could decrypt it and produce a policy the NV index would accept. After the
fix the file's key ID is CRED_AES256_GCM_BY_TPM2_HMAC_PINNED_SRK and only this
machine's TPM can read it, so there is no longer a policy to copy. The boot
assertions then confirm the fail-closed end of that: a credential that is not this
machine's leaves the volume shut.

The control matters as much as the attack: the same boot with the machine's own
credential still opens. Without it, "the root stayed shut" is true for the wrong
reason -- a broken policy file, a moved PCR 7, a loose qcow2 -- and would pass on a
machine that was bricked before the case started.
"""

from __future__ import annotations

import base64
import json
import struct
import subprocess
from pathlib import Path

from harness import boot_case, luks2
from harness.disk import Gpt, replace_region


def _forged_credential(vm, dest: Path) -> Path:
    """A null-key pcrlock credential naming this machine's SRK and NV handles."""

    gpt = Gpt.load(vm.disk)
    document = luks2.header_at(vm.disk, gpt.require_label("vngrd-root").offset)
    token = luks2.tpm2_token(document)
    if token is None:
        raise AssertionError("no systemd-tpm2 token on the root volume")

    def field(name: str) -> str:
        value = token.get(name, "")
        if not isinstance(value, str) or not value:
            raise AssertionError("token has no %s: the handles this check needs are absent" % name)
        return value

    # The whole point: these two come off the LUKS2 header, world-readable, and the
    # consumer's only verification is that the credential names the same ones.
    srk_handle = field("tpm2_srk")
    nv_handle = field("tpm2_pcrlock_nv")

    # Structurally valid, so it gets past the JSON parser: a parse failure would
    # leave the root shut for a reason that has nothing to do with authenticity.
    policy = {
        "pcrBank": "sha256",
        "pcrValues": [
            {"pcr": 7, "values": ["00" * 32]},
            {"pcr": 13, "values": ["00" * 32]},
            {"pcr": 14, "values": ["00" * 32]},
        ],
        "nvIndex": 30474752,
        "nvHandle": nv_handle,
        "nvPublic": "",
        "srkHandle": srk_handle,
        "pinPublic": "",
        "pinPrivate": "",
    }
    policy_path = dest.parent / "forged-pcrlock-policy.json"
    policy_path.write_text(json.dumps(policy, indent=1) + "\n")

    # The name is the one cryptsetup scans for, and it must equal the machine's own:
    # the loader checks the authenticated name against the credential's stem
    # (import-creds.c strips the .cred suffix), so a wrong name is refused for a
    # reason unrelated to the seal.
    credential = vm.esp()
    remote = _credential_path(credential)
    machine_id = remote.rsplit("/", 1)[-1][len("pcrlock.") : -len(".cred")]

    tools_creds = vm.tools.systemd_creds
    if not tools_creds:
        raise AssertionError(
            "systemd-creds is needed to forge the credential, and the image's rootfs "
            "(%s/usr/bin/systemd-creds) is not built" % vm.tools.paths.rootfs_out
        )

    command = [str(tools_creds), "encrypt", "--name", "pcrlock." + machine_id, "--with-key=null",
               str(policy_path), str(dest)]
    result = subprocess.run(command, capture_output=True, text=True, env=vm.tools.systemd_creds_env())
    if result.returncode != 0 or not dest.is_file():
        raise AssertionError(
            "could not forge the credential: %s" % (result.stderr or result.stdout).strip()
        )
    return dest


# src/shared/creds-util.h, v262.
KEY_TPM2_HMAC_PINNED_SRK = "d4062dfb71ad4c86804b40ef1180f1fc"
KEY_NULL = "058469daf6f54324800549da0f8ea2fb"


def _credential_pcr_mask(path: Path) -> int | None:
    """The TPM2 PCR mask the credential's sealed key is bound to, or None.

    Layout (src/shared/creds-util.c): encrypted_credential_header is id[16] plus
    four le32 (key_size, block_size, iv_size, tag_size), then iv[] padded to an
    8-byte boundary, and the tpm2_credential_header starts there -- its first
    field is the PCR mask, le64. No decryption needed to read it, which is the
    point: the mask is not a secret.
    """
    try:
        blob = base64.b64decode(path.read_bytes(), validate=False)
    except Exception:  # noqa: BLE001
        return None
    if len(blob) < 32:
        return None
    iv_size = struct.unpack_from("<I", blob, 24)[0]
    off = (32 + iv_size + 7) & ~7
    if off + 8 > len(blob):
        return None
    return struct.unpack_from("<Q", blob, off)[0]


def _credential_files(esp) -> list[str]:
    """Every *.cred on the ESP, by name. syscall-free: mdirlike walking."""
    found = []
    for line in esp.walk().splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[-1].endswith(".cred"):
            found.append(fields[-1])
    return sorted(found)


def _credential_key_id(path: Path) -> str | None:
    """The credential's key ID as hex, or None if it cannot be parsed.

    The format is base64 over a binary blob whose first 16 bytes are the key ID
    (struct encrypted_credential_header), so this needs no systemd and no TPM --
    which is the point: the property being checked is readable by anyone.
    """
    try:
        blob = base64.b64decode(path.read_bytes(), validate=False)
    except Exception:  # noqa: BLE001 - an unparseable file is the answer "no"
        return None
    if len(blob) < 16:
        return None
    return blob[:16].hex()


def _credential_path(esp) -> str:
    """::/loader/credentials/pcrlock.<machine-id>.cred, as the ESP spells it."""

    for line in esp.walk().splitlines():
        fields = line.split()
        if not fields:
            continue
        name = fields[-1]
        if name.startswith("pcrlock.") and name.endswith(".cred"):
            return "loader/credentials/" + name
    raise AssertionError(
        "the ESP carries no pcrlock.<machine-id>.cred: vngrd-pcrlock-esp.service "
        "was supposed to write one, and without it the control boot cannot unseal"
    )


@boot_case(id="t18-pcrlock-credential-forged", timeout=420)
def t18_pcrlock_credential_forged(vm, report):
    """An ESP write cannot substitute the pcrlock policy the unseal is bound to."""

    # Control: this machine's own credential opens the root. This is also what
    # makes the case meaningful -- a root that was already shut proves nothing.
    gpt = Gpt.load(vm.disk)
    control = vm.start()
    control.require("boot.root-unsealed")
    control.require("tpm.bound")
    report.require(
        "pcrlock.control-unsealed",
        True,
        "the machine's own pcrlock credential opened the root, so the case has a baseline",
    )

    esp = vm.esp()
    remote = _credential_path(esp)
    original = esp.get(remote, vm.state / "original-pcrlock.cred")

    # The half of the fix that is observable without a TPM: the machine's own
    # credential must not be readable by a disk reader. systemd-creds writes the key
    # ID as the first 16 bytes of the credential, so the whole question is which ID
    # it is. --with-key=null (what this unit used to write, and what upstream's
    # write_boot_policy_file() still writes) is CRED_AES256_GCM_BY_NULL; the TPM
    # binding this image requires is CRED_AES256_GCM_BY_TPM2_HMAC_PINNED_SRK, the
    # v262 addition that pins the sealed key to the SRK rather than to any TPM.
    key_id = _credential_key_id(original)
    if key_id is None:
        raise AssertionError("the ESP pcrlock credential is not parseable: %s" % original)
    report.require(
        "pcrlock.credential-is-tpm-sealed",
        key_id == KEY_TPM2_HMAC_PINNED_SRK,
        "the ESP pcrlock credential is sealed with %s, not the machine's TPM: any "
        "reader of the disk can decrypt it and produce a policy the NV index accepts"
        % key_id,
    )
    # PCR 7 on top of the SRK. The SRK alone is satisfied by *any* boot that can
    # reach this TPM: reload db with a self-signed certificate, or stay in setup
    # mode, and the SRK is unchanged and the SRK/NV handle match still passes. PCR 7
    # is the one binding an ESP write cannot fake, because the firmware checks it.
    pcr_mask = _credential_pcr_mask(original)
    report.require(
        "pcrlock.credential-is-pcr7-bound",
        pcr_mask is not None and pcr_mask == (1 << 7),
        "the ESP pcrlock credential is bound to PCR mask %r, not PCR 7 only (%r): "
        "a credential sealed to the SRK alone decrypts under a Secure Boot policy "
        "the machine's owner did not choose" % (pcr_mask, 1 << 7),
    )
    # And the credential must be the only one. The stub packs every *.cred it finds
    # under \loader\credentials into the initrd, so a second file is a second
    # input to the unseal that nothing here has reviewed.
    report.require(
        "pcrlock.one-credential-on-the-esp",
        _credential_files(esp) == [remote.rsplit("/", 1)[-1]],
        "the ESP carries unexpected pcrlock credentials: %s" % _credential_files(esp),
    )

    forged = _forged_credential(vm, vm.state / "forged-pcrlock.cred")
    esp.put(forged, remote)
    # The write back is not optional, and it is easy to miss: Esp.put() copies into
    # the *extracted* image, and the VM boots disk.raw. Without this line the plant
    # exists only in a scratch file, the boot reads the machine's own credential,
    # and the case passes while testing nothing.
    replace_region(vm.disk, gpt.esp().offset, esp.path)
    back = vm.esp().get(remote, vm.state / "verify-plant.cred")
    if open(back, "rb").read() != open(forged, "rb").read():
        raise AssertionError(
            "the forged credential is not the one on the ESP the machine will boot"
        )

    # And the same boot with the forged one. What the machine sees is identical to
    # the control in every way except whose credential it is -- same name, same
    # handles, same machine, same TPM.
    #
    # No login-ready assertion, and that is deliberate: the boot *stalls* at the
    # recovery-key prompt, which is the correct failure mode for a verified boot
    # (t6a/t6b use the same shape -- the unit never finishes, so nothing mounts and
    # no shell appears). The assertions below are what distinguish that from a
    # machine that simply did not boot at all.
    attack = vm.start()
    attack.require("tpm.bound")
    attack.require("cryptsetup.start")
    attack.require_absent("ordering.skip-cryptsetup")
    attack.require("boot.usr-mounted")
    # The PIN was accepted and the policy was not: the machine gets as far as
    # asking for a passphrase, which only happens when the TPM token path has
    # already been exhausted. Before the fix that prompt never appeared, because
    # the attacker's policy was accepted in place of the machine's.
    report.require(
        "pcrlock.forged-credential-refused",
        attack.events.missing("boot.root-unsealed"),
        "the root unsealed from a pcrlock policy this machine did not write: the "
        "credential is not bound to the machine",
    )
    report.require(
        "pcrlock.passphrase-fallback-reached",
        attack.events.missing("boot.login-ready")
        and attack.events.missing("boot.root-unsealed"),
        "expected the boot to fall through to the passphrase path, saw a completed boot",
    )

    # Restore, so a later case on the same machine is not left with a forged ESP.
    # (The boot stopped at the recovery-key prompt by design, so there is nothing
    # to shut down cleanly; the state is left as the harness left it.)
    esp.put(original, remote)
    replace_region(vm.disk, gpt.esp().offset, esp.path)

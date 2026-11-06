"""Tier 2: artefact cases that read the provisioned machine, without a fresh boot.

These are the cheap half of the boot tier: provisioning has already produced the
LUKS2 token and the install log, so the assertions are deterministic and cannot
race a VM teardown.
"""

import base64
import subprocess

from harness import boot_case, luks2, skip
from harness.console import TEST_RECOVERY_PASSPHRASE
from harness.disk import Gpt
from harness.guest import EventStream
from harness.qemu import normalise


def _root_document(machine):
    gpt = Gpt.load(machine.disk)
    root = gpt.require_label("vngrd-root")
    return luks2.header_at(machine.disk, root.offset)


@boot_case(id="t0-install", timeout=30)
def t0_install(machine, policy, report):
    """The first boot built a root sealed exactly as the policy declares.

    The seal is read from the LUKS2 token, not from the log, because the token is
    what the TPM will actually be asked to satisfy.
    """
    document = _root_document(machine)

    kinds = luks2.keyslot_types(document)
    report.require("luks2.keyslot", "luks2" in kinds, "keyslot types: %s" % kinds)
    # The recovery path is a passphrase keyslot, not a systemd-recovery token.
    # Provisioning asks for a user-supplied passphrase (systemd-cryptenroll
    # --password), so there is no systemd-recovery token on the volume; the TPM
    # token is the second keyslot. Two luks2 keyslots are therefore the shape:
    # one passphrase and one TPM2.
    slots = document.get("keyslots", {})
    report.require(
        "luks2.recovery-keyslot",
        len(slots) >= 2,
        "only %d keyslot(s): with no second (passphrase) keyslot every TPM "
        "failure is a brick; keyslots=%s" % (len(slots), sorted(slots)),
    )
    report.require("luks2.tpm2-token", luks2.tpm2_token(document) is not None, "no systemd-tpm2 token")

    # The seal that is on disk is the one the *enrollment* wrote, not the one
    # repart wrote: repart's token is replaced on the boot that provisions
    # (systemd-cryptenroll --wipe-slot=tpm2 --tpm2-pcrlock=). So the PCR set is
    # no longer carried in the token -- it is carried by the pcrlock policy --
    # and the token names the policy and the NV index instead. Asserting the old
    # fields would fail a *correct* pcrlock machine, which is what this used to
    # do ("token names [] but the policy declares [7]").
    if policy.pcrlock_enrolled:
        report.require(
            "seal.pcrs-absent",
            not luks2.field(document, "tpm2-pcrs"),
            "a pcrlock token must not also name a bare PCR set: %s"
            % (luks2.field(document, "tpm2-pcrs"),),
        )
        report.require(
            "seal.pcrlock", luks2.field(document, "tpm2_pcrlock") is True, "no tpm2_pcrlock in the token"
        )
        report.require(
            "seal.pcrlock-nv",
            # underscores, not the dashes the other tpm2- fields use: this is
            # libcryptsetup's spelling of the serialized NV handle
            bool(luks2.field(document, "tpm2_pcrlock_nv")),
            "no tpm2_pcrlock_nv: the NV index the policy is stored in",
        )
        report.require("seal.pin", luks2.field(document, "tpm2-pin") is True, "the token is not PIN-protected")
    else:
        pcrs = sorted(luks2.field(document, "tpm2-pcrs") or [])
        report.require(
            "seal.pcrs",
            pcrs == sorted(policy.pcr_mask),
            "token names %s but the policy declares %s" % (pcrs, sorted(policy.pcr_mask)),
        )
    pubkey_pcrs = sorted(luks2.field(document, "tpm2_pubkey_pcrs") or [])
    report.require(
        "seal.pubkey-pcrs",
        pubkey_pcrs == sorted(policy.pubkey_pcr_mask),
        "token %s vs policy %s" % (pubkey_pcrs, sorted(policy.pubkey_pcr_mask)),
    )
    report.require("seal.pubkey", bool(luks2.field(document, "tpm2_pubkey")), "no tpm2_pubkey")
    report.require(
        "seal.policy-hash", luks2.field(document, "tpm2-policy-hash") is not None, "no policy hash"
    )

    log = machine.state / "provision.log"
    if log.is_file():
        # Normalise first: the console carries ANSI redraws and CR, and an
        # anchor will not match a line with an escape sequence in the middle.
        events = EventStream.from_log(normalise(log.read_text(errors="replace")))
        report.require("provision:initrd", events.saw("boot.enter-initrd"), str(log))
        report.require("provision:usr-mounted", events.saw("boot.usr-mounted"), str(log))
        report.require("provision:no-emergency", events.missing("boot.emergency"), str(log))
        report.require(
            "provision:no-recovery-passphrase-in-log",
            TEST_RECOVERY_PASSPHRASE not in log.read_text(errors="replace"),
            "the recovery passphrase was echoed to the serial log; it must only "
            "travel through the ask-password prompt",
        )

        # The partition identity is frozen exactly once, on this boot, by
        # vngrd-gpt-freeze. It is the input vngrd-gpt-guard compares against on
        # every later boot, so a provisioning boot that did not freeze one leaves
        # a provisioned machine with no GPT identity to check. The guard itself is
        # silent here: repart's crypttab marker exists and the guard runs after
        # repart, so it takes the provisioning-boot path. This reads the freeze's
        # own line rather than relying on that silence.
        report.require(
            "prekernel:gpt-frozen",
            events.saw("gpt.frozen"),
            "the provisioning boot did not freeze a partition identity, so "
            "a provisioned machine has no GPT identity to check",
        )
        report.require(
            "prekernel:no-gpt-refusal-on-provision",
            events.missing("gpt.refused"),
            "vngrd-gpt-guard refused the very boot that was provisioning the disk",
        )

        # The ESP contents are the third of these bindings and freeze on the same
        # boot for the same reason. The guard is silent here for the same reason
        # as the GPT guard: the provisioning marker is present and it runs after
        # repart, so this boot is allowed before the index exists. This reads the
        # freeze's line, and separately asserts that the guard did not refuse the
        # boot it was meant to let through.
        report.require(
            "prekernel:esp-frozen",
            events.saw("esp.frozen"),
            "the provisioning boot did not freeze an ESP identity, so "
            "a provisioned machine has no ESP identity to check",
        )
        report.require(
            "prekernel:no-esp-refusal-on-provision",
            events.missing("esp.refused"),
            "vngrd-esp-guard refused the very boot that was provisioning the disk",
        )


@boot_case(id="t9-pcr11-enroll", timeout=30)
def t9_pcr11_enroll(machine, policy, image, tools, report):
    """The token's PolicyAuthorize names the build's own PCR signing key.

    A PolicyAuthorize against a different RSA key unseals exactly as little as no
    PolicyAuthorize at all, and no boot-time assertion can tell the two apart, so
    the key is compared byte for byte here.
    """
    if not policy.pcr_cert:
        skip("no SignExpectedPcrCertificate configured (fresh checkout)")

    document = _root_document(machine)
    pubkey_pcrs = sorted(luks2.field(document, "tpm2_pubkey_pcrs") or [])
    report.require("policy.pubkey-pcrs", pubkey_pcrs == [11], "expected [11], got %s" % pubkey_pcrs)

    encoded = luks2.field(document, "tpm2_pubkey")
    report.require("policy.pubkey-present", bool(encoded), "no tpm2_pubkey in the token")
    if encoded:
        token_pem = base64.b64decode(encoded)
        result = subprocess.run(
            [tools.require("openssl"), "x509", "-in", policy.pcr_cert, "-noout", "-pubkey"],
            capture_output=True,
        )
        report.require(
            "policy.pubkey-matches-build",
            result.returncode == 0 and result.stdout == token_pem,
            "the token's public key is not the build's PCR signing key",
        )

    report.require("policy.pcrsig", image.uki.has_pcrsig(), "the UKI has no .pcrsig section")


@boot_case(id="t12-gpt-measurement", timeout=30)
def t12_gpt_measurement(machine, policy, report):
    """The firmware measured the GPT, and PCR 5 is deliberately not in the seal.

    The GPT measurement is still captured for diagnostics, but a seal naming PCR 5
    would be a brick: repart creates the root after the firmware has measured the
    table. This case checks both halves of that decision.
    """
    log = machine.state / "provision.log"
    if not log.is_file():
        skip("no provisioning log")
    text = normalise(log.read_text(errors="replace"))
    report.require(
        "firmware:event-log",
        "EV_NO_ACTION" in text,
        "the guest did not dump a firmware event log; the GPT measurement is unknown",
    )
    report.require(
        "firmware:gpt-measured",
        "EV_EFI_GPT_EVENT" in text,
        "no EV_EFI_GPT_EVENT in the event log: this firmware does not measure the GPT",
    )

    document = _root_document(machine)
    # What the seal names depends on whether the root is sealed to a pcrlock
    # policy. With one, the PCR set is not carried in the token at all -- it is
    # carried by the policy the enrollment wrote, and the token references the
    # NV index that policy lives in. Asserting the repart-era fields would fail a
    # correctly enrolled machine, which is what this used to do.
    if policy.pcrlock_enrolled:
        report.require(
            "seal.pcrs-absent",
            not luks2.field(document, "tpm2-pcrs"),
            "a pcrlock token must not also name a bare PCR set: %s"
            % (luks2.field(document, "tpm2-pcrs"),),
        )
        report.require(
            "seal.pcrlock", luks2.field(document, "tpm2_pcrlock") is True, "no tpm2_pcrlock in the token"
        )
        # PCR 5 is a deliberate exclusion, not an accident of the pcrlock
        # prediction: repart creates the root after the firmware measures the
        # GPT, so a seal naming it would never open again.
        report.require(
            "seal.pcr5-not-asserted",
            5 not in policy.pcr_mask,
            "PCR 5 is in the declared seal mask: the root would be bricked on the "
            "next boot because repart creates the partition after the measurement",
        )
    else:
        pcrs = sorted(luks2.field(document, "tpm2-pcrs") or [])
        report.require(
            "seal.matches-policy",
            pcrs == sorted(policy.pcr_mask),
            "token %s vs policy %s" % (pcrs, sorted(policy.pcr_mask)),
        )
        if 5 in policy.pcr_mask:
            report.require("seal.includes-pcr5", 5 in pcrs, "the policy names PCR 5 but the token does not")
        else:
            report.require(
                "seal.excludes-pcr5",
                5 not in pcrs,
                "PCR 5 is in the token but the policy does not declare it",
        )

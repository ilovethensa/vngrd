"""Tier 1: the declared security contract, and that the build agrees with itself.

These are the checks that would have caught the old PCR 5 contradiction: the seal
the cases assert on is read from one place instead of being retyped per case.
"""

import re
from pathlib import Path

from harness import skip, test


@test(tier="image", id="policy.identity")
def policy_matches_the_published_image(policy, image):
    """The image metadata and the artefact version agree."""
    assert policy.image_id == "vngrd", policy.image_id
    assert policy.version == image.version, (policy.version, image.version)


@test(tier="image", id="policy.posture")
def secure_boot_and_pcr_signing_are_enabled(policy):
    """The properties the suite measures must be switched on in the first place."""
    assert policy.secureboot, "SecureBoot is not enabled in mkosi.conf"
    assert not policy.secureboot_auto_enroll, (
        "SecureBootAutoEnroll is on: a production image must not trust enrollment "
        "keys on its own ESP. Auto-enrolment belongs to the disposable "
        "mkosi.profiles/autoenroll profile, not the default build"
    )
    assert policy.sign_expected_pcr, "SignExpectedPcr is off: the UKI carries no .pcrsig"
    assert policy.verity == "hash", "Verity is %r, not hash" % policy.verity


@test(tier="image", id="policy.seal")
def the_seal_is_a_policy_authorize_over_pcr11(policy):
    """PolicyAuthorize is what binds the root to an image, not just a signed one."""
    assert policy.pcr_mask, "the seal names no PCR at all"
    assert policy.pcr_mask == frozenset({7}), (
        "the PCR 7 + PolicyAuthorize decision changed to %s; PCR 5 must stay out "
        "because repart creates the root after the firmware measures the GPT"
        % sorted(policy.pcr_mask)
    )
    assert policy.policy_authorize, "no --tpm2-public-key=: the seal is a bare PolicyPCR"
    assert 11 in policy.pubkey_pcr_mask, policy.pubkey_pcr_mask
    assert policy.pcrlock_disabled, "pcrlock discovery is on; it shards the volume key"


@test(tier="image", id="policy.phases")
def the_signed_phase_set_is_exactly_enter_initrd(policy):
    """The set of signed PCR 11 values IS the window the key is available in."""
    assert policy.phases == ("enter-initrd",), policy.phases


@test(tier="image", id="policy.lockdown")
def the_signed_command_line_asks_for_lockdown(policy):
    assert policy.lockdown_mode == "integrity", policy.lockdown_mode


@test(tier="image", id="policy.self-consistent")
def the_build_does_not_contradict_itself(policy):
    """Definition vs effective command line, and the PolicyAuthorize shape."""
    disagreements = policy.disagreements()
    assert not disagreements, "; ".join(disagreements)


@test(tier="image", id="policy.installed-agrees")
def the_installed_repart_dropin_agrees_with_the_parsed_policy(policy):
    """The drop-in the guest will execute must be the one the contract describes.

    This is the check the old suite could not make: it retyped `[5, 7]` into a
    case while the installed command line said `--tpm2-pcrs=7`.
    """
    dropin = Path(policy.source_notes["repart_dropin"])
    if not dropin.is_file():
        skip("no installed repart drop-in at %s" % dropin)
    text = dropin.read_text()
    match = re.search(r"^ExecStart=systemd-repart.*$", text, re.MULTILINE)
    assert match, "no ExecStart=systemd-repart in %s" % dropin
    line = match.group(0)
    assert "--tpm2-pcrs=%s" % policy.pcr_mask_text in line, line
    assert "--tpm2-public-key-pcrs=%s" % policy.pubkey_pcr_mask_text in line, line

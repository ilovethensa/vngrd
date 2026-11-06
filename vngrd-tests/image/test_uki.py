"""Tier 1: the published UKI.

The UKI is the authenticated root of the boot chain, so its contract is checked
host-side before any VM runs: the sections exist, the embedded command line is
the one the policy describes, and the .pcrsig signs exactly the phase set the
policy names.
"""

from harness import pcrsig, skip, test

REQUIRED_SECTIONS = (".linux", ".initrd", ".cmdline", ".osrel", ".uname", ".pcrpkey", ".pcrsig")


@test(tier="image", id="uki.sections")
def the_uki_carries_every_required_section(image):
    missing = [name for name in REQUIRED_SECTIONS if not image.uki.has_section(name)]
    assert not missing, "missing sections: %s" % ", ".join(missing)


@test(tier="image", id="uki.cmdline")
def the_embedded_command_line_is_authenticated_and_complete(image, policy):
    """usrhash= must name this image's verity hash; the rest comes from mkosi."""
    uki = image.uki
    assert uki.usrhash() == image.roothash, (uki.usrhash(), image.roothash)

    entries = uki.cmdline_entries()
    for token in policy.kernel_cmdline.split():
        assert token in entries, "the UKI cmdline is missing %r" % token
    assert "root=/dev/mapper/vngrd-root" in entries
    assert "lockdown=integrity" in entries


@test(tier="image", id="uki.pcrsig-shape")
def the_pcrsig_signs_one_pcr11_value_at_enter_initrd(image, policy):
    """More than one signed entry would keep the key available past the initrd."""
    doc = image.uki.pcrsig_doc()
    assert pcrsig.count(doc) == 1, "the .pcrsig carries %d entries" % pcrsig.count(doc)
    assert pcrsig.pcr_mask(doc) == sorted(policy.pubkey_pcr_mask), pcrsig.pcr_mask(doc)
    assert [name for _, name in pcrsig.phases(doc)] == list(policy.phases), pcrsig.phases(doc)


@test(tier="image", id="uki.signature")
def the_published_uki_verifies_against_the_configured_certificate(image, policy):
    """A UKI the firmware will refuse makes every boot case measure nothing."""
    if not policy.secureboot_cert:
        skip("no SecureBootCertificate configured (fresh checkout)")
    assert image.uki.signature_ok(policy.secureboot_cert), (
        "sbverify rejected %s against %s" % (image.uki.path, policy.secureboot_cert)
    )


@test(tier="image", id="uki.esp-name")
def the_esp_uki_name_carries_the_verity_root_hash(image, tmp):
    """The ESP filename embeds the roothash, which is how slots are told apart."""
    esp = image.esp(tmp / "esp.img")
    path = esp.uki_path()
    assert image.roothash in path, "%s does not contain the roothash" % path

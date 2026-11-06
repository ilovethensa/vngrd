"""Tier 1: the two new build-time facts the boot tier depends on.

Both halves of the pcrlock credential fix live in files that are installed into the
image rather than computed at boot, and both have a build-time expression the suite
can read without a VM:

  * vngrd-pcrlock-esp.service must seal the policy credential to the machine's TPM
    and then decrypt-verify it, because the credential is the only thing that tells
    the initrd which pcrlock policy to bind the volume-key shard to;
  * vngrd-cmdline-guard.service must exist and be enabled from a target that only
    exists in the initrd, because "the stub dropped the injected command line" and
    "the guard checked it" are two different claims and the second one needs a unit
    that actually runs.

The systemd half of each is asserted by the boot cases (t16, t18) and by
packages/systemd/build, not here: by the time this tier runs that half is a
compiled binary, and grepping a binary for a patch is not a check.
"""

from pathlib import Path

from harness import test

GUARD_UNIT = "usr/lib/systemd/system/vngrd-cmdline-guard.service"
GUARD_WANTS = "usr/lib/systemd/system/initrd-root-device.target.wants/vngrd-cmdline-guard.service"
PCRLOCK_ESP_UNIT = "usr/lib/systemd/system/vngrd-pcrlock-esp.service"


@test(tier="image", id="policy.pcrlock-credential-sealed")
def the_pcrlock_credential_is_sealed_to_the_machine(paths):
    """The ESP pcrlock credential is written with --with-key=tpm2, and verified."""
    unit = paths.rootfs_out / PCRLOCK_ESP_UNIT
    if not unit.is_file():
        from harness import skip

        skip("no built rootfs at %s" % paths.rootfs_out)
    text = unit.read_text()

    starts = [line for line in text.splitlines() if line.startswith("ExecStart=")]
    assert starts, "no ExecStart= in %s" % unit
    assert any(
        line.startswith("ExecStart=/usr/bin/systemd-creds encrypt") and "--with-key=tpm2" in line
        for line in starts
    ), (
        "the pcrlock policy must be sealed with --with-key=tpm2: a null-key credential "
        "is accepted by the loader against a set of handles that are in the "
        "world-readable LUKS2 header, so an ESP write can substitute one. Found: %s"
        % starts
    )

    posts = [line for line in text.splitlines() if line.startswith("ExecStartPost=")]
    assert any(
        "systemd-creds decrypt" in line and "/efi/loader/credentials/pcrlock.%m.cred" in line
        for line in posts
    ), "the unit must decrypt-verify the credential it wrote (ExecStartPost=): %s" % posts
    assert any(
        line.startswith("ExecStartPost=/usr/bin/cmp -s ") and "/var/lib/systemd/pcrlock.json" in line
        for line in posts
    ), "the unit must compare the decrypted credential against the policy: %s" % posts


@test(tier="image", id="policy.esp-unsigned-inputs")
def the_published_esp_carries_no_unsigned_boot_inputs(image, tmp):
    r"""Nothing on the shipped ESP may add to what the signed UKI says.

    systemd-stub builds the kernel command line and the initrd from the UKI plus
    whatever it finds next to it: *.cred under \loader\credentials is packed into
    the initrd unsigned, and <uki>.extra.d/*.addon.efi can add command-line and
    initrd sections. Addons are PE-verified against db by the firmware, so they
    need a db key to be useful; credentials are not verified at all by the stub,
    which is why the pcrlock credential is written at runtime, sealed to the
    machine's TPM and PCR 7, rather than shipped here.

    This is the control on the *published* artefact: the image must not carry a
    credential, an addon, or an .extra.d directory, because anything that appears
    here is an input to every future boot that no signature covers. The runtime
    copy is checked by t18, on a provisioned machine instead.
    """
    esp = image.esp(tmp / "esp.img")
    listing = esp.walk()

    creds = [
        line.split()[-1]
        for line in listing.splitlines()
        if len(line.split()) >= 3 and line.split()[-1].endswith(".cred")
    ]
    assert not creds, (
        "the published ESP carries a credential: %s. A credential shipped in the "
        "image would be unsigned input to every boot; what belongs on the ESP is "
        "written at runtime, sealed to the machine's TPM and PCR 7 "
        "(vngrd-pcrlock-esp.service)." % creds
    )

    extra_dirs = [line for line in listing.splitlines() if ".extra.d" in line]
    assert not extra_dirs, "the published ESP carries an .extra.d directory: %s" % extra_dirs

    addons = [
        line.split()[-1]
        for line in listing.splitlines()
        if line.split() and line.split()[-1].endswith(".addon.efi")
    ]
    assert not addons, "the published ESP carries a PE addon: %s" % addons


@test(tier="image", id="policy.cmdline-guard-enabled")
def the_cmdline_guard_is_installed_and_enabled_for_the_initrd(paths):
    """The guard is in the initrd and pulled in by a target only the initrd has."""
    for tree in (paths.rootfs_out, paths.initrd_out):
        if not tree.is_dir():
            from harness import skip

            skip("no built tree at %s" % tree)
        unit = tree / GUARD_UNIT
        assert unit.is_file(), "missing %s in %s" % (GUARD_UNIT, tree)
        wants = tree / GUARD_WANTS
        assert wants.is_symlink(), (
            "%s must be a symlink: Before= orders a unit, it does not start one, and an "
            "unstarted guard is a boot that trusts a command line it should not" % GUARD_WANTS
        )
        target = Path(wants.readlink())
        assert not target.is_absolute(), "%s must be a relative symlink" % GUARD_WANTS
        assert wants.exists(), "%s dangles" % GUARD_WANTS
        # The binary is only in the initrd; the rootfs never runs the guard.
        if tree == paths.initrd_out:
            guard_binary = tree / "usr/lib/vngrd/vngrd-cmdline-guard"
            assert guard_binary.is_file(), "the initrd is missing %s" % guard_binary
            assert (guard_binary.stat().st_mode & 0o111), "vngrd-cmdline-guard is not executable"

    text = (paths.rootfs_out / GUARD_UNIT).read_text()
    assert "FailureAction=reboot-force" in text, (
        "the guard must fail closed: a mismatched command line has to stop the boot, "
        "not let it continue into the mounts that act on it"
    )
    assert "Before=sysroot.mount sysusr-usr.mount systemd-veritysetup@usr.service" in text, (
        "the guard must run before the verity setup that acts on usrhash=; ordering "
        "it only against the mounts leaves the generator's usrhash= live in between"
    )
    assert "ConditionPathExists=/.extra/signed-cmdline" not in text, (
        "the guard must not be skipped when .extra/signed-cmdline is absent: a UKI "
        "without a .cmdline is a malformed image, not a boot to let through"
    )

"""Tier 1: filesystem shape of the built rootfs and initrd.

These are the hermetic-/usr invariants, checked on the artefact rather than in a
package build script, so a package that installs to /bin is caught by the suite
that consumes the tree.
"""

from pathlib import Path

from harness import test

FORBIDDEN_TOP_LEVEL = ("bin", "sbin", "lib", "lib64")
USR_ALLOWED = {"bin", "include", "lib", "share"}


@test(tier="image", id="factory.merged-usr")
def the_rootfs_has_no_unmerged_top_level_directories(paths):
    """Merged /usr only: no /bin, /sbin, /lib or /lib64, not even as symlinks."""
    root = paths.rootfs_out
    if not root.is_dir():
        from harness import skip

        skip("no built rootfs at %s" % root)
    present = [name for name in FORBIDDEN_TOP_LEVEL if (root / name).exists()]
    assert not present, "forbidden top-level entries: %s" % ", ".join(present)


@test(tier="image", id="factory.usr-layout")
def usr_contains_only_the_four_allowed_subdirectories(paths):
    usr = paths.rootfs_out / "usr"
    if not usr.is_dir():
        from harness import skip

        skip("no built rootfs at %s" % paths.rootfs_out)
    actual = {entry.name for entry in usr.iterdir() if entry.is_dir() or entry.is_symlink()}
    assert actual == USR_ALLOWED, "unexpected /usr entries: %s" % sorted(actual - USR_ALLOWED)


@test(tier="image", id="factory.repart-definition")
def the_repart_definition_agrees_with_the_policy(policy):
    """The declared PCR set and the installed definition must be one value."""
    definition = Path(policy.source_notes["repart_definition"])
    assert definition.is_file(), definition
    declared = None
    for line in definition.read_text().splitlines():
        if line.startswith("TPM2PCRs="):
            declared = line.split("=", 1)[1].strip()
    assert declared is not None, "no TPM2PCRs= in %s" % definition
    assert declared == policy.pcr_mask_text, (
        "definition TPM2PCRs=%s but effective --tpm2-pcrs=%s" % (declared, policy.pcr_mask_text)
    )


@test(tier="image", id="factory.initrd-repart-dropin")
def the_initrd_carries_the_repart_dropin_it_will_execute(paths, policy):
    """The drop-in must be inside the initrd tree, not only in the host rootfs."""
    installed = (
        paths.initrd_out / "usr/lib/systemd/system/systemd-repart.service.d/10-device.conf"
    )
    if not installed.is_file():
        from harness import skip

        skip("no initrd tree at %s" % paths.initrd_out)
    assert "--tpm2-pcrs=%s" % policy.pcr_mask_text in installed.read_text()

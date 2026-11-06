"""Tier 1: the ESP frozen-digest guard is wired, on both sides of the build.

vngrd-esp-guard is the boot-partition half of the pre-kernel binding: it
recomputes the ESP digest frozen by vngrd-esp-freeze and refuses a boot whose
bootloader tree changed. Two claims matter here, and a VM boot only ever shows
either of them as a reboot loop with no cause:

  * the unit is installed AND enabled from initrd-root-fs.target.wants -- Before=
    orders a unit, it does not start one, so an unenabled guard is a boot that
    trusts whatever is on the ESP while looking exactly like a boot that checked;
  * vngrd-fixate.service still carries the esp-freeze ExecStart -- without it no
    index is ever written, and a provisioned machine would have no ESP identity
    to check.

Both are greps over the built trees, so this runs without a VM. The binaries are
asserted too: they arrive in the image through build.sh's install list and the
usr/lib/vngrd tree seed rather than a seed-bin entry of their own, so a
reorganisation of either drops them with no build error at all until a boot
fails to exec.
"""

from pathlib import Path

from harness import test

GUARD_UNIT = "usr/lib/systemd/system/vngrd-esp-guard.service"
GUARD_WANTS = "usr/lib/systemd/system/initrd-root-fs.target.wants/vngrd-esp-guard.service"
FIXATE_UNIT = "usr/lib/systemd/system/vngrd-fixate.service"
GUARD_BIN = "usr/lib/vngrd/vngrd-esp-guard"
FREEZE_BIN = "usr/lib/vngrd/vngrd-esp-freeze"


@test(tier="image", id="policy.esp-guard-enabled")
def the_esp_guard_is_installed_and_enabled_for_the_initrd(paths):
    """The guard is in both trees, enabled from an initrd-only target, and fail-closed."""
    for tree in (paths.rootfs_out, paths.initrd_out):
        if not tree.is_dir():
            from harness import skip

            skip("no built tree at %s" % tree)

        unit = tree / GUARD_UNIT
        assert unit.is_file(), "missing %s in %s" % (GUARD_UNIT, tree)
        text = unit.read_text()
        assert "FailureAction=reboot-force" in text, (
            "%s must fail closed: a guard that fails and lets the boot continue "
            "prints nothing anyone is watching for and gates nothing" % GUARD_UNIT
        )
        assert "Before=sysroot.mount" in text, (
            "%s must run before the root is mounted: ordering it after does not "
            "protect the boot, it observes it" % GUARD_UNIT
        )
        assert "ExecStart=/usr/lib/vngrd/vngrd-esp-guard" in text, (
            "%s does not exec the guard binary -- the control is the program, "
            "not the unit" % GUARD_UNIT
        )

        wants = tree / GUARD_WANTS
        assert wants.is_symlink(), (
            "%s must be a symlink: Before= orders a unit, it does not start one, "
            "and an unstarted guard is a boot that trusts a substituted ESP"
            % GUARD_WANTS
        )
        target = Path(wants.readlink())
        assert not target.is_absolute(), "%s must be a relative symlink" % GUARD_WANTS
        assert wants.exists(), "%s dangles" % GUARD_WANTS

        guard_binary = tree / GUARD_BIN
        assert guard_binary.is_file(), "missing %s in %s" % (GUARD_BIN, tree)
        assert (guard_binary.stat().st_mode & 0o111), "vngrd-esp-guard is not executable"

    # The freeze is a third ExecStart of the fixate unit, which is what makes the
    # index exist at all. Asserted in both trees for the same reason as above, and
    # against a message that names the consequence rather than the missing line.
    for tree in (paths.rootfs_out, paths.initrd_out):
        if not tree.is_dir():
            continue
        fixate = tree / FIXATE_UNIT
        assert fixate.is_file(), "missing %s in %s" % (FIXATE_UNIT, tree)
        starts = [line for line in fixate.read_text().splitlines() if line.startswith("ExecStart=")]
        assert any(
            line == "ExecStart=/usr/lib/vngrd/vngrd-esp-freeze" for line in starts
        ), (
            "%s does not run vngrd-esp-freeze: nothing would ever write "
            "VNGRD_NV_ESP_INDEX, and a provisioned machine would have no ESP "
            "identity to check. Found: %s" % (FIXATE_UNIT, starts)
        )
        freeze_binary = tree / FREEZE_BIN
        assert freeze_binary.is_file(), "missing %s in %s" % (FREEZE_BIN, tree)
        assert (freeze_binary.stat().st_mode & 0o111), "vngrd-esp-freeze is not executable"

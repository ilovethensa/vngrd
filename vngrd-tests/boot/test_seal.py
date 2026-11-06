"""Tier 2: the TPM and the seal are load-bearing.

t6a changes the Secure Boot policy (PCR 7) by enrolling a second certificate.
t6b keeps the policy and replaces the TPM's SRK with a fresh one.
t8 breaks the LUKS2 headers so the volume cannot open for a reason unrelated to
the seal -- and therefore checks the TPM precondition explicitly, because "the
root stayed shut" is true with or without a TPM.

All four assert that a TPM was actually bound (`tpm.bound`) before concluding
anything from a locked root. That check is a FAIL, not a skip.
"""

from harness import boot_case, skip, varstore


@boot_case(id="t6a-pcr7", timeout=180)
def t6a_pcr7(vm, policy, tools, report):
    """A different Secure Boot policy must not unlock this root.

    PCR 7 IS the binding, and it is the one systemd-cryptenroll(1) recommends:
    "encrypted volumes would be bound to some combination of PCRs 7, 11, and 14",
    with 0 and 2 explicitly "not advisable" because the certificates measured
    into 7 already cover the code they measure. So this case guards the binding,
    and it is the reason the enrollment runs lock-secureboot-policy and
    lockdown-secureboot-authority in the initrd, at the same instant the
    prediction is computed: the component has to describe the log it will be
    matched against, and those definitions only exist in the initrd's tmpfs
    /var/lib/pcrlock.d -- which is fine, because what survives is the prediction.

    It was XFAIL for one round, and that was real, not a softened test: the
    components were read from a directory the initrd could not see, PCR 7's
    "Variable: SecureBoot-..." record matched nothing, the PCR was unrecognized
    and dropped from the policy, and the volume opened with a modified db. The
    measured mask on a machine with the shipped-only definitions was
    "2, 3, 13, 14" -- no 7. Regenerating the component from the same log the
    prediction used moved it to "0, 1, 2, 3, 7, ...", and PCR 7 has been in the
    policy since.

    PCRs 0-3 are deliberately out: systemd-pcrextend@0-1-<hash> extends PCRs 0
    and 1 immediately before /sysusr/usr is mounted, so a policy naming them is
    unsatisfiable on the boots where that lands after the unseal. That was the
    Esys_PolicyOR 0x1c4 round, and it is documented in vngrd-tpm-pcrlock.service.
    """
    der = varstore.self_signed_certificate(tools, vm.state, "vngrd-attacker")
    try:
        varstore.add_db_certificate(tools, vm.varstore, der)
    except Exception as exc:  # noqa: BLE001 - varstore editing is a capability
        skip("cannot edit the OVMF variable store: %s" % exc)

    boot = vm.start()
    boot.require("tpm.bound")
    # /usr is verity'd and independent of the Secure Boot policy, so it must mount.
    boot.require("boot.usr-mounted")
    boot.require("cryptsetup.start")
    boot.require_absent("ordering.skip-cryptsetup")
    boot.require_absent("boot.root-unsealed")
    boot.require_absent("boot.login-ready")


@boot_case(id="t6b-fresh-srk", timeout=180)
def t6b_fresh_srk(vm, report):
    """A fresh SRK, same varstore, same disk: the volume must not open.

    A fresh TPM state also removes every NV register this image froze. Since the
    guards fail closed before `systemd-cryptsetup`, the expected refusal is earlier than the unseal now: one of the GPT, ESP or rollback
    guards stops the boot. If that ordering ever regresses, cryptsetup starting
    and failing is still an acceptable refusal for this case; the outer property
    is that the root never opens.
    """
    from harness import tpm

    tpm.wipe(vm.tpm_dir)

    boot = vm.start()
    boot.require("tpm.bound")
    boot.require("boot.usr-mounted")
    refused_early = any(
        boot.events.saw(name) for name in ("esp.refused", "gpt.refused", "rollback.refused")
    )
    report.require(
        "fresh-srk.guard-or-cryptsetup",
        refused_early or boot.events.saw("cryptsetup.failed"),
        "a fresh SRK must either trip an NV guard before unseal or make cryptsetup fail",
    )
    boot.require_absent("boot.root-unsealed")
    boot.require_absent("boot.login-ready")


@boot_case(id="t8-luks2", timeout=180)
def t8_luks2(vm, report):
    """Both LUKS2 binary headers broken: the root must not open, /usr must be fine."""
    root = vm.gpt.require_label("vngrd-root")

    # LUKS2 keeps a secondary binary header at partition offset 0x4000. Breaking
    # only the primary lets cryptsetup recover from the secondary and rewrite the
    # primary, producing a fully successful boot on a "corrupted" volume.
    vm.poke(root.offset + 4, b"\0\0")
    vm.poke(root.offset + 0x4000 + 4, b"\0\0")

    boot = vm.start()
    # The volume cannot open for a reason unrelated to the seal, so a missing TPM
    # would be invisible here without this guard.
    boot.require("tpm.bound")
    boot.require("boot.usr-mounted")
    boot.require("cryptsetup.failed")
    boot.require_absent("boot.root-unsealed")
    boot.require_absent("boot.login-ready")


@boot_case(id="t17-tpm-not-bypass", tpm=False, timeout=180)
def t17_tpm_not_bypass(vm, report):
    """With no TPM the volume must stay sealed: the TPM is not optional.

    The outer property is asserted, not the inner one: with no TPM the machine
    does not boot at all, so this shows the machine requires a TPM, not that
    cryptsetup refused one. Whether cryptsetup was reached is reported rather
    than dressed up as a pass.
    """
    boot = vm.start(terminal=("No bootable option or device was found.",))

    boot.require_absent("boot.login-ready")
    boot.require_absent("boot.multi-user")
    boot.require_absent("boot.root-unsealed")
    boot.require_absent("sb.denied")  # otherwise the refusal was Secure Boot, not the TPM
    boot.expect("tpm.absent")
    boot.expect("cryptsetup.start")

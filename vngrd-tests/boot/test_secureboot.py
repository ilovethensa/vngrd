"""Tier 2: Secure Boot accepts and refuses exactly one thing -- the signature.

t1 mutates one byte of the UKI's .linux and expects a firmware refusal. t5 is the
negative control: the same bytes with Secure Boot off must boot. Without t5, a
harness that is simply broken produces the same "no boot" result as one
correctly detecting a tampered image.
"""

from harness import boot_case, skip
from harness.uki import tamper_linux_byte


def _plant_tampered_uki(vm, policy):
    uki = vm.uki()
    offset = tamper_linux_byte(uki)
    if policy.secureboot_cert:
        # Host-side proof that this is a tampering test and not a corrupt file.
        if uki.signature_ok(policy.secureboot_cert):
            raise AssertionError("sbverify accepted a tampered UKI host-side")
    vm.replace_uki(uki.path)
    return offset


@boot_case(id="t1-uki", timeout=120)
def t1_uki(vm, policy, report):
    """A one-byte change to .linux must be refused by the firmware."""
    if not policy.secureboot_cert:
        skip("no SecureBootCertificate configured (fresh checkout)")
    _plant_tampered_uki(vm, policy)

    boot = vm.start(terminal=("No bootable option or device was found.",))
    boot.require("sb.denied")
    boot.require("sb.no-bootable")
    boot.require_absent("kernel.started")
    boot.require_absent("initrd.started")


@boot_case(id="t5-no-secure-boot", secureboot=False, tpm=False, needs_machine=False, timeout=420)
def t5_no_secure_boot(vm, policy, report):
    """The negative control for t1: the same mutation with Secure Boot off boots."""
    _plant_tampered_uki(vm, policy)

    boot = vm.start(terminal=("Booting initrd of",))
    boot.require("kernel.started")
    boot.expect("initrd.started")
    boot.require_absent("sb.denied")
    boot.require_absent("sb.no-bootable")
    # No TPM, so the root cannot unseal; that is expected and asserted so a
    # future change that makes it complete is noticed.
    boot.require_absent("boot.login-ready")

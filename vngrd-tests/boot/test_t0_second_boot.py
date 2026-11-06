"""Tier 2: a machine sealed on its first boot must open again on the next one."""

from harness import boot_case
from harness.qemu import normalise


@boot_case(id="t0-second-boot", timeout=600)
def t0_second_boot(vm, report):
    """The volume sealed by provisioning opens again with no re-seal and no operator.

    systemd-repart is gated on the root partition being absent, so if the first
    boot created it this boot must find it and use it. A "pass" that came from a
    re-provision would mean nothing, so the repart assertions are deliberate.

    WHAT THIS CASE FOUND, in two rounds, and why the fix is the PCR selection.

    Round one -- the first boot after provisioning failed the unseal:

        Please enter LUKS2 token PIN: ...(answered)
        systemd-cryptsetup[174]: Esys_PolicyOR() ErrorCode (0x000001c4)
        Please enter recovery key for disk vngrd-root:

    Measured with a diagnostic run inside the initrd: the host's make-policy had
    run with the root's /var/lib/pcrlock.d populated by the lock-* units, so its
    prediction named PCR 0 = b3bd826a. The next initrd has no /var/lib/pcrlock.d
    (its /var is a tmpfs), so the same event log replayed to PCR 0 = 1c17662 and
    the TPM holding 1c17662 was asked for b3bd826a. 0x1c4 is TPM2_RC_VALUE from
    PolicyOR: "the live PCR is in none of the predicted branches".

    The fix was to generate the definitions at the instant the prediction is
    computed -- the four lock-* steps run in the initrd, immediately before
    make-policy, so component and prediction describe the same instant. That
    moved the ESP policy from "PCR 15 and nothing else" to the intended coverage,
    and PCR 7 came into it, which is the binding systemd-cryptenroll(1)
    recommends over direct firmware measurements.

    Round two -- and the reason the selection is now --pcr=7,13,14. Still
    Esys_PolicyOR 0x1c4, and the diagnostic at unseal time showed why:

        PCR 0  platform-code      5 records  allEventsMatched NO
                                  CALCULATED 1c17662  OBSERVED 1c17662
        PCR 7  secure-boot-policy 8 records  CALCULATED 329effb == policy branch 1

    PCRs 0 and 1 are extended by systemd-pcrextend@0-1-<hash>, which runs
    immediately before /sysusr/usr is mounted -- a point that lands before the
    unseal on some boots and after it on others. A policy computed on a boot
    where it had already run cannot be satisfied on a boot where it has not. That
    is not fixable by ordering, because the two consumers are the same unit at
    different points, so those PCRs are out of the selection. systemd's own
    documentation calls PCRs 0 and 2 "not advisable" for volume unlocking, since
    the certificates measured into PCR 7 already cover them.

    What is left is PCR 7 (certificates, the recommended binding), plus 13 and 14
    (sysexts/shim-policy, one record each and stable across boots).
    """
    boot = vm.start()

    boot.require("boot.usr-mounted")
    boot.require("boot.root-unsealed")
    boot.require("boot.login-ready")
    boot.require_absent("boot.emergency")

    # The volume is the SAME one, not a new one: these are repart doing
    # provisioning work and must not appear on a second boot.
    # Normalise first: the console carries ANSI redraws and CR, and an
    # anchor split by a cursor-positioning sequence does not match a plain
    # substring. Every unit-name assertion here is a stable API string, so
    # normalising is the only thing that makes them see it.
    text = normalise(boot.log_path.read_text(errors="replace"))
    report.require(
        "repart:no-gpt-rewrite",
        "Creating a new GPT disk label" not in text,
        "repart rewrote the partition table on a second boot",
    )
    # A passphrase prompt would mean the TPM did not release the key.
    report.require("tpm:no-passphrase", "Passphrase:" not in text, "a passphrase was requested")

    # The refresh this second boot is supposed to perform. The host-side
    # systemd-pcrlock-make-policy.service used to fail on every boot -- the
    # enrollment's policy covered PCR 15 and the host's own machine-id
    # measurement moved it, so the NV write it must satisfy answered
    # TPM2_RC_PCR_CHANGED -- and it was therefore disabled. It is enabled now,
    # and the evidence that it is *working* rather than merely running is the
    # two full unit names and the absence of their failure lines.
    # The host must NOT run a GPT lock that feeds a definition into
    # /var/lib/pcrlock.d: that component is invisible to the initrd, and writing
    # it there is what made the host's prediction differ from the initrd's on the
    # boot that provisions -- the failure described in the docstring above. Its
    # absence is the assertion.
    report.require(
        "pcrlock:no-host-gpt-lock",
        "Finished Lock GPT Partition Table to TPM PCR Policy." not in text,
        "the host ran a GPT lock, whose component lives where the initrd cannot "
        "see it while still changing the policy shape",
    )
    report.require(
        "pcrlock:policy-made",
        "Finished Make TPM PCR Policy." in text,
        "the host's make-policy did not finish, so the policy never follows the firmware",
    )
    for failed in (
        "Failed to start Make TPM PCR Policy.",
        "Failed to start Lock GPT Partition Table to TPM PCR Policy.",
    ):
        report.require("pcrlock:no-failure:%s" % failed[:24], failed not in text, "%s" % failed)

    # The three bindings this project adds on top of the seal, and why reaching a
    # login prompt is already the assertion. The guards are silent when they pass
    # and reboot-force when they do not, so a machine that got here has passed
    # all three -- but that is the whole point of the controls and a reader
    # should not have to infer it from the absence of a reboot. The refusal text
    # is theirs, and it is the only line any of them can print.
    report.require(
        "prekernel:no-gpt-refusal",
        "vngrd-gpt-guard:" not in text,
        "vngrd-gpt-guard refused this boot: the GPT identity frozen on the first "
        "boot no longer matches the disk, which is either the substitution the "
        "control exists to catch or a digest that is not stable across boots",
    )
    report.require(
        "prekernel:no-esp-refusal",
        "vngrd-esp-guard:" not in text,
        "vngrd-esp-guard refused this boot: the ESP contents frozen on the first "
        "boot no longer match, which is either a replaced bootloader or a digest "
        "that does not survive what the first host boot writes to the ESP",
    )
    report.require(
        "prekernel:no-rollback-refusal",
        "vngrd-rollback-guard:" not in text,
        "vngrd-rollback-guard refused this boot: the running version is below the "
        "floor this machine committed, which would loop it",
    )
    # vngrd-rollback-commit.service is Required by boot-complete.target, and that
    # target's drop-in (boot-complete.target.d/10-vngrd.conf) documents that any
    # unit near it changes which job PID 1 deletes when an ordering cycle is
    # resolved -- which once blessed a slot with no consistency check at all. The
    # cycle itself is gone; this is the assertion that the new unit did not bring
    # it back.
    report.require(
        "boot:no-ordering-cycle",
        "Ordering cycle" not in text,
        "PID 1 had to break an ordering cycle: a job was dropped and the boot "
        "completed anyway, which is how the gate was once skipped silently",
    )

    # The fixate digest was frozen on the first boot, so this is the first boot
    # on which the fixate check can actually apply.
    boot.expect("fixate.nv-sealed")
    boot.expect("fixate.applied")

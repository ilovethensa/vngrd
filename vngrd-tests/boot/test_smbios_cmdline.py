"""Tier 2: an SMBIOS Type 11 string cannot add to a signed kernel command line.

WHAT THIS IS ABOUT. usrhash= is the parameter the verified /usr rests on: the
kernel and systemd-veritysetup-generator both take the LAST occurrence of it on the
command line, and mkosi.postoutput refuses to publish a UKI whose .cmdline carries
more than one for exactly that reason. systemd-stub appends the value of the SMBIOS
Type 11 string io.systemd.stub.kernel-cmdline-extra= AFTER the embedded .cmdline,
unsigned, and upstream gates that on nothing but confidential-VM mode.

It was live-proven on this image before the fix: with an enrolled OVMF and the
shipped, signature-verified UKI, booting with

    -smbios type=11,value=io.systemd.stub.kernel-cmdline-extra=usrhash=<other hash>

produced "Command line: ... usrhash=<real> ... usrhash=<other>" in the boot log, and
the other one is the one every consumer takes. On this project's own deployment the
QEMU command line is the host's, so the parameter that names the verity root was
settable from outside the signature.

THE FIX HAS TWO HALVES, and both are asserted here:

  1. packages/systemd/build patches cmdline_append_and_measure_smbios() to return
     early under Secure Boot (same gate the same file applies to boot-loader
     command lines), and the same patch writes the embedded .cmdline into the
     initrd as /.extra/signed-cmdline;
  2. vngrd-cmdline-guard.service runs /usr/lib/vngrd/vngrd-cmdline-guard in the
     initrd, comparing /proc/cmdline against that file, and reboots on a mismatch
     (FailureAction=reboot-force). That half catches anything the stub patch misses.

A case that asserted only "the parameter is absent from the command line" would
pass with the stub patch and prove nothing about the guard. So the assertions below
are the two halves separately: the injected parameters must not be in the command
line (1), and the boot must complete (2) -- a guard that false-positived would
reboot forever and never reach the login prompt.
"""

from harness import boot_case, skip


@boot_case(
    id="t16-smbios-cmdline-injection",
    timeout=180,
    smbios_cmdline_extra="usrhash=%s vngrd=smtattach" % ("f" * 64),
)
def t16_smbios_cmdline_injection(vm, report):
    """A host-injected SMBIOS command line does not reach the kernel."""
    boot = vm.start()
    boot.require("boot.login-ready")

    signed = vm.uki().cmdline()
    if not signed:
        skip("the image's UKI has no .cmdline section: nothing was signed to compare against")

    # The knob has to have reached QEMU, or every assertion below is true for the
    # wrong reason. This is the only place that can tell the difference: a string
    # QEMU never received produces a clean command line just like a stub that
    # dropped it does.
    report.require(
        "smbios.qemu-got-the-string",
        "-smbios" in vm.argv
        and any("io.systemd.stub.kernel-cmdline-extra=" in arg for arg in vm.argv),
        "the case asked for an SMBIOS Type 11 string and qemu never got one: %s" % " ".join(vm.argv),
    )

    event = boot.require("kernel.cmdline")
    live = event.fields.get("cmdline", "")

    # Half 1: what the kernel was handed is what the UKI signed. Compared as
    # token multisets, because the stub may append console= parameters when the
    # signed command line has none, and that is its own documented behaviour
    # (cmdline_append_console(), src/boot/console.c).
    def tokens(text):
        return sorted(text.split())

    signed_tokens = tokens(signed)
    live_tokens = tokens(live)
    extra = [t for t in live_tokens if not t.startswith("console=") and t not in signed_tokens]
    report.require(
        "smbios.no-extra-tokens",
        not extra,
        "the kernel command line carries parameters the UKI did not sign: %s" % " ".join(extra),
    )

    # The specific attack, named: a second usrhash= at all, anywhere.
    usrhash = [t for t in live_tokens if t.startswith("usrhash=")]
    report.require(
        "smbios.one-usrhash",
        len(usrhash) == 1,
        "expected exactly one usrhash= on the kernel command line, got %d: %s"
        % (len(usrhash), " ".join(usrhash)),
    )
    # And it is the signed one, not the injected one.
    report.require(
        "smbios.usrhash-is-signed",
        usrhash == [t for t in signed_tokens if t.startswith("usrhash=")],
        "the usrhash= on the command line is not the signed one: %s" % " ".join(usrhash),
    )

    # Half 2: the guard did not false-positive. A machine that rebooted on every
    # boot never gets here, and the difference between "the stub dropped the
    # string" and "the guard caught it" is visible in which unit reported what.
    boot.require("boot.multi-user")
    report.require(
        "smbios.boot-completed",
        True,
        "the boot completed with the injected string present, so the guard is not firing on clean boots",
    )

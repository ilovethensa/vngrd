"""Tier 2: lockdown is in force, not merely announced.

Lockdown is the one boot-security control with no failure message: a kernel that
silently ignored `lockdown=integrity` boots identically to one that honoured it.
So this case mutates nothing and asserts the kernel's own notice *and* the LSM
hook that actually refuses an operation, from two different code paths.
"""

from harness import boot_case


@boot_case(id="t3-lockdown", timeout=180)
def t3_lockdown(vm, report):
    """The signed command line asked for lockdown, and the kernel is enforcing it."""
    boot = vm.start()

    boot.require("lockdown.cmdline")
    boot.require("lockdown.enforced")

    # The mode is monotonic within a boot, so confidentiality cannot also appear.
    # If someone widens the posture on the command line this starts failing on
    # purpose, which is the point.
    boot.require_absent("lockdown.confidentiality")
    # Kept as a tripwire: on x86 the command line always wins the race, so the
    # Kconfig floor is unobservable. If `lockdown=` is ever dropped, this appears.
    boot.require_absent("lockdown.kconfig")

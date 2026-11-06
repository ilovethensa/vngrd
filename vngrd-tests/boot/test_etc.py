"""Tier 2: /etc is a tmpfs rebuilt from the verified factory tree.

The property that a planted unit does not survive a reboot needs the guest to
report on itself, because the harness has no way to plant a file inside /etc and
watch the next boot. So this case requires the structured reporter: the guest
runs its checks and says what it saw, and the host asserts on the reported ids.
It skips cleanly when the image does not ship the reporter, rather than passing
vacuously.
"""

from harness import boot_case, skip


@boot_case(id="t15-etc-tmpfs", timeout=420)
def t15_etc_tmpfs(vm, report):
    """The machine booted on a tmpfs /etc, and the removed machinery is gone."""
    boot = vm.start()
    boot.require("boot.login-ready")

    if boot.events.producer != "reporter":
        skip(
            "the image does not ship the vngrd test reporter, so the guest cannot "
            "report on /etc; run guest/install.sh and rebuild to enable this case"
        )

    boot.expect_no_parse_issues()
    for assertion_id in (
        "etc-is-tmpfs",
        "etc-nsswitch-present",
        "etc-confine-gone",
    ):
        event = boot.require("assert", id=assertion_id)
        report.require(
            "check:%s" % assertion_id,
            event.fields.get("ok") == "1",
            "%s reported ok=%s detail=%s"
            % (assertion_id, event.fields.get("ok"), event.fields.get("detail")),
        )
    # How far the boot got is not a security property; it is reported so a
    # log-derived pass cannot be mistaken for a reporter-derived one.
    boot.expect("boot.self-test-complete")

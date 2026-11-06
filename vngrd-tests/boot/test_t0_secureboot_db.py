"""Tier 2: the db the firmware actually enforces contains the intended CAs.

The host-side image tier proves what the published `db.auth` contains; this
case proves what the machine's firmware exposes in its live `db` variable. The
two are not the same claim: a host-side enrolment that silently skipped a
certificate, or firmware that rejected part of the update, would pass the first
and fail here.

The guest has no `efi-readvar` (the image is deliberately small and does not
carry efitools), so the certificate subjects are extracted with `tr` and read
back over the console. That is a read of the live efivarfs file, not a
host-side parse of the OVMF variable store.
"""

from __future__ import annotations

import re
import time

from harness import boot_case

LOGIN_PROMPT = re.compile(r"login:\s*$", re.MULTILINE)
POWERED_OFF = re.compile(r"reboot: Power down|Power down|System halted", re.IGNORECASE)
DB_DONE = re.compile(r"VNGRO_DB_DONE (\d+)")
DB_VAR = "/sys/firmware/efi/efivars/db-d719b2cb-3d3a-4596-a3bc-dad00e67656f"


def _root_shell(console) -> None:
    if not console.wait_for(LOGIN_PROMPT, 240):
        raise AssertionError("the Secure Boot db case never reached a login prompt")
    console.type("root")
    if not console.wait_for(re.compile("Welcome to fish"), 120):
        raise AssertionError("root login did not start a shell")
    time.sleep(2)
    console.type("")
    console.type("echo VNGRO_SHELL_READY")
    if not console.wait_for(re.compile("VNGRO_SHELL_READY"), 60):
        raise AssertionError("root login did not reach a shell")


def _read_db(console, seen: dict) -> None:
    _root_shell(console)
    console.type("test -e %s; echo VNGRO_DB_EXISTS $status" % DB_VAR)
    if not console.wait_for(re.compile(r"VNGRO_DB_EXISTS (\d+)"), 60):
        raise AssertionError("the guest produced no db existence status")
    match = re.search(r"VNGRO_DB_EXISTS (\d+)", console.tail())
    seen["exists_status"] = int(match.group(1))

    # The variable is ESLs plus attributes; the X.509 subjects are ASCII in the
    # DER (PrintableString/UTF8String), so replacing non-printing bytes with
    # newlines makes them readable without a parser in the guest. LC_ALL=C is
    # required: a UTF-8 locale makes tr's [:print:] class useless on DER bytes.
    console.type(
        "LC_ALL=C tr -c '[:print:]' '\\n' < %s; echo VNGRO_DB_DONE $status" % DB_VAR
    )
    if not console.wait_for(DB_DONE, 120):
        raise AssertionError("the guest produced no db dump terminator")
    match = DB_DONE.search(console.tail())
    seen["dump_status"] = int(match.group(1))
    seen["text"] = console.tail()

    console.type("sync")
    console.type("systemctl poweroff")
    if not console.wait_for(POWERED_OFF, 180):
        raise AssertionError("the guest did not power off after the db check")


@boot_case(id="t0-secureboot-db", timeout=600)
def t0_secureboot_db(vm, report):
    """The firmware's live db names the vngrd and Microsoft 2023 CAs."""
    seen: dict = {}
    boot = vm.start(interact=lambda console: _read_db(console, seen))
    boot.require("boot.usr-mounted")
    boot.require("boot.root-unsealed")

    report.require(
        "db:variable-present",
        seen.get("exists_status") == 0,
        "the guest has no %s (status %s)" % (DB_VAR, seen.get("exists_status")),
    )
    report.require(
        "db:dump-read",
        seen.get("dump_status") == 0,
        "reading db failed (status %s)" % seen.get("dump_status"),
    )

    text = seen.get("text", "")
    for label, needle in (
        ("vngrd", "vngrd Secure Boot"),
        ("microsoft-uefi-2023", "Microsoft UEFI CA 2023"),
        ("microsoft-option-rom-2023", "Microsoft Option ROM UEFI CA 2023"),
    ):
        report.require(
            "db:cert:%s" % label,
            needle in text,
            "the live db does not contain %r; the enrolment did not install the "
            "same trust set as secureboot/db.auth" % needle,
        )
    report.require(
        "db:no-microsoft-2011",
        "Microsoft Corporation UEFI CA 2011" not in text,
        "the legacy Microsoft UEFI CA 2011 is enrolled; the published db.auth "
        "deliberately excludes it",
    )

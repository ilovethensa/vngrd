"""Tier 0: the guest reporter payload, run as the guest would run it.

This is the one test that ties the two halves of the event contract together:
the shell script the image ships is executed here, and its output is parsed by
the same parser the host uses against a real console. A change to the line
format on either side fails here, in milliseconds, instead of on a boot.
"""

import subprocess

from harness import guest, test

REPORTER = "guest/vngrd-testreport"
CHECKS = "guest/checks.tsv"


def _run(paths, console, *args, expect_rc=0):
    result = subprocess.run(
        ["sh", str(paths.tests / REPORTER), *args],
        env={"VNGRD_TEST_CONSOLE": str(console), "PATH": "/usr/bin:/bin"},
        capture_output=True,
        text=True,
    )
    assert result.returncode == expect_rc, (result.returncode, result.stderr)
    return console.read_text()


@test(tier="unit", id="guest-payload.event")
def the_reporter_emits_events_the_host_can_parse(paths, tmp):
    console = tmp / "console.log"
    console.write_text("")
    text = _run(paths, console, "event", "boot.usr-mounted", "fs=erofs")
    stream = guest.EventStream.parse(text)
    assert not stream.issues, stream.issues
    assert stream.producer == "reporter"
    assert stream.saw("boot.usr-mounted", fs="erofs")


@test(tier="unit", id="guest-payload.assert")
def the_reporter_emits_assertions_with_an_id_and_status(paths, tmp):
    console = tmp / "console.log"
    console.write_text("")
    text = _run(paths, console, "assert", "id=etc-is-tmpfs", "ok=1", "detail=tmpfs")
    stream = guest.EventStream.parse(text)
    assert stream.saw("assert", id="etc-is-tmpfs", ok="1", detail="tmpfs")


@test(tier="unit", id="guest-payload.checks")
def the_check_runner_evaluates_every_mode(paths, tmp):
    tsv = tmp / "checks.tsv"
    tsv.write_text(
        "eq-check\teq\thello\techo hello\n"
        "has-check\thas\tworld\techo hello world\n"
        "rc-check\trc\t0\ttrue\n"
        "absent-check\tabsent\t/nonexistent-vngrd-path\t\n"
        "bad-check\teq\tnope\techo other\n"
    )
    console = tmp / "console.log"
    console.write_text("")
    text = _run(paths, console, "checks", str(tsv))
    stream = guest.EventStream.parse(text)
    assert not stream.issues, stream.issues
    verdicts = {event.fields["id"]: event.fields["ok"] for event in stream.all("assert")}
    assert verdicts["eq-check"] == "1", verdicts
    assert verdicts["has-check"] == "1", verdicts
    assert verdicts["rc-check"] == "1", verdicts
    assert verdicts["absent-check"] == "1", verdicts
    assert verdicts["bad-check"] == "0", verdicts
    assert stream.saw("boot.self-test-complete")


@test(tier="unit", id="guest-payload.checks-file")
def the_shipped_checks_file_is_well_formed(paths):
    lines = (paths.tests / CHECKS).read_text().splitlines()
    count = 0
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        # A trailing command column may be omitted for `absent`, which names a
        # path rather than running anything.
        assert len(fields) in (3, 4), "malformed checks.tsv line: %r" % line
        assertion_id, mode, _expected = fields[:3]
        command = fields[3] if len(fields) == 4 else ""
        assert mode in {"eq", "has", "rc", "absent"}, mode
        if mode != "absent":
            assert command.strip(), "no command for %s" % assertion_id
        count += 1
    assert count >= 3, "the checks file has only %d checks" % count

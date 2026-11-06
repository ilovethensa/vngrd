"""Result model and reporting.

The verdict of a case is its exit status: pass means the function returned,
fail means it raised. Nothing greps a text file for the word "FAIL". Assertions
are recorded so the report can say *which* property was checked, and so the
runner can enforce that a case recorded at least one.
"""

from __future__ import annotations

import dataclasses
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

PASS = "pass"
FAIL = "fail"
SKIP = "skip"
XFAIL = "xfail"
XPASS = "xpass"


@dataclass
class Assertion:
    id: str
    ok: bool
    detail: str = ""


@dataclass
class CaseResult:
    id: str
    tier: str
    status: str = PASS
    seconds: float = 0.0
    message: str = ""
    traceback: str = ""
    assertions: list[Assertion] = field(default_factory=list)
    artifacts: list[str] = field(default_factory=list)
    log: str = ""

    @property
    def failed(self) -> bool:
        return self.status == FAIL

    @property
    def skipped(self) -> bool:
        return self.status == SKIP


class Recorder:
    """Per-case assertion and artifact recorder, injected as the `report` fixture."""

    def __init__(self, result: CaseResult) -> None:
        self.result = result

    def record(self, assertion_id: str, ok: bool, detail: str = "") -> bool:
        self.result.assertions.append(Assertion(assertion_id, bool(ok), detail))
        return bool(ok)

    def check(self, assertion_id: str, condition: object, detail: str = "") -> bool:
        ok = bool(condition)
        self.record(assertion_id, ok, "" if ok else (detail or "condition was false"))
        return ok

    def require(self, assertion_id: str, condition: object, detail: str = "") -> None:
        if not self.check(assertion_id, condition, detail):
            raise AssertionError("%s: %s" % (assertion_id, detail or "condition was false"))

    def artifact(self, path: str | Path) -> None:
        self.result.artifacts.append(str(path))


def timed(func, *args, **kwargs):
    start = time.monotonic()
    value = func(*args, **kwargs)
    return value, time.monotonic() - start


def write_junit(results: list[CaseResult], destination: Path) -> None:
    suite = ET.Element(
        "testsuite",
        {
            "name": "vngrd-tests",
            "tests": str(len(results)),
            "failures": str(sum(1 for r in results if r.status == FAIL)),
            "skipped": str(sum(1 for r in results if r.status == SKIP)),
            "time": "%.3f" % sum(r.seconds for r in results),
        },
    )
    for result in results:
        case = ET.SubElement(
            suite,
            "testcase",
            {"classname": "vngrd.%s" % result.tier, "name": result.id, "time": "%.3f" % result.seconds},
        )
        if result.status == FAIL:
            failure = ET.SubElement(case, "failure", {"message": result.message or "failed"})
            failure.text = result.traceback or result.message
        elif result.status == SKIP:
            ET.SubElement(case, "skipped", {"message": result.message})
        elif result.status == XFAIL:
            ET.SubElement(case, "skipped", {"message": "xfail: %s" % result.message})
        for assertion in result.assertions:
            ET.SubElement(
                case,
                "system-out",
                {"name": assertion.id},
            ).text = "ok=%s %s" % (int(assertion.ok), assertion.detail)
    tree = ET.ElementTree(suite)
    ET.indent(tree, space="  ")
    tree.write(destination, encoding="utf-8", xml_declaration=True)


def to_dict(results: list[CaseResult]) -> list[dict]:
    return [dataclasses.asdict(result) for result in results]

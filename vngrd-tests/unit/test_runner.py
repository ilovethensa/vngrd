"""Tier 0: the harness itself.

The old suite's worst failures were meta-failures: an assertion that never ran,
a case graded from text, a case that measured nothing. These tests pin the
behaviour that makes those impossible.
"""

from harness import test
from harness.errors import ConfigError
from harness.registry import CASES, Case, test as register
from harness.result import Recorder, CaseResult
from harness.runner import _select, run_case


class StubSession:
    """A Session that provides no fixture except `report`."""

    def build_kwargs(self, case, result):
        kwargs = {}
        if "report" in case.fixtures:
            kwargs["report"] = Recorder(result)
        return kwargs

    def cleanup(self):
        pass


def _case(func, tier="unit", **kwargs) -> Case:
    return Case(id=kwargs.pop("id", func.__name__), func=func, tier=tier, doc="", **kwargs)


@test(tier="unit", id="runner.no-assertions-boot")
def a_boot_case_that_asserts_nothing_is_a_failure():
    """Booting and returning is not a measurement."""
    result = run_case(_case(lambda: None, tier="boot"), StubSession())
    assert result.status == "fail", result.status
    assert "no assertions" in result.message, result.message


@test(tier="unit", id="runner.no-assertions-unit")
def a_unit_case_that_returns_is_a_pass():
    """Tier 0 functions may use plain assert without recording."""
    result = run_case(_case(lambda: None, tier="unit"), StubSession())
    assert result.status == "pass", result.status


@test(tier="unit", id="runner.recorded-failure")
def a_recorded_failed_assertion_fails_the_case():
    def body(report):
        report.check("something", False, "it was false")

    result = run_case(_case(body, tier="unit"), StubSession())
    assert result.status == "fail", result.status
    assert "something" in result.message, result.message


@test(tier="unit", id="runner.xfail")
def xfail_and_xpass_are_both_reported():
    def boom():
        raise AssertionError("known broken")

    result = run_case(_case(boom, xfail="waiting on a fix"), StubSession())
    assert result.status == "xfail", result.status

    result = run_case(_case(lambda: None, xfail="waiting on a fix"), StubSession())
    assert result.status == "xpass", result.status


@test(tier="unit", id="runner.duplicate-id")
def a_duplicate_case_id_is_refused():
    @register(tier="unit", id="duplicate-probe")
    def first():
        pass

    try:

        @register(tier="unit", id="duplicate-probe")
        def second():
            pass

    except RuntimeError:
        CASES.pop("duplicate-probe", None)
        return
    CASES.pop("duplicate-probe", None)
    raise AssertionError("the registry accepted two cases with the same id")


@test(tier="unit", id="runner.select")
def selection_by_tier_and_id_is_exact():
    a = _case(lambda: None, tier="unit", id="a")
    b = _case(lambda: None, tier="image", id="b")
    assert _select([a, b], [], [], ["unit"]) == [a]
    assert _select([a, b], ["b"], [], []) == [b]
    try:
        _select([a, b], ["nope"], [], [])
    except ConfigError:
        return
    raise AssertionError("selecting a missing id did not fail")


@test(tier="unit", id="runner.recorder")
def the_recorder_keeps_ok_and_not_ok_assertions():
    result = CaseResult(id="x", tier="unit")
    recorder = Recorder(result)
    assert recorder.check("yes", True)
    assert not recorder.check("no", False, "detail")
    assert [(a.id, a.ok) for a in result.assertions] == [("yes", True), ("no", False)]

"""Discovery and execution.

Two invariants the old harness could not hold, enforced here:

  1. A case that runs must assert something. A boot case that merely boots and
     returns is graded a failure, because "green with no assertions" is exactly
     the false pass the old text-graded verdict files produced.

  2. The verdict is the exception, not a string. Nothing greps a log for the
     word FAIL.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import time
import traceback
from pathlib import Path

from . import log
from .context import Options, Session
from .errors import ConfigError, SkipTest
from .paths import Paths
from .registry import CASES, TIERS, Case, by_tier
from .result import FAIL, PASS, SKIP, XFAIL, XPASS, CaseResult, to_dict, write_junit

TIERS_REQUIRING_BOOT = ("boot",)


def discover(paths: Paths, tiers: tuple[str, ...] = TIERS) -> list[str]:
    """Import every case module under the requested tier directories."""
    loaded: list[str] = []
    for tier in tiers:
        tier_dir = paths.tests / tier
        if not tier_dir.is_dir():
            continue
        for module_path in sorted(tier_dir.glob("*.py")):
            if module_path.name.startswith("_"):
                continue
            name = "vngrd_cases_%s_%s" % (tier, module_path.stem)
            spec = importlib.util.spec_from_file_location(name, module_path)
            if spec is None or spec.loader is None:
                raise ConfigError("cannot load case module %s" % module_path)
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            spec.loader.exec_module(module)
            loaded.append(str(module_path))
    return loaded


def _select(cases: list[Case], ids: list[str], tags: list[str], tiers: list[str]) -> list[Case]:
    selected = cases
    if tiers:
        selected = [c for c in selected if c.tier in tiers]
    if ids:
        wanted = set(ids)
        selected = [c for c in selected if c.id in wanted]
        missing = wanted - {c.id for c in selected}
        if missing:
            raise ConfigError("no such case: %s" % ", ".join(sorted(missing)))
    if tags:
        selected = [c for c in selected if set(tags) & set(c.tags)]
    return selected


def _validate_fixtures(cases: list[Case]) -> None:
    """Fail collection if a case asks for a fixture that does not exist."""
    known = {
        "report",
        "tmp",
        "policy",
        "image",
        "tools",
        "paths",
        "machine",
        "vm",
        "session",
    }
    for case in cases:
        unknown = set(case.fixtures) - known
        if unknown:
            raise ConfigError(
                "case %r asks for unknown fixture(s): %s" % (case.id, ", ".join(sorted(unknown)))
            )


def run_case(case: Case, session: Session) -> CaseResult:
    result = CaseResult(id=case.id, tier=case.tier)
    log.step("%s [%s]" % (case.id, case.tier))
    start = time.monotonic()
    try:
        kwargs = session.build_kwargs(case, result)
        case.func(**kwargs)
        result.status = PASS
    except SkipTest as exc:
        result.status = SKIP
        result.message = str(exc)
    except AssertionError as exc:
        result.status = FAIL
        result.message = str(exc) or "assertion failed"
        result.traceback = traceback.format_exc()
    except Exception as exc:  # noqa: BLE001 - a harness error is still a failed case
        result.status = FAIL
        result.message = "%s: %s" % (type(exc).__name__, exc)
        result.traceback = traceback.format_exc()
    finally:
        result.seconds = time.monotonic() - start

    # A recorded assertion that is not ok fails the case even if the function
    # returned. report.check() is non-raising by design, so this is what makes it
    # safe to use.
    if result.status == PASS:
        failed = [a.id for a in result.assertions if not a.ok]
        if failed:
            result.status = FAIL
            result.message = "assertion(s) failed: %s" % ", ".join(failed)

    # xfail bookkeeping: a known-broken case that starts passing must be seen.
    if case.xfail:
        if result.status == FAIL:
            result.status = XFAIL
            result.message = case.xfail
        elif result.status == PASS:
            result.status = XPASS
            result.message = "case marked xfail (%s) but passed" % case.xfail

    # No-assertion enforcement, boot tier only: the old false-green lived there.
    if (
        case.tier in TIERS_REQUIRING_BOOT
        and result.status == PASS
        and not case.allow_empty
        and not result.assertions
    ):
        result.status = FAIL
        result.message = "case made no assertions: it cannot have measured anything"

    if result.status == FAIL:
        for assertion in result.assertions:
            if not assertion.ok:
                log.bad("%s: %s" % (assertion.id, assertion.detail or "failed"))

    return result


def run(args: argparse.Namespace) -> int:
    paths = Paths.load()
    try:
        loaded = discover(paths, tuple(args.tier or TIERS))
    except ConfigError as exc:
        log.bad(str(exc))
        return 2

    cases = _select(list(CASES.values()), args.case or [], args.tag or [], args.tier or [])
    cases.sort(key=lambda c: (TIERS.index(c.tier), c.id))

    _validate_fixtures(cases)

    if not cases:
        log.bad("no cases selected (%d modules loaded)" % len(loaded))
        return 2

    options = Options(
        version=args.version,
        provision=args.provision,
        keep=args.keep,
        force_boot=args.tier == ["boot"],
        verbose=args.verbose,
    )
    session = Session(paths, options)

    log.say("vngrd-tests: %d case(s) across %s" % (len(cases), ", ".join(args.tier or TIERS)))
    log.say("image %s from %s" % (session.version, paths.image_out))
    log.say("")

    results: list[CaseResult] = []
    failures = 0
    for case in cases:
        result = run_case(case, session)
        results.append(result)
        if result.status == FAIL:
            failures += 1
            if args.maxfail and failures >= args.maxfail:
                log.warn("stopping after %d failure(s)" % failures)
                break
    session.cleanup()

    log.say("")
    log.say("=== summary ===")
    for result in results:
        marker = {
            PASS: log.GREEN + "PASS" + log.NONE,
            FAIL: log.RED + "FAIL" + log.NONE,
            SKIP: log.YELLOW + "SKIP" + log.NONE,
            XFAIL: log.YELLOW + "XFAIL" + log.NONE,
            XPASS: log.RED + "XPASS" + log.NONE,
        }[result.status]
        log.say("  %-6s %-32s %6.2fs %s" % (marker, result.id, result.seconds, result.message))
    log.say("")

    if args.junit:
        write_junit(results, Path(args.junit))
        log.say("junit: %s" % args.junit)
    if args.json:
        # to_dict and not r.__dict__: a CaseResult carries a list of Assertion
        # dataclasses (Recorder.require's records), which the stdlib encoder
        # refuses with TypeError. The symptom is a run in which every case has
        # passed and the LAST thing it does is raise, exit 1 and write no json --
        # a green boot tier reported as a failed make.
        Path(args.json).write_text(json.dumps(to_dict(results), indent=2) + "\n")
        log.say("json:  %s" % args.json)

    return 1 if failures else 0


def list_cases(args: argparse.Namespace) -> int:
    paths = Paths.load()
    discover(paths, TIERS)
    cases = _select(list(CASES.values()), args.case or [], args.tag or [], args.tier or [])
    cases.sort(key=lambda c: (TIERS.index(c.tier), c.id))
    for case in cases:
        first_line = (case.doc.splitlines() or [""])[0]
        if case.tier != "boot":
            log.say("%-6s %-30s %s" % (case.tier, case.id, first_line))
            continue
        flags = []
        if case.secureboot:
            flags.append("sb")
        if case.tpm:
            flags.append("tpm")
        if case.needs_machine:
            flags.append("machine")
        if case.xfail:
            flags.append("xfail")
        log.say("%-6s %-30s %-22s %s" % (case.tier, case.id, ",".join(flags), first_line))
    log.say("")
    log.say("%d case(s)" % len(cases))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vngrd-tests", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument(
            "--tier",
            action="extend",
            nargs="+",
            choices=[*TIERS, "all"],
            help="tier(s) to include ('all' for every tier)",
        )
        p.add_argument("--case", action="extend", nargs="+", help="case id(s)")
        p.add_argument("--tag", action="extend", nargs="+", help="tag filter(s)")

    p_run = sub.add_parser("run", help="run cases")
    common(p_run)
    p_run.add_argument("--version", help="image version (default: newest)")
    p_run.add_argument("--provision", action="store_true", help="re-provision the machine")
    p_run.add_argument("--keep", action="store_true", help="keep per-case scratch")
    p_run.add_argument("--maxfail", type=int, default=0, help="stop after N failures")
    p_run.add_argument("-v", "--verbose", action="count", default=0)
    p_run.add_argument("--junit", help="write JUnit XML here")
    p_run.add_argument("--json", help="write JSON results here")
    p_run.set_defaults(func=run)

    p_list = sub.add_parser("list", help="list cases")
    common(p_list)
    p_list.set_defaults(func=list_cases)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    # Default tier selection: the cheap tiers only. The boot tier needs qemu, a
    # TPM and several minutes, so it is opt-in (`--tier boot` or `--tier all`).
    if not args.tier and args.command == "run":
        args.tier = ["unit", "image"]
    if args.tier and "all" in args.tier:
        args.tier = list(TIERS)
    try:
        return args.func(args)
    except ConfigError as exc:
        log.bad(str(exc))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

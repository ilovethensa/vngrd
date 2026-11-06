"""Tier 0: the config parser, which is the suite's single source of truth."""

from harness import test
from harness.paths import _version_key
from harness.policy import merge_ini, parse_ini
from harness.util import parse_scalars


@test(tier="unit", id="policy.ini")
def ini_reader_handles_sections_comments_and_last_value_wins(tmp):
    path = tmp / "mkosi.conf"
    path.write_text(
        "# a comment\n"
        "[Content]\n"
        "KernelCommandLine=first\n"
        "KernelCommandLine=second\n"
        "\n"
        "[Validation]\n"
        "SignExpectedPcr=yes\n"
    )
    sections = parse_ini(path)
    assert sections["Content"]["KernelCommandLine"] == "second"
    assert sections["Validation"]["SignExpectedPcr"] == "yes"


@test(tier="unit", id="policy.ini-merge")
def ini_merge_overrides_per_key_and_keeps_the_rest():
    base = {"Content": {"A": "1", "B": "2"}}
    merge_ini(base, {"Content": {"B": "3"}, "Build": {"C": "4"}})
    assert base == {"Content": {"A": "1", "B": "3"}, "Build": {"C": "4"}}


@test(tier="unit", id="policy.scalars")
def scalar_parsing_accepts_every_spelling_repart_emits():
    assert parse_scalars("7") == [7]
    assert parse_scalars("5,7") == [5, 7]
    assert parse_scalars("7, 5") == [5, 7]
    assert parse_scalars("[5, 7]") == [5, 7]
    assert parse_scalars("") == []


@test(tier="unit", id="policy.version-order")
def version_sorting_is_numeric_not_lexical():
    versions = ["0.10", "0.2", "0.1"]
    assert sorted(versions, key=_version_key, reverse=True) == ["0.10", "0.2", "0.1"]

"""Tests for check_review.py: one good and one bad case per rule."""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("check_review", HERE / "check_review.py")
assert _spec is not None and _spec.loader is not None
check_review = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_review)
check = check_review.check


PROSE = """## Summary

The change does what the ticket asks.

## Findings

F1. modules/x.py:42 — a None owner reaches .lower() and the sweep crashes — MEDIUM — 0.7
F2. modules/y.py:10-14 -- the retry loop never sleeps on 429 -- LOW -- 0.4
"""

PROSE_WITH_SUMMARY = """## What this change does

It adds the retry loop.
It keeps the old path.
It logs each retry.

## Findings

None.
"""


def review(*fields: str, prose: str = PROSE) -> str:
    return prose + "\n" + "\n".join(fields) + "\n"


def faults_matching(text: str, pattern: str) -> list[str]:
    return [f for f in check(text) if re.search(pattern, f)]


# --- the three good shapes ---------------------------------------------------


def test_pass_is_clean() -> None:
    assert check(review("verdict: PASSED")) == []


def test_rework_with_reason_is_clean() -> None:
    assert check(review("verdict: REWORK NEEDED", "reason: F1 breaks the sweep on None")) == []


def test_could_not_observe_with_description_is_clean() -> None:
    text = review(
        "verdict: REWORK NEEDED",
        "reason: could not observe: branch head 5f1e is not fetchable from origin",
    )
    assert check(text) == []


def test_findings_none_is_clean() -> None:
    prose = "## Findings\n\nNone.\n"
    assert check(review("verdict: REWORK NEEDED", "reason: x", prose=prose)) == []


# --- rule: exactly one verdict line with one of the two values -------------


def test_missing_verdict() -> None:
    assert faults_matching(review(prose="Looks good to me.\n"), "exactly one verdict")


def test_two_verdicts() -> None:
    text = review("verdict: REWORK NEEDED", "reason: x", "verdict: PASSED")
    assert faults_matching(text, "exactly one verdict")


def test_prose_verdict_counts_as_a_second_verdict() -> None:
    prose = "Verdict: fine overall.\n\n## Findings\n\nNone.\n"
    assert faults_matching(review("verdict: REWORK NEEDED", "reason: x", prose=prose), "exactly one verdict")


@pytest.mark.parametrize(
    "value",
    ["PASS", "passed", "CODE REVIEW PASSED", "CODE_REVIEW_PASSED", "`REWORK NEEDED`", "SHIP"],
)
def test_verdict_value_must_be_canonical(value: str) -> None:
    assert faults_matching(review(f"verdict: {value}"), "verdict must be exactly one of")


@pytest.mark.parametrize("line", ["  verdict: REWORK NEEDED", "Verdict: REWORK NEEDED"])
def test_verdict_line_must_be_bare(line: str) -> None:
    assert faults_matching(review(line), "must be bare")


def test_markdown_verdict_is_not_a_verdict() -> None:
    assert faults_matching(review("**verdict:** REWORK NEEDED"), "exactly one verdict")


# --- rule: REWORK NEEDED carries a reason, PASSED carries none


def test_rework_without_reason_is_refused() -> None:
    assert faults_matching(review("verdict: REWORK NEEDED"), "REWORK NEEDED requires a reason")


def test_empty_reason() -> None:
    assert faults_matching(review("verdict: REWORK NEEDED", "reason:"), "reason: is empty")


def test_duplicate_reason() -> None:
    text = review("verdict: REWORK NEEDED", "reason: a", "reason: b")
    assert faults_matching(text, "duplicate reason")


def test_reason_length_limit() -> None:
    assert check(review("verdict: REWORK NEEDED", "reason: " + "a" * 500)) == []
    text = review("verdict: REWORK NEEDED", "reason: " + "a" * 501)
    assert faults_matching(text, "limit is 500")


@pytest.mark.parametrize("tail", ["", " ", "   "])
def test_could_not_observe_with_empty_description_is_refused(tail: str) -> None:
    text = review("verdict: REWORK NEEDED", f"reason: could not observe:{tail}")
    assert faults_matching(text, "must be followed by what could not")


def test_reason_on_a_pass_is_refused() -> None:
    text = review("verdict: PASSED", "reason: fine")
    assert faults_matching(text, "belongs only on a REWORK NEEDED")


# --- rule: machine fields come last ------------------------------------------


def test_prose_after_fields() -> None:
    text = review("verdict: REWORK NEEDED", "reason: x") + "Thanks for the change!\n"
    assert faults_matching(text, "prose after the machine fields")


# --- rule: each finding line carries file:line -------------------------------


@pytest.mark.parametrize(
    "line",
    [
        "F1. modules/x.py — crashes on None — HIGH — 0.9",  # no :line
        "F1. modules/x.py:0 — crashes on None — HIGH — 0.9",  # line 0
        "F1. modules/x.py:12 — crashes on None — CRITICAL — 0.9",  # bad severity
        "F1. modules/x.py:12 — crashes on None — HIGH — 90%",  # bad confidence
        "F1. modules/x.py:12 — crashes on None — HIGH",  # no confidence
        "F1: modules/x.py:12 crashes on None HIGH 0.9",  # no separators
    ],
)
def test_malformed_finding(line: str) -> None:
    prose = f"## Findings\n\n{line}\n"
    assert faults_matching(review("verdict: REWORK NEEDED", "reason: x", prose=prose), "finding is not")


def test_bullet_under_findings_is_refused() -> None:
    prose = "## Findings\n\n- modules/x.py crashes sometimes\n"
    text = review("verdict: REWORK NEEDED", "reason: x", prose=prose)
    assert faults_matching(text, "every line must be a finding")


def test_prose_outside_findings_is_free() -> None:
    prose = "## Summary\n\n- a bullet that is not a finding\n\n## Findings\n\nNone.\n"
    assert check(review("verdict: REWORK NEEDED", "reason: x", prose=prose)) == []


def test_repeated_finding_number() -> None:
    prose = (
        "## Findings\n\n"
        "F1. a.py:1 — x breaks — LOW — 0.2\n"
        "F1. b.py:2 — y breaks — LOW — 0.2\n"
    )
    assert faults_matching(review("verdict: REWORK NEEDED", "reason: x", prose=prose), "repeated")


# --- rule: the summary section (check_brief) --------------------------------

brief = check_review.check_brief


def _summary(*lines: str, after: str = "## Findings\n\nNone.\n") -> str:
    return "## What this change does\n\n" + "\n".join(lines) + "\n\n" + after


@pytest.mark.parametrize("count", [3, 5])
def test_summary_of_three_to_five_lines_is_clean(count: int) -> None:
    assert brief(_summary(*[f"line {i}" for i in range(count)])) == []


def test_summary_missing() -> None:
    assert [f for f in brief("## Findings\n\nNone.\n") if "heading is required" in f]


@pytest.mark.parametrize("count", [2, 6])
def test_summary_wrong_length(count: int) -> None:
    faults = brief(_summary(*[f"line {i}" for i in range(count)]))
    assert [f for f in faults if "3 to 5 non-blank lines" in f and "line 1" in f]


def test_summary_after_findings() -> None:
    text = "## Findings\n\nNone.\n\n## What this change does\n\na\nb\nc\n"
    assert [f for f in brief(text) if "must come before" in f]


@pytest.mark.parametrize(
    "bad", ["F1. a.py:1 — x — LOW — 0.2", "verdict: REWORK NEEDED", "reason: x"]
)
def test_summary_line_may_not_look_like_a_finding_or_field(bad: str) -> None:
    faults = brief(_summary("one", "two", bad))
    assert [f for f in faults if "must not start like" in f and "line 5" in f]


def test_summary_heading_twice() -> None:
    text = _summary("a", "b", "c") + "\n" + _summary("a", "b", "c")
    assert [f for f in brief(text) if "exactly once" in f]


# --- rule: verdict and reason sit only in the trailing machine-field block --------


def test_verdict_in_the_middle_of_the_prose_is_refused() -> None:
    text = (
        "## What this change does\n\na\nb\nc\n\nverdict: PASSED\n\n"
        "## Findings\n\nNone.\n"
    )
    assert faults_matching(text, "prose after the machine fields")


def test_reason_in_the_middle_of_the_prose_is_refused() -> None:
    text = (
        "## Findings\n\nNone.\n\nreason: x\n\n## Notes\n\nlater prose\n\n"
        "verdict: REWORK NEEDED\n"
    )
    assert faults_matching(text, "prose after the machine fields")


def test_prose_line_after_the_verdict_is_refused() -> None:
    text = review("verdict: PASSED") + "Looks fine.\n"
    assert faults_matching(text, "prose after the machine fields")


def test_reason_may_come_before_the_verdict_at_the_end() -> None:
    assert check(review("reason: x", "verdict: REWORK NEEDED")) == []


def test_blank_lines_between_the_trailing_fields_are_fine() -> None:
    assert check(PROSE + "\nverdict: REWORK NEEDED\n\nreason: x\n\n") == []


def test_only_verdict_and_reason_are_machine_fields() -> None:
    # Any other "name: value" line after the fields is prose, and prose may not follow them.
    assert faults_matching(
        review("verdict: PASSED", "status: x"), "prose after the machine fields"
    )


def test_reason_prefix_could_not_observe_is_case_insensitive() -> None:
    text = review("verdict: REWORK NEEDED", "reason: Could Not Observe:")
    assert faults_matching(text, "must be followed by what could not")


def test_reason_exactly_one_character_is_clean() -> None:
    assert check(review("verdict: REWORK NEEDED", "reason: x")) == []


# --- the command line --------------------------------------------------------


def _run(args: list[str], stdin: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(HERE / "check_review.py"), *args],
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
    )


def test_cli_file_ok(tmp_path: Path) -> None:
    path = tmp_path / "review.md"
    path.write_text(
        review("verdict: REWORK NEEDED", "reason: x", prose=PROSE_WITH_SUMMARY), encoding="utf-8"
    )
    result = _run([str(path)])
    assert result.returncode == 0, result.stderr


def test_cli_without_summary_exits_1_and_names_the_rule(tmp_path: Path) -> None:
    path = tmp_path / "review.md"
    path.write_text(review("verdict: REWORK NEEDED", "reason: x"), encoding="utf-8")
    result = _run([str(path)])
    assert result.returncode == 1
    assert "What this change does" in result.stderr


def test_cli_stdin_fault_is_named() -> None:
    result = _run([], stdin="no verdict here\n")
    assert result.returncode == 1
    assert "exactly one verdict" in result.stderr


def test_cli_missing_file(tmp_path: Path) -> None:
    result = _run([str(tmp_path / "absent.md")])
    assert result.returncode == 1
    assert "cannot read" in result.stderr

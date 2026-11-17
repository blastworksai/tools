#!/usr/bin/env python3
"""check_review.py: deterministic linter for a bw-code-review output.

Usage: check_review.py <review-file>   (or the review on stdin)
Exit 0 when the review is postable, 1 with every fault named on stderr.

Machine fields (bare lines, last in the file, nothing after them):
  * verdict: PASSED | REWORK NEEDED   (exactly one, lowercase "verdict:")
  * reason: <one line, 1-500 characters>   (exactly one on REWORK NEEDED, none on PASSED)
  * a reason that starts "could not observe:" must say what could not be observed.
A line that starts with verdict: or reason: in any case counts as a field wherever it sits,
so a prose line such as "Verdict: fine" breaks the one-verdict rule, and any prose after the
first field is refused.

Finding lines (documented in SKILL.md):
  * a line starting with F<n>. or F<n>: is a finding, and must read
        F<n>. <path>:<line>[-<line>] — <failure scenario> — <HIGH|MEDIUM|LOW> — <confidence 0-1>
    ("--" is accepted in place of the em dash);
  * under a "## Findings" heading, every non-blank line up to the next
    heading is either a finding line or exactly "None.";
  * finding numbers are unique.

Summary rule (check_brief, run by the command line after check()):
  * a "## What this change does" heading appears exactly once, before the
    "## Findings" heading, followed by 3 to 5 non-blank lines before the next heading;
  * none of those lines starts like a finding (F<n>. or F<n>:) or a machine field
    (verdict:, reason:).

Stdlib only.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

VERDICTS = ("PASSED", "REWORK NEEDED")
PASS = "PASSED"
REWORK = "REWORK NEEDED"
# A review that could not observe something is REWORK NEEDED with this reason prefix.
COULD_NOT_OBSERVE = "could not observe:"
REASON_MAX = 500

# How a verdict or reason line is found: any indentation or case counts, so a prose line
# such as "Verdict: fine" counts against the one-verdict rule.
REVIEW_FIELD = re.compile(r"^\s*(verdict|reason)\s*:\s*(.*?)\s*$", re.IGNORECASE)
# A machine field anywhere (for the "fields come last" rule).
MACHINE_LINE = re.compile(r"^\s*(verdict|reason)\s*:", re.IGNORECASE)

FINDING_START = re.compile(r"^F(\d+)[.:]\s")
SEP = r"\s+(?:—|--)\s+"
FINDING = re.compile(
    r"^F(?P<n>\d+)[.:]\s+"
    r"(?P<path>[^\s:]+):(?P<line>[1-9]\d*)(?:-[1-9]\d*)?"
    + SEP
    + r"(?P<scenario>\S.*?)"
    + SEP
    + r"(?P<severity>HIGH|MEDIUM|LOW)"
    + SEP
    + r"(?P<confidence>0(?:\.\d+)?|1(?:\.0+)?)\s*$"
)
HEADING = re.compile(r"^#{1,6}\s")
FINDINGS_HEADING = re.compile(r"^#{1,6}\s+Findings\s*$", re.IGNORECASE)
SUMMARY_HEADING = re.compile(r"^#{1,6}\s+What this change does\s*$", re.IGNORECASE)
SUMMARY_MIN = 3
SUMMARY_MAX = 5


def _check_findings(lines: list[str]) -> list[str]:
    faults: list[str] = []
    seen: set[str] = set()
    in_findings = False
    for number, line in enumerate(lines, 1):
        if HEADING.match(line):
            in_findings = bool(FINDINGS_HEADING.match(line))
            continue
        stripped = line.strip()
        if FINDING_START.match(line):
            match = FINDING.match(line)
            if match is None:
                faults.append(
                    f"line {number}: finding is not "
                    "'F<n>. <path>:<line> — <scenario> — <HIGH|MEDIUM|LOW> — <0-1>': "
                    f"{stripped[:120]}"
                )
                continue
            if match["n"] in seen:
                faults.append(f"line {number}: finding number F{match['n']} is repeated")
            seen.add(match["n"])
            continue
        if in_findings and stripped and stripped != "None.":
            faults.append(
                f"line {number}: under '## Findings' every line must be a finding "
                f"(F<n>. <path>:<line> — ...) or 'None.': {stripped[:120]}"
            )
    return faults


def check(text: str) -> list[str]:
    """Return every fault in ``text``; an empty list means postable."""
    faults: list[str] = []
    lines = text.splitlines()

    fields: dict[str, list[tuple[int, str, str]]] = {}
    for number, line in enumerate(lines, 1):
        match = REVIEW_FIELD.match(line)
        if match:
            fields.setdefault(match.group(1).lower(), []).append(
                (number, line, match.group(2).strip())
            )

    verdicts = fields.get("verdict", [])
    verdict: str | None = None
    if len(verdicts) != 1:
        where = ", ".join(str(n) for n, _, _ in verdicts) or "none found"
        faults.append(f"exactly one verdict: line is required (lines: {where})")
    else:
        number, line, value = verdicts[0]
        if not line.startswith("verdict:"):
            faults.append(f"line {number}: the verdict line must be bare, lowercase 'verdict:'")
        if value not in VERDICTS:
            faults.append(
                f"line {number}: verdict must be exactly one of "
                f"{' | '.join(VERDICTS)} (got {value!r})"
            )
        else:
            verdict = value

    for name in ("reason",):
        found = fields.get(name, [])
        if len(found) > 1:
            faults.append(f"duplicate {name}: lines ({', '.join(str(n) for n, _, _ in found)})")
        for number, line, value in found:
            if not line.startswith(f"{name}:"):
                faults.append(f"line {number}: the {name} line must be bare, lowercase '{name}:'")
            if not value:
                faults.append(f"line {number}: {name}: is empty")

    reasons = fields.get("reason", [])
    if verdict == REWORK and not reasons:
        faults.append("REWORK NEEDED requires a reason: line (one line, 1-500 characters)")
    if verdict == PASS and reasons:
        faults.append("reason: belongs only on a REWORK NEEDED (verdict is PASSED)")
    for number, _line, value in reasons:
        if not value:
            continue  # already reported as empty
        if len(value) > REASON_MAX:
            faults.append(
                f"line {number}: reason is {len(value)} characters; the limit is {REASON_MAX}"
            )
        if value.lower().startswith(COULD_NOT_OBSERVE) and not value[len(COULD_NOT_OBSERVE):].strip():
            faults.append(
                f"line {number}: 'could not observe:' must be followed by what could not "
                "be observed"
            )

    # Prose first, machine fields last: once the first field appears, only
    # fields or blank lines may follow.
    first_field = next((i for i, line in enumerate(lines) if MACHINE_LINE.match(line)), None)
    if first_field is not None:
        for number, line in enumerate(lines[first_field:], first_field + 1):
            if line.strip() and not MACHINE_LINE.match(line):
                faults.append(
                    f"line {number}: prose after the machine fields; put all prose "
                    "before the first verdict/reason line"
                )
                break

    prose = lines[:first_field] if first_field is not None else lines
    faults.extend(_check_findings(prose))
    return faults


def check_brief(text: str) -> list[str]:
    """Return the faults in the summary section; an empty list means it is well formed."""
    lines = text.splitlines()
    headings = [n for n, line in enumerate(lines, 1) if SUMMARY_HEADING.match(line)]
    if not headings:
        return ["summary: a '## What this change does' heading is required (none found)"]
    if len(headings) > 1:
        where = ", ".join(str(n) for n in headings)
        return [f"summary: '## What this change does' must appear exactly once (lines: {where})"]
    start = headings[0]
    faults: list[str] = []
    findings = next((n for n, line in enumerate(lines, 1) if FINDINGS_HEADING.match(line)), None)
    if findings is not None and findings < start:
        faults.append(
            f"line {start}: summary: '## What this change does' must come before "
            f"'## Findings' (line {findings})"
        )
    body: list[tuple[int, str]] = []
    for number, line in enumerate(lines[start:], start + 1):
        if HEADING.match(line):
            break
        if line.strip():
            body.append((number, line))
    if not SUMMARY_MIN <= len(body) <= SUMMARY_MAX:
        faults.append(
            f"line {start}: summary: '## What this change does' needs {SUMMARY_MIN} to "
            f"{SUMMARY_MAX} non-blank lines (found {len(body)})"
        )
    for number, line in body:
        if FINDING_START.match(line) or MACHINE_LINE.match(line):
            faults.append(
                f"line {number}: summary: a summary line must not start like a finding "
                f"(F<n>.) or a machine field (verdict:, reason:, ...): {line.strip()[:120]}"
            )
    return faults


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print("usage: check_review.py [<review-file>]  (reads stdin without one)", file=sys.stderr)
        return 1
    if len(argv) == 2 and argv[1] != "-":
        try:
            text = Path(argv[1]).read_text(encoding="utf-8")
        except OSError as exc:
            print(f"check_review: cannot read {argv[1]}: {exc.strerror}", file=sys.stderr)
            return 1
    else:
        text = sys.stdin.read()
    faults = check(text) + check_brief(text)
    for fault in faults:
        print(f"check_review: {fault}", file=sys.stderr)
    if faults:
        print(f"check_review: FAIL ({len(faults)} fault(s)); do not post", file=sys.stderr)
        return 1
    print("check_review: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

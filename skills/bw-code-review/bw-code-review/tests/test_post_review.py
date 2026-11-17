"""Tests for post_review.py: the diff parser, finding placement, event choice, the
review builder, and the command line end to end against a fake `gh` on PATH.
No network and no gh login are needed."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent.parent
SCRIPT = HERE / "post_review.py"
_spec = importlib.util.spec_from_file_location("post_review", SCRIPT)
assert _spec is not None and _spec.loader is not None
post_review = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(post_review)
check_review = post_review.check_review

SHA = "0123456789abcdef0123456789abcdef01234567"
OTHER_SHA = "fedcba9876543210fedcba9876543210fedcba98"
REPO = "octocat/hello-world"
PR = 838

DIFF = """diff --git a/modules/x.py b/modules/x.py
index 1111111..2222222 100644
--- a/modules/x.py
+++ b/modules/x.py
@@ -10,3 +10,4 @@ def f():
 ctx10
+added11
 ctx12
 ctx13
@@ -40,2 +41,3 @@
 ctx41
-gone
+new42
+new43
"""

SUMMARY = """## What this change does

It adds a line.
It keeps the old path.
It logs the change.
"""


def make_review(
    findings: list[str],
    verdict: str = "PASSED",
    extra: str = "",
    reason: str = "a real reason",
) -> str:
    body = "None." if not findings else "\n".join(findings)
    text = f"{SUMMARY}\n## Findings\n\n{body}\n"
    if extra:
        text += f"\n## Review boundary\n\n{extra}\n"
    text += f"\nverdict: {verdict}\n"
    if verdict != "PASSED":
        text += f"reason: {reason}\n"
    return text


F1 = "F1. modules/x.py:11 — the added line is never read — HIGH — 0.8"
F2 = "F2. modules/x.py:100 — a line outside the diff is wrong — MEDIUM — 0.6"
F3 = "F3. modules/x.py:12-13 -- the two context lines drift -- LOW -- 0.4"
F4 = "F4. modules/x.py:13-41 — a range across two hunks — LOW — 0.3"
FINDINGS = [F1, F2, F3, F4]


def test_fixtures_are_valid_reviews() -> None:
    for verdict in ("PASSED", "REWORK NEEDED"):
        text = make_review(FINDINGS, verdict)
        assert check_review.check(text) == []
        assert check_review.check_brief(text) == []


# --- parse_diff ---------------------------------------------------------------


def lines_of(hunks: dict, path: str) -> list[set[int]]:
    return [h[2] for h in hunks[path]]


def test_parse_diff_added_context_and_deleted_not_counted() -> None:
    hunks = post_review.parse_diff(DIFF)
    assert lines_of(hunks, "modules/x.py") == [{10, 11, 12, 13}, {41, 42, 43}]


def test_parse_diff_hunk_start_and_end() -> None:
    hunks = post_review.parse_diff(DIFF)
    assert [(s, e) for s, e, _ in hunks["modules/x.py"]] == [(10, 13), (41, 43)]


def test_parse_diff_rename_uses_new_path() -> None:
    patch = (
        "diff --git a/old.py b/new.py\nsimilarity index 80%\nrename from old.py\n"
        "rename to new.py\n--- a/old.py\n+++ b/new.py\n@@ -1,2 +1,2 @@\n keep\n-a\n+b\n"
    )
    hunks = post_review.parse_diff(patch)
    assert "old.py" not in hunks
    assert lines_of(hunks, "new.py") == [{1, 2}]


def test_parse_diff_new_file() -> None:
    patch = (
        "diff --git a/n.py b/n.py\nnew file mode 100644\n--- /dev/null\n+++ b/n.py\n"
        "@@ -0,0 +1,3 @@\n+a\n+b\n+c\n"
    )
    assert lines_of(post_review.parse_diff(patch), "n.py") == [{1, 2, 3}]


def test_parse_diff_deleted_file_has_no_new_side() -> None:
    patch = (
        "diff --git a/d.py b/d.py\ndeleted file mode 100644\n--- a/d.py\n+++ /dev/null\n"
        "@@ -1,2 +0,0 @@\n-a\n-b\n"
    )
    assert post_review.parse_diff(patch) == {}


def test_parse_diff_binary_file_has_no_hunks_and_does_not_leak_a_path() -> None:
    patch = (
        "diff --git a/img.png b/img.png\nBinary files a/img.png and b/img.png differ\n"
        "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1 +1 @@\n-x\n+y\n"
    )
    hunks = post_review.parse_diff(patch)
    assert "img.png" not in hunks
    assert lines_of(hunks, "a.py") == [{1}]


def test_parse_diff_no_newline_marker_is_ignored() -> None:
    patch = (
        "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1,2 +1,2 @@\n ctx\n-old\n"
        "\\ No newline at end of file\n+new\n\\ No newline at end of file\n"
    )
    assert lines_of(post_review.parse_diff(patch), "a.py") == [{1, 2}]


def test_parse_diff_header_missing_counts_and_function_context() -> None:
    patch = (
        "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -5 +5 @@ def f(x):\n-old\n+new\n"
    )
    assert lines_of(post_review.parse_diff(patch), "a.py") == [{5}]


def test_parse_diff_content_that_looks_like_file_headers_stays_content() -> None:
    patch = (
        "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1,1 +1,4 @@\n ctx\n"
        "+++ b/x\n++ b/x\n+tail\n"
    )
    hunks = post_review.parse_diff(patch)
    assert list(hunks) == ["a.py"]
    assert lines_of(hunks, "a.py") == [{1, 2, 3, 4}]


def git(*args: str, cwd: Path) -> str:
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@example.invalid",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@example.invalid",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
    }
    return subprocess.run(
        ["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True
    ).stdout


def test_parse_diff_on_a_real_git_patch(tmp_path: Path) -> None:
    work = tmp_path / "w"
    work.mkdir()
    git("init", "--quiet", "-b", "main", cwd=work)
    filler = "    pass\n" * 12
    (work / "a.py").write_text("head\n" + filler + "def f():\n" + filler + "end\n")
    (work / "one.txt").write_text("one\n")
    git("add", "a.py", "one.txt", cwd=work)
    git("commit", "--quiet", "-m", "base", cwd=work)
    base = git("rev-parse", "HEAD", cwd=work).strip()
    (work / "a.py").write_text(
        "head\n" + filler + "def f():\n" + filler + "++ b/x\n+++ b/y\nend\n"
    )
    (work / "one.txt").write_text("two\n")
    git("commit", "--quiet", "-am", "change", cwd=work)
    patch = git("diff", "-M", "-D", f"{base}...HEAD", cwd=work)
    assert "@@ -1 +1 @@" in patch  # a header with omitted counts
    assert re.search(r"^@@ .* @@ def f\(\):$", patch, re.MULTILINE)  # function context
    assert "\n+++ b/x\n" in patch and "\n++++ b/y\n" in patch
    hunks = post_review.parse_diff(patch)
    assert sorted(hunks) == ["a.py", "one.txt"]
    new_lines = (work / "a.py").read_text().splitlines()
    exist = set().union(*lines_of(hunks, "a.py"))
    by_content = {new_lines[n - 1]: n for n in exist}
    assert by_content["++ b/x"] in exist and by_content["+++ b/y"] in exist
    assert all(1 <= n <= len(new_lines) for n in exist)
    assert lines_of(hunks, "one.txt") == [{1}]


def quoted_patch(header_path: str) -> str:
    return (
        f'diff --git "a/x" "b/x"\n--- a/x\n+++ {header_path}\n'
        "@@ -1,2 +1,3 @@\n ctx1\n+added2\n ctx3\n"
    )


def test_parse_diff_decodes_git_octal_quoted_path() -> None:
    hunks = post_review.parse_diff(quoted_patch('"b/caf\\303\\251.py"'))
    assert list(hunks) == ["café.py"]
    pinned, _ = post_review.place_findings(post_review.parse_findings(make_review(
        ["F1. café.py:2 — the added line is wrong — HIGH — 0.8"])), hunks)
    assert [(f.path, f.start) for f in pinned] == [("café.py", 2)]


def test_parse_diff_decodes_quote_and_tab_escapes() -> None:
    hunks = post_review.parse_diff(quoted_patch('"b/a\\"b\\tc\\\\d\\n.txt"'))
    assert list(hunks) == ['a"b\tc\\d\n.txt']


def test_new_path_other_escapes_and_plain_forms() -> None:
    assert post_review._new_path('"b/\\a\\b\\f\\r\\v"') == "\a\b\f\r\v"
    assert post_review._new_path("b/plain.py\t") == "plain.py"
    assert post_review._new_path('"/dev/null"') is None
    assert post_review._new_path('"b/caf\\303\\251.py"\t') == "café.py"


def test_parse_diff_on_a_real_git_patch_with_quoted_and_spaced_names(tmp_path: Path) -> None:
    work = tmp_path / "w"
    work.mkdir()
    git("init", "--quiet", "-b", "main", cwd=work)
    names = ["café.py", "with space.txt"]
    for name in names:
        (work / name).write_text("one\ntwo\n")
    git("add", *names, cwd=work)
    git("commit", "--quiet", "-m", "base", cwd=work)
    for name in names:
        (work / name).write_text("one\nchanged\n")
    git("commit", "--quiet", "-am", "change", cwd=work)
    patch = git("diff", "HEAD~1", "HEAD", cwd=work)
    assert '"b/caf\\303\\251.py"' in patch  # git quoted it
    hunks = post_review.parse_diff(patch)
    assert sorted(hunks) == sorted(names)
    found = post_review.parse_findings(make_review([
        "F1. café.py:2 — the changed line is wrong — HIGH — 0.8",
    ]))
    pinned, unpinned = post_review.place_findings(found, hunks)
    assert [f.path for f in pinned] == ["café.py"] and unpinned == []
    # parse_findings cannot hold a space in a path (its pattern is [^\s:]+), so the
    # spaced file is proved through its hunks and a direct Finding
    spaced = post_review.Finding(0, 2, "with space.txt", 2, 2, "s", "LOW", "0.5")
    pinned, unpinned = post_review.place_findings([spaced], hunks)
    assert pinned == [spaced] and unpinned == []


# --- parse_findings and place_findings ----------------------------------------


def test_parse_findings_fields() -> None:
    found = post_review.parse_findings(make_review([F1, F3]))
    assert [(f.n, f.path, f.start, f.end, f.severity, f.confidence) for f in found] == [
        (1, "modules/x.py", 11, 11, "HIGH", "0.8"),
        (3, "modules/x.py", 12, 13, "LOW", "0.4"),
    ]
    assert found[0].scenario == "the added line is never read"


HUNKS = post_review.parse_diff(DIFF)


def finding(path: str, start: int, end: int | None = None, n: int = 1) -> object:
    return post_review.Finding(0, n, path, start, start if end is None else end, "s", "LOW", "0.5")


def test_place_in_hunk_single_line_is_pinned() -> None:
    pinned, unpinned = post_review.place_findings([finding("modules/x.py", 11)], HUNKS)
    assert len(pinned) == 1 and not unpinned


def test_place_deleted_side_line_is_unpinned() -> None:
    # old line 41 area: new-side 40 does not exist (only the old side had it)
    pinned, unpinned = post_review.place_findings([finding("modules/x.py", 40)], HUNKS)
    assert not pinned and len(unpinned) == 1


def test_place_range_across_two_hunks_is_unpinned() -> None:
    pinned, unpinned = post_review.place_findings([finding("modules/x.py", 13, 41)], HUNKS)
    assert not pinned and len(unpinned) == 1


def test_place_file_not_in_diff_is_unpinned() -> None:
    pinned, unpinned = post_review.place_findings([finding("other.py", 11)], HUNKS)
    assert not pinned and len(unpinned) == 1


def test_place_range_inside_one_hunk_is_pinned_with_start_line() -> None:
    f = finding("modules/x.py", 12, 13)
    pinned, unpinned = post_review.place_findings([f], HUNKS)
    assert pinned == [f] and not unpinned
    payload = post_review.build_review(make_review([F3]), pinned, unpinned, "APPROVE", SHA)
    note = payload["comments"][0]
    assert (note["start_line"], note["line"], note["start_side"], note["side"]) == (
        12, 13, "RIGHT", "RIGHT",
    )


def test_place_reversed_range_is_unpinned() -> None:
    pinned, unpinned = post_review.place_findings([finding("modules/x.py", 50, 40)], HUNKS)
    assert not pinned and len(unpinned) == 1
    hunks = {"a.py": [(1, 100, set(range(1, 101)))]}
    pinned, unpinned = post_review.place_findings([finding("a.py", 50, 40)], hunks)
    assert not pinned and len(unpinned) == 1


def test_place_range_over_adjacent_hunks_with_every_line_present_is_unpinned() -> None:
    hunks = {"a.py": [(1, 5, {1, 2, 3, 4, 5}), (6, 10, {6, 7, 8, 9, 10})]}
    pinned, unpinned = post_review.place_findings([finding("a.py", 4, 7)], hunks)
    assert not pinned and len(unpinned) == 1


def test_place_gap_inside_a_hunk_range_is_unpinned() -> None:
    hunks = {"a.py": [(1, 10, {1, 2, 3, 9, 10})]}
    pinned, unpinned = post_review.place_findings([finding("a.py", 2, 9)], hunks)
    assert not pinned and len(unpinned) == 1


# --- choose_event: verdict x author grid ---------------------------------------

REWORK_REASON = "REWORK NEEDED"


@pytest.mark.parametrize(
    ("verdict", "same_author", "expected"),
    [
        ("PASSED", False, "APPROVE"),
        ("PASSED", True, "COMMENT"),
        ("REWORK NEEDED", False, "REQUEST_CHANGES"),
        ("REWORK NEEDED", True, "COMMENT"),
        ("REWORK NEEDED (could not observe)", False, "REQUEST_CHANGES"),
        ("REWORK NEEDED (could not observe)", True, "COMMENT"),
    ],
)
def test_choose_event_grid(verdict: str, same_author: bool, expected: str) -> None:
    # could-not-observe is a REWORK NEEDED with a reason prefix; it parses to REWORK.
    reason = "could not observe: the CI log"
    text = make_review([], "REWORK NEEDED", reason=reason) if "REWORK" in verdict else make_review([])
    parsed = post_review.parse_verdict(text)
    assert parsed == verdict.split(" (")[0]
    author = "Review-Bot"
    poster = "review-bot" if same_author else "someone"
    assert post_review.choose_event(parsed, author, poster) == expected


def test_choose_event_unknown_people_never_downgrades() -> None:
    assert post_review.choose_event("PASSED", None, None) == "APPROVE"


# --- build_review --------------------------------------------------------------


def built(findings: list[str], event: str = "APPROVE", verdict: str = "PASSED",
          extra: str = "") -> dict:
    text = make_review(findings, verdict, extra=extra)
    pinned, unpinned = post_review.place_findings(post_review.parse_findings(text), HUNKS)
    return post_review.build_review(text, pinned, unpinned, event, SHA, verdict)


def test_line_notes_sit_right_after_findings_before_a_later_heading() -> None:
    body = built([F1, F2], extra="Only the diff was read.")["body"]
    order = [m.group(0) for m in re.finditer(r"^## .*$", body, re.MULTILINE)]
    assert order == [
        "## What this change does", "## Findings", "## Line notes", "## Review boundary",
    ]
    assert body.index("F2. modules/x.py:100") < body.index("## Line notes")


def test_machine_fields_stay_last_in_the_body() -> None:
    body = built([F1, F2])["body"]
    tail = body.split("## Line notes")[1]
    after_notes = tail[tail.index("verdict:"):]
    assert all(
        check_review.MACHINE_LINE.match(line) for line in after_notes.splitlines() if line.strip()
    )
    assert body.rstrip().splitlines()[-1] == "verdict: PASSED"


def test_line_notes_inserted_before_machine_fields_when_findings_is_last_prose() -> None:
    body = built([F1])["body"]
    assert body.index("## Line notes") < body.index("verdict:")


def test_none_findings_give_the_no_findings_line_and_no_comments() -> None:
    payload = built([])
    assert "No findings, so no line notes." in payload["body"]
    assert payload["comments"] == []


def test_line_note_lines_say_pinned_or_not() -> None:
    body = built([F1, F2])["body"]
    assert "- F1 — pinned to modules/x.py:11 in Files changed" in body
    assert "- F2 — not on a changed line, so it is only here" in body


def test_comment_event_adds_the_self_approval_line() -> None:
    assert post_review.SELF_AUTHOR_NOTE in built([F1], event="COMMENT")["body"]
    assert post_review.SELF_AUTHOR_NOTE not in built([F1], event="APPROVE")["body"]


def test_commit_id_is_the_staged_head() -> None:
    assert built([F1])["commit_id"] == SHA


def test_line_note_text_carries_the_parsed_verdict_on_a_pass_with_a_low_finding() -> None:
    low = "F1. modules/x.py:11 — a small nit — LOW — 0.5"
    note = built([low])["comments"][0]
    assert "verdict: PASSED" in note["body"]
    assert note["body"].startswith("**F1 · LOW · confidence 0.5**\n\na small nit\n\n")
    assert note["path"] == "modules/x.py" and note["line"] == 11 and note["side"] == "RIGHT"
    assert "start_line" not in note


def test_line_note_text_carries_rework_verdict_not_a_hardcoded_one() -> None:
    note = built([F1], event="REQUEST_CHANGES", verdict="REWORK NEEDED")["comments"][0]
    assert "verdict: REWORK NEEDED" in note["body"]
    assert "PASSED" not in note["body"]


# --- length limits -------------------------------------------------------------


def body_of_length(n: int) -> str:
    text = make_review([F1], extra="x")
    base = len(built_from(text)["body"])
    return make_review([F1], extra="x" * (1 + n - base))


def built_from(text: str) -> dict:
    pinned, unpinned = post_review.place_findings(post_review.parse_findings(text), HUNKS)
    return post_review.build_review(text, pinned, unpinned, "APPROVE", SHA, "PASSED")


def test_global_body_of_exactly_the_limit_passes_and_one_over_is_refused() -> None:
    ok = built_from(body_of_length(65536))
    assert len(ok["body"]) == 65536
    post_review.check_lengths(ok)
    over = built_from(body_of_length(65537))
    assert len(over["body"]) == 65537
    with pytest.raises(post_review.Refusal, match="65536"):
        post_review.check_lengths(over)


def test_line_note_body_limit() -> None:
    def payload(n: int) -> dict:
        return {"body": "ok", "comments": [{"path": "a", "line": 1, "body": "x" * n}]}

    post_review.check_lengths(payload(65536))
    with pytest.raises(post_review.Refusal, match="line note"):
        post_review.check_lengths(payload(65537))


# --- invariant sweep -----------------------------------------------------------


SWEEP = [
    [], [F1], [F2], [F1, F2], FINDINGS,
    [F3, "F7. modules/x.py:50-40 -- reversed -- LOW -- 0.1", "F9. gone.py:1 — no file — HIGH — 1"],
    ["F1. modules/x.py:41-43 — whole second hunk — HIGH — 0.9",
     "F2. modules/x.py:10 — first line — LOW — 0"],
]


@pytest.mark.parametrize("findings", SWEEP)
@pytest.mark.parametrize("verdict", ["PASSED", "REWORK NEEDED"])
def test_invariant_every_finding_once_in_line_notes_at_most_once_pinned(
    findings: list[str], verdict: str
) -> None:
    payload = built(findings, verdict=verdict)
    numbers = [int(re.match(r"F(\d+)", line)[1]) for line in findings]
    section = payload["body"].split("## Line notes")[1]
    section = re.split(r"^## |^verdict:", section, flags=re.MULTILINE)[0]
    in_notes = [int(m) for m in re.findall(r"^- F(\d+) — ", section, re.MULTILINE)]
    assert sorted(in_notes) == sorted(numbers)
    for n in numbers:
        marks = [c for c in payload["comments"] if c["body"].startswith(f"**F{n} · ")]
        assert len(marks) <= 1
    for c in payload["comments"]:
        start = c.get("start_line", c["line"])
        wanted = set(range(start, c["line"] + 1))
        assert any(wanted <= exist for _s, _e, exist in HUNKS[c["path"]])


# --- contract drift: check_review.check vs post_review.parse_findings -----------

GOOD_LINES = [
    "F1. a.py:3 — scenario — HIGH — 0.8",
    "F2: dir/b.py:10-14 -- scenario -- LOW -- 0",
    "F3. a.py:50-40 — reversed range is accepted by the checker — MEDIUM — 1.0",
    "F4. a.py:7 — a — b — c — HIGH — 0.5",
]
BAD_LINES = [
    "F1. a.py:3 — scenario — HIGH",
    "F1. a.py:3 — scenario — high — 0.5",
    "F1. a.py:0 — scenario — HIGH — 0.5",
    "F1. a.py:3 — scenario — HIGH — 1.5",
    "F1. a.py:3 — — HIGH — 0.5",
    "F1. a.py — scenario — HIGH — 0.5",
    "F1 a.py:3 — scenario — HIGH — 0.5",
    " F1. a.py:3 — scenario — HIGH — 0.5",
    "F1. a.py:3 - scenario - HIGH - 0.5",
]


@pytest.mark.parametrize("line", GOOD_LINES)
def test_drift_checker_accepts_and_parser_parses(line: str) -> None:
    text = make_review([line])
    assert check_review.check(text) == []
    assert len(post_review.parse_findings(text)) == 1


@pytest.mark.parametrize("line", BAD_LINES)
def test_drift_checker_refuses_and_parser_skips(line: str) -> None:
    text = make_review([line])
    assert check_review.check(text) != []
    assert post_review.parse_findings(text) == []


def test_drift_parser_pieces_equal_checker_pattern_on_every_line() -> None:
    for line in GOOD_LINES + BAD_LINES:
        mine = post_review.FINDING_WITH_END.match(line)
        theirs = check_review.FINDING.match(line)
        assert (mine is None) == (theirs is None), line
        if mine and theirs:
            for key in ("n", "path", "line", "scenario", "severity", "confidence"):
                assert mine[key] == theirs[key]


# --- the command line, with a fake gh -------------------------------------------

FAKE_GH = '''#!{python}
import json, os, sys, time
d = os.environ["FAKE_GH_DIR"]
cfg = json.load(open(os.path.join(d, "cfg.json")))
argv = sys.argv[1:]
with open(os.path.join(d, "log.jsonl"), "a") as fh:
    fh.write(json.dumps(argv) + "\\n")
if argv[:2] == ["api", "user"]:
    print(cfg["poster"]); sys.exit(0)
if argv[:2] == ["pr", "view"] and argv[-1] == "headRefOid":
    if cfg.get("after") == "fail":
        sys.stderr.write("gh: connection reset\\n"); sys.exit(1)
    print(json.dumps({{"headRefOid": cfg.get("head_after", cfg["head"])}})); sys.exit(0)
if argv[:2] == ["pr", "view"]:
    print(json.dumps({{"author": {{"login": cfg["author"]}}, "headRefOid": cfg["head"]}})); sys.exit(0)
if argv[:2] == ["pr", "comment"]:
    if cfg.get("comment") == "fail":
        sys.stderr.write("gh: comment refused (HTTP 403)\\n"); sys.exit(1)
    print("https://github.com/x/y/pull/1#issuecomment-9"); sys.exit(0)
if argv[0] == "api" and "--method" in argv:
    payload = open(argv[argv.index("--input") + 1]).read()
    open(os.path.join(d, "posted.json"), "w").write(payload)
    mode = cfg.get("post", "ok")
    if mode == "ok":
        print(json.dumps({{"html_url": "https://github.com/x/y/pull/1#pullrequestreview-5"}})); sys.exit(0)
    if mode == "422":
        sys.stderr.write("gh: Unprocessable Entity (HTTP 422)\\n"); sys.exit(1)
    if mode == "502":
        sys.stderr.write("gh: Bad Gateway (HTTP 502)\\n"); sys.exit(1)
    if mode == "noanswer":
        sys.exit(1)
    if mode == "timeout":
        time.sleep(30); sys.exit(0)
if argv[0] == "api" and "--paginate" in argv:
    mode = cfg.get("readback", "none")
    if mode == "fail":
        sys.stderr.write("gh: connection reset\\n"); sys.exit(1)
    if mode == "found":
        p = json.load(open(os.path.join(d, "posted.json")))
        print(json.dumps([{{"id": 1, "user": {{"login": cfg["poster"]}}, "commit_id": p["commit_id"],
                           "body": p["body"], "html_url": "https://github.com/x/y/pull/1#pullrequestreview-7"}}]))
        sys.exit(0)
    if mode == "found_other_head":
        p = json.load(open(os.path.join(d, "posted.json")))
        print(json.dumps([{{"id": 1, "user": {{"login": cfg["poster"]}}, "commit_id": "f" * 40,
                           "body": p["body"], "html_url": "u"}}]))
        sys.exit(0)
    print("[]"); sys.exit(0)
sys.stderr.write("fake gh: unexpected " + repr(argv) + "\\n"); sys.exit(2)
'''


class Rig:
    def __init__(self, tmp: Path) -> None:
        self.tmp = tmp
        self.out = tmp / "OUT"
        self.out.mkdir()
        self.fake = tmp / "fake"
        self.fake.mkdir()
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH.format(python=sys.executable))
        gh.chmod(0o755)
        self.bin = bin_dir
        self.configure()

    def configure(self, **cfg: str) -> None:
        base = {"poster": "review-bot", "author": "someone-else", "head": SHA}
        (self.fake / "cfg.json").write_text(json.dumps({**base, **cfg}))

    def stage(self, text: str, diff: str = DIFF, repo: str = REPO, head: str = SHA,
              meta: bool = True) -> Path:
        (self.out / "review.md").write_text(text)
        (self.out / "diff.patch").write_text(diff)
        if meta:
            (self.out / "meta.txt").write_text(f"repo: {repo}\nbase: main\nhead_sha: {head}\n")
        return self.out / "review.md"

    def run(self, *args: str, timeout: str = "20") -> subprocess.CompletedProcess:
        env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "FAKE_GH_DIR": str(self.fake),
            "POST_REVIEW_TIMEOUT": timeout,
        }
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
        )

    def calls(self) -> list[list[str]]:
        log = self.fake / "log.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text().splitlines()]

    def posts(self) -> list[list[str]]:
        return [c for c in self.calls() if c[0] == "api" and "--method" in c]

    def comments(self) -> list[list[str]]:
        return [c for c in self.calls() if c[:2] == ["pr", "comment"]]

    def payload(self) -> dict:
        return json.loads((self.out / "github_review.json").read_text())


@pytest.fixture()
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def go(rig: Rig, text: str | None = None, *extra: str, pr: str = str(PR),
       timeout: str = "20") -> subprocess.CompletedProcess:
    path = rig.stage(text if text is not None else make_review(FINDINGS))
    return rig.run(str(path), "--pr", pr, *extra, timeout=timeout)


def test_cli_help_works() -> None:
    proc = subprocess.run([sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True)
    assert proc.returncode == 0 and "--dry-run" in proc.stdout


def test_cli_pass_posts_one_approve_with_line_notes(rig: Rig) -> None:
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    assert len(rig.posts()) == 1 and rig.comments() == []
    post = rig.posts()[0]
    assert post[:3] == ["api", "--method", "POST"]
    assert post[3] == f"repos/{REPO}/pulls/{PR}/reviews"
    assert post[-2:] == ["--input", str(rig.out / "github_review.json")]
    payload = rig.payload()
    assert payload["event"] == "APPROVE" and payload["commit_id"] == SHA
    assert [c["path"] for c in payload["comments"]] == ["modules/x.py", "modules/x.py"]
    assert (rig.out / "github_body.md").read_text() == payload["body"]
    assert "pullrequestreview-5" in proc.stdout
    assert "pinned: 2" in proc.stdout and "unpinned: 2" in proc.stdout
    assert "head moved before posting: no" in proc.stdout
    assert "head moved after posting" not in proc.stdout
    assert "head after posting" not in proc.stdout


def test_cli_reads_user_and_pr_view_with_the_documented_arguments(rig: Rig) -> None:
    go(rig)
    calls = rig.calls()
    assert ["api", "user", "--jq", ".login"] in calls
    assert ["pr", "view", str(PR), "--repo", REPO, "--json", "author,headRefOid"] in calls


def test_cli_rework_posts_request_changes(rig: Rig) -> None:
    proc = go(rig, make_review(FINDINGS, "REWORK NEEDED"))
    assert proc.returncode == 0, proc.stderr
    assert rig.payload()["event"] == "REQUEST_CHANGES"


def test_cli_author_is_poster_sends_comment_and_says_why(rig: Rig) -> None:
    rig.configure(author="REVIEW-BOT")
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    payload = rig.payload()
    assert payload["event"] == "COMMENT"
    assert post_review.SELF_AUTHOR_NOTE in payload["body"]
    assert "event: COMMENT" in proc.stdout


def test_cli_head_moved_makes_no_write_at_all(rig: Rig) -> None:
    rig.configure(head=OTHER_SHA)
    proc = go(rig)
    assert proc.returncode == 1
    assert "head moved: restage and review again" in proc.stderr
    assert rig.posts() == [] and rig.comments() == []
    assert not (rig.out / "github_review.json").exists()


def test_cli_rejected_422_falls_back_to_exactly_one_comment(rig: Rig) -> None:
    rig.configure(post="422")
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    assert len(rig.posts()) == 1 and len(rig.comments()) == 1
    assert rig.comments()[0] == [
        "pr", "comment", str(PR), "--repo", REPO, "--body-file", str(rig.out / "github_fallback.md"),
    ]
    assert "fallback comment posted" in proc.stdout
    assert "HTTP 422" in proc.stderr
    assert not any(c[0] == "api" and "--paginate" in c for c in rig.calls())


def test_cli_422_fallback_body_does_not_claim_findings_are_pinned(rig: Rig) -> None:
    rig.configure(post="422")
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    fallback = (rig.out / "github_fallback.md").read_text()
    assert "pinned to" not in fallback
    assert "GitHub refused the review, so no line notes were posted." in fallback
    assert (
        "F1 — meant for modules/x.py:11 in Files changed, "
        "but GitHub refused the review, so it is only here"
    ) in fallback
    assert "F3 — meant for modules/x.py:12-13 in Files changed" in fallback
    assert "F2 — not on a changed line, so it is only here" in fallback
    assert "pinned to" in (rig.out / "github_body.md").read_text()  # the review body is unchanged
    assert fallback != (rig.out / "github_body.md").read_text()


def test_cli_head_unchanged_after_posting_is_exit_zero_with_one_extra_read(rig: Rig) -> None:
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    after = [c for c in rig.calls() if c[:2] == ["pr", "view"] and c[-1] == "headRefOid"]
    assert after == [["pr", "view", str(PR), "--repo", REPO, "--json", "headRefOid"]]
    assert "head moved after posting" not in proc.stdout


def test_cli_head_moved_after_posting_reports_it_and_exits_one(rig: Rig) -> None:
    rig.configure(head_after=OTHER_SHA)
    proc = go(rig)
    assert proc.returncode == 1
    assert "review posted" in proc.stdout and "pullrequestreview-5" in proc.stdout
    assert (
        f"head moved after posting: the review sits on the staged head {SHA[:7]}, "
        f"the PR head is now {OTHER_SHA[:7]}; restage and review again"
    ) in proc.stdout
    assert len(rig.posts()) == 1 and rig.comments() == []


def test_cli_head_moved_after_a_readback_confirmed_post_exits_one(rig: Rig) -> None:
    rig.configure(post="502", readback="found", head_after=OTHER_SHA)
    proc = go(rig)
    assert proc.returncode == 1
    assert "confirmed by read-back" in proc.stdout and "head moved after posting" in proc.stdout
    assert rig.comments() == [] and len(rig.posts()) == 1


def test_cli_head_read_failing_after_posting_is_unknown_and_exit_zero(rig: Rig) -> None:
    rig.configure(after="fail")
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    assert "head after posting: unknown (gh: connection reset)" in proc.stdout
    assert "head moved after posting" not in proc.stdout


def test_cli_fallback_comment_with_head_unchanged_is_exit_zero_with_one_extra_pr_view(rig: Rig) -> None:
    rig.configure(post="422")
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    assert len(rig.comments()) == 1
    after = [c for c in rig.calls() if c[:2] == ["pr", "view"] and c[-1] == "headRefOid"]
    assert after == [["pr", "view", str(PR), "--repo", REPO, "--json", "headRefOid"]]
    assert "head moved after posting" not in proc.stdout


def test_cli_fallback_comment_with_head_moved_after_exits_one_and_reports_it(rig: Rig) -> None:
    rig.configure(post="422", head_after=OTHER_SHA)
    proc = go(rig)
    assert proc.returncode == 1
    assert "fallback comment posted" in proc.stdout
    assert (
        f"head moved after posting: the review sits on the staged head {SHA[:7]}, "
        f"the PR head is now {OTHER_SHA[:7]}; restage and review again"
    ) in proc.stdout
    assert len(rig.comments()) == 1


def test_cli_timeout_with_review_found_on_readback_posts_no_comment(rig: Rig) -> None:
    rig.configure(post="timeout", readback="found")
    proc = go(rig, timeout="0.5")
    assert proc.returncode == 0, proc.stderr
    assert len(rig.posts()) == 1 and rig.comments() == []
    assert "confirmed by read-back" in proc.stdout and "pullrequestreview-7" in proc.stdout
    assert "timed out" in proc.stderr


def test_cli_timeout_with_nothing_on_readback_falls_back_once(rig: Rig) -> None:
    rig.configure(post="timeout", readback="none")
    proc = go(rig, timeout="0.5")
    assert proc.returncode == 0, proc.stderr
    assert len(rig.posts()) == 1 and len(rig.comments()) == 1
    readbacks = [c for c in rig.calls() if c[0] == "api" and "--paginate" in c]
    assert len(readbacks) == 1


def test_cli_5xx_is_unclear_and_reads_back_before_any_fallback(rig: Rig) -> None:
    rig.configure(post="502", readback="found")
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    assert rig.comments() == []


def test_cli_readback_with_review_at_another_head_does_not_count(rig: Rig) -> None:
    rig.configure(post="noanswer", readback="found_other_head")
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    assert len(rig.comments()) == 1


def test_cli_readback_failure_is_outcome_unknown_with_no_further_write(rig: Rig) -> None:
    rig.configure(post="timeout", readback="fail")
    proc = go(rig, timeout="0.5")
    assert proc.returncode == 1
    assert rig.comments() == [] and len(rig.posts()) == 1
    assert "outcome unknown" in proc.stdout
    assert "read-back failed" in proc.stderr


def test_cli_post_and_comment_both_fail_exits_one(rig: Rig) -> None:
    rig.configure(post="422", comment="fail")
    proc = go(rig)
    assert proc.returncode == 1
    assert len(rig.posts()) == 1 and len(rig.comments()) == 1
    assert "HTTP 422" in proc.stderr and "HTTP 403" in proc.stderr


def test_cli_checker_fault_exits_one_and_calls_no_gh(rig: Rig) -> None:
    bad = make_review(FINDINGS).replace("## What this change does", "## Summary")
    proc = go(rig, bad)
    assert proc.returncode == 1 and "summary" in proc.stderr
    assert rig.calls() == []


def test_cli_brief_free_review_with_check_fault_calls_no_gh(rig: Rig) -> None:
    proc = go(rig, make_review(FINDINGS).replace("verdict: PASSED", "verdict: fine"))
    assert proc.returncode == 1 and rig.calls() == []


def test_cli_dry_run_writes_payload_and_calls_no_gh(rig: Rig) -> None:
    proc = go(rig, None, "--dry-run")
    assert proc.returncode == 0, proc.stderr
    assert rig.calls() == []
    assert not (rig.fake / "log.jsonl").exists()
    assert rig.payload()["event"] == "APPROVE"
    assert (rig.out / "github_body.md").exists()
    assert "DRY RUN: not posted" in proc.stdout
    assert "pinned: 2" in proc.stdout and "unpinned: 2" in proc.stdout
    assert "other than the poster" in proc.stdout


def test_cli_dry_run_event_for_rework(rig: Rig) -> None:
    proc = go(rig, make_review(FINDINGS, "REWORK NEEDED"), "--dry-run")
    assert proc.returncode == 0 and rig.payload()["event"] == "REQUEST_CHANGES"


def test_cli_dry_run_refuses_an_over_long_body(rig: Rig) -> None:
    proc = go(rig, body_of_length(65537), "--dry-run")
    assert proc.returncode == 1 and "65536" in proc.stderr
    assert not (rig.out / "github_review.json").exists()


def test_cli_over_long_global_body_is_refused_before_any_gh_call(rig: Rig) -> None:
    proc = go(rig, body_of_length(65537))
    assert proc.returncode == 1 and "65536" in proc.stderr
    assert rig.calls() == []


def test_cli_body_whose_fallback_fits_the_limit_posts(rig: Rig) -> None:
    proc = go(rig, body_of_length(65000))
    assert proc.returncode == 0, proc.stderr
    assert len(rig.payload()["body"]) == 65000
    assert len((rig.out / "github_fallback.md").read_text()) <= 65536


def test_cli_fallback_body_over_the_limit_is_refused_before_any_gh_call(rig: Rig) -> None:
    proc = go(rig, body_of_length(65536))  # the review fits; its fallback is longer
    assert proc.returncode == 1 and "fallback comment body" in proc.stderr
    assert rig.calls() == []


def test_cli_dry_run_refuses_a_fallback_body_over_the_limit(rig: Rig) -> None:
    proc = go(rig, body_of_length(65536), "--dry-run")
    assert proc.returncode == 1 and "fallback comment body" in proc.stderr
    assert not (rig.out / "github_review.json").exists()


def test_check_lengths_covers_the_fallback_body() -> None:
    post_review.check_lengths({"body": "ok", "comments": []}, "x" * 65536)
    with pytest.raises(post_review.Refusal, match="fallback"):
        post_review.check_lengths({"body": "ok", "comments": []}, "x" * 65537)


def test_cli_downgrade_that_pushes_the_body_over_the_limit_makes_no_write(rig: Rig) -> None:
    rig.configure(author="review-bot")
    proc = go(rig, body_of_length(65536))
    assert proc.returncode == 1 and "65536" in proc.stderr
    assert rig.posts() == [] and rig.comments() == []


def test_cli_rework_needs_no_pr_match_with_the_staged_review(rig: Rig) -> None:
    proc = go(rig, make_review(FINDINGS, "REWORK NEEDED"), pr="9")
    assert proc.returncode == 0, proc.stderr


@pytest.mark.parametrize("pr", ["0", "-3", "abc", "1.5"])
def test_cli_non_positive_pr_is_refused(rig: Rig, pr: str) -> None:
    proc = go(rig, None, pr=pr)
    assert proc.returncode == 1 and rig.calls() == []


def test_cli_missing_meta_or_diff_is_refused(rig: Rig) -> None:
    path = rig.stage(make_review(FINDINGS), meta=False)
    proc = rig.run(str(path), "--pr", str(PR))
    assert proc.returncode == 1 and "meta.txt" in proc.stderr and rig.calls() == []
    rig.stage(make_review(FINDINGS))
    (rig.out / "diff.patch").unlink()
    proc = rig.run(str(rig.out / "review.md"), "--pr", str(PR))
    assert proc.returncode == 1 and "diff.patch" in proc.stderr and rig.calls() == []


def test_cli_first_ever_out_folder_has_no_earlier_payload_files(rig: Rig) -> None:
    assert not (rig.out / "github_review.json").exists()
    proc = go(rig, make_review([]))
    assert proc.returncode == 0, proc.stderr
    assert rig.payload()["comments"] == []
    assert "No findings, so no line notes." in rig.payload()["body"]


def test_cli_gh_missing_from_path_is_refused_without_posting(rig: Rig) -> None:
    path = rig.stage(make_review(FINDINGS))
    env = {**os.environ, "PATH": str(rig.tmp / "empty")}
    (rig.tmp / "empty").mkdir()
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), str(path), "--pr", str(PR)],
        env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
    )
    assert proc.returncode == 1 and "gh was not found" in proc.stderr


# --- how 4xx is told from unclear -----------------------------------------------


@pytest.mark.parametrize(
    ("code", "out", "err", "expected"),
    [
        (1, "", "gh: Unprocessable Entity (HTTP 422)", True),
        (1, "", "gh: Not Found (HTTP 404)", True),
        (1, '{"message":"x"}\n', "gh: Forbidden (HTTP 403)", True),
        (1, "", "gh: Request Timeout (HTTP 408)", False),
        (1, "", "gh: Bad Gateway (HTTP 502)", False),
        (1, "", "connection reset", False),
        (None, "", "timed out", False),
        (0, "", "", False),
    ],
)
def test_definite_rejection_classifier(code, out, err, expected) -> None:
    assert post_review.is_definite_rejection(code, out, err) is expected


def test_event_map_is_exactly_passed_approve_rework_request_changes() -> None:
    assert post_review.choose_event("PASSED", "author", "poster") == "APPROVE"
    assert post_review.choose_event("REWORK NEEDED", "author", "poster") == "REQUEST_CHANGES"
    assert post_review.choose_event("PASSED", "same", "SAME") == "COMMENT"


def test_cli_passed_with_a_reason_line_is_refused_before_any_gh_call(rig: Rig) -> None:
    text = make_review(FINDINGS) + "reason: not allowed on a pass\n"
    proc = go(rig, text)
    assert proc.returncode == 1 and "belongs only on a REWORK NEEDED" in proc.stderr
    assert rig.calls() == []


# --- the result file the tracker gate reads ----------------------------------


def result_of(rig: Rig) -> dict:
    return json.loads((rig.out / "github_result.json").read_text())


def test_cli_result_file_after_a_posted_review(rig: Rig) -> None:
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    assert result_of(rig) == {
        "posted": True, "kind": "review", "repo": REPO, "pr": PR, "head": SHA,
        "review_url": "https://github.com/x/y/pull/1#pullrequestreview-5",
    }


def test_cli_result_file_after_a_fallback_comment(rig: Rig) -> None:
    rig.configure(post="422")
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    got = result_of(rig)
    assert got["posted"] is True and got["kind"] == "comment" and got["review_url"] == ""
    assert got["repo"] == REPO and got["pr"] == PR and got["head"] == SHA


def test_cli_result_file_after_a_readback_confirmed_review_carries_its_url(rig: Rig) -> None:
    rig.configure(post="502", readback="found")
    proc = go(rig)
    assert proc.returncode == 0, proc.stderr
    got = result_of(rig)
    assert got["kind"] == "review" and got["review_url"].endswith("pullrequestreview-7")


def test_cli_result_file_still_written_when_the_head_read_after_posting_fails(rig: Rig) -> None:
    rig.configure(after="fail")
    assert go(rig).returncode == 0
    assert result_of(rig)["posted"] is True


def test_cli_no_result_file_on_a_checker_refusal(rig: Rig) -> None:
    proc = go(rig, make_review(FINDINGS).replace("verdict: PASSED", "verdict: fine"))
    assert proc.returncode == 1
    assert not (rig.out / "github_result.json").exists()


def test_cli_no_result_file_when_the_head_moved_before_posting(rig: Rig) -> None:
    rig.configure(head=OTHER_SHA)
    assert go(rig).returncode == 1
    assert not (rig.out / "github_result.json").exists()


def test_cli_no_result_file_when_the_head_moved_after_posting(rig: Rig) -> None:
    rig.configure(head_after=OTHER_SHA)
    assert go(rig).returncode == 1
    assert not (rig.out / "github_result.json").exists()


def test_cli_no_result_file_when_the_fallback_head_moved_after_posting(rig: Rig) -> None:
    rig.configure(post="422", head_after=OTHER_SHA)
    assert go(rig).returncode == 1
    assert not (rig.out / "github_result.json").exists()


def test_cli_no_result_file_when_nothing_posted(rig: Rig) -> None:
    rig.configure(post="422", comment="fail")
    assert go(rig).returncode == 1
    assert not (rig.out / "github_result.json").exists()


def test_cli_no_result_file_on_a_dry_run(rig: Rig) -> None:
    proc = go(rig, None, "--dry-run")
    assert proc.returncode == 0, proc.stderr
    assert not (rig.out / "github_result.json").exists()


@pytest.mark.parametrize("failing", ["checker", "head_moved", "none"])
def test_cli_a_stale_result_file_is_removed_at_the_start_of_a_live_run(rig: Rig, failing: str) -> None:
    (rig.out / "github_result.json").write_text('{"posted": true}')
    if failing == "head_moved":
        rig.configure(head=OTHER_SHA)
    text = make_review(FINDINGS).replace("verdict: PASSED", "verdict: fine") if failing == "checker" else None
    go(rig, text)
    stale = (rig.out / "github_result.json")
    assert not stale.exists() or json.loads(stale.read_text()).get("kind") == "review"
    if failing != "none":
        assert not stale.exists()

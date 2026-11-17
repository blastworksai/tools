#!/usr/bin/env python3
"""post_review.py: turn a checked bw-code-review review.md into ONE GitHub review.

Usage: post_review.py <OUT>/review.md --pr <n> [--dry-run]
OUT is the folder stage.sh made: it holds meta.txt (repo:, head_sha:) and diff.patch
(the three-dot diff the reviewer read). Exit 0 when the review (or the one allowed
fallback comment) posted, 1 on any refusal or failure.

What it does
  * refuses (exit 1, no gh call) on any check_review.check() or check_brief() fault, a
    missing meta.txt or diff.patch, a --pr that is not a positive integer, and any body
    over GitHub's 65,536 characters (global body, fallback body, each line note: refused,
    never cut);
  * pins a finding to its line only when its file is in the diff on the new side and every
    line of its range is a new-side line inside ONE hunk (GitHub answers 422 for the whole
    review if one note is off the diff); every other finding stays in the body only;
  * event: PR author == posting login -> COMMENT (GitHub does not let an author approve
    their own PR); else PASSED -> APPROVE, REWORK NEEDED (including
    "could not observe") -> REQUEST_CHANGES;
  * the body is the review with a "## Line notes" section right after the Findings section;
  * writes OUT/github_review.json (the API payload), OUT/github_body.md and
    OUT/github_fallback.md.

Live flow (no --dry-run): gh api user --jq .login; gh pr view <n> --repo <repo> --json
author,headRefOid; a moved head (headRefOid != staged head_sha) stops everything with no
write at all ("head moved: restage and review again"); then ONE
gh api --method POST repos/<repo>/pulls/<n>/reviews --input OUT/github_review.json.
Never a retry of the same call. After a review (directly or confirmed by
read-back) or a fallback comment that posted, ONE more gh pr view --json headRefOid: a head that differs from the staged one
is reported ("head moved after posting", exit 1, no further write; the review did post);
a failed read is reported as "head after posting: unknown" and keeps the exit code.

Result file: a live run first deletes any old OUT/github_result.json. Only when it exits 0
with the review or the fallback comment posted and the head not moved after posting does it
write {"posted": true, "kind": "review"|"comment", "repo", "pr", "head", "review_url"}.
run_tracker.py reads it. A refusal, failure, moved head or dry run leaves no such file.

How a definite rejection is told from an unclear failure (gh has no structured status):
  * gh api prints "gh: <reason> (HTTP <code>)" on stderr and exits non-zero when GitHub
    answers 4xx/5xx. The script looks for "HTTP <3 digits>" in gh's stderr, then stdout.
  * code 400-499 except 408 -> DEFINITE rejection: GitHub answered and did not create the
    review, so ONE fallback `gh pr comment <n> --repo <repo> --body-file OUT/github_fallback.md`
    (the review body whose Line notes say no line notes were posted).
  * a timeout (subprocess timeout, env POST_REVIEW_TIMEOUT seconds, default 60), 408, any
    5xx, a non-zero exit with no HTTP code, or no answer -> UNCLEAR: the review may exist.
    The script reads the PR's reviews back once (gh api --paginate .../reviews). A review by
    the posting login at the staged head with this exact body -> reported as posted, no
    fallback. None -> the one fallback comment. Read-back failing -> outcome unknown, no
    further write, exit 1.

--dry-run makes no gh call at all (not even reads), writes the two payload files, and
reports the event it would send for a PR author other than the poster, the pinned and
unpinned counts and "DRY RUN: not posted". gh is found on PATH (shutil.which).

Stdlib only.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

_HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("check_review", _HERE / "check_review.py")
assert _spec is not None and _spec.loader is not None
check_review = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_review)

PROG = "post_review"
BODY_LIMIT = 65536
DEFAULT_TIMEOUT = 60.0
TIMEOUT_ENV = "POST_REVIEW_TIMEOUT"
SELF_AUTHOR_NOTE = (
    "GitHub does not let the PR author approve their own PR, "
    "so this review is sent as a plain comment."
)

# Same pieces as check_review.FINDING, plus a capture for the range end. The drift test
# proves the two accept the same lines.
FINDING_WITH_END = re.compile(
    r"^F(?P<n>\d+)[.:]\s+"
    r"(?P<path>[^\s:]+):(?P<line>[1-9]\d*)(?:-(?P<end>[1-9]\d*))?"
    + check_review.SEP
    + r"(?P<scenario>\S.*?)"
    + check_review.SEP
    + r"(?P<severity>HIGH|MEDIUM|LOW)"
    + check_review.SEP
    + r"(?P<confidence>0(?:\.\d+)?|1(?:\.0+)?)\s*$"
)
HUNK_HEADER = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
HTTP_CODE = re.compile(r"HTTP (\d{3})")
HEAD_RE = re.compile(r"[0-9a-f]{40}")
RESULT_FILE = "github_result.json"

Hunks = dict[str, list[tuple[int, int, set[int]]]]


class Refusal(Exception):
    """A reason to stop with exit 1."""


class Finding(NamedTuple):
    idx: int
    n: int
    path: str
    start: int
    end: int
    scenario: str
    severity: str
    confidence: str


# --- the diff ----------------------------------------------------------------


_SIMPLE_ESCAPES = {
    "a": 7, "b": 8, "f": 12, "n": 10, "r": 13, "t": 9, "v": 11, "\\": 92, '"': 34,
}


def _unquote_c(body: str) -> str:
    """Decode the inside of git's C-style quoted path (core.quotePath) to text.

    Escapes: backslash, quote, \\t \\n \\a \\b \\f \\r \\v and three-digit octal bytes; the
    bytes are read as UTF-8 (surrogateescape keeps any byte that is not).
    """
    out = bytearray()
    i = 0
    while i < len(body):
        ch = body[i]
        if ch != "\\" or i + 1 >= len(body):
            out += ch.encode("utf-8", "surrogateescape")
            i += 1
            continue
        nxt = body[i + 1]
        if nxt in _SIMPLE_ESCAPES:
            out.append(_SIMPLE_ESCAPES[nxt])
            i += 2
        elif re.fullmatch(r"[0-7]{3}", body[i + 1 : i + 4]):
            out.append(int(body[i + 1 : i + 4], 8) & 0xFF)
            i += 4
        else:  # unknown escape: keep it as written
            out += b"\\"
            i += 1
    return out.decode("utf-8", "surrogateescape")


def _new_path(raw: str) -> str | None:
    raw = raw.rstrip("\t").rstrip("\r")
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        raw = _unquote_c(raw[1:-1])
    if raw == "/dev/null":
        return None
    return raw[2:] if raw.startswith("b/") else raw


def parse_diff(patch: str) -> Hunks:
    """Per new-side path, the hunks as (start, end, new-side line numbers that exist).

    Stateful: a hunk header's counts are consumed exactly, so a content line such as
    '+++ b/x' inside a hunk is never taken for a file header.
    """
    result: Hunks = {}
    lines = patch.split("\n")
    path: str | None = None
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if line.startswith("diff --git "):
            path = None
            continue
        if line.startswith("+++ "):
            path = _new_path(line[4:])
            continue
        match = HUNK_HEADER.match(line)
        if match is None:
            continue
        old_left = int(match.group(2)) if match.group(2) is not None else 1
        new_left = int(match.group(4)) if match.group(4) is not None else 1
        start = new_no = int(match.group(3))
        exist: set[int] = set()
        while (old_left > 0 or new_left > 0) and i < len(lines):
            body = lines[i]
            i += 1
            if body.startswith("\\"):
                continue
            if body.startswith("+"):
                exist.add(new_no)
                new_no += 1
                new_left -= 1
            elif body.startswith("-"):
                old_left -= 1
            else:  # context; a blank context line may have lost its space
                exist.add(new_no)
                new_no += 1
                old_left -= 1
                new_left -= 1
        if path is not None and exist:
            result.setdefault(path, []).append((start, max(exist), exist))
    return result


# --- findings ----------------------------------------------------------------


def parse_findings(text: str) -> list[Finding]:
    found: list[Finding] = []
    for line in text.splitlines():
        match = FINDING_WITH_END.match(line)
        if match is None:
            continue
        start = int(match["line"])
        end = int(match["end"]) if match["end"] else start
        found.append(
            Finding(
                len(found),
                int(match["n"]),
                match["path"],
                start,
                end,
                match["scenario"],
                match["severity"],
                match["confidence"],
            )
        )
    return found


def place_findings(
    findings: list[Finding], hunks: Hunks
) -> tuple[list[Finding], list[Finding]]:
    pinned: list[Finding] = []
    unpinned: list[Finding] = []
    for f in findings:
        ok = f.start <= f.end and any(
            all(n in exist for n in range(f.start, f.end + 1))
            for _s, _e, exist in hunks.get(f.path, [])
        )
        (pinned if ok else unpinned).append(f)
    return pinned, unpinned


def parse_verdict(text: str) -> str | None:
    for line in text.splitlines():
        match = check_review.REVIEW_FIELD.match(line)
        if match and match.group(1).lower() == "verdict":
            value = match.group(2).strip()
            return value if value in check_review.VERDICTS else None
    return None


def choose_event(verdict: str, pr_author: str | None, poster: str | None) -> str:
    if pr_author and poster and pr_author.lower() == poster.lower():
        return "COMMENT"
    return "APPROVE" if verdict == check_review.PASS else "REQUEST_CHANGES"


# --- the review --------------------------------------------------------------


def _where(f: Finding) -> str:
    return f"{f.path}:{f.start}" if f.start == f.end else f"{f.path}:{f.start}-{f.end}"


def _line_note(f: Finding, verdict: str) -> dict:
    note: dict = {
        "path": f.path,
        "line": f.end,
        "side": "RIGHT",
        "body": (
            f"**F{f.n} · {f.severity} · confidence {f.confidence}**\n\n"
            f"{f.scenario}\n\n"
            f"Part of this review (verdict: {verdict}). "
            "The full review is the global comment on the Conversation tab."
        ),
    }
    if f.start != f.end:
        note["start_line"] = f.start
        note["start_side"] = "RIGHT"
    return note


def _insert_line_notes(text: str, notes: list[str]) -> str:
    lines = text.split("\n")
    heading = next(
        (i for i, line in enumerate(lines) if check_review.FINDINGS_HEADING.match(line)), None
    )
    if heading is not None:
        end = len(lines)
        for i in range(heading + 1, len(lines)):
            if check_review.HEADING.match(lines[i]) or check_review.MACHINE_LINE.match(lines[i]):
                end = i
                break
    else:
        end = next(
            (i for i, line in enumerate(lines) if check_review.MACHINE_LINE.match(line)),
            len(lines),
        )
    ins = end
    while ins > 0 and not lines[ins - 1].strip():
        ins -= 1
    after = lines[ins:]
    if after and after[0].strip():
        after = [""] + after
    elif not after:
        after = [""]
    return "\n".join(lines[:ins] + ["", "## Line notes", ""] + notes + after)


FALLBACK_NOTE = "GitHub refused the review, so no line notes were posted."


def _body_with_notes(
    text: str,
    pinned: list[Finding],
    unpinned: list[Finding],
    event: str,
    fallback: bool,
) -> str:
    ordered = sorted([(f, True) for f in pinned] + [(f, False) for f in unpinned], key=lambda p: p[0].idx)
    notes: list[str] = [FALLBACK_NOTE] if fallback else []
    for f, is_pinned in ordered:
        if is_pinned and fallback:
            notes.append(
                f"- F{f.n} — meant for {_where(f)} in Files changed, "
                "but GitHub refused the review, so it is only here"
            )
        elif is_pinned:
            notes.append(f"- F{f.n} — pinned to {_where(f)} in Files changed")
        else:
            notes.append(f"- F{f.n} — not on a changed line, so it is only here")
    if not ordered:
        notes.append("No findings, so no line notes.")
    if event == "COMMENT":
        notes.extend(["", SELF_AUTHOR_NOTE])
    return _insert_line_notes(text.rstrip("\n"), notes) + "\n"


def build_fallback_body(
    text: str, pinned: list[Finding], unpinned: list[Finding], event: str
) -> str:
    """The plain-comment body: the review, with line notes that say none were posted."""
    return _body_with_notes(text, pinned, unpinned, event, True)


def build_review(
    text: str,
    pinned: list[Finding],
    unpinned: list[Finding],
    event: str,
    head_sha: str,
    verdict: str | None = None,
) -> dict:
    verdict = verdict or parse_verdict(text) or ""
    body = _body_with_notes(text, pinned, unpinned, event, False)
    return {
        "commit_id": head_sha,
        "body": body,
        "event": event,
        "comments": [_line_note(f, verdict) for f in sorted(pinned, key=lambda f: f.idx)],
    }


def check_lengths(payload: dict, fallback_body: str | None = None) -> None:
    if len(payload["body"]) > BODY_LIMIT:
        raise Refusal(
            f"the review body is {len(payload['body'])} characters; GitHub's limit is "
            f"{BODY_LIMIT}. Shorten the review."
        )
    if fallback_body is not None and len(fallback_body) > BODY_LIMIT:
        raise Refusal(
            f"the fallback comment body is {len(fallback_body)} characters; GitHub's "
            f"limit is {BODY_LIMIT}. Shorten the review."
        )
    for note in payload["comments"]:
        if len(note["body"]) > BODY_LIMIT:
            raise Refusal(
                f"the line note for {note['path']}:{note['line']} is {len(note['body'])} "
                f"characters; GitHub's limit is {BODY_LIMIT}. Shorten the finding."
            )


# --- inputs ------------------------------------------------------------------


def read_meta(path: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition(":")
        if sep:
            meta.setdefault(key.strip(), value.strip())
    return meta


# --- gh ----------------------------------------------------------------------


def _timeout() -> float:
    try:
        return float(os.environ.get(TIMEOUT_ENV, DEFAULT_TIMEOUT))
    except ValueError:
        return DEFAULT_TIMEOUT


def run_gh(gh: str, args: list[str]) -> tuple[int | None, str, str]:
    """Run gh once. Returns (exit code, stdout, stderr); the code is None on a timeout."""
    try:
        proc = subprocess.Popen(
            [gh, *args],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
    except OSError as exc:
        return 127, "", f"cannot run gh: {exc.strerror}"
    try:
        out, err = proc.communicate(timeout=_timeout())
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        out, err = proc.communicate()
        return None, out or "", f"timed out after {_timeout()} seconds"
    return proc.returncode, out, err


def http_status(out: str, err: str) -> int | None:
    for blob in (err, out):
        match = HTTP_CODE.search(blob)
        if match:
            return int(match.group(1))
    return None


def is_definite_rejection(code: int | None, out: str, err: str) -> bool:
    if code is None or code == 0:
        return False
    status = http_status(out, err)
    return status is not None and 400 <= status < 500 and status != 408


def _decode_many(blob: str) -> list:
    decoder = json.JSONDecoder()
    items: list = []
    pos = 0
    while True:
        while pos < len(blob) and blob[pos].isspace():
            pos += 1
        if pos >= len(blob):
            return items
        value, pos = decoder.raw_decode(blob, pos)
        items.extend(value if isinstance(value, list) else [value])


def _same_body(a: str, b: str) -> bool:
    return (a or "").replace("\r\n", "\n").strip() == (b or "").replace("\r\n", "\n").strip()


def _first_line(text: str) -> str:
    return (text.strip().splitlines() or [""])[0]


# --- main --------------------------------------------------------------------


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # refusals exit 1, like the rest
        print(f"{PROG}: {message}", file=sys.stderr)
        sys.exit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(
        prog=PROG,
        description="Post a checked bw-code-review review.md as one GitHub review "
        "with line notes (see the module docstring).",
    )
    parser.add_argument("review", help="<OUT>/review.md; OUT also holds meta.txt and diff.patch")
    parser.add_argument("--pr", required=True, help="the pull request number")
    parser.add_argument("--dry-run", action="store_true", help="build the payload, call nothing")
    return parser


def prepare(
    text: str, hunks: Hunks, event: str, head: str, verdict: str
) -> tuple[dict, list[Finding], list[Finding]]:
    pinned, unpinned = place_findings(parse_findings(text), hunks)
    payload = build_review(text, pinned, unpinned, event, head, verdict)
    check_lengths(payload, build_fallback_body(text, pinned, unpinned, event))
    return payload, pinned, unpinned


def run(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        pr = int(args.pr)
    except ValueError:
        pr = 0
    if pr <= 0:
        print(f"{PROG}: --pr must be a positive integer (got {args.pr!r})", file=sys.stderr)
        return 1
    review_path = Path(args.review)
    out_dir = review_path.resolve().parent
    if not args.dry_run:
        try:
            (out_dir / RESULT_FILE).unlink(missing_ok=True)
        except OSError as exc:
            print(f"{PROG}: cannot remove the old {RESULT_FILE}: {exc.strerror}", file=sys.stderr)
            return 1
    try:
        text = review_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"{PROG}: cannot read {args.review}: {exc.strerror}", file=sys.stderr)
        return 1
    faults = check_review.check(text) + check_review.check_brief(text)
    if faults:
        for fault in faults:
            print(f"{PROG}: {fault}", file=sys.stderr)
        print(f"{PROG}: refused: the review fails check_review; nothing posted", file=sys.stderr)
        return 1
    try:
        meta_path, diff_path = out_dir / "meta.txt", out_dir / "diff.patch"
        for needed in (meta_path, diff_path):
            if not needed.is_file():
                raise Refusal(f"{needed.name} is missing in {out_dir}; stage first")
        meta = read_meta(meta_path)
        repo, head = meta.get("repo", ""), meta.get("head_sha", "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise Refusal(f"meta.txt has no usable repo: line (got {repo!r})")
        if not HEAD_RE.fullmatch(head):
            raise Refusal(f"meta.txt has no usable head_sha: line (got {head!r})")
        verdict = parse_verdict(text) or ""
        hunks = parse_diff(diff_path.read_text(encoding="utf-8", errors="replace"))
        payload, pinned, unpinned = prepare(
            text, hunks, choose_event(verdict, None, None), head, verdict
        )
    except Refusal as exc:
        print(f"{PROG}: refused: {exc}", file=sys.stderr)
        return 1

    def write_files(p: dict) -> None:
        (out_dir / "github_review.json").write_text(
            json.dumps(p, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        (out_dir / "github_body.md").write_text(p["body"], encoding="utf-8")
        (out_dir / "github_fallback.md").write_text(
            build_fallback_body(text, pinned, unpinned, p["event"]), encoding="utf-8"
        )

    report: list[str] = []
    if args.dry_run:
        write_files(payload)
        report += [
            f"event (for a PR author other than the poster): {payload['event']}",
            f"pinned: {len(pinned)}",
            f"unpinned: {len(unpinned)}",
            f"payload: {out_dir / 'github_review.json'}",
            "DRY RUN: not posted",
        ]
        print("\n".join(f"{PROG}: {line}" for line in report))
        return 0

    gh = shutil.which("gh")
    if gh is None:
        print(f"{PROG}: gh was not found on PATH; nothing posted", file=sys.stderr)
        return 1
    code, o, e = run_gh(gh, ["api", "user", "--jq", ".login"])
    poster = o.strip()
    if code != 0 or not poster:
        print(f"{PROG}: cannot read the posting login: {_first_line(e or o)}", file=sys.stderr)
        return 1
    code, o, e = run_gh(
        gh, ["pr", "view", str(pr), "--repo", repo, "--json", "author,headRefOid"]
    )
    try:
        if code != 0:
            raise ValueError(_first_line(e or o))
        view = json.loads(o)
        author = view["author"]["login"]
        live_head = view["headRefOid"]
    except (ValueError, KeyError, TypeError) as exc:
        print(f"{PROG}: cannot read PR {pr} on {repo}: {exc}", file=sys.stderr)
        return 1
    if live_head != head:
        print(
            f"{PROG}: head moved: restage and review again "
            f"(staged {head}, PR head now {live_head}); nothing posted",
            file=sys.stderr,
        )
        return 1
    try:
        payload, pinned, unpinned = prepare(
            text, hunks, choose_event(verdict, author, poster), head, verdict
        )
    except Refusal as exc:
        print(f"{PROG}: refused: {exc}", file=sys.stderr)
        return 1
    write_files(payload)
    report += [
        f"event: {payload['event']}",
        f"pinned: {len(pinned)}",
        f"unpinned: {len(unpinned)}",
        "head moved before posting: no",
    ]
    failures: list[str] = []
    posted = False
    code, o, e = run_gh(
        gh,
        [
            "api", "--method", "POST", f"repos/{repo}/pulls/{pr}/reviews",
            "--input", str(out_dir / "github_review.json"),
        ],
    )
    unknown = False
    review_posted = False
    review_url = ""
    if code == 0:
        posted = review_posted = True
        try:
            url = json.loads(o).get("html_url", "")
        except (ValueError, AttributeError):
            url = ""
        review_url = url or ""
        report.append(f"review posted: {url or '(no html_url in the answer)'}")
    else:
        error = _first_line(e or o) or "no answer"
        failures.append(f"review post failed: {error}")
        fallback = True
        if not is_definite_rejection(code, o, e):
            rc, ro, re_ = run_gh(gh, ["api", "--paginate", f"repos/{repo}/pulls/{pr}/reviews"])
            try:
                if rc != 0:
                    raise ValueError(_first_line(re_ or ro) or "no answer")
                items = _decode_many(ro)
            except ValueError as exc:
                failures.append(f"read-back failed: {exc}")
                report.append("outcome unknown: the review may or may not exist; no further write")
                fallback, unknown = False, True
            else:
                mine = next(
                    (
                        r
                        for r in items
                        if isinstance(r, dict)
                        and ((r.get("user") or {}).get("login") or "").lower() == poster.lower()
                        and r.get("commit_id") == head
                        and _same_body(r.get("body", ""), payload["body"])
                    ),
                    None,
                )
                if mine is not None:
                    posted, fallback, review_posted = True, False, True
                    review_url = mine.get("html_url", "") or ""
                    report.append(
                        f"review posted (confirmed by read-back): {mine.get('html_url', '')}"
                    )
        if fallback:
            code, o, e = run_gh(
                gh,
                [
                    "pr", "comment", str(pr), "--repo", repo,
                    "--body-file", str(out_dir / "github_fallback.md"),
                ],
            )
            if code == 0:
                posted = True
                report.append(f"fallback comment posted: {_first_line(o)}")
            else:
                failures.append(f"fallback comment failed: {_first_line(e or o) or 'no answer'}")
    head_moved_after = False
    if posted:
        rc, ro, re_ = run_gh(
            gh, ["pr", "view", str(pr), "--repo", repo, "--json", "headRefOid"]
        )
        try:
            if rc != 0:
                raise ValueError(_first_line(re_ or ro) or "no answer")
            after = json.loads(ro)["headRefOid"]
        except (ValueError, KeyError, TypeError) as exc:
            report.append(f"head after posting: unknown ({exc})")
        else:
            if after != head:
                head_moved_after = True
                report.append(
                    f"head moved after posting: the review sits on the staged head "
                    f"{head[:7]}, the PR head is now {str(after)[:7]}; "
                    "restage and review again"
                )
    for line in report:
        print(f"{PROG}: {line}")
    for failure in failures:
        print(f"{PROG}: {failure}", file=sys.stderr)
    if not posted and not unknown:
        print(f"{PROG}: FAIL: nothing posted", file=sys.stderr)
    if posted and not head_moved_after:
        (out_dir / RESULT_FILE).write_text(
            json.dumps(
                {
                    "posted": True,
                    "kind": "review" if review_posted else "comment",
                    "repo": repo,
                    "pr": pr,
                    "head": head,
                    "review_url": review_url,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        return 0
    return 1


def main(argv: list[str]) -> int:
    try:
        return run(argv[1:])
    except Refusal as exc:
        print(f"{PROG}: refused: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

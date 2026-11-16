#!/usr/bin/env python3
"""run_tracker.py: the optional tracker hook that runs once after a review is posted.

Usage: run_tracker.py <OUT>/review.md [--pr <n>] [--review-url <url>] [--no-github] [--dry-run]

Reads config.json next to this script. With no config.json, or no "tracker_command"
in it, it prints "tracker: none configured" and exits 0.

"tracker_command" is an argv list, never a shell string. Each element has these
placeholders replaced: {review} {verdict} {reason} {repo} {pr} {head} {review_url}.
  {review}      the path of review.md
  {verdict}     PASSED or REWORK NEEDED
  {reason}      the reason line (empty on PASSED)
  {repo}, {head}  from OUT/meta.txt (empty when meta.txt is absent)
  {pr}          the --pr value (empty when not given)
  {review_url}  the --review-url value (empty when not given)

It refuses (exit 1) when check_review finds any fault in the review.
It runs the command once: no shell, stdin closed, a timeout of "tracker_timeout_s"
seconds (default 60), no retry. It prints the exit code and the first line of the
output. Exit 0 when the command succeeded, 1 otherwise.
--dry-run prints the argv it would run and runs nothing.

GitHub gate: a live run refuses (exit 1, nothing run) unless OUT/github_result.json, which
post_review.py writes only after a post that left the head unmoved, exists, is valid, says
"posted": true, and its repo, pr and head equal OUT/meta.txt's repo and head_sha and the
--pr given. --no-github skips that requirement (for a review that had no PR or no gh
login) and says so in the output. --dry-run never requires the file. {review_url} comes
from the result file when --review-url is not given.

Stdlib only.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("check_review", _HERE / "check_review.py")
assert _spec is not None and _spec.loader is not None
check_review = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_review)

PROG = "run_tracker"
DEFAULT_TIMEOUT = 60.0
RESULT_FILE = "github_result.json"
PLACEHOLDERS = ("review", "verdict", "reason", "repo", "pr", "head", "review_url")


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # refusals exit 1, like the rest
        print(f"{PROG}: {message}", file=sys.stderr)
        sys.exit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(prog=PROG, description="Run the configured tracker command once.")
    parser.add_argument("review", help="<OUT>/review.md")
    parser.add_argument("--pr", default="", help="the pull request number")
    parser.add_argument("--review-url", default="", help="the URL of the posted review")
    parser.add_argument(
        "--no-github",
        action="store_true",
        help="skip the GitHub result check (no PR, or gh not logged in)",
    )
    parser.add_argument("--dry-run", action="store_true", help="print the argv, run nothing")
    return parser


def read_meta(path: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return meta
    for line in text.splitlines():
        key, sep, value = line.partition(":")
        if sep:
            meta.setdefault(key.strip(), value.strip())
    return meta


_PLACEHOLDER = re.compile(r"\{(" + "|".join(PLACEHOLDERS) + r")\}")


def substitute(element: str, values: dict[str, str]) -> str:
    """Replace each known {placeholder} in one argv element in a single pass.

    A value that itself contains "{head}" is never substituted again.
    """
    return _PLACEHOLDER.sub(lambda match: values[match.group(1)], element)


def load_config(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise SystemExit(f"{PROG}: cannot read {path.name}: {exc}")
    if not isinstance(value, dict):
        raise SystemExit(f"{PROG}: {path.name} must be a JSON object")
    return value


def github_gate(out_dir: Path, meta: dict[str, str], pr: str) -> tuple[str | None, str]:
    """Return (refusal reason or None, review_url from the result file)."""
    path = out_dir / RESULT_FILE
    if not path.is_file():
        return f"{RESULT_FILE} is missing: post_review.py has not posted this review", ""
    try:
        result = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return f"{RESULT_FILE} is not valid JSON: {exc}", ""
    if not isinstance(result, dict) or result.get("posted") is not True:
        return f'{RESULT_FILE} does not say "posted": true', ""
    pr_ok = pr.isdigit() and result.get("pr") == int(pr)
    for name, ok in (
        ("repo", bool(meta.get("repo")) and result.get("repo") == meta.get("repo")),
        ("pr", pr_ok),
        ("head", bool(meta.get("head_sha")) and result.get("head") == meta.get("head_sha")),
    ):
        if not ok:
            return f"{RESULT_FILE} {name} does not match meta.txt and --pr", ""
    url = result.get("review_url")
    return None, url if isinstance(url, str) else ""


def _timeout(config: dict) -> float:
    value = config.get("tracker_timeout_s", DEFAULT_TIMEOUT)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
        return DEFAULT_TIMEOUT
    return float(value)


def run(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    review_path = Path(args.review)
    config = load_config(_HERE / "config.json")
    command = config.get("tracker_command")
    if command is None:
        print("tracker: none configured")
        return 0
    if (
        not isinstance(command, list)
        or not command
        or not all(isinstance(item, str) for item in command)
    ):
        print(f"{PROG}: tracker_command must be a non-empty list of strings", file=sys.stderr)
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
        print(f"{PROG}: refused: the review fails check_review; tracker not run", file=sys.stderr)
        return 1
    fields = {
        match.group(1).lower(): match.group(2).strip()
        for line in text.splitlines()
        if (match := check_review.REVIEW_FIELD.match(line))
    }
    meta = read_meta(review_path.resolve().parent / "meta.txt")
    values = {
        "review": str(review_path),
        "verdict": fields.get("verdict", ""),
        "reason": fields.get("reason", ""),
        "repo": meta.get("repo", ""),
        "pr": str(args.pr),
        "head": meta.get("head_sha", ""),
        "review_url": args.review_url,
    }
    if not args.dry_run:
        if args.no_github:
            print(f"{PROG}: --no-github: the GitHub result is not required")
        else:
            reason, result_url = github_gate(review_path.resolve().parent, meta, str(args.pr))
            if reason:
                print(f"{PROG}: refused: {reason}; tracker not run", file=sys.stderr)
                return 1
            if not args.review_url:
                values["review_url"] = result_url
    argv_out = [substitute(item, values) for item in command]
    if args.dry_run:
        print(f"{PROG}: would run: {json.dumps(argv_out)}")
        print(f"{PROG}: DRY RUN: nothing run")
        return 0
    timeout = _timeout(config)
    try:
        proc = subprocess.Popen(
            argv_out,
            shell=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
    except OSError as exc:
        print(f"{PROG}: tracker command failed to start: {exc.strerror or exc}", file=sys.stderr)
        return 1
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        print(f"{PROG}: tracker command timed out after {timeout:g} seconds", file=sys.stderr)
        return 1
    first = (out.strip().splitlines() or [""])[0]
    print(f"{PROG}: exit code {proc.returncode}")
    print(f"{PROG}: output: {first}")
    return 0 if proc.returncode == 0 else 1


def main(argv: list[str]) -> int:
    return run(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))

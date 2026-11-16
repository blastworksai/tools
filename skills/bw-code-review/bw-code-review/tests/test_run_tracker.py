"""Tests for run_tracker.py. Each test copies the two scripts into a temp folder so
that config.json (read next to the script) can be written freely. No network."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent.parent
SHA = "0123456789abcdef0123456789abcdef01234567"

REVIEW = """## What this change does

It adds a retry loop.
It keeps the old path.
It logs each retry.

## Findings

None.

verdict: PASSED
"""

REWORK = REVIEW.replace("verdict: PASSED", "verdict: REWORK NEEDED\nreason: the loop never ends")


class Rig:
    def __init__(self, tmp: Path) -> None:
        self.skill = tmp / "skill"
        self.skill.mkdir()
        for name in ("run_tracker.py", "check_review.py"):
            shutil.copy(HERE / name, self.skill / name)
        self.out = tmp / "OUT"
        self.out.mkdir()
        self.marks = tmp / "marks"
        self.marks.mkdir()

    def config(self, **cfg: object) -> None:
        (self.skill / "config.json").write_text(json.dumps(cfg))

    def review(self, text: str = REVIEW, meta: bool = True) -> Path:
        path = self.out / "review.md"
        path.write_text(text)
        if meta:
            (self.out / "meta.txt").write_text(f"repo: octocat/hello-world\nhead_sha: {SHA}\n")
        return path

    def result(self, **fields: object) -> None:
        """Write OUT/github_result.json as post_review.py would, then override fields."""
        body = {
            "posted": True, "kind": "review", "repo": "octocat/hello-world", "pr": 12,
            "head": SHA, "review_url": "https://example.invalid/r/9",
        }
        body.update(fields)
        (self.out / "github_result.json").write_text(json.dumps(body))

    def run(self, *args: str, gate: bool = False) -> subprocess.CompletedProcess:
        """gate=False adds --no-github to a live run so tests of the command itself stay
        about the command; gate=True leaves the GitHub gate on."""
        if not gate and "--dry-run" not in args and "--no-github" not in args:
            args = (*args, "--no-github")
        return subprocess.run(
            [sys.executable, str(self.skill / "run_tracker.py"), *args],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def recorder(self, name: str = "rec") -> list[str]:
        """An argv head that records its own arguments as JSON in marks/<name>.json."""
        script = self.marks / f"{name}.py"
        script.write_text(
            "import json, sys\n"
            f"json.dump(sys.argv[1:], open({str(self.marks / (name + '.json'))!r}, 'w'))\n"
            "print('recorded ok')\n"
        )
        return [sys.executable, str(script)]

    def recorded(self, name: str = "rec") -> list[str] | None:
        path = self.marks / f"{name}.json"
        return json.loads(path.read_text()) if path.exists() else None


@pytest.fixture()
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def test_no_config_prints_none_configured_and_exits_zero(rig: Rig) -> None:
    path = rig.review()
    proc = rig.run(str(path))
    assert proc.returncode == 0, proc.stderr
    assert "tracker: none configured" in proc.stdout


def test_no_config_does_not_even_read_the_review(rig: Rig) -> None:
    proc = rig.run(str(rig.out / "absent.md"))
    assert proc.returncode == 0 and "tracker: none configured" in proc.stdout


def test_config_without_a_command_prints_none_configured(rig: Rig) -> None:
    rig.config(self_names=["bot"], tracker_timeout_s=5)
    proc = rig.run(str(rig.review()))
    assert proc.returncode == 0, proc.stderr
    assert "tracker: none configured" in proc.stdout


def test_placeholders_are_substituted_per_element(rig: Rig) -> None:
    rig.config(
        tracker_command=[
            *rig.recorder(),
            "{review}",
            "{verdict}",
            "{reason}",
            "{repo}",
            "{pr}",
            "{head}",
            "{review_url}",
            "pr-{pr}-of-{repo}",
            "{unknown}",
        ]
    )
    path = rig.review(REWORK)
    proc = rig.run(str(path), "--pr", "12", "--review-url", "https://example.invalid/r/1")
    assert proc.returncode == 0, proc.stderr
    assert rig.recorded() == [
        str(path),
        "REWORK NEEDED",
        "the loop never ends",
        "octocat/hello-world",
        "12",
        SHA,
        "https://example.invalid/r/1",
        "pr-12-of-octocat/hello-world",
        "{unknown}",
    ]
    assert "exit code 0" in proc.stdout and "recorded ok" in proc.stdout


def test_a_substituted_value_is_not_substituted_again(rig: Rig) -> None:
    rig.config(tracker_command=[*rig.recorder(), "{review_url}"])
    proc = rig.run(str(rig.review()), "--review-url", "x-{head}-{pr}")
    assert proc.returncode == 0, proc.stderr
    assert rig.recorded() == ["x-{head}-{pr}"]


def test_missing_optional_values_become_empty(rig: Rig) -> None:
    rig.config(tracker_command=[*rig.recorder(), "{pr}", "{review_url}", "{reason}", "{repo}"])
    proc = rig.run(str(rig.review(meta=False)))
    assert proc.returncode == 0, proc.stderr
    assert rig.recorded() == ["", "", "", ""]


def test_no_shell_a_semicolon_stays_literal(rig: Rig) -> None:
    marker = rig.marks / "injected"
    rig.config(
        tracker_command=[*rig.recorder(), f"x; touch {marker}", "$(touch " + str(marker) + ")", "`id`"]
    )
    proc = rig.run(str(rig.review()))
    assert proc.returncode == 0, proc.stderr
    assert not marker.exists()
    assert rig.recorded() == [
        f"x; touch {marker}",
        "$(touch " + str(marker) + ")",
        "`id`",
    ]


def test_a_shell_string_command_is_refused(rig: Rig) -> None:
    rig.config(tracker_command="echo hello; echo there")
    proc = rig.run(str(rig.review()))
    assert proc.returncode == 1 and "non-empty list of strings" in proc.stderr


@pytest.mark.parametrize("command", [[], ["ok", 3], [None]])
def test_a_bad_command_list_is_refused(rig: Rig, command: list) -> None:
    rig.config(tracker_command=command)
    proc = rig.run(str(rig.review()))
    assert proc.returncode == 1 and "non-empty list of strings" in proc.stderr


def test_timeout_kills_the_command_and_exits_one(rig: Rig) -> None:
    rig.config(
        tracker_command=[sys.executable, "-c", "import time; time.sleep(30)"],
        tracker_timeout_s=0.5,
    )
    proc = rig.run(str(rig.review()))
    assert proc.returncode == 1
    assert "timed out after 0.5 seconds" in proc.stderr


def test_non_zero_exit_is_reported_and_exits_one_without_retry(rig: Rig) -> None:
    counter = rig.marks / "count"
    script = (
        "import sys; open(sys.argv[1], 'a').write('x'); print('boom first line'); "
        "print('second'); sys.exit(3)"
    )
    rig.config(tracker_command=[sys.executable, "-c", script, str(counter)])
    proc = rig.run(str(rig.review()))
    assert proc.returncode == 1
    assert "exit code 3" in proc.stdout
    assert "output: boom first line" in proc.stdout and "second" not in proc.stdout
    assert counter.read_text() == "x"  # ran exactly once


def test_a_command_that_cannot_start_exits_one(rig: Rig) -> None:
    rig.config(tracker_command=[str(rig.marks / "no-such-program")])
    proc = rig.run(str(rig.review()))
    assert proc.returncode == 1 and "failed to start" in proc.stderr


def test_stdin_is_closed(rig: Rig) -> None:
    script = "import sys; print(repr(sys.stdin.read()))"
    rig.config(tracker_command=[sys.executable, "-c", script])
    proc = rig.run(str(rig.review()))
    assert proc.returncode == 0, proc.stderr
    assert "output: ''" in proc.stdout


def test_check_fault_is_refused_before_running(rig: Rig) -> None:
    rig.config(tracker_command=rig.recorder())
    proc = rig.run(str(rig.review(REVIEW.replace("verdict: PASSED", "verdict: maybe"))))
    assert proc.returncode == 1
    assert "refused" in proc.stderr and "verdict must be exactly one of" in proc.stderr
    assert rig.recorded() is None


def test_missing_summary_is_refused_before_running(rig: Rig) -> None:
    rig.config(tracker_command=rig.recorder())
    proc = rig.run(str(rig.review(REVIEW.replace("## What this change does", "## Notes"))))
    assert proc.returncode == 1 and "What this change does" in proc.stderr
    assert rig.recorded() is None


def test_unreadable_review_is_refused_before_running(rig: Rig) -> None:
    rig.config(tracker_command=rig.recorder())
    proc = rig.run(str(rig.out / "absent.md"))
    assert proc.returncode == 1 and "cannot read" in proc.stderr
    assert rig.recorded() is None


def test_dry_run_prints_the_argv_and_runs_nothing(rig: Rig) -> None:
    rig.config(tracker_command=[*rig.recorder(), "{verdict}", "{pr}"])
    proc = rig.run(str(rig.review()), "--pr", "7", "--dry-run")
    assert proc.returncode == 0, proc.stderr
    assert rig.recorded() is None
    assert "DRY RUN: nothing run" in proc.stdout
    line = next(x for x in proc.stdout.splitlines() if "would run:" in x)
    argv = json.loads(line.split("would run: ", 1)[1])
    assert argv[-2:] == ["PASSED", "7"]


def test_dry_run_still_refuses_a_check_fault(rig: Rig) -> None:
    rig.config(tracker_command=rig.recorder())
    proc = rig.run(str(rig.review("no verdict here\n")), "--dry-run")
    assert proc.returncode == 1


def test_dry_run_with_no_config_says_none_configured(rig: Rig) -> None:
    proc = rig.run(str(rig.review()), "--dry-run")
    assert proc.returncode == 0 and "tracker: none configured" in proc.stdout


def test_broken_config_is_refused(rig: Rig) -> None:
    (rig.skill / "config.json").write_text("{not json")
    proc = rig.run(str(rig.review()))
    assert proc.returncode != 0 and "config.json" in proc.stderr


def test_the_example_config_is_valid_and_its_command_is_an_argv_list() -> None:
    example = json.loads((HERE / "config.example.json").read_text())
    assert isinstance(example["self_names"], list)
    command = example["tracker_command"]
    assert isinstance(command, list) and all(isinstance(x, str) for x in command)
    assert command[:2] == ["gh", "issue"]


# --- the GitHub gate ---------------------------------------------------------


def gated(rig: Rig, *args: str) -> subprocess.CompletedProcess:
    rig.config(tracker_command=[*rig.recorder(), "{review_url}", "{pr}"])
    return rig.run(str(rig.review()), *args, gate=True)


def test_gate_refuses_without_a_result_file_and_runs_nothing(rig: Rig) -> None:
    proc = gated(rig, "--pr", "12")
    assert proc.returncode == 1
    assert "github_result.json is missing" in proc.stderr and "tracker not run" in proc.stderr
    assert rig.recorded() is None


def test_gate_accepts_a_matching_result_and_takes_the_url_from_it(rig: Rig) -> None:
    rig.result()
    proc = gated(rig, "--pr", "12")
    assert proc.returncode == 0, proc.stderr
    assert rig.recorded() == ["https://example.invalid/r/9", "12"]


def test_gate_an_explicit_review_url_wins_over_the_result_file(rig: Rig) -> None:
    rig.result()
    proc = gated(rig, "--pr", "12", "--review-url", "https://example.invalid/mine")
    assert proc.returncode == 0, proc.stderr
    assert rig.recorded() == ["https://example.invalid/mine", "12"]


@pytest.mark.parametrize(
    "fields,pr,word",
    [
        ({"head": "f" * 40}, "12", "head"),
        ({"repo": "someone/else"}, "12", "repo"),
        ({"pr": 13}, "12", "pr"),
        ({}, "13", "pr"),
        ({}, "", "pr"),
        ({"posted": False}, "12", "posted"),
        ({"posted": "true"}, "12", "posted"),
    ],
)
def test_gate_refuses_a_mismatched_or_unposted_result(
    rig: Rig, fields: dict, pr: str, word: str
) -> None:
    rig.result(**fields)
    proc = gated(rig, "--pr", pr)
    assert proc.returncode == 1 and word in proc.stderr and "tracker not run" in proc.stderr
    assert rig.recorded() is None


def test_gate_refuses_an_invalid_result_file(rig: Rig) -> None:
    (rig.out / "github_result.json").write_text("{not json")
    rig.config(tracker_command=rig.recorder())
    proc = rig.run(str(rig.review()), "--pr", "12", gate=True)
    assert proc.returncode == 1 and "not valid JSON" in proc.stderr
    assert rig.recorded() is None


def test_gate_refuses_when_meta_is_absent(rig: Rig) -> None:
    rig.result()
    rig.config(tracker_command=rig.recorder())
    proc = rig.run(str(rig.review(meta=False)), "--pr", "12", gate=True)
    assert proc.returncode == 1 and rig.recorded() is None


def test_no_github_bypasses_the_gate_and_says_so(rig: Rig) -> None:
    rig.config(tracker_command=[*rig.recorder(), "{review_url}"])
    proc = rig.run(str(rig.review()), "--no-github", gate=True)
    assert proc.returncode == 0, proc.stderr
    assert "--no-github" in proc.stdout
    assert rig.recorded() == [""]


def test_dry_run_never_requires_the_result_file(rig: Rig) -> None:
    rig.config(tracker_command=rig.recorder())
    proc = rig.run(str(rig.review()), "--pr", "12", "--dry-run", gate=True)
    assert proc.returncode == 0, proc.stderr
    assert "DRY RUN: nothing run" in proc.stdout and rig.recorded() is None

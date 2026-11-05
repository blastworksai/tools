#!/usr/bin/env python3
"""Run synthetic Luau behavior fixtures in an explicitly selected Tern desktop.

No model calls, GUI creation, provider requests, or successful skipped suites.
A failed/partial run exits nonzero. Keep this desktop and its Carly conversation
exclusive to verification: each real lua tool invocation writes a turn.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid


# Removing a shipped fixture must not silently make --suite all greener.
REQUIRED_SUITES = frozenset({
    "accounts", "aggregate", "capacity", "companion", "host_setup", "identity",
    "metadata_runner", "presentation", "protocol", "roster", "setup", "snapshot",
    "source_collect", "window",
})
MARKER = "USAGE_VERIFY "


class VerificationError(Exception):
    """A control, fixture, or result-contract failure; never a skipped success."""


def control(tern: str, endpoint: str, words: list[str], deadline: float) -> dict:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise VerificationError("desktop control deadline expired")
    try:
        reply = subprocess.run(
            [tern, "ctl", "--control", endpoint, *words],
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            encoding="utf-8", timeout=remaining, check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise VerificationError("desktop control timed out; the GUI tool may still be running") from exc
    except (OSError, UnicodeError) as exc:
        raise VerificationError(f"cannot run/read Tern desktop control: {exc}") from exc
    if reply.returncode != 0:
        raise VerificationError(f"tern ctl exited {reply.returncode}: {reply.stderr.strip() or reply.stdout.strip()}")
    try:
        value = json.loads(reply.stdout)
    except json.JSONDecodeError as exc:
        raise VerificationError("tern ctl did not return a JSON reply") from exc
    if not isinstance(value, dict) or value.get("ok") is not True:
        raise VerificationError(f"desktop control rejected the command: {value}")
    return value


def desktop_state(tern: str, endpoint: str, deadline: float) -> dict:
    value = control(tern, endpoint, ["state"], deadline)
    carly = value.get("carly")
    if not isinstance(carly, dict):
        raise VerificationError("no desktop Carly state; start a dedicated real Tern desktop, not tern serve")
    return carly


def run_suite(tern: str, endpoint: str, root: Path, suite: str, timeout: float) -> dict:
    run_id = uuid.uuid4().hex
    deadline = time.monotonic() + timeout
    # JSON encoding provides script quoting. Tern ctl joins argv into one command
    # line; passing the unquoted code as the last argv item is not equivalent.
    # POSIX paths also work with Tern on Windows, without Lua backslash escapes.
    driver = (root / "tests" / "run_luau.luau").as_posix()
    code = (
        f"return assert(loadstring(tern.fs.read({json.dumps(driver, ensure_ascii=False)})))"
        f"({json.dumps(root.as_posix(), ensure_ascii=False)}, "
        f"{{{json.dumps(suite)}}}, {json.dumps(run_id)})"
    )
    control(tern, endpoint, ["carly", "lua", json.dumps(code, ensure_ascii=False)], deadline)
    # Carly tools normally settle before ctl returns. Inspect state nonetheless:
    # ctl's {ok:true} is not a fixture result and tool errors can coexist with it.
    while True:
        last = desktop_state(tern, endpoint, deadline).get("last_tool")
        if not isinstance(last, dict):
            raise VerificationError("desktop returned no state.carly.last_tool result")
        if last.get("error") is not False:
            raise VerificationError(f"Carly Lua tool failed: {last.get('text', 'missing error result')}")
        text = last.get("text")
        if not isinstance(text, str):
            raise VerificationError("Carly Lua tool returned no text")
        # A fresh Lua VM may precede its return value with a notice.
        payload = next((line.removeprefix("→ ") for line in text.splitlines()
                        if line.startswith(MARKER) or line.startswith("→ " + MARKER)), "")
        if payload.startswith(MARKER):
            try:
                result = json.loads(payload[len(MARKER):])
            except json.JSONDecodeError as exc:
                raise VerificationError("Carly returned malformed fixture JSON") from exc
            if isinstance(result, dict) and result.get("run_id") == run_id:
                return validate_result(result, suite)
        # Never accept an earlier PASS or a concurrent user's tool result.
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise VerificationError("no matching fixture result before timeout (stale or competing Carly tool)")
        time.sleep(min(0.1, remaining))


def validate_result(result: dict, suite: str) -> dict:
    rows = result.get("results")
    if result.get("version") != 1 or not isinstance(rows, list) or len(rows) != 1:
        raise VerificationError("aggregate driver returned missing or unexpected suites")
    row = rows[0]
    if not isinstance(row, dict) or row.get("suite") != suite:
        raise VerificationError("aggregate driver returned the wrong suite")
    count = row.get("checks")
    if (type(count) is not int or count <= 0 or row.get("status") != "PASS"
            or result.get("status") != "PASS" or result.get("suites") != 1
            or result.get("passed") != 1 or result.get("failed") != 0
            or result.get("checks") != count):
        raise VerificationError(str(row.get("error", "fixture did not pass every requested suite")))
    actual = row.get("result")
    if not isinstance(actual, str):
        raise VerificationError("fixture PASS text is missing")
    match = re.fullmatch(r"PASS ([0-9]+) .+", actual) or re.fullmatch(
        rf"PASS {re.escape(suite)}: ([0-9]+) checks", actual
    )
    if (match is None or int(match.group(1)) != count
            or re.search(r"\bSKIP\w*\b", actual, flags=re.IGNORECASE)):
        raise VerificationError("fixture's actual PASS/check text disagrees with the aggregate result")
    return row


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control", required=True, help="explicit real desktop socket path or loopback TCP port")
    parser.add_argument("--suite", default="all", help="all, or one tests/<name>.luau fixture")
    parser.add_argument("--tern", default="tern", help="Tern executable path (not a shell command)")
    parser.add_argument("--plugin-dir", type=Path, default=Path(__file__).resolve().parents[1],
                        help="package directory readable by both this launcher and the local Tern desktop")
    parser.add_argument("--timeout", type=float, default=30.0, help="deadline in seconds per fixture, including control/state")
    args = parser.parse_args()
    if not args.control.strip() or any(ord(char) < 32 for char in args.control):
        parser.error("--control must name an explicit desktop endpoint without control characters")
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be positive and finite")
    return args


def main() -> int:
    args = arguments()
    passed, checks, selected = 0, 0, []
    current = "preflight"
    try:
        root = args.plugin_dir.resolve(strict=True)
        tests = root / "tests"
        available = {path.stem for path in tests.glob("*.luau") if path.name != "run_luau.luau" and path.is_file()}
        missing = REQUIRED_SUITES - available
        if missing:
            raise VerificationError("missing shipped suites: " + ", ".join(sorted(missing)))
        if not (tests / "run_luau.luau").is_file():
            raise VerificationError("missing aggregate driver tests/run_luau.luau")
        if any(re.fullmatch(r"[a-z][a-z0-9_]*", name) is None for name in available):
            raise VerificationError("fixture filenames must be lowercase identifiers")
        if args.suite != "all" and args.suite not in available:
            raise VerificationError(f"unknown suite {args.suite!r}; available: {', '.join(sorted(available))}")
        selected = sorted(available) if args.suite == "all" else [args.suite]
        desktop_state(args.tern, args.control, time.monotonic() + args.timeout)
        for current in selected:
            row = run_suite(args.tern, args.control, root, current, args.timeout)
            passed += 1
            checks += row["checks"]
            print(f"{current}: {row['result']}", flush=True)
    except (VerificationError, OSError) as exc:
        print(f"FAIL {current}: {exc}", file=sys.stderr)
        print(f"FAILED: {passed}/{len(selected)} suites passed; {checks} reported checks in passed suites; "
              f"{len(selected) - passed} suites failed or not run. No aggregate PASS.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(f"INTERRUPTED: {passed}/{len(selected)} suites passed; {checks} reported checks. "
              "The GUI tool may still be running; no aggregate PASS.", file=sys.stderr)
        return 130
    print(f"PASS: {passed}/{len(selected)} suites; {checks} reported checks/cases; 0 skipped. "
          "Synthetic behavior fixtures only, not live deployment acceptance.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

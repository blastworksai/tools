#!/usr/bin/env python3
"""Expose an interactive execute plan to TODO. Blastworks.ai, MIT."""

import argparse
from base64 import b64decode, b64encode
from binascii import Error as InvalidEncoding
import importlib.util
import json
import os
import re
import shlex
import sys
import time
from pathlib import Path, PureWindowsPath
from types import ModuleType
from typing import Any

CORE_PATH = Path(__file__).resolve().parent / "bin" / "todo.py"
CODEX_EXECUTE = re.compile(r"[ \t]*\$glitch-execute(?:[ \t]+(.*))?")
CLAUDE_PID = re.compile(r"[1-9][0-9]{0,9}")
MAX_PAYLOAD = 256 * 1024
MAX_OPERAND = 4096
WINDOWS_SWITCHES = ' -NoLogo -NoProfile -NonInteractive -EncodedCommand '
WINDOWS_EXIT = '\nexit $LASTEXITCODE'
WINDOWS_LITERAL = re.compile(r"'((?:[^']|'')*)'")
LEGACY_INSTRUCTION = (
    "TODO found the canonical plan without a TERN-SESSION block. Adopt the plan "
    "through the normal authorized execute workflow. Add a schema 2 block from "
    "its agreed checkpoints and verified state. Preserve approvals and START HERE. "
    "After saving the block in that exact plan, run this one command: "
)
INVALID_BLOCK = "TODO could not read the plan's TERN-SESSION checkpoint block. Correct it through the normal execute workflow."


class HookParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ValueError(message)


def _load_core() -> ModuleType:
    # The installer stages the helper and its imports together. The cwd and
    # stdin payload must never participate in Python module lookup.
    spec = importlib.util.spec_from_file_location("todo", CORE_PATH)
    if spec is None or spec.loader is None:
        raise ImportError("TODO publisher is unavailable")
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(CORE_PATH.parent))
    core = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(core)
    return core


def _operand(raw: Any) -> str | None:
    if not isinstance(raw, str) or len(raw) > MAX_OPERAND:
        return None
    if any(ord(character) < 32 for character in raw):
        return None
    # shlex tokenizes the argument. It does not expand variables, globs or
    # substitutions. The publisher only receives the resulting literal path.
    if os.name == 'nt':
        # A native Windows path may contain backslashes. Accept one unquoted
        # word or one quoted path, without shell expansion or concatenation.
        stripped = raw.strip()
        quoted = re.fullmatch(r"\"([^\"]+)\"|'([^']+)'", stripped)
        if quoted:
            words = [quoted[1] or quoted[2]]
        else:
            words = [stripped] if re.fullmatch(r'''[^\s"']+''', stripped) else []
    else:
        try:
            words = shlex.split(raw)
        except ValueError:
            return None
    if len(words) != 1:
        return None
    operand = words[0]
    if not operand or operand.startswith(("-", "~")):
        return None
    return operand


def _execute_invocation(payload: dict[str, Any], harness: str) -> tuple[str, str] | None:
    event = payload.get("hook_event_name")
    if harness == "codex" and event == "UserPromptSubmit":
        prompt = payload.get("prompt")
        match = CODEX_EXECUTE.fullmatch(prompt) if isinstance(prompt, str) else None
        raw = match[1] if match else None
        invocation_id = payload.get("turn_id")
    elif harness == "claude" and event == "UserPromptExpansion":
        if payload.get("expansion_type") != "slash_command" or payload.get("command_name") != "glitch-execute":
            return None
        raw = payload.get("command_args")
        invocation_id = payload.get("prompt_id")
    elif harness == "claude" and event == "PreToolUse":
        tool_input = payload.get("tool_input")
        if payload.get("tool_name") != "Skill" or not isinstance(tool_input, dict):
            return None
        if tool_input.get("skill") != "glitch-execute":
            return None
        raw = tool_input.get("args")
        invocation_id = payload.get("prompt_id")
    else:
        return None

    operand = _operand(raw)
    if operand is None or not isinstance(invocation_id, str) or not invocation_id:
        return None
    return operand, invocation_id


def _lifecycle(payload: dict[str, Any], harness: str) -> bool | None:
    """Return true for startup, false for end, or none for an unrelated event."""
    event = payload.get("hook_event_name")
    if event == "SessionStart":
        source = payload.get("source")
        if source == "startup" or (harness == "claude" and source in ("clear", "resume")):
            return True
    if event == "SessionEnd" and payload.get("reason") not in ("compact", "compaction"):
        return False
    return None


def windows_system_directory() -> PureWindowsPath:
    import ctypes

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    buffer = ctypes.create_unicode_buffer(32768)
    length = kernel.GetSystemDirectoryW(buffer, len(buffer))
    if not 0 < length < len(buffer):
        raise OSError('cannot identify Windows system directory')
    return PureWindowsPath(buffer.value)


def command_line(arguments: list[str]) -> str:
    if os.name != 'nt':
        return shlex.join(arguments)
    # Both agents start hooks through a shell. A single encoded argument keeps
    # the command literal across CMD, PowerShell, and MSYS Bash.
    powershell = (windows_system_directory() / 'WindowsPowerShell/v1.0/powershell.exe').as_posix()
    if not re.fullmatch(r'[A-Za-z]:/[A-Za-z0-9_/.-]+', powershell):
        raise ValueError('cannot quote the Windows system PowerShell path')
    literals = ("'" + arg.replace("'", "''") + "'" for arg in arguments)
    script = '& ' + ' '.join(literals) + WINDOWS_EXIT
    encoded = b64encode(script.encode('utf-16-le')).decode('ascii')
    return powershell + WINDOWS_SWITCHES + encoded


def command_words(command: str) -> list[str]:
    shell, separator, encoded = command.partition(WINDOWS_SWITCHES)
    if not separator or not shell.lower().endswith('/powershell.exe'):
        return shlex.split(command)
    try:
        script = b64decode(encoded, validate=True).decode('utf-16-le')
    except (InvalidEncoding, UnicodeError):
        return []
    if not script.startswith('& ') or not script.endswith(WINDOWS_EXIT):
        return []
    literals = script[2:-len(WINDOWS_EXIT)]
    matches = list(WINDOWS_LITERAL.finditer(literals))
    if ' '.join(match[0] for match in matches) != literals:
        return []
    return [match[1].replace("''", "'") for match in matches]


def _context_for_publication(result: dict[str, Any]) -> str | None:
    if result.get("ok") is True and result.get("state") == "legacy":
        command = command_line([
            sys.executable, "-I", str(CORE_PATH), "adopt",
            "--plan", result["path"], "--token", result["token"],
        ])
        return LEGACY_INSTRUCTION + command
    return None


def handle_event(
    payload: dict[str, Any], *, root: Path, harness: str, executable: Path, observed_ns: int,
) -> str | None:
    if os.getenv("CLAUDE_INVOKED_BY") or os.getenv("CODEX_INVOKED_BY"):
        return None
    if payload.get("permission_mode") in ("plan", "read-only", "readOnly"):
        return None
    if payload.get("agent_id") or payload.get("agent_type"):
        return None

    invocation = _execute_invocation(payload, harness)
    lifecycle = _lifecycle(payload, harness)
    if invocation is None and lifecycle is None:
        return None
    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return None

    declared_pid = None
    if harness == "claude":
        native_pid = os.getenv("CLAUDE_PID", "")
        if not CLAUDE_PID.fullmatch(native_pid):
            return None
        declared_pid = int(native_pid)
    core = _load_core()
    agent_pid, birth = core.verify_execute_process(harness, executable=executable, declared_pid=declared_pid)
    binding = dict(agent_pid=agent_pid, expected_birth=birth, session_id=session_id, observed_ns=observed_ns)
    if lifecycle is not None:
        core.clear_execute_plan(**binding, startup=lifecycle)
        return None

    argument, invocation_id = invocation
    try:
        result = core.publish_execute_plan(root, argument, **binding, invocation_id=invocation_id)
    except core.InvalidCheckpointBlock:
        return INVALID_BLOCK
    return _context_for_publication(result)


def main(argv: list[str]) -> None:
    observed_ns = time.monotonic_ns()
    try:
        parser = HookParser(add_help=False, allow_abbrev=False)
        parser.add_argument("--root", required=True, type=Path)
        parser.add_argument("--harness", required=True, choices=("claude", "codex"))
        parser.add_argument("--executable", required=True, type=Path)
        args = parser.parse_args(argv)
        if not args.root.is_absolute() or not args.executable.is_absolute():
            return

        raw = sys.stdin.buffer.read(MAX_PAYLOAD + 1)
        if len(raw) > MAX_PAYLOAD:
            return
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            return
        message = handle_event(payload, observed_ns=observed_ns, **vars(args))
        if message:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": payload["hook_event_name"],
                "additionalContext": message}}))
    except Exception:
        # An unavailable companion must never interrupt the harness workflow.
        return


if __name__ == "__main__":
    main(sys.argv[1:])

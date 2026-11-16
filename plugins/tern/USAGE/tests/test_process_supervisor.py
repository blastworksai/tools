"""Synthetic provider supervision tests; Windows APIs are faked off Windows."""
from __future__ import annotations

import asyncio
import base64
from contextlib import contextmanager
import io
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch

import provider_metadata as core
from usage_service import process_supervisor as supervisor
from usage_service import profiles
from usage_service.process_supervisor import Result
from usage_service.protocol import ServiceError


class FakeStream:
    def __init__(self, *chunks):
        self.chunks = list(chunks)

    async def read(self, _size):
        await asyncio.sleep(0)
        return self.chunks.pop(0) if self.chunks else b""


class FakeStdin:
    def __init__(self):
        self.data = bytearray()
        self.closed = False

    def write(self, value):
        self.data.extend(value)

    async def drain(self):
        await asyncio.sleep(0)

    def close(self):
        self.closed = True


class FakeProcess:
    def __init__(self, *, status=0, running=False, stdout=(b"",), stderr=(b"",)):
        self.pid = 43120
        self.returncode = None if running else status
        self.stdout = FakeStream(*stdout)
        self.stderr = FakeStream(*stderr)
        self.stdin = FakeStdin()
        self.finished = asyncio.Event()
        if not running:
            self.finished.set()
        self.killed = False
        self.pipes_closed = False
        self._transport = SimpleNamespace(close=self.close_transport)

    def close_transport(self):
        def closed():
            self.stdin.close()
            self.pipes_closed = True
        asyncio.get_running_loop().call_soon(closed)

    async def wait(self):
        await self.finished.wait()
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = -9
        self.finished.set()


class ExecuteTests(unittest.TestCase):
    def execute(self, process, *, timeout=1, input=None, max_output=supervisor.MAX_BYTES):
        launches = []
        groups = []

        async def launch(*argv, **kwargs):
            launches.append((argv, kwargs))
            return process

        def killpg(pid, sig):
            groups.append((pid, sig))
            process.kill()

        with patch.object(supervisor.asyncio, "create_subprocess_exec", new=launch), \
             patch.object(supervisor.os, "killpg", new=killpg):
            result = asyncio.run(supervisor._execute_async(
                ["/provider", "usage", "--json"], {"PATH": "/usr/bin"}, "/home/source",
                timeout, input, posix_group=True, max_output=max_output))
        return result, launches, groups

    def test_success_captures_bounded_streams_and_owns_the_process_group(self):
        process = FakeProcess(stdout=(b'{"ok":', b"true}"), stderr=(b"diagnostic",))
        result, launches, groups = self.execute(process, input=b"request")
        self.assertEqual(result, Result(0, b'{"ok":true}', b"diagnostic"))
        self.assertEqual(process.stdin.data, b"request")
        self.assertTrue(process.stdin.closed)
        argv, kwargs = launches[0]
        self.assertEqual(argv, ("/provider", "usage", "--json"))
        self.assertEqual(kwargs["env"], {"PATH": "/usr/bin"})
        self.assertEqual(kwargs["cwd"], "/home/source")
        self.assertTrue(kwargs["start_new_session"])
        self.assertNotIn("shell", kwargs)
        self.assertEqual(groups, [(process.pid, signal.SIGKILL)])

    def test_nonzero_status_retains_output_and_fixed_error(self):
        result, _, _ = self.execute(FakeProcess(status=7, stdout=(b"private response",)))
        self.assertEqual(result.status, 7)
        self.assertEqual(result.stdout, b"private response")
        self.assertEqual(result.error, supervisor.UNAVAILABLE)

    def test_timeout_kills_only_the_owned_group(self):
        process = FakeProcess(running=True, stdout=(b"partial",))
        result, _, groups = self.execute(process, timeout=0.01)
        self.assertEqual(result, Result(None, b"partial", b"", supervisor.TIMEOUT))
        self.assertEqual(groups, [(process.pid, signal.SIGKILL)])

    def test_output_overflow_is_bounded_and_unavailable(self):
        process = FakeProcess(running=True, stdout=(b"12345",))
        result, _, groups = self.execute(process, max_output=4)
        self.assertEqual(result, Result(None, b"1234", b"", supervisor.UNAVAILABLE))
        self.assertEqual(groups, [(process.pid, signal.SIGKILL)])

    def test_launch_failure_never_exposes_os_error_text(self):
        async def launch(*args, **kwargs):
            raise OSError("sensitive provider path")

        with patch.object(supervisor.asyncio, "create_subprocess_exec", new=launch):
            result = asyncio.run(supervisor._execute_async(
                ["/provider"], {}, None, 1, None, posix_group=True))
        self.assertEqual(result, Result(None, error=supervisor.UNAVAILABLE))
        self.assertNotIn("sensitive", repr(result))


class DiscoveryTests(unittest.TestCase):
    def test_minimal_mac_path_finds_homebrew_and_intel_locations(self):
        for executable in ("/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
            with self.subTest(executable=executable):
                found = supervisor.resolve_executable(
                    "claude", {"PATH": "/usr/bin:/bin", "HOME": "/Users/source"},
                    os_name="posix", is_file=lambda path: path == executable)
                self.assertEqual(found, executable)

    def test_explicit_path_order_wins_over_fallbacks(self):
        files = {"/selected/bin/claude", "/opt/homebrew/bin/claude"}
        found = supervisor.resolve_executable(
            "claude", {"PATH": "/selected/bin", "HOME": "/Users/source"},
            os_name="posix", is_file=files.__contains__)
        self.assertEqual(found, "/selected/bin/claude")

    def test_relative_executable_is_absolute_against_supplied_cwd(self):
        found = supervisor.resolve_executable(
            "vendor/bin/claude", {"PATH": "/usr/bin"}, "/work/source",
            os_name="posix", is_file=lambda path: path == "/work/source/vendor/bin/claude")
        self.assertEqual(found, "/work/source/vendor/bin/claude")

    def test_windows_npm_directory_comes_from_the_selected_user(self):
        expected = r"C:\Users\selected\AppData\Roaming\npm\codex.cmd"
        found = supervisor.resolve_executable(
            "codex", {"PATH": r"C:\Windows\System32", "APPDATA": r"C:\Users\selected\AppData\Roaming"},
            os_name="nt", is_file=lambda path: path == expected)
        self.assertEqual(found, expected)
        derived = supervisor.resolve_executable(
            "codex", {"PATH": r"C:\Windows\System32", "USERPROFILE": r"C:\Users\selected"},
            os_name="nt", is_file=lambda path: path == expected)
        self.assertEqual(derived, expected)

    def test_windows_prefers_native_executables_over_batch_adapters(self):
        native = r"C:\vendor\claude.exe"
        batch = r"C:\Users\selected\AppData\Roaming\npm\claude.cmd"
        files = {native, batch}
        found = supervisor.resolve_executable(
            "claude", {"PATH": r"C:\vendor", "APPDATA": r"C:\Users\selected\AppData\Roaming"},
            os_name="nt", is_file=files.__contains__)
        self.assertEqual(found, native)

    def test_cmd_and_bat_discovery_select_the_explicit_call_adapter(self):
        env = {"PATH": r"C:\Windows\System32", "SystemRoot": r"C:\Windows",
               "APPDATA": r"C:\Users\selected\AppData\Roaming"}
        for suffix in (".cmd", ".bat"):
            with self.subTest(suffix=suffix):
                batch = r"C:\Users\selected\AppData\Roaming\npm\claude" + suffix
                found = supervisor.resolve_executable(
                    "claude", env, os_name="nt", is_file=lambda path: path == batch)
                self.assertEqual(found, batch)
                argv = supervisor._batch_argv([found, "auth", "status", "--json"], env, "nt")
                self.assertEqual(argv, [r"C:\Windows\System32\cmd.exe", "/d", "/s", "/c",
                                        "call", batch, "auth", "status", "--json"])

    def test_cmd_active_batch_paths_and_arguments_fail_closed(self):
        env = {"SystemRoot": r"C:\Windows"}
        safe = r"C:\npm\claude.cmd"
        forbidden = list('%&^<>|!"()') + [chr(value) for value in (*range(32), *range(127, 160))]
        for character in forbidden:
            with self.subTest(character=character):
                with self.assertRaises(ValueError):
                    supervisor._batch_argv([r"C:\npm\cla" + character + "ude.cmd", "--json"], env, "nt")
                with self.assertRaises(ValueError):
                    supervisor._batch_argv([safe, "--value=" + character], env, "nt")

    def test_batch_paths_with_spaces_keep_quotes_after_fixed_call_token(self):
        env = {"SystemRoot": r"C:\Windows",
               "APPDATA": r"C:\Users\Selected User\AppData\Roaming"}
        for suffix in (".cmd", ".bat"):
            with self.subTest(suffix=suffix):
                batch = env["APPDATA"] + r"\npm\claude" + suffix
                found = supervisor.resolve_executable(
                    "claude", env, os_name="nt", is_file=lambda path: path == batch)
                arguments = ["--profile-path", "D:\\Profiles\\Account 配置\\"]
                argv = supervisor._batch_argv([found, *arguments], env, "nt")
                self.assertEqual(argv[4:], ["call", batch, *arguments])
                # Check Python's actual Windows serialization, not a POSIX shell.
                command = supervisor.subprocess.list2cmdline(argv)
                self.assertEqual(command, r'C:\Windows\System32\cmd.exe /d /s /c call "' +
                                 batch + '" --profile-path "D:\\Profiles\\Account 配置\\\\' + '"')

    def test_batch_trailing_backslashes_remain_structured_for_native_forwarding(self):
        env = {"SystemRoot": r"C:\Windows"}
        batch = r"C:\Provider Tools\cli.cmd"
        for trailing in (1, 2):
            with self.subTest(trailing=trailing):
                value = "D:\\Selected Profile" + "\\" * trailing
                argv = supervisor._batch_argv([batch, value], env, "nt")
                self.assertEqual(argv[-1], value)
                # CRT escaping doubles trailing backslashes before a closing quote.
                # This is not proof of an arbitrary batch shim's %1/%* behavior.
                serialized = supervisor.subprocess.list2cmdline(argv)
                self.assertTrue(serialized.endswith(
                    '"D:\\Selected Profile' + "\\" * (2 * trailing) + '"'))

    def test_empty_arguments_remain_rejected_before_batch_adaptation(self):
        with self.assertRaises(ValueError):
            supervisor._validated([r"C:\Provider Tools\cli.cmd", ""], {}, None, 1, None)

    def test_native_executable_arguments_are_not_subject_to_batch_restrictions(self):
        argv = [r"C:\Provider Tools\cli.exe", "D:\\Profiles\\Account % & ^ 配置\\"]
        self.assertIs(supervisor._batch_argv(argv, {}, "nt"), argv)

    def test_missing_and_drive_relative_executables_fail_closed(self):
        with self.assertRaises(FileNotFoundError):
            supervisor.resolve_executable("missing", {"PATH": "/usr/bin"}, os_name="posix", is_file=lambda path: False)
        with self.assertRaises(ValueError):
            supervisor.resolve_executable("C:vendor\\claude", {"PATH": "C:\\Windows"}, os_name="nt")


class WindowsBoundaryTests(unittest.TestCase):
    def request(self, **overrides):
        value = {
            "argv": ["claude", "auth", "status", "--json"],
            "env": {"PATH": r"C:\Windows\System32", "SystemRoot": r"C:\Windows"},
            "cwd": r"C:\Users\selected",
            "timeout": 15,
            "input": base64.b64encode(b"request").decode("ascii"),
        }
        value.update(overrides)
        return json.dumps(value).encode("ascii")

    def run_worker(self, request, job, completed):
        calls = []
        job.assign_current_process.side_effect = lambda: calls.append("job")

        async def execute(*args, **kwargs):
            calls.append("provider")
            kwargs["finish_worker"](completed)
            return completed

        stdin = SimpleNamespace(buffer=io.BytesIO(request))
        stdout = SimpleNamespace(buffer=io.BytesIO())
        with patch.object(supervisor, "_WindowsJob", return_value=job), \
             patch.object(supervisor, "resolve_executable", return_value=r"C:\npm\claude.cmd"), \
             patch.object(supervisor, "_execute_async", new=execute), \
             patch.object(supervisor.sys, "stdin", stdin), \
             patch.object(supervisor.sys, "stdout", stdout):
            status = supervisor._windows_worker()
        self.assertEqual(status, 0)
        return calls, supervisor._decode_worker_envelope(stdout.buffer.getvalue())

    def test_worker_assigns_kill_on_close_job_before_provider_execution(self):
        calls, result = self.run_worker(self.request(), Mock(), Result(0, b"output", b"error"))
        self.assertEqual(calls, ["job", "provider"])
        self.assertEqual(result, Result(0, b"output", b"error"))

    def test_job_setup_failure_prevents_provider_launch(self):
        job = Mock()
        job.assign_current_process.side_effect = OSError("private native error")
        execute = AsyncMock(return_value=Result(0))
        stdin = SimpleNamespace(buffer=io.BytesIO(self.request()))
        stdout = SimpleNamespace(buffer=io.BytesIO())
        with patch.object(supervisor, "_WindowsJob", return_value=job), \
             patch.object(supervisor, "_execute_async", new=execute), \
             patch.object(supervisor.sys, "stdin", stdin), \
             patch.object(supervisor.sys, "stdout", stdout):
            supervisor._windows_worker()
        execute.assert_not_awaited()
        self.assertEqual(supervisor._decode_worker_envelope(stdout.buffer.getvalue()).error, supervisor.UNAVAILABLE)

    def test_refused_batch_input_never_reaches_provider_execution(self):
        safe = r"C:\Provider Tools\cli.cmd"
        cases = [(safe, value) for value in ("", 'private"value', "private&value",
                                            "private%value", "private\nvalue", "private\x85value")]
        cases.append((r"C:\Private&Tools\cli.cmd", "--json"))
        for executable, argument in cases:
            with self.subTest(executable=executable, argument=argument):
                execute = AsyncMock(side_effect=AssertionError("refused provider launched"))
                stdin = SimpleNamespace(buffer=io.BytesIO(
                    self.request(argv=[executable, argument])))
                stdout = SimpleNamespace(buffer=io.BytesIO())
                with patch.object(supervisor, "_WindowsJob", return_value=Mock()), \
                     patch.object(supervisor, "resolve_executable", return_value=executable), \
                     patch.object(supervisor, "_execute_async", new=execute), \
                     patch.object(supervisor.sys, "stdin", stdin), \
                     patch.object(supervisor.sys, "stdout", stdout):
                    supervisor._windows_worker()
                execute.assert_not_called()
                self.assertEqual(supervisor._decode_worker_envelope(stdout.buffer.getvalue()),
                                 Result(None, error=supervisor.UNAVAILABLE))

    def test_windows_parent_uses_fixed_helper_and_decodes_only_its_envelope(self):
        expected = Result(0, b"provider stdout", b"provider stderr")
        completed = Result(0, supervisor._worker_envelope(expected))
        execute = AsyncMock(return_value=completed)
        with patch.object(supervisor, "_execute_async", new=execute):
            result = asyncio.run(supervisor._run_windows_async(
                ["claude", "auth", "status", "--json"], {"PATH": "C:\\Windows"}, None, 15, b"request"))
        self.assertEqual(result, expected)
        args, kwargs = execute.await_args
        self.assertEqual(args[0][1:4], ["-I", "-B", os.path.abspath(supervisor.__file__)])
        self.assertEqual(args[0][4], "--windows-worker")
        self.assertEqual(args[3], 15)
        self.assertFalse(kwargs["posix_group"])
        request = json.loads(args[4])
        self.assertEqual(request["argv"], ["claude", "auth", "status", "--json"])
        self.assertEqual(base64.b64decode(request["input"]), b"request")

    def test_windows_parent_preserves_timeout_category(self):
        with patch.object(supervisor, "_execute_async", new=AsyncMock(return_value=Result(None, error=supervisor.TIMEOUT))):
            result = asyncio.run(supervisor._run_windows_async(["claude"], {}, None, 1, None))
        self.assertEqual(result, Result(None, error=supervisor.TIMEOUT))

    def test_job_sets_kill_on_close_and_retains_the_handle(self):
        kernel = Mock()
        kernel.CreateJobObjectW.return_value = 123
        kernel.SetInformationJobObject.return_value = 1
        kernel.AssignProcessToJobObject.return_value = 1
        kernel.GetCurrentProcess.return_value = 456
        with patch("ctypes.WinDLL", return_value=kernel, create=True):
            job = supervisor._WindowsJob()
            job.assign_current_process()
        self.assertEqual(job.handle, 123)
        self.assertEqual(kernel.SetInformationJobObject.call_args.args[0:2], (123, 9))
        information = kernel.SetInformationJobObject.call_args.args[2]._obj
        self.assertEqual(information.BasicLimitInformation.LimitFlags, 0x2000)
        kernel.AssignProcessToJobObject.assert_called_once_with(123, 456)
        kernel.CloseHandle.assert_not_called()
        job.terminate()
        kernel.TerminateJobObject.assert_called_once_with(123, 0)

    def test_failed_job_assignment_closes_only_the_unassigned_handle(self):
        kernel = Mock()
        kernel.CreateJobObjectW.return_value = 123
        kernel.SetInformationJobObject.return_value = 1
        kernel.AssignProcessToJobObject.return_value = 0
        with patch("ctypes.WinDLL", return_value=kernel, create=True), self.assertRaises(OSError):
            supervisor._WindowsJob().assign_current_process()
        kernel.CloseHandle.assert_called_once_with(123)


class MemoryStream(io.BytesIO):
    def close(self):
        if not self.closed:
            self.saved = self.getvalue()
        super().close()

    def contents(self):
        return self.saved if self.closed else self.getvalue()


class Read1OnlyStream(io.BytesIO):
    def read(self, *args):
        raise AssertionError("provider pumps must use read1 for incremental output")


class BlockingStream:
    def __init__(self, raw=b""):
        import threading
        self.raw = io.BytesIO(raw)
        self.closed = threading.Event()

    def read(self, size=-1):
        chunk = self.raw.read(size)
        if chunk:
            return chunk
        self.closed.wait()
        return b""

    def close(self):
        self.closed.set()


class FakeInteractiveProcess:
    def __init__(self, stdout, *, status=0):
        self.pid = 43121
        self.stdin = MemoryStream()
        self.stdout = stdout
        self.returncode = status
        self.killed = False

    def poll(self):
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = -9
        self.stdout.close()

    def wait(self, timeout=None):
        return self.returncode


@contextmanager
def interactive_fixture(process, *, timeout=1, initial=None):
    groups = []

    def killpg(pid, sig):
        groups.append((pid, sig))
        process.kill()

    with patch.object(supervisor.subprocess, "Popen", return_value=process) as popen, \
         patch.object(supervisor.os, "killpg", new=killpg):
        session = supervisor.interactive_bounded(
            ["codex", "app-server", "--stdio"], {"PATH": "/usr/bin"}, "/home/source", timeout, initial)
        try:
            yield session, popen, groups
        finally:
            session.close()


def frames(raw):
    stream = io.BytesIO(raw)
    result = []
    while frame := supervisor._read_frame(stream):
        result.append(frame)
    return result


class InteractiveSessionTests(unittest.TestCase):
    def test_incremental_output_reassembles_token_and_json_lines(self):
        output = supervisor._frame(supervisor._STDOUT, b'{"jsonrpc":"2.0",') + \
            supervisor._frame(supervisor._STDOUT, b'"id":1}\n') + \
            supervisor._frame(supervisor._STDOUT, b"http://127.0.0.1:42/#token=own-child\n") + \
            supervisor._frame(supervisor._EXIT, b'{"status":0,"error":null}')
        process = FakeInteractiveProcess(io.BytesIO(output))
        with interactive_fixture(process) as (session, popen, _):
            self.assertEqual(session.readline(), b'{"jsonrpc":"2.0","id":1}\n')
            self.assertEqual(session.readline(), b"http://127.0.0.1:42/#token=own-child\n")
            self.assertEqual(session.readline(), b"")
            result = session.close()
        self.assertEqual(result.status, 0)
        self.assertEqual(result.stdout, b'{"jsonrpc":"2.0","id":1}\nhttp://127.0.0.1:42/#token=own-child\n')
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertFalse(popen.call_args.kwargs["shell"])

    def test_sequential_writes_follow_their_observed_responses(self):
        output = b"".join((
            supervisor._frame(supervisor._STDOUT, b"initialize-response\n"),
            supervisor._frame(supervisor._STDOUT, b"account-response\n"),
            supervisor._frame(supervisor._STDOUT, b"quota-response\n"),
        ))
        process = FakeInteractiveProcess(BlockingStream(output), status=None)
        with interactive_fixture(process, initial=b"initialize\n") as (session, _, _):
            self.assertEqual(session.readline(), b"initialize-response\n")
            session.write(b"initialized\n")
            session.write(b"account/read\n")
            self.assertEqual(session.readline(), b"account-response\n")
            session.write(b"quota/read\n")
            self.assertEqual(session.readline(), b"quota-response\n")
            session.close_stdin()
            session.close()
        sent = frames(process.stdin.contents())
        self.assertEqual(sent[0][0], supervisor._CONFIG)
        self.assertEqual([payload for kind, payload in sent[1:] if kind == supervisor._INPUT],
                         [b"initialize\n", b"initialized\n", b"account/read\n", b"quota/read\n"])
        self.assertEqual(sent[-1], (supervisor._CLOSE_STDIN, b""))

    def test_read_timeout_cancels_the_owned_process_group(self):
        process = FakeInteractiveProcess(BlockingStream(), status=None)
        with interactive_fixture(process, timeout=0.02) as (session, _, groups):
            with self.assertRaises(supervisor.BoundedError) as raised:
                session.readline()
            self.assertEqual(raised.exception.code, supervisor.TIMEOUT)
            result = session.close()
        self.assertEqual(result.error, supervisor.TIMEOUT)
        self.assertIn((process.pid, signal.SIGKILL), groups)

    def test_explicit_cancellation_is_contained_and_not_a_false_provider_error(self):
        process = FakeInteractiveProcess(BlockingStream(), status=None)
        with interactive_fixture(process, timeout=30) as (session, _, groups):
            result = session.close()
        self.assertEqual(result, Result(None))
        self.assertEqual(groups, [(process.pid, signal.SIGKILL)])

    def test_line_and_input_bounds_fail_closed(self):
        output = supervisor._frame(supervisor._STDOUT, b"12345") + \
            supervisor._frame(supervisor._EXIT, b'{"status":0,"error":null}')
        process = FakeInteractiveProcess(io.BytesIO(output))
        with interactive_fixture(process) as (session, _, _):
            with self.assertRaises(supervisor.BoundedError) as raised:
                session.readline(limit=4)
            self.assertEqual(raised.exception.code, supervisor.UNAVAILABLE)
            self.assertEqual(session.close().error, supervisor.UNAVAILABLE)

        process = FakeInteractiveProcess(BlockingStream(), status=None)
        with interactive_fixture(process) as (session, _, _):
            with self.assertRaises(supervisor.BoundedError) as raised:
                session.write(b"x" * (supervisor.MAX_BYTES + 1))
            self.assertEqual(raised.exception.code, supervisor.UNAVAILABLE)

    def test_windows_worker_assigns_job_before_provider_and_frames_output(self):
        calls = []
        job = Mock()
        job.assign_current_process.side_effect = lambda: calls.append("job")
        provider = FakeInteractiveProcess(Read1OnlyStream(b"first\nsecond\n"))
        provider.stderr = Read1OnlyStream(b"diagnostic")

        def launch(*args, **kwargs):
            calls.append("provider")
            return provider

        request = json.dumps({"argv": ["claude", "auth", "status", "--json"],
                              "env": {"PATH": r"C:\Windows", "SystemRoot": r"C:\Windows"},
                              "cwd": r"C:\Users\selected", "timeout": 15,
                              "deadline": time.monotonic() + 15}).encode("ascii")
        stdin = SimpleNamespace(buffer=io.BytesIO(supervisor._frame(supervisor._CONFIG, request)))
        stdout = SimpleNamespace(buffer=io.BytesIO())
        with patch.object(supervisor, "_WindowsJob", return_value=job), \
             patch.object(supervisor, "resolve_executable", return_value=r"C:\npm\claude.exe"), \
             patch.object(supervisor.subprocess, "Popen", side_effect=launch) as popen, \
             patch.object(supervisor.os, "name", "nt"), \
             patch.object(supervisor.sys, "stdin", stdin), \
             patch.object(supervisor.sys, "stdout", stdout):
            self.assertEqual(supervisor._interactive_worker(), 0)
        self.assertEqual(calls, ["job", "provider"])
        self.assertFalse(popen.call_args.kwargs["start_new_session"])
        self.assertFalse(popen.call_args.kwargs["shell"])
        sent = frames(stdout.buffer.getvalue())
        self.assertEqual(b"".join(payload for kind, payload in sent if kind == supervisor._STDOUT),
                         b"first\nsecond\n")
        self.assertEqual(b"".join(payload for kind, payload in sent if kind == supervisor._STDERR),
                         b"diagnostic")
        self.assertEqual(sent[-1][0], supervisor._EXIT)
        self.assertEqual(json.loads(sent[-1][1]), {"status": 0, "error": None})

    def test_worker_timeout_is_visible_to_the_interactive_consumer(self):
        output = supervisor._frame(supervisor._EXIT, b'{"status":null,"error":"source_timeout"}')
        process = FakeInteractiveProcess(io.BytesIO(output))
        with interactive_fixture(process) as (session, _, _):
            with self.assertRaises(supervisor.BoundedError) as caught:
                session.readline()
            self.assertEqual(caught.exception.code, supervisor.TIMEOUT)

    def test_windows_control_eof_terminates_job_even_after_stdin_close(self):
        job = Mock()
        provider = FakeInteractiveProcess(Read1OnlyStream(b""))
        provider.stderr = Read1OnlyStream(b"")
        cancelled = supervisor.threading.Event()
        job.terminate.side_effect = cancelled.set

        def wait_for_cancellation(timeout=None):
            self.assertTrue(cancelled.wait(1))
            return 0

        provider.wait = wait_for_cancellation
        request = json.dumps({"argv": ["provider"], "env": {}, "cwd": None,
                              "timeout": 15, "deadline": time.monotonic() + 15}).encode()
        control = supervisor._frame(supervisor._CONFIG, request) + supervisor._frame(supervisor._CLOSE_STDIN)
        stdin = SimpleNamespace(buffer=io.BytesIO(control))
        stdout = SimpleNamespace(buffer=io.BytesIO())
        with patch.object(supervisor, "_WindowsJob", return_value=job), \
             patch.object(supervisor, "resolve_executable", return_value=r"C:\provider.exe"), \
             patch.object(supervisor.subprocess, "Popen", return_value=provider), \
             patch.object(supervisor.os, "name", "nt"), \
             patch.object(supervisor.sys, "stdin", stdin), \
             patch.object(supervisor.sys, "stdout", stdout):
            supervisor._interactive_worker()
        self.assertTrue(provider.stdin.closed)
        self.assertGreaterEqual(job.terminate.call_count, 2)  # EOF and final cleanup


class PublicAndCallerTests(unittest.IsolatedAsyncioTestCase):
    async def test_metadata_wrapper_projects_stdout_and_sanitizes_failures(self):
        env = {"HOME": "/home/source", "PATH": "/usr/bin"}
        with patch.object(core, "run_bounded", return_value=Result(0, b"{}", b"PRIVATE_STDERR")):
            self.assertEqual(core.bounded_process(["claude"], env), b"{}")
        for category in (supervisor.TIMEOUT, supervisor.UNAVAILABLE):
            with self.subTest(category=category), \
                 patch.object(core, "run_bounded", return_value=Result(
                     None, b"PRIVATE_STDOUT", b"PRIVATE_STDERR", category)):
                with self.assertRaises(core.SafeError) as raised:
                    core.bounded_process(["claude"], env)
            self.assertNotIn("PRIVATE_", str(raised.exception))
            self.assertNotIn(env["HOME"], str(raised.exception))

    async def test_profiles_project_helper_error_without_source_identity(self):
        owner = {"source_uid": "1001", "source_user": "source"}
        response = json.dumps({"version": 1, **owner, "error": "local_login_unavailable"}).encode()
        store = SimpleNamespace(settings=lambda: {"metadata_enabled": True})
        spec = {"provider": "openai", "kind": "codex", "selectors": {}, "source_uid": "1001"}
        with patch.object(profiles, "_target", return_value=(owner, None)), \
             patch.object(profiles, "run_bounded_async", new=AsyncMock(return_value=Result(0, response))):
            result = await profiles.acquire_usage(store, spec)
        self.assertEqual(result, {"version": 1, "error": "local_login_unavailable"})
        self.assertIn("usage_service/process_supervisor.py", profiles.BUNDLE)

    async def test_profiles_preserve_timeout_service_category(self):
        owner = {"source_uid": "1001", "source_user": "source"}
        store = SimpleNamespace(settings=lambda: {"metadata_enabled": True})
        spec = {"provider": "openai", "kind": "codex", "selectors": {}, "source_uid": "1001"}
        with patch.object(profiles, "_target", return_value=(owner, None)), \
             patch.object(profiles, "run_bounded_async", new=AsyncMock(return_value=Result(None, error=supervisor.TIMEOUT))):
            with self.assertRaises(ServiceError) as raised:
                await profiles.acquire_usage(store, spec)
        self.assertEqual((raised.exception.code, raised.exception.status), (supervisor.TIMEOUT, 503))


class DeadlineCleanupTests(unittest.IsolatedAsyncioTestCase):
    async def test_exited_parent_cleanup_closes_pipes_without_waiting_for_external_eof(self):
        class NeverEOFStream:
            async def read(self, _size):
                await asyncio.Event().wait()

        # Model an escaped writer: killing the owned group cannot deliver EOF.
        # The direct parent's wait() already returns 0.
        process = FakeProcess()
        process.stdout = NeverEOFStream()
        process.stderr = NeverEOFStream()
        with patch.object(supervisor.asyncio, "create_subprocess_exec",
                          new=AsyncMock(return_value=process)), \
             patch.object(supervisor.os, "killpg"):
            result = await asyncio.wait_for(supervisor._execute_async(
                ["provider"], {}, None, .01, None, posix_group=True), 1)
        self.assertEqual(result.error, supervisor.TIMEOUT)
        self.assertTrue(process.pipes_closed)
        self.assertTrue(process.stdin.closed)

    async def test_windows_job_termination_precedes_inherited_pipe_wait(self):
        # A direct child exited, but its grandchild still owns both pipe handles.
        events = []
        descendants_stopped = asyncio.Event()

        class HeldStream:
            async def read(self, _size):
                await descendants_stopped.wait()
                return b""

        class HeldProcess(FakeProcess):
            async def wait(self):
                events.append("wait")
                await descendants_stopped.wait()
                return self.returncode

        process = HeldProcess()
        process.stdout = process.stderr = HeldStream()

        def finish(result):
            events.append("terminate-job")
            self.assertEqual(result.error, supervisor.TIMEOUT)
            descendants_stopped.set()

        with patch.object(supervisor.asyncio, "create_subprocess_exec",
                          new=AsyncMock(return_value=process)):
            result = await asyncio.wait_for(supervisor._execute_async(
                ["provider"], {}, None, .01, None, posix_group=False, finish_worker=finish), 1)
        self.assertEqual(result.error, supervisor.TIMEOUT)
        self.assertEqual(events[-2:], ["terminate-job", "wait"])


@unittest.skipUnless(sys.platform == "linux", "Linux harmless process-tree smoke")
class RealProcessSmokeTests(unittest.TestCase):
    """Real Python children only; no provider executable, network, or credentials."""

    @staticmethod
    def alive(pid):
        try:
            # Zombies have no live descendants/handles and cannot execute work.
            state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
            return state not in {"Z", "X"}
        except FileNotFoundError:
            return False

    def assert_stopped(self, pid):
        deadline = time.monotonic() + 3
        while self.alive(pid) and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertFalse(self.alive(pid), f"owned fixture process {pid} survived")

    @staticmethod
    def provider(exit_parent=False):
        return ("import subprocess,sys,time\n"
                "child=subprocess.Popen([sys.executable,'-I','-B','-c','import time; time.sleep(60)'])\n"
                "print(child.pid,flush=True)\n" +
                ("" if exit_parent else "time.sleep(60)\n"))

    def test_idle_session_deadline_kills_inherited_pipe_grandchild(self):
        with tempfile.TemporaryDirectory() as home:
            env = {"HOME": home, "PATH": os.defpath}
            with supervisor.interactive_bounded(
                    [sys.executable, "-I", "-B", "-c", self.provider(True)], env, home, 2) as session:
                descendant = int(session.readline())
                # No client read enforces this timeout: the worker must enforce it.
                session._process.wait(timeout=5)
                self.assert_stopped(descendant)
                with self.assertRaises(supervisor.BoundedError) as caught:
                    session.readline()
                self.assertEqual(caught.exception.code, supervisor.TIMEOUT)

    def test_transport_eof_kills_provider_and_grandchild(self):
        with tempfile.TemporaryDirectory() as home:
            env = {"HOME": home, "PATH": os.defpath}
            with supervisor.interactive_bounded(
                    [sys.executable, "-I", "-B", "-c", self.provider()], env, home, 30) as session:
                descendant = int(session.readline())
                session.close_stdin()
                session._process.stdin.close()  # Consumer disappeared after closing provider stdin.
                session._process.wait(timeout=5)
                self.assert_stopped(descendant)

    def test_noninteractive_timeout_kills_inherited_pipe_grandchild(self):
        with tempfile.TemporaryDirectory() as home:
            processes = []
            create = asyncio.create_subprocess_exec

            async def capture(*args, **kwargs):
                process = await create(*args, **kwargs)
                processes.append(process)
                return process

            async def run():
                with patch.object(supervisor.asyncio, "create_subprocess_exec", new=capture):
                    result = await supervisor.run_bounded_async(
                        [sys.executable, "-I", "-B", "-c", self.provider(True)],
                        {"HOME": home, "PATH": os.defpath}, home, 2)
                # Inspect the actual transport while its loop is still alive,
                # not warning output or a later garbage-collection side effect.
                process, = processes
                self.assertTrue(process._transport.is_closing())
                for descriptor in (1, 2):
                    pipe = process._transport.get_pipe_transport(descriptor)
                    self.assertTrue(pipe.is_closing())
                    self.assertTrue(pipe.get_extra_info("pipe").closed)
                return result

            result = asyncio.run(run())
            self.assertEqual(result.error, supervisor.TIMEOUT)
            self.assert_stopped(int(result.stdout))


if __name__ == "__main__":
    unittest.main()

"""Bounded provider execution with descendant containment and fixed error codes."""
from __future__ import annotations

import asyncio
import base64
import binascii
from dataclasses import dataclass
import json
import math
import ntpath
import os
import posixpath
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
from typing import Literal

MAX_BYTES = 1024 * 1024
TIMEOUT = "source_timeout"
UNAVAILABLE = "source_usage_unavailable"
ErrorCategory = Literal["source_timeout", "source_usage_unavailable"]


@dataclass(frozen=True)
class Result:
    status: int | None
    stdout: bytes = b""
    stderr: bytes = b""
    error: ErrorCategory | None = None


class _OutputOverflow(Exception):
    pass


def _search_directories(env, os_name):
    path = ntpath if os_name == "nt" else posixpath
    separator = ";" if os_name == "nt" else ":"
    home = env.get("HOME") or env.get("USERPROFILE")
    directories = []
    for value in env.get("PATH", os.defpath).split(separator):
        if value and path.isabs(value):
            directories.append(value)
    if os_name == "nt":
        appdata = env.get("APPDATA")
        if not appdata and home:
            appdata = path.join(home, "AppData", "Roaming")
        if appdata:
            directories.append(path.join(appdata, "npm"))
    else:
        if home:
            directories.extend((path.join(home, ".local", "bin"), path.join(home, ".bun", "bin")))
        directories.extend(("/opt/homebrew/bin", "/usr/local/bin"))
    result = []
    seen = set()
    for directory in directories:
        normalized = path.normpath(directory)
        key = path.normcase(normalized)
        if key not in seen:
            seen.add(key)
            result.append(normalized)
    return result


def resolve_executable(command, env, cwd=None, *, os_name=None, is_file=None):
    """Resolve a provider name without relying on a GUI's interactive shell PATH."""
    os_name = os.name if os_name is None else os_name
    if os_name not in {"posix", "nt"} or not isinstance(command, str) or not command or "\x00" in command:
        raise ValueError("Invalid provider executable")
    path = ntpath if os_name == "nt" else posixpath
    directories = _search_directories(env, os_name)
    has_directory = bool(path.dirname(command)) or bool(path.splitdrive(command)[0])
    if path.isabs(command):
        bases = [path.normpath(command)]
    elif has_directory:
        if os_name == "nt" and path.splitdrive(command)[0]:
            raise ValueError("Drive-relative provider executable")
        base_cwd = os.fspath(cwd) if cwd is not None else env.get("HOME") or env.get("USERPROFILE")
        if not base_cwd or not path.isabs(base_cwd):
            raise ValueError("Relative provider executable requires an absolute cwd")
        bases = [path.normpath(path.join(base_cwd, command))]
    else:
        bases = [path.join(directory, command) for directory in directories]

    if os_name != "nt" and not has_directory and is_file is None:
        separator = ":"
        found = shutil.which(command, path=separator.join(directories))
        if found and path.isabs(found):
            return path.normpath(found)

    predicate = is_file
    if predicate is None:
        predicate = lambda value: path.isfile(value) and (os_name == "nt" or os.access(value, os.X_OK))
    extension = path.splitext(command)[1].lower()
    if os_name != "nt" or extension:
        native = [(base, False) for base in bases]
        batch = []
    else:
        native = [(base + suffix, False) for base in bases for suffix in (".exe", "")]
        batch = [(base + suffix, True) for base in bases for suffix in (".cmd", ".bat")]
    if extension in {".cmd", ".bat"}:
        native, batch = [], [(base, True) for base in bases]
    for candidate, _ in (*native, *batch):
        if path.isabs(candidate) and predicate(candidate):
            return path.normpath(candidate)
    raise FileNotFoundError("Provider executable is unavailable")


def _batch_argv(argv, env, os_name):
    """Adapt restricted batch input, not an arbitrary shim's argument grammar.

    Nonempty arguments without the characters below may contain spaces, Unicode
    and trailing backslashes. Python's CRT serialization suits intact %*
    forwarding to a native argv parser; a shim rebuilding %1/%~1 can change it.
    Exact shim fidelity still needs native qualification (see README).
    """
    if os_name != "nt" or ntpath.splitext(argv[0])[1].lower() not in {".cmd", ".bat"}:
        return argv
    if any(character in '%&^<>|!"()' or ord(character) < 32 or 127 <= ord(character) <= 159
           for value in argv for character in value):
        raise ValueError("Windows batch command context is unsupported")
    comspec = env.get("ComSpec") or env.get("COMSPEC")
    if not comspec:
        root = env.get("SystemRoot") or env.get("SYSTEMROOT") or env.get("WINDIR")
        if root:
            comspec = ntpath.join(root, "System32", "cmd.exe")
    if not comspec or not ntpath.isabs(comspec):
        raise ValueError("Windows batch interpreter is unavailable")
    # /s strips an opening command-string quote. CALL keeps the command string
    # starting with a fixed word, preserving a quoted batch path containing spaces.
    # Reject expansion/control syntax before CALL's second parse; this does not
    # establish the called shim's forwarding semantics.
    return [comspec, "/d", "/s", "/c", "call", *argv]


def _validated(argv, env, cwd, timeout, input):
    if not isinstance(argv, (list, tuple)) or not argv:
        raise ValueError("Invalid provider argv")
    args = list(argv)
    if any(not isinstance(value, str) or not value or "\x00" in value for value in args):
        raise ValueError("Invalid provider argv")
    context = dict(env)
    if any(not isinstance(key, str) or not isinstance(value, str) or "\x00" in key or "\x00" in value
           for key, value in context.items()):
        raise ValueError("Invalid provider environment")
    directory = None if cwd is None else os.fspath(cwd)
    if directory is not None and (not directory or "\x00" in directory):
        raise ValueError("Invalid provider cwd")
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("Invalid provider timeout")
    if input is not None and not isinstance(input, bytes):
        raise ValueError("Invalid provider input")
    if input is not None and len(input) > MAX_BYTES:
        raise ValueError("Provider input is too large")
    return args, context, directory, float(timeout), input


async def _stop_async(process, posix_group):
    if posix_group:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    elif process.returncode is None:
        try:
            process.kill()
        except ProcessLookupError:
            pass
    # asyncio.Process has no public close operation. Keep this runtime transport
    # access here: close our pipe ends, never drain to EOF after the deadline.
    # An escaped writer may retain its ends even after the owned group is killed.
    process._transport.close()
    await process.wait()
    # wait() returns immediately for an already-exited direct child. Let the
    # pipe-close callbacks queued above run before the caller closes its loop;
    # this is a scheduling turn, not a timed grace or a wait for external EOF.
    await asyncio.sleep(0)


def stop_owned_process(process, grace=0):
    """Compatibility cleanup for the previous synchronous child boundary."""
    if grace and process.poll() is None:
        if os.name == "posix":
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        else:
            process.terminate()
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            pass
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    elif process.poll() is None:
        process.kill()
    process.wait()


async def _execute_async(argv, env, cwd, timeout, input, *, posix_group, max_output=MAX_BYTES,
                         finish_worker=None):
    process = None
    tasks = []
    exchange = None
    output = {"stdout": bytearray(), "stderr": bytearray()}
    result = Result(None, error=UNAVAILABLE)
    deadline = time.monotonic() + timeout
    try:
        process = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.PIPE if input is not None else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
            cwd=cwd,
            start_new_session=posix_group,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )

        async def read(stream, name):
            while chunk := await stream.read(8192):
                remaining = max_output - len(output[name])
                if len(chunk) > remaining:
                    output[name].extend(chunk[:remaining])
                    raise _OutputOverflow
                output[name].extend(chunk)

        async def feed():
            try:
                process.stdin.write(input)
                await process.stdin.drain()
                process.stdin.close()
            except (BrokenPipeError, ConnectionResetError):
                pass

        tasks = [asyncio.ensure_future(process.wait()),
                 asyncio.create_task(read(process.stdout, "stdout")),
                 asyncio.create_task(read(process.stderr, "stderr"))]
        if input is not None:
            tasks.append(asyncio.create_task(feed()))
        exchange = asyncio.gather(*tasks)
        await asyncio.wait_for(exchange, timeout=max(0, deadline - time.monotonic()))
        status = process.returncode
        result = Result(status, bytes(output["stdout"]), bytes(output["stderr"]),
                        None if status == 0 else UNAVAILABLE)
        return result
    except TimeoutError:
        result = Result(None, bytes(output["stdout"]), bytes(output["stderr"]), TIMEOUT)
        return result
    except Exception:
        result = Result(None, bytes(output["stdout"]), bytes(output["stderr"]), UNAVAILABLE)
        return result
    finally:
        if exchange is not None and not exchange.done():
            exchange.cancel()
        for task in tasks:
            if not task.done():
                task.cancel()
        if finish_worker is not None:
            # The Windows worker reports first, then terminates its entire Job,
            # including itself. Never wait for pipes retained by grandchildren.
            finish_worker(result)
        # Settle cancelled readers before giving their streams to cleanup.
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if process is not None:
            try:
                await _stop_async(process, posix_group)
            except (OSError, ProcessLookupError, subprocess.SubprocessError):
                pass


_FRAME = struct.Struct(">cI")
_CONFIG = b"F"
_INPUT = b"I"
_CLOSE_STDIN = b"C"
_STDOUT = b"O"
_STDERR = b"E"
_EXIT = b"R"
_FRAME_LIMIT = 4 * MAX_BYTES + 65536


class BoundedError(Exception):
    """Fixed interactive failure suitable for the existing Unavailable boundary."""

    def __init__(self, code: ErrorCategory):
        self.code = code
        super().__init__(code)


def _frame(kind, payload=b""):
    return _FRAME.pack(kind, len(payload)) + payload


def _read_exact(stream, size):
    result = bytearray()
    while len(result) < size:
        chunk = stream.read(size - len(result))
        if not chunk:
            raise EOFError
        result.extend(chunk)
    return bytes(result)


def _read_frame(stream):
    header = stream.read(_FRAME.size)
    if not header:
        return None
    if len(header) != _FRAME.size:
        raise EOFError
    kind, size = _FRAME.unpack(header)
    if size > _FRAME_LIMIT:
        raise ValueError("Interactive frame is too large")
    return kind, _read_exact(stream, size)


class BoundedSession:
    """Synchronous request/response session with one deadline and bounded streams."""

    def __init__(self, argv, env, cwd, timeout, input):
        self._deadline = time.monotonic() + timeout
        self._condition = threading.Condition()
        self._write_lock = threading.Lock()
        self._control_lock = threading.Lock()
        self._pending = bytearray()
        self._stdout = bytearray()
        self._stderr = bytearray()
        self._input_size = 0
        self._stdin_closed = False
        self._closed = False
        self._close_result = None
        self._failure = None
        self._remote_done = False
        self._remote_status = None
        self._remote_error = None
        self._process = None
        self._reader = None
        helper = [os.path.abspath(sys.executable), "-I", "-B", os.path.abspath(__file__), "--interactive-worker"]
        try:
            self._process = subprocess.Popen(
                helper,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                env=env,
                cwd=cwd,
                shell=False,
                start_new_session=os.name == "posix",
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            self._reader = threading.Thread(target=self._read_worker, daemon=True)
            self._reader.start()
            config = json.dumps({"argv": argv, "env": env, "cwd": cwd, "timeout": timeout,
                                 "deadline": self._deadline},
                                ensure_ascii=True, separators=(",", ":")).encode("ascii")
            self._send(_CONFIG, config)
            if input is not None:
                self.write(input)
        except BoundedError:
            self.close()
            raise
        except Exception:
            self.close()
            raise BoundedError(UNAVAILABLE) from None

    def __enter__(self):
        return self

    def __exit__(self, _kind, _value, _traceback):
        self.close()
        return False

    def _remaining(self):
        return self._deadline - time.monotonic()

    def _stop_transport(self):
        process = self._process
        if process is None:
            return
        if os.name == "posix":
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        elif process.poll() is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass

    def _fail(self, code):
        with self._condition:
            if self._failure is None:
                self._failure = code
            self._condition.notify_all()
        self._stop_transport()

    def _send(self, kind, payload):
        remaining = self._remaining()
        if remaining <= 0:
            self._fail(TIMEOUT)
            raise BoundedError(TIMEOUT)
        finished = threading.Event()
        failures = []

        def send():
            try:
                with self._write_lock:
                    self._process.stdin.write(_frame(kind, payload))
                    self._process.stdin.flush()
            except Exception as exc:
                failures.append(exc)
            finally:
                finished.set()

        threading.Thread(target=send, daemon=True).start()
        if not finished.wait(remaining):
            self._fail(TIMEOUT)
            raise BoundedError(TIMEOUT)
        if failures:
            self._fail(UNAVAILABLE)
            raise BoundedError(UNAVAILABLE)

    def _read_worker(self):
        try:
            while True:
                frame = _read_frame(self._process.stdout)
                if frame is None:
                    with self._condition:
                        self._remote_done = True
                        failed = not self._closed and self._remote_status is None and self._remote_error is None
                        self._condition.notify_all()
                    if failed:
                        self._fail(UNAVAILABLE)
                    return
                kind, payload = frame
                if kind in (_STDOUT, _STDERR):
                    target = self._stdout if kind == _STDOUT else self._stderr
                    with self._condition:
                        overflow = len(target) + len(payload) > MAX_BYTES
                        if not overflow:
                            target.extend(payload)
                            if kind == _STDOUT:
                                self._pending.extend(payload)
                            self._condition.notify_all()
                    if overflow:
                        self._fail(UNAVAILABLE)
                        return
                elif kind == _EXIT:
                    value = json.loads(payload)
                    status = value["status"]
                    error = value["error"]
                    if ((status is not None and type(status) is not int)
                            or error not in (None, TIMEOUT, UNAVAILABLE) or set(value) != {"status", "error"}):
                        raise ValueError
                    with self._condition:
                        self._remote_status = status
                        self._remote_error = error
                        self._remote_done = True
                        self._condition.notify_all()
                else:
                    raise ValueError
        except Exception:
            with self._condition:
                self._remote_done = True
                failed = not self._closed
                self._condition.notify_all()
            if failed:
                self._fail(UNAVAILABLE)

    def readline(self, limit=65536):
        """Return the next stdout line including its newline; b'' means provider EOF."""
        if type(limit) is not int or not 0 < limit <= MAX_BYTES:
            raise ValueError("Invalid interactive line limit")
        with self._condition:
            while True:
                if self._failure is not None:
                    raise BoundedError(self._failure)
                newline = self._pending.find(b"\n")
                if newline >= 0 and newline + 1 <= limit:
                    line = bytes(self._pending[:newline + 1])
                    del self._pending[:newline + 1]
                    return line
                if newline >= 0 or len(self._pending) > limit:
                    code = UNAVAILABLE
                    self._fail(code)
                    raise BoundedError(code)
                if self._remote_done:
                    if self._remote_error is not None:
                        raise BoundedError(self._remote_error)
                    if self._pending:
                        line = bytes(self._pending)
                        self._pending.clear()
                        return line
                    return b""
                remaining = self._remaining()
                if remaining <= 0:
                    self._fail(TIMEOUT)
                    raise BoundedError(TIMEOUT)
                self._condition.wait(remaining)

    def write(self, data):
        """Write provider stdin only after any required response has been observed."""
        if not isinstance(data, bytes):
            raise ValueError("Interactive input must be bytes")
        with self._control_lock:
            with self._condition:
                if self._closed or self._stdin_closed or self._remote_done:
                    code = UNAVAILABLE
                    self._fail(code)
                    raise BoundedError(code)
                if self._failure is not None:
                    raise BoundedError(self._failure)
                if self._input_size + len(data) > MAX_BYTES:
                    code = UNAVAILABLE
                    self._fail(code)
                    raise BoundedError(code)
            self._send(_INPUT, data)
            self._input_size += len(data)

    def close_stdin(self):
        """Close provider stdin without ending stdout reads or process containment."""
        with self._control_lock:
            if self._stdin_closed:
                return
            self._send(_CLOSE_STDIN, b"")
            self._stdin_closed = True

    def close(self):
        """Cancel any remaining work and return all bounded output and the final status."""
        with self._condition:
            if self._close_result is not None:
                return self._close_result
            self._closed = True
            self._condition.notify_all()
        process = self._process
        if process is not None:
            self._stop_transport()
            try:
                process.stdin.close()
            except (OSError, ValueError):
                pass
            try:
                process.wait()
            except (OSError, subprocess.SubprocessError):
                pass
            try:
                process.stdout.close()
            except (OSError, ValueError):
                pass
        if self._reader is not None:
            self._reader.join(timeout=1)
        with self._condition:
            error = self._failure or self._remote_error
            if error is None and self._remote_status not in (None, 0):
                error = UNAVAILABLE
            self._close_result = Result(self._remote_status, bytes(self._stdout), bytes(self._stderr), error)
            return self._close_result


def interactive_bounded(argv, env, cwd, timeout, input=None):
    """Open a bounded interactive provider session; use as a context manager."""
    try:
        argv, env, cwd, timeout, input = _validated(argv, env, cwd, timeout, input)
    except (TypeError, ValueError) as exc:
        raise BoundedError(UNAVAILABLE) from None
    return BoundedSession(argv, env, cwd, timeout, input)


def _send_worker(stream, lock, kind, payload=b""):
    with lock:
        stream.write(_frame(kind, payload))
        stream.flush()


def _interactive_worker():
    process = None
    job = None
    output = sys.stdout.buffer
    write_lock = threading.Lock()
    failure = []
    status = None
    error = UNAVAILABLE

    def terminate_tree():
        # The fixed worker is its own POSIX session leader, or owns its Job.
        # Terminating this boundary also ends the worker, even if stdin is ignored.
        if job is not None:
            job.terminate()
        elif os.name == "posix":
            os.killpg(os.getpid(), signal.SIGKILL)

    try:
        frame = _read_frame(sys.stdin.buffer)
        if frame is None or frame[0] != _CONFIG:
            raise ValueError
        request = json.loads(frame[1])
        if not isinstance(request, dict) or set(request) != {"argv", "env", "cwd", "timeout", "deadline"}:
            raise ValueError
        argv, env, cwd, timeout, _ = _validated(request["argv"], request["env"], request["cwd"], request["timeout"], None)
        deadline = request["deadline"]
        if type(deadline) not in (int, float) or not math.isfinite(deadline):
            raise ValueError
        deadline = min(deadline, time.monotonic() + timeout)
        if os.name == "nt":
            job = _WindowsJob()
            job.assign_current_process()
        if deadline <= time.monotonic():
            raise subprocess.TimeoutExpired("provider", timeout)
        executable = resolve_executable(argv[0], env, cwd)
        provider_argv = _batch_argv([executable, *argv[1:]], env, os.name)
        process = subprocess.Popen(
            provider_argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd=cwd,
            shell=False,
            start_new_session=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )

        def pump(stream, kind):
            total = 0
            try:
                while chunk := stream.read1(8192):
                    total += len(chunk)
                    if total > MAX_BYTES:
                        failure.append(UNAVAILABLE)
                        process.kill()
                        return
                    _send_worker(output, write_lock, kind, chunk)
            except OSError:
                return

        def control():
            total = 0
            try:
                while True:
                    frame = _read_frame(sys.stdin.buffer)
                    if frame is None:
                        terminate_tree()
                        return
                    kind, payload = frame
                    if kind == _INPUT:
                        total += len(payload)
                        if total > MAX_BYTES:
                            terminate_tree()
                            return
                        process.stdin.write(payload)
                        process.stdin.flush()
                    elif kind == _CLOSE_STDIN:
                        process.stdin.close()
                        # Continue monitoring the transport: later EOF is cancellation.
                    else:
                        raise ValueError
            except (OSError, ValueError, EOFError):
                terminate_tree()

        threads = [threading.Thread(target=pump, args=(process.stdout, _STDOUT), daemon=True),
                   threading.Thread(target=pump, args=(process.stderr, _STDERR), daemon=True),
                   threading.Thread(target=control, daemon=True)]
        for thread in threads:
            thread.start()
        status = process.wait(timeout=max(0, deadline - time.monotonic()))
        for thread in threads[:2]:
            thread.join(timeout=max(0, deadline - time.monotonic()))
            if thread.is_alive():
                raise subprocess.TimeoutExpired("provider", timeout)
        error = failure[0] if failure else (None if status == 0 else UNAVAILABLE)
    except subprocess.TimeoutExpired:
        status, error = None, TIMEOUT
    except Exception:
        status, error = None, UNAVAILABLE
    finally:
        try:
            _send_worker(output, write_lock, _EXIT, json.dumps(
                {"status": status, "error": error}, separators=(",", ":")).encode("ascii"))
        except (OSError, ValueError):
            pass
        finally:
            terminate_tree()
    return 0


def _worker_envelope(result):
    return json.dumps({
        "status": result.status,
        "stdout": base64.b64encode(result.stdout).decode("ascii"),
        "stderr": base64.b64encode(result.stderr).decode("ascii"),
        "error": result.error,
    }, ensure_ascii=True, separators=(",", ":")).encode("ascii")


def _decode_worker_envelope(raw):
    try:
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != {"status", "stdout", "stderr", "error"}:
            raise ValueError
        status = value["status"]
        if (status is not None and type(status) is not int) or value["error"] not in (None, TIMEOUT, UNAVAILABLE):
            raise ValueError
        stdout = base64.b64decode(value["stdout"], validate=True)
        stderr = base64.b64decode(value["stderr"], validate=True)
        if len(stdout) > MAX_BYTES or len(stderr) > MAX_BYTES:
            raise ValueError
        return Result(status, stdout, stderr, value["error"])
    except (ValueError, TypeError, UnicodeError, binascii.Error, json.JSONDecodeError):
        return Result(None, error=UNAVAILABLE)


class _WindowsJob:
    def __init__(self):
        self.handle = None
        self.kernel = None

    def assign_current_process(self):
        import ctypes
        from ctypes import wintypes

        class BasicLimit(ctypes.Structure):
            _fields_ = [
                ("PerProcessUserTimeLimit", ctypes.c_longlong),
                ("PerJobUserTimeLimit", ctypes.c_longlong),
                ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t),
                ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD),
            ]

        class IOCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_ulonglong) for name in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class ExtendedLimit(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", BasicLimit),
                ("IoInfo", IOCounters),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t),
            ]

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPWSTR]
        kernel.CreateJobObjectW.restype = wintypes.HANDLE
        kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        kernel.SetInformationJobObject.restype = wintypes.BOOL
        kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        kernel.AssignProcessToJobObject.restype = wintypes.BOOL
        kernel.GetCurrentProcess.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        kernel.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        kernel.TerminateJobObject.restype = wintypes.BOOL
        handle = kernel.CreateJobObjectW(None, None)
        if not handle:
            raise OSError("Windows job creation failed")
        try:
            information = ExtendedLimit()
            information.BasicLimitInformation.LimitFlags = 0x00002000
            if not kernel.SetInformationJobObject(handle, 9, ctypes.byref(information), ctypes.sizeof(information)):
                raise OSError("Windows job configuration failed")
            if not kernel.AssignProcessToJobObject(handle, kernel.GetCurrentProcess()):
                raise OSError("Windows job assignment failed")
        except Exception:
            kernel.CloseHandle(handle)
            raise
        # The handle stays open until this worker exits; closing it kills remaining descendants.
        self.handle = handle
        self.kernel = kernel

    def terminate(self):
        """End this worker and all descendants after its result has been flushed."""
        if self.handle is not None:
            if not self.kernel.TerminateJobObject(self.handle, 0):
                # Closing our sole handle retains kill-on-close on API failure.
                self.kernel.CloseHandle(self.handle)


async def _run_windows_async(argv, env, cwd, timeout, input):
    request = json.dumps({
        "argv": argv,
        "env": env,
        "cwd": cwd,
        "timeout": timeout,
        "input": None if input is None else base64.b64encode(input).decode("ascii"),
    }, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    helper = [os.path.abspath(sys.executable), "-I", "-B", os.path.abspath(__file__), "--windows-worker"]
    completed = await _execute_async(helper, env, cwd, timeout, request,
                                     posix_group=False, max_output=4 * MAX_BYTES + 65536)
    if completed.error is not None:
        return Result(None, error=completed.error)
    return _decode_worker_envelope(completed.stdout)


async def run_bounded_async(argv, env, cwd, timeout, input=None) -> Result:
    """Async form of the same provider boundary for the refresh event loop."""
    try:
        argv, env, cwd, timeout, input = _validated(argv, env, cwd, timeout, input)
        if os.name == "nt":
            return await _run_windows_async(argv, env, cwd, timeout, input)
        executable = resolve_executable(argv[0], env, cwd)
        return await _execute_async([executable, *argv[1:]], env, cwd, timeout, input, posix_group=True)
    except (OSError, TypeError, ValueError):
        return Result(None, error=UNAVAILABLE)


def run_bounded(argv, env, cwd, timeout, input=None) -> Result:
    """Run one fixed provider command and return bounded bytes and a fixed error category."""
    return asyncio.run(run_bounded_async(argv, env, cwd, timeout, input))


def _windows_worker():
    job = None

    def finish(result):
        try:
            sys.stdout.buffer.write(_worker_envelope(result))
            sys.stdout.buffer.flush()
        finally:
            if job is not None:
                job.terminate()

    try:
        raw = sys.stdin.buffer.read(4 * MAX_BYTES + 65537)
        if len(raw) > 4 * MAX_BYTES + 65536:
            raise ValueError
        request = json.loads(raw)
        if not isinstance(request, dict) or set(request) != {"argv", "env", "cwd", "timeout", "input"}:
            raise ValueError
        encoded = request["input"]
        provider_input = None if encoded is None else base64.b64decode(encoded, validate=True)
        argv, env, cwd, timeout, provider_input = _validated(
            request["argv"], request["env"], request["cwd"], request["timeout"], provider_input)
        job = _WindowsJob()
        job.assign_current_process()
        executable = resolve_executable(argv[0], env, cwd)
        provider_argv = _batch_argv([executable, *argv[1:]], env, "nt")
        asyncio.run(_execute_async(provider_argv, env, cwd, timeout, provider_input,
                                   posix_group=False, finish_worker=finish))
    except Exception:
        finish(Result(None, error=UNAVAILABLE))
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--windows-worker"]:
        raise SystemExit(_windows_worker())
    if sys.argv[1:] == ["--interactive-worker"]:
        raise SystemExit(_interactive_worker())

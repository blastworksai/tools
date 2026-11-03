#!/usr/bin/env python3
"""USAGE's provider-read helper: one usage-only read as the current OS user.

Python 3.11 required. The companion supplies approved non-secret selectors over
stdin; only normalized account fields, quota windows, the source UID/SID and
fixed error codes leave. The provider's own CLI may renew its login while it
reports quota; this helper never logs in, runs a shell or takes a model turn.
"""
import sys
sys.dont_write_bytecode = True
if sys.version_info < (3, 11):
    print('{"version":1,"error":"Source metadata requires Python 3.11 or newer"}')
    raise SystemExit(0)

import json
import math
import os
from pathlib import Path

# Isolated subprocess execution does not put the script directory on sys.path.
# Only this fixed installed bundle supplies the sibling adapters.
if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
import re
import shutil
import signal
import stat
import subprocess
import threading
import urllib.request

MAX_BYTES = 1024 * 1024
MAX_REQUEST = 65536
ENDPOINTS = frozenset({"https://www.googleapis.com/oauth2/v2/userinfo"})
COMMANDS = frozenset({
    ("claude", "auth", "status", "--json"),
    ("muse", "usage", "--json"),
})
KINDS = frozenset({"kimi", "claude", "codex", "agy", "muse", "grok"})
PROVIDERS = frozenset({"kimi", "claude", "codex", "openai", "antigravity", "muse", "grok"})
FIELDS = frozenset({"principal", "principal_kind", "label", "plan", "organization",
                    "organization_id", "workspace", "workspace_id", "tenant", "tenant_id"})
SECRET_KEY = re.compile(r"token|secret|password|api[_-]?key|authorization|credential|^(access|refresh|key)$", re.I)
# These are non-secret provider profile selectors, not arbitrary environment input.
PROFILE_SELECTORS = {
    "kimi": frozenset({"KIMI_CODE_HOME", "TZ"}),
    "claude": frozenset({"CLAUDE_CONFIG_DIR", "TZ"}),
    "codex": frozenset({"CODEX_HOME", "TZ"}),
    "agy": frozenset({"TZ"}),
    "muse": frozenset({"XDG_CONFIG_HOME", "TZ"}),
    "grok": frozenset({"TZ"}),
}


class SafeError(Exception):
    """Only fixed, nonsensitive diagnostics may be constructed here."""


def stop_owned_process(process, grace=0):
    """Reap only a process/session created by this helper, including its children."""
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


def bounded_process(argv, env, *, input_bytes=None, timeout=15):
    """Read at most MAX_BYTES, discard stderr, and kill on timeout/overflow."""
    process = None
    result = bytearray()
    overflow = threading.Event()
    try:
        process = subprocess.Popen(argv, stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, shell=False,
                                   start_new_session=os.name == "posix", cwd=env.get("HOME"),
                                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        def drain():
            try:
                while True:
                    chunk = process.stdout.read(8192)
                    if not chunk:
                        break
                    if len(result) + len(chunk) > MAX_BYTES:
                        overflow.set()
                        process.kill()
                        break
                    result.extend(chunk)
            except OSError:
                overflow.set()
        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        if input_bytes is not None:
            def feed():
                try:
                    process.stdin.write(input_bytes)
                    process.stdin.close()
                except OSError:
                    overflow.set()
            threading.Thread(target=feed, daemon=True).start()
        process.wait(timeout=timeout)
        reader.join(timeout=1)
        if process.returncode != 0 or overflow.is_set() or reader.is_alive():
            raise SafeError("Source provider command is unavailable")
        return bytes(result)
    except (OSError, subprocess.SubprocessError):
        raise SafeError("Source provider command is unavailable") from None
    finally:
        if process is not None:
            stop_owned_process(process)
            if process.stdout is not None:
                process.stdout.close()
            if process.stdin is not None and not process.stdin.closed:
                process.stdin.close()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SafeError("Source account endpoint redirected")


class SourceIO:
    safe_error_type = SafeError

    def __init__(self, home, env):
        self.home = Path(home).resolve()
        self.env = dict(env)
        self.roots = [self.home]
        # Only verified profile selectors can add a root.
        for key in ("KIMI_CODE_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME"):
            value = env.get(key)
            if value and Path(value).is_absolute():
                self.roots.append(Path(value).resolve())
        # Profile locations are private too, including when a provider echoes
        # one inside an otherwise allowlisted display field.
        self.secrets = {str(root) for root in self.roots}
        self._remember(env)
        # Identity corroboration and quota projection share one provider reading.
        # This state exists only for this request and never leaves the source.
        self._muse_usage_snapshot = {}

    def _remember(self, value, sensitive=False):
        if isinstance(value, dict):
            for key, item in value.items():
                # Google's credential cache stores the decoded account address as
                # id_token_email; it is metadata, not the id_token credential.
                self._remember(item, key != "id_token_email" and bool(SECRET_KEY.search(str(key))))
        elif isinstance(value, list):
            for item in value:
                self._remember(item, sensitive)
        elif sensitive and isinstance(value, str) and value:
            self.secrets.add(value)

    def _read(self, path):
        path = Path(path).resolve()
        if not any(path.is_relative_to(root) for root in self.roots):
            raise SafeError("Source profile path is outside the approved context")
        descriptor = None
        try:
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_BYTES:
                raise SafeError("Source profile file is unsupported")
            if hasattr(os, "geteuid") and info.st_uid != os.geteuid():
                raise SafeError("Source profile file belongs to another user")
            if os.name == "nt" and windows_sid(path) != windows_sid():
                raise SafeError("Source profile file belongs to another user")
            with os.fdopen(descriptor, "rb") as stream:
                descriptor = None
                data = stream.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                raise SafeError("Source profile file is too large")
            return data
        except FileNotFoundError:
            # Adapters distinguish a missing optional config from unreadable data.
            raise FileNotFoundError("Source profile file is unavailable") from None
        except OSError:
            raise SafeError("Source profile file is unavailable") from None
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def read_json(self, path):
        try:
            value = json.loads(self._read(path))
        except (ValueError, UnicodeError):
            raise SafeError("Source profile JSON is invalid") from None
        self._remember(value)
        return value

    def request_json(self, url, headers=None):
        if url not in ENDPOINTS:
            raise SafeError("Source account endpoint is not approved")
        headers = headers or {}
        if (not isinstance(headers, dict) or set(headers) - {"Authorization", "Accept"}
                or any(not isinstance(value, str) or len(value) > 32776 or "\r" in value or "\n" in value
                       for value in headers.values())):
            raise SafeError("Source account request is invalid")
        self._remember(headers)
        authorization = headers.get("Authorization", "")
        if authorization.startswith("Bearer "):
            self.secrets.add(authorization[7:])
        try:
            # Explicit empty proxy handler ignores all ambient proxy variables.
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
            request = urllib.request.Request(url, headers=headers, method="GET")
            with opener.open(request, timeout=10) as response:
                if response.status != 200:
                    raise SafeError("Source account request failed")
                body = response.read(MAX_BYTES + 1)
            if len(body) > MAX_BYTES:
                raise SafeError("Source account response is too large")
            value = json.loads(body)
            self._remember(value)
            return value
        except Exception:
            raise SafeError("Source account request failed") from None

    def run_json(self, argv, env=None):
        if not isinstance(argv, (list, tuple)) or tuple(argv) not in COMMANDS:
            raise SafeError("Source provider command is not approved")
        if env is not None and env != self.env:
            raise SafeError("Source provider command context is not approved")
        snapshot = self._muse_usage_snapshot if tuple(argv) == ("muse", "usage", "--json") else None
        if snapshot is not None:
            if "error" in snapshot:
                raise SafeError(snapshot["error"]) from None
            if "result" in snapshot:
                return snapshot["result"]
        executable = shutil.which(argv[0], path=self.env.get("PATH", os.defpath))
        if not executable:
            raise SafeError("Source provider CLI is unavailable")
        execution_env = self.env
        if snapshot is not None:
            # Muse's launcher otherwise checks/downloads updates before
            # dispatching even its read-only usage command.
            execution_env = {**self.env, "MUSE_NO_AUTO_UPDATE": "1"}
        # Claude auth status is read-only: never call login or token refresh.
        try:
            value = json.loads(bounded_process([executable, *argv[1:]], execution_env))
            self._remember(value)
        except Exception as exc:
            message = str(exc) if isinstance(exc, SafeError) else "Source provider CLI response is invalid"
            if snapshot is not None:
                snapshot["error"] = message
            raise SafeError(message) from None
        if snapshot is not None:
            snapshot["result"] = value
        return value




def current_home():
    if os.name == "posix":
        import pwd
        entry = pwd.getpwuid(os.geteuid())
        if entry.pw_uid == 0:
            raise SafeError("Source metadata requires a non-root user context")
        return Path(entry.pw_dir)
    if os.name == "nt":
        import ctypes
        profile = ctypes.create_unicode_buffer(32768)
        # CSIDL_PROFILE, current user's token, current profile location.
        if ctypes.windll.shell32.SHGetFolderPathW(None, 0x28, None, 0, profile) != 0:
            raise SafeError("Source operating-system user profile is unavailable")
        home = Path(profile.value)
        if not home.is_absolute():
            raise SafeError("Source operating-system user profile is unavailable")
        return home
    raise SafeError("Source operating-system user context is unsupported")


def windows_sid(path=None):
    """Current token SID, or file owner SID; never infer identity from HOME."""
    import ctypes
    from ctypes import wintypes
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(wintypes.LPWSTR)]
    advapi.ConvertSidToStringSidW.restype = wintypes.BOOL
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    descriptor, token = ctypes.c_void_p(), wintypes.HANDLE()
    output = wintypes.LPWSTR()
    try:
        if path is not None:
            owner = ctypes.c_void_p()
            advapi.GetNamedSecurityInfoW.argtypes = [
                wintypes.LPWSTR, ctypes.c_int, wintypes.DWORD,
                ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p, ctypes.c_void_p,
                ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
            if advapi.GetNamedSecurityInfoW(str(path), 1, 1, ctypes.byref(owner),
                                          None, None, None, ctypes.byref(descriptor)) != 0:
                raise SafeError("Source profile ownership is unavailable")
            sid = owner
        else:
            kernel.GetCurrentProcess.restype = wintypes.HANDLE
            advapi.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
            advapi.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                                   wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            if not advapi.OpenProcessToken(kernel.GetCurrentProcess(), 8, ctypes.byref(token)):
                raise SafeError("Source operating-system identity is unavailable")
            size = wintypes.DWORD()
            advapi.GetTokenInformation(token, 1, None, 0, ctypes.byref(size))
            if not 0 < size.value <= 65536:
                raise SafeError("Source operating-system identity is unavailable")
            buffer = ctypes.create_string_buffer(size.value)
            if not advapi.GetTokenInformation(token, 1, buffer, size, ctypes.byref(size)):
                raise SafeError("Source operating-system identity is unavailable")
            sid = ctypes.cast(buffer, ctypes.POINTER(ctypes.c_void_p))[0]
        if not advapi.ConvertSidToStringSidW(sid, ctypes.byref(output)):
            raise SafeError("Source operating-system identity is unavailable")
        return output.value
    finally:
        if output:
            kernel.LocalFree(ctypes.cast(output, ctypes.c_void_p))
        if descriptor:
            kernel.LocalFree(descriptor)
        if token:
            kernel.CloseHandle(token)


def source_identity():
    if os.name == "posix":
        import pwd
        entry = pwd.getpwuid(os.geteuid())
        if entry.pw_uid == 0:
            raise SafeError("Source metadata requires a non-root user context")
        return {"source_uid": str(entry.pw_uid), "source_user": entry.pw_name}
    if os.name == "nt":
        return {"source_uid": windows_sid()}
    raise SafeError("Source operating-system user context is unsupported")


def validate_selectors(kind, selectors):
    if kind not in PROFILE_SELECTORS or not isinstance(selectors, dict) or set(selectors) - PROFILE_SELECTORS[kind]:
        raise SafeError("Source profile selectors are unsupported")
    for key, value in selectors.items():
        if not isinstance(value, str) or not value or len(value) > 4096 or not value.isprintable():
            raise SafeError("Source profile selector is invalid")
        if key == "TZ":
            if not re.fullmatch(r"[A-Za-z0-9_+./-]{1,128}", value) or ".." in value:
                raise SafeError("Source profile selector is invalid")
        elif not Path(value).is_absolute():
            raise SafeError("Source profile selector is invalid")
    return dict(selectors)


def profile_environment(kind, home, selectors):
    """Explicit setup context; process discovery cannot override this selection."""
    selectors = validate_selectors(kind, selectors)
    env = {key: os.environ[key] for key in (
        "PATH", "SystemRoot", "SYSTEMROOT", "WINDIR", "LANG", "LC_ALL", "TZ",
    ) if key in os.environ}
    # Provider CLIs may be installed per user, including mapped Unix users.
    env["PATH"] = os.pathsep.join([str(home / ".local/bin"), str(home / ".bun/bin"),
                                  env.get("PATH", os.defpath)])
    env["HOME"] = str(home)
    if os.name == "nt":
        env["USERPROFILE"] = str(home)
        env["APPDATA"] = str(home / "AppData/Roaming")
        env["LOCALAPPDATA"] = str(home / "AppData/Local")
    env.update(selectors)
    for key, value in selectors.items():
        if key != "TZ":
            path = Path(value).resolve(strict=True)
            if not path.is_dir():
                raise SafeError("Source profile directory is unavailable")
            if os.name == "posix" and path.stat().st_uid != os.geteuid():
                raise SafeError("Source profile directory belongs to another user")
            if os.name == "nt" and windows_sid(path) != windows_sid():
                raise SafeError("Source profile directory belongs to another user")
            env[key] = str(path)
    return env


def project_usage(usage, secrets):
    """Project account-free, normalized quota windows for every supported provider."""
    if not isinstance(usage, dict) or usage.get("provider") not in PROVIDERS:
        raise SafeError("Source usage is unsupported")
    windows = usage.get("windows")
    if not isinstance(windows, list) or len(windows) > 64:
        raise SafeError("Source usage windows are invalid")
    def number(value, maximum):
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= maximum:
            raise SafeError("Source usage values are invalid")
        return value
    reasons = {"server_sent_no_usage", "unavailable", "not_reported", "unparsed",
               "vendor_usage_unavailable", "local_login_unavailable", "source_timeout",
               "source_usage_unavailable", "source_metadata_disabled"}
    result = {"provider": usage["provider"], "windows": [],
              "observed_at_ms": number(usage.get("observed_at_ms"), 253370764800000)}
    if "credit_balance" in usage:
        result["credit_balance"] = number(usage["credit_balance"], 9_007_199_254_740_991)
    seen = set()
    for window in windows:
        if not isinstance(window, dict):
            raise SafeError("Source usage window is invalid")
        pair = (window.get("key"), window.get("pool"))
        if any(not isinstance(v, str) or not v or len(v) > 128 or not v.isprintable()
               or any(secret in v for secret in secrets) for v in pair) or pair in seen:
            raise SafeError("Source usage window kind is unsupported")
        seen.add(pair)
        projected = {"key": pair[0], "pool": pair[1],
                     "observed_at_ms": number(window.get("observed_at_ms"), 253370764800000)}
        reason = window.get("unavailable_reason")
        if reason is not None:
            if reason not in reasons or "used" in window or "remaining" in window:
                raise SafeError("Source usage availability is invalid")
            projected["unavailable_reason"] = reason
        else:
            projected["used"] = number(window.get("used"), 100)
            projected["remaining"] = number(window.get("remaining"), 100)
            if abs(projected["used"] + projected["remaining"] - 100) > 0.000001:
                raise SafeError("Source usage values are inconsistent")
        if window.get("resets_at_ms") is not None:
            projected["resets_at_ms"] = number(window["resets_at_ms"], 253370764800000)
        if "window_duration_mins" in window:
            duration = window["window_duration_mins"]
            if type(duration) is not int or not 0 < duration <= 525600:
                raise SafeError("Source usage duration is invalid")
            projected["window_duration_mins"] = duration
        result["windows"].append(projected)
    if usage.get("plan") is not None:
        plan = usage["plan"]
        if (not isinstance(plan, str) or not plan.strip() or len(plan) > 512
                or not plan.isprintable() or any(secret in plan for secret in secrets)):
            raise SafeError("Source usage plan is not safe to export")
        result["plan"] = plan.strip()
    reason = usage.get("unavailable_reason")
    if reason is not None:
        if not isinstance(reason, str) or reason not in reasons or windows:
            raise SafeError("Source usage availability is invalid")
        result["unavailable_reason"] = reason
    return result


def project_metadata(metadata, secrets):
    if not isinstance(metadata, dict):
        raise SafeError("Source account metadata is unavailable")
    result = {}
    for key in FIELDS:
        value = metadata.get(key)
        if value is None:
            continue
        if (not isinstance(value, str) or not value.strip() or len(value) > 512
                or not value.isprintable() or any(secret in value for secret in secrets)):
            raise SafeError("Source account metadata is not safe to export")
        result[key] = value.strip()
    if not all(key in result for key in ("principal", "principal_kind", "label")):
        raise SafeError("Source account identity is incomplete")
    if result["principal_kind"] not in {"email", "id"}:
        raise SafeError("Source account identity kind is unsupported")
    return result


def validate_request(request):
    if not isinstance(request, dict) or type(request.get("version")) is not int or request["version"] != 1:
        raise SafeError("Metadata request version is unsupported")
    if set(request) - {"version", "provider", "kind", "command"}:
        raise SafeError("Metadata request fields are unsupported")
    if (not isinstance(request.get("provider"), str) or request["provider"] not in PROVIDERS
            or not isinstance(request.get("kind"), str) or request["kind"] not in KINDS):
        raise SafeError("Metadata provider or source kind is unsupported")
    command = request.get("command")
    if command is not None:
        if not isinstance(command, str) or not command or len(command) > 1024 or re.search(r"[\s\x00-\x1f]", command):
            raise SafeError("Custom launch command context is unsupported")
        basename = command.replace("\\", "/").rsplit("/", 1)[-1].removesuffix(".exe")
        names = {request["kind"]}
        if request["kind"] == "agy":
            names.add("antigravity")
        if basename not in names:
            raise SafeError("Custom launch command context is unsupported")
    return request


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        if argv != ["--headless"]:
            raise SafeError("Metadata helper arguments are unsupported")
        raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
        if len(raw) > MAX_REQUEST:
            raise SafeError("Metadata request is too large")
        try:
            request = json.loads(raw)
        except (ValueError, UnicodeError):
            raise SafeError("Metadata request JSON is invalid") from None
        # SIGTERM unwinds owned provider children before the helper exits.
        if hasattr(signal, "SIGTERM"):
            def stop(_signal, _frame):
                raise SystemExit(0)
            signal.signal(signal.SIGTERM, stop)
        from usage_service.readers import handle
        response = handle(request)
    except SafeError as exc:
        response = {"version": 1, "error": str(exc)}
    except Exception:
        response = {"version": 1, "error": "Source metadata runtime is unavailable"}
    print(json.dumps(response, ensure_ascii=True, separators=(",", ":"), allow_nan=False))


if __name__ == "__main__":
    main()

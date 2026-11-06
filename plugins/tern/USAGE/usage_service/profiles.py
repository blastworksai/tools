"""Run one bounded, usage-only provider read for a SPAWN-defined account.

The fixed helper bundle runs as the account's verified OS user (Linux sudo -n
for another user, never root). Selectors stay on this machine; only projected
metadata, usage and fixed error codes come back. No login flow, privilege
grant, shell command or account reducer.
"""
from __future__ import annotations

import asyncio
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

import provider_metadata as helper
from .protocol import ServiceError, decode, encode

BUNDLE = ("provider_metadata.py", "metadata_providers.py",
          "usage_service/__init__.py", "usage_service/readers.py")
# SPAWN provider -> the provider CLI whose login USAGE reads.
KINDS = {"claude": "claude", "openai": "codex", "kimi": "kimi", "muse": "muse",
         "antigravity": "agy", "grok": "grok"}
# Helper error codes that pass through; anything else is reported generically.
ERRORS = frozenset({"local_login_unavailable", "web_login_expired", "unparsed", "vendor_usage_unavailable",
                    "source_timeout", "source_usage_unavailable", "source_profile_invalid",
                    "source_context_ambiguous", "api_key_login", "web_login_forbidden"})


def _text(value, maximum=256):
    if not isinstance(value, str) or not value.strip() or len(value) > maximum or not value.isprintable():
        raise ServiceError("source_profile_invalid")
    return value


def _target(user=None):
    """OS identity + optional already-authorized Linux sudo target, never HOME."""
    try:
        identity = helper.source_identity()
        if user is None or user == identity.get("source_user") or user == identity["source_uid"]:
            return identity, None
        if not sys.platform.startswith("linux") or os.name != "posix":
            raise ServiceError("forbidden", 403)
        if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.-]{0,63}\$?", user):
            raise ServiceError("forbidden", 403)
        import pwd
        entry = pwd.getpwnam(user)
        if entry.pw_uid == 0:
            raise ServiceError("forbidden", 403)
        return {"source_uid": str(entry.pw_uid), "source_user": entry.pw_name}, entry.pw_name
    except (helper.SafeError, KeyError, OSError):
        raise ServiceError("source_profile_unavailable") from None


def _verified_bundle(origin):
    """Verify code-only staging against this immutable runtime release."""
    try:
        public = Path(_text(origin, 4096))
        if not public.is_absolute():
            raise ServiceError("source_helper_unverified")
        public = public.resolve(strict=True)
        private = Path(__file__).resolve().parents[1]
        # Public code may be owner-maintained, never writable by another user.
        for directory in (public, *public.parents):
            info = directory.stat()
            if os.name == "posix":
                if info.st_uid not in {0, os.geteuid()}:
                    raise ServiceError("source_helper_unverified")
                # A root/owner-owned sticky ancestor protects our directory entry.
                # The executable bundle itself must never be writable by others.
                if info.st_mode & 0o022 and (directory == public or not info.st_mode & stat.S_ISVTX):
                    raise ServiceError("source_helper_unverified")
        for name in BUNDLE:
            candidate = public / name
            info = candidate.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_size > helper.MAX_BYTES:
                raise ServiceError("source_helper_unverified")
            if os.name == "posix" and (info.st_uid not in {0, os.geteuid()} or info.st_mode & 0o022):
                raise ServiceError("source_helper_unverified")
            if hashlib.sha256(candidate.read_bytes()).digest() != hashlib.sha256((private / name).read_bytes()).digest():
                raise ServiceError("source_helper_unverified")
        return public
    except (OSError, ValueError, TypeError):
        raise ServiceError("source_helper_unverified") from None


@contextmanager
def _helper_bundle(target_user):
    private = Path(__file__).resolve().parents[1]
    if target_user is None:
        yield private
        return
    # Linux cross-user helpers cannot traverse the owner's private runtime/home.
    # Publish only fixed code, never profile selectors, input, output or credentials.
    with tempfile.TemporaryDirectory(prefix="usage-helper-", dir="/tmp") as directory:
        public = Path(directory)
        for name in BUNDLE:
            candidate = public / name
            candidate.parent.mkdir(parents=True, exist_ok=True)
            if candidate.parent != public:
                candidate.parent.chmod(0o755)
            candidate.write_bytes((private / name).read_bytes())
            candidate.chmod(0o644)
        public.chmod(0o755)
        yield _verified_bundle(str(public))



def _metadata(value):
    """Drop raw helper data; provider fields describe identities, never locations."""
    metadata = helper.project_metadata(value, set())
    if any(v.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:[\\/]", v) or "://" in v for v in metadata.values()):
        raise helper.SafeError("Invalid response")
    return metadata


async def acquire_usage(store, spec):
    """One bounded helper under the verified OS user/bundle boundary.

    ``spec`` is refresh's frozen per-account context: provider, kind,
    selectors, source_uid and optional user.
    """
    if not store.settings()["metadata_enabled"]:
        raise ServiceError("source_metadata_disabled", 403)
    expected, user = _target(spec.get("user"))
    if spec.get("source_uid", expected["source_uid"]) != expected["source_uid"]:
        raise ServiceError("source_context_ambiguous")
    executable = str(Path(getattr(sys, "_base_executable", sys.executable)).resolve())
    env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "TZ", "SystemRoot", "WINDIR") if key in os.environ}
    if user:
        env = {"PATH": "/usr/local/bin:" + os.defpath, "LANG": "C.UTF-8"}
    request = {"version": 1, "provider": spec["provider"], "kind": spec["kind"]}
    raw = encode({"request": request, "selectors": spec["selectors"]})
    if len(raw) > helper.MAX_REQUEST:
        raise ServiceError("source_profile_invalid")
    with _helper_bundle(user) as bundle:
        argv = [executable, "-I", "-B", str(bundle / "provider_metadata.py"), "--headless"]
        if user:
            argv = ["/usr/bin/sudo", "-n", "-u", user, "--", *argv]
        process = None
        try:
            process = await asyncio.create_subprocess_exec(*argv, stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, env=env,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            async def exchange():
                process.stdin.write(raw)
                await process.stdin.drain()
                process.stdin.close()
                output = bytearray()
                while chunk := await process.stdout.read(8192):
                    output.extend(chunk)
                    if len(output) > helper.MAX_BYTES:
                        raise ServiceError("source_usage_unavailable")
                await process.wait()
                if process.returncode != 0:
                    raise ServiceError("source_usage_unavailable")
                try:
                    value = decode(bytes(output))
                except ServiceError:
                    raise ServiceError("source_usage_unavailable") from None
                # A helper that failed before identifying itself is not an identity mismatch.
                if not isinstance(value, dict) or "source_uid" not in value:
                    raise ServiceError("source_usage_unavailable")
                if any(value.get(k) != v for k, v in expected.items()):
                    raise ServiceError("source_context_ambiguous")
                result = {"version": 1}
                if "metadata" in value:
                    result["metadata"] = _metadata(value["metadata"])
                if "usage" in value:
                    result["usage"] = helper.project_usage(value["usage"], set())
                if "error" in value:
                    result["error"] = value["error"] if value["error"] in ERRORS else "source_usage_unavailable"
                return result
            return await asyncio.wait_for(exchange(), timeout=75)
        except TimeoutError:
            raise ServiceError("source_timeout", 503) from None
        except (OSError, TypeError, ValueError, helper.SafeError):
            raise ServiceError("source_usage_unavailable", 503) from None
        finally:
            if process is not None and process.returncode is None:
                process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), timeout=15)
                except TimeoutError:
                    process.kill()
                    await process.wait()

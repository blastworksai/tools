"""Owner-local bootstrap and lifecycle; imports remain standard-library only.

The CLI, private records and HTTP replies are validation boundaries. Lifecycle
changes are serialized by bootstrap.lock; only the daemon holds instance.lock.
Releases are content-addressed copies, so a running process never imports a
half-updated installed package.
"""
from __future__ import annotations

import asyncio
from contextlib import closing
import errno
import hashlib
import http.client
import os
from pathlib import Path
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

from . import BUILD, PROTOCOL, SCHEMA
from .protocol import CLIENT_LEASE_SECONDS, MAX_BODY, ServiceError, decode, encode, identifier
from .security import check_private, private_directory, private_staging_directory, write_private

STAMP_FIELDS = ("build", "protocol", "schema", "lock_digest", "source_digest")
PACKAGE_ROOT = Path(__file__).resolve().parent.parent
START_SECONDS = 30
STOP_SECONDS = 30
HTTP_SECONDS = 5
LOCK_SECONDS = 360
_HEX = re.compile(r"[0-9a-f]{64}\Z")
_TOKEN = re.compile(r"[A-Za-z0-9_-]{43,128}\Z")
_ENDPOINT = re.compile(r"http://127\.0\.0\.1:([1-9][0-9]{0,4})\Z")
_OPERATIONS = frozenset({"display", "register_client", "diagnostics", "setup_state", "configure",
                         "unpair", "pair_offer", "pair_accept", "usage_refresh", "usage_status",
                         "usage_preferences", "usage_results", "usage_publish"})
_BACKUP = re.compile(r"upgrade-[0-9a-f]{32}\.sqlite3\Z")


class RuntimeFailure(ServiceError):
    def __init__(self, code: str, state: str):
        super().__init__(code, 503)
        self.state = state

    def public(self) -> dict:
        return dict(super().public(), state=self.state)


class OSLock:
    """Real kernel lock, shared by independent interpreter processes."""
    def __init__(self, path: Path, *, timeout: float = 0, create: bool = True):
        self.path = Path(path)
        self.timeout = timeout
        self.create = create
        self.fd: int | None = None

    def __enter__(self):
        check_private(self.path.parent)
        flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        if self.create:
            flags |= os.O_CREAT
        try:
            self.fd = os.open(self.path, flags, 0o600)
            check_private(self.path)
            if os.name == "nt" and os.fstat(self.fd).st_size == 0:
                os.write(self.fd, b"\0")
            deadline = time.monotonic() + self.timeout
            while True:
                try:
                    if os.name == "posix":
                        import fcntl
                        fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    elif os.name == "nt":
                        import msvcrt
                        os.lseek(self.fd, 0, os.SEEK_SET)
                        msvcrt.locking(self.fd, msvcrt.LK_NBLCK, 1)
                    else:
                        raise RuntimeFailure("setup_required", "platform_unsupported")
                    return self
                except OSError as exc:
                    if exc.errno not in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                        raise
                    if time.monotonic() >= deadline:
                        raise RuntimeFailure("companion_unavailable", "busy") from None
                    time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        except BaseException:
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None
            raise

    def __exit__(self, *_):
        if self.fd is not None:
            try:
                if os.name == "nt":
                    import msvcrt
                    os.lseek(self.fd, 0, os.SEEK_SET)
                    msvcrt.locking(self.fd, msvcrt.LK_UNLCK, 1)
            finally:
                os.close(self.fd)
                self.fd = None


def _running(root: Path) -> bool:
    try:
        with OSLock(root / "instance.lock", create=False):
            return False
    except FileNotFoundError:
        return False
    except RuntimeFailure as exc:
        if exc.state == "busy":
            return True
        raise


def _read_private(path: Path, maximum: int = MAX_BODY) -> bytes:
    check_private(path)
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise ServiceError("invalid_request")
    return data


def _json_file(path: Path) -> dict:
    value = decode(_read_private(path))
    if not isinstance(value, dict):
        raise ServiceError("invalid_request")
    return value


def _stamp(value: object) -> dict:
    if not isinstance(value, dict):
        raise ServiceError("incompatible_version")
    if (not isinstance(value.get("build"), str) or not re.fullmatch(r"[A-Za-z0-9_.+-]{1,80}", value["build"])
            or any(type(value.get(k)) is not int or not 1 <= value[k] <= 1_000_000 for k in ("protocol", "schema"))
            or any(not isinstance(value.get(k), str) or not _HEX.fullmatch(value[k]) for k in ("lock_digest", "source_digest"))):
        raise ServiceError("incompatible_version")
    return {key: value[key] for key in STAMP_FIELDS}


def _endpoint(value: object) -> tuple[str, int]:
    match = _ENDPOINT.fullmatch(value) if isinstance(value, str) else None
    if not match or not 1 <= int(match[1]) <= 65535:
        raise ServiceError("unauthorized", 401)
    return value, int(match[1])


def _sources(package: Path) -> dict[str, bytes]:
    package = Path(package)
    names = ["requirements.lock", "pyproject.toml"]
    directory = package / "usage_service"
    if directory.is_symlink() or not directory.is_dir():
        raise RuntimeFailure("setup_required", "package_invalid")
    for path in sorted([*package.glob("*.py"), *directory.rglob("*.py")]):
        relative = path.relative_to(package)
        if path.is_symlink() or any((package / parent).is_symlink() for parent in relative.parents):
            raise RuntimeFailure("setup_required", "package_invalid")
        names.append(path.relative_to(package).as_posix())
    # This also verifies prior immutable releases during upgrade. Keep the
    # baseline stable; new modules are included by discovery, not required of old builds.
    required = {"usage_service.py", "provider_metadata.py",
                "usage_service/__init__.py", "usage_service/runtime.py", "usage_service/server.py",
                "usage_service/store.py", "usage_service/security.py",
                "usage_service/protocol.py", "usage_service/sync.py", "usage_service/profiles.py",
                "usage_service/display.py"}
    if not required.issubset(names):
        raise RuntimeFailure("setup_required", "package_incomplete")
    result = {}
    total = 0
    for name in sorted(names):
        path = package / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 2 * MAX_BODY:
            raise RuntimeFailure("setup_required", "package_invalid")
        data = path.read_bytes()
        total += len(data)
        if total > 16 * MAX_BODY:
            raise RuntimeFailure("setup_required", "package_invalid")
        if name.endswith(".py"):
            try:
                compile(data, name, "exec")
            except (SyntaxError, ValueError):
                raise RuntimeFailure("setup_required", "package_invalid") from None
        result[name] = data
    return result


def _source_digest(files: dict[str, bytes]) -> str:
    digest = hashlib.sha256()
    for name, data in sorted(files.items()):
        encoded = name.encode("utf-8")
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def _stamp_of(files: dict[str, bytes]) -> dict:
    return {"build": BUILD, "protocol": PROTOCOL, "schema": SCHEMA,
            "lock_digest": hashlib.sha256(files["requirements.lock"]).hexdigest(),
            "source_digest": _source_digest(files)}


def source_stamp(package_root: Path | None = None) -> dict:
    return _stamp_of(_sources(package_root or PACKAGE_ROOT))


def _stage_release(root: Path, files: dict[str, bytes], stamp: dict) -> Path:
    releases = root / "releases"
    private_directory(releases)
    destination = releases / stamp["source_digest"]
    if destination.exists():
        check_private(destination)
        if _source_digest(_sources(destination)) != stamp["source_digest"]:
            raise RuntimeFailure("setup_required", "release_changed")
        return destination
    staging = private_staging_directory(releases, ".release-")
    try:
        for name, content in files.items():
            path = staging / name
            for parent in reversed(path.parent.relative_to(staging).parents):
                if str(parent) != ".":
                    private_directory(staging / parent)
            if path.parent != staging:
                private_directory(path.parent)
            write_private(path, content)
        os.replace(staging, destination)
        return destination
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def _python(environment: Path) -> Path:
    return environment / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def _interpreter() -> dict:
    # Format shared with pre-2.0 builds so their installed environments keep matching.
    return {"implementation": sys.implementation.name, "version": list(sys.version_info[:3]),
            "platform": sys.platform, "cache_tag": sys.implementation.cache_tag}


def _environment_name(stamp: dict) -> str:
    return stamp["lock_digest"] + "-" + hashlib.sha256(encode(_interpreter())).hexdigest()[:16]


def _environment(root: Path, name: str, stamp: dict) -> Path:
    if not isinstance(name, str) or not re.fullmatch(r"[0-9a-f]{64}-[0-9a-f]{16}", name):
        raise RuntimeFailure("setup_required", "environment_invalid")
    directory = root / "environments" / name
    check_private(directory.parent)
    check_private(directory)
    marker = _json_file(directory / "environment.json")
    if (marker.get("lock_digest") != stamp["lock_digest"] or not isinstance(marker.get("interpreter"), dict)
            or name != stamp["lock_digest"] + "-" + hashlib.sha256(encode(marker["interpreter"])).hexdigest()[:16]
            or not _python(directory).is_file()):
        raise RuntimeFailure("setup_required", "environment_invalid")
    _stamp(marker.get("installed_with"))
    return directory


def _child_environment(root: Path) -> dict[str, str]:
    # Ignore Python injection and package-manager settings. Pip is also --isolated.
    result = {key: value for key, value in os.environ.items()
              if not key.startswith(("PYTHON", "PIP_", "UV_"))}
    result.update(TMPDIR=str(root / "tmp"), TMP=str(root / "tmp"), TEMP=str(root / "tmp"),
                  PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1", PIP_CONFIG_FILE=os.devnull)
    return result


def _run_setup(argv: list[str], root: Path, timeout: int) -> None:
    try:
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, cwd=root, env=_child_environment(root),
                                close_fds=True, timeout=timeout, check=False,
                                **({"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}))
    except (OSError, subprocess.SubprocessError):
        raise RuntimeFailure("setup_required", "dependency_install_failed") from None
    if result.returncode:
        raise RuntimeFailure("setup_required", "dependency_install_failed")


def _stage_environment(root: Path, release: Path, stamp: dict, consent: bool) -> str:
    name = _environment_name(stamp)
    parent = root / "environments"
    directory = parent / name
    if directory.exists():
        _environment(root, name, stamp)
        return name
    if not consent:
        raise RuntimeFailure("setup_required", "dependency_consent_required")
    private_directory(parent)
    private_directory(root / "tmp")
    staging = private_staging_directory(parent, ".environment-")
    try:
        _run_setup([sys.executable, "-I", "-B", "-m", "venv", "--copies", str(staging)], root, 90)
        python = str(_python(staging))
        _run_setup([python, "-I", "-B", "-m", "pip", "--isolated", "--disable-pip-version-check",
                    "--no-input", "--no-cache-dir", "install", "--require-hashes", "--only-binary=:all:",
                    "--no-compile", "-r", str(release / "requirements.lock")], root, 240)
        _run_setup([python, "-I", "-B", "-c", "import aiohttp, cryptography, tzdata"], root, 30)
        write_private(staging / "environment.json", encode({"lock_digest": stamp["lock_digest"],
                      "interpreter": _interpreter(), "installed_with": stamp}))
        os.replace(staging, directory)
        return name
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def _root_identity(root: Path) -> str | None:
    path = root / "state.sqlite3"
    if not path.exists():
        return None
    check_private(path)
    try:
        with closing(sqlite3.connect("file:" + quote(str(path.absolute())) + "?mode=ro", uri=True, timeout=5)) as db:
            row = db.execute("SELECT device_id FROM installations LIMIT 1").fetchone()
    except sqlite3.Error:
        raise ServiceError("migration_conflict", 409) from None
    return identifier(row[0]) if row else None


def _launch_record(root: Path, value: dict | None = None) -> dict:
    value = _json_file(root / "launch.json") if value is None else value
    stamp = _stamp(value.get("stamp"))
    if not isinstance(value.get("launch_id"), str) or not _TOKEN.fullmatch(value["launch_id"]):
        raise ServiceError("unauthorized", 401)
    identity = value.get("root_identity")
    if identity is not None:
        identifier(identity)
    _environment(root, value.get("environment"), stamp)
    release = root / "releases" / stamp["source_digest"]
    check_private(release.parent)
    check_private(release)
    if _source_digest(_sources(release)) != stamp["source_digest"]:
        raise RuntimeFailure("setup_required", "release_changed")
    return {"stamp": stamp, "environment": value["environment"], "launch_id": value["launch_id"],
            "root_identity": identity}


def _runtime(root: Path) -> dict:
    value = _json_file(root / "runtime.json")
    stamp = _stamp(value)
    endpoint, _ = _endpoint(value.get("endpoint"))
    device_id = identifier(value.get("device_id"))
    if not isinstance(value.get("launch_id"), str) or not _TOKEN.fullmatch(value["launch_id"]):
        raise ServiceError("unauthorized", 401)
    return dict(stamp, endpoint=endpoint, device_id=device_id, launch_id=value["launch_id"])


def publish_ready(root: Path, endpoint: str, device_id: str, stamp: dict) -> None:
    """Server calls after binding/auth setup and Store initialization, never before."""
    root = Path(root)
    record = _launch_record(root)
    stamp = _stamp(stamp)
    endpoint, _ = _endpoint(endpoint)
    identifier(device_id)
    if (record["stamp"] != stamp or _root_identity(root) != device_id
            or record["root_identity"] not in (None, device_id)):
        raise ServiceError("migration_conflict", 409)
    token = _read_private(root / "local.token", 128).decode("ascii")
    if not _TOKEN.fullmatch(token):
        raise ServiceError("unauthorized", 401)
    record["root_identity"] = device_id
    write_private(root / "launch.json", encode(record))
    write_private(root / "runtime.json", encode(dict(stamp, endpoint=endpoint, device_id=device_id,
                  launch_id=record["launch_id"])))


def _request(root: Path, metadata: dict, method: str, path: str, payload: dict | None = None) -> dict:
    _, port = _endpoint(metadata["endpoint"])
    try:
        token = _read_private(root / "local.token", 128).decode("ascii")
    except UnicodeError:
        raise ServiceError("unauthorized", 401) from None
    if not _TOKEN.fullmatch(token):
        raise ServiceError("unauthorized", 401)
    body = encode(payload) if payload is not None else None
    if body is not None and len(body) > MAX_BODY:
        raise ServiceError("snapshot_too_large", 413)
    timeout = HTTP_SECONDS if method == "GET" else 25
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        deadline = time.monotonic() + timeout
        connection.request(method, path, body=body, headers={"Authorization": "Bearer " + token,
                           "Content-Type": "application/json", "Connection": "close"})
        transport = connection.sock
        response = connection.getresponse()
        if response.status not in range(200, 300) and response.status not in range(400, 600):
            raise ServiceError("companion_unavailable", 503)
        if response.getheader("Content-Type", "").split(";", 1)[0].strip() != "application/json":
            raise ServiceError("companion_unavailable", 503)
        chunks = bytearray()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError()
            if transport is not None:
                transport.settimeout(remaining)
            chunk = response.read1(min(65536, MAX_BODY + 1 - len(chunks)))
            if not chunk:
                break
            chunks.extend(chunk)
            if len(chunks) > MAX_BODY:
                raise ServiceError("snapshot_too_large", 413)
            if response.isclosed():
                break
        result = decode(bytes(chunks))
        if not isinstance(result, dict) or type(result.get("ok")) is not bool or token.encode() in chunks:
            raise ServiceError("companion_unavailable", 503)
        if not result["ok"]:
            error = result.get("error")
            raise ServiceError(error.get("code") if isinstance(error, dict) else "internal_error", response.status)
        if not 200 <= response.status < 300:
            raise ServiceError("companion_unavailable", 503)
        return result
    except (OSError, http.client.HTTPException):
        raise ServiceError("companion_unavailable", 503) from None
    finally:
        connection.close()


def _health(root: Path, expected: dict | None = None) -> dict:
    metadata = _runtime(root)
    result = _request(root, metadata, "GET", "/health")
    actual = _stamp(result)
    device_id = identifier(result.get("device_id"))
    if (actual != _stamp(metadata) or device_id != metadata["device_id"]
            or device_id != _root_identity(root)):
        raise ServiceError("unauthorized", 401)
    if expected is not None and actual != expected:
        raise ServiceError("incompatible_version", 409)
    return dict(metadata, ok=True)


def _public(metadata: dict, state: str = "ready") -> dict:
    return dict({key: metadata[key] for key in (*STAMP_FIELDS, "endpoint", "device_id")}, ok=True, state=state)


def _shutdown(root: Path, metadata: dict) -> None:
    _request(root, metadata, "POST", "/rpc", {"operation": "shutdown", "payload": {}})
    with OSLock(root / "instance.lock", timeout=STOP_SECONDS):
        pass


def detached_options() -> dict:
    result = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL,
              "close_fds": True}
    if os.name == "nt":
        # DETACHED_PROCESS prevents console inheritance; CREATE_NO_WINDOW covers
        # GUI-launched console interpreters. Windows ignores the latter when detached.
        result["creationflags"] = subprocess.DETACHED_PROCESS | subprocess.CREATE_NO_WINDOW
    else:
        result["start_new_session"] = True
    return result


def _start(root: Path, record: dict) -> dict:
    write_private(root / "launch.json", encode(record))
    for name in ("startup.json", "runtime.json"):
        path = root / name
        if path.exists():
            check_private(path)
            path.unlink()
    environment = _environment(root, record["environment"], record["stamp"])
    release = root / "releases" / record["stamp"]["source_digest"]
    try:
        child = subprocess.Popen([str(_python(environment)), "-I", "-B", str(release / "usage_service.py"),
                                  "_serve", "--data-root", str(root)], cwd=root,
                                 env=_child_environment(root), **detached_options())
    except OSError:
        raise RuntimeFailure("companion_unavailable", "start_failed") from None
    deadline = time.monotonic() + START_SECONDS
    while time.monotonic() < deadline:
        if (root / "startup.json").exists():
            failure = _json_file(root / "startup.json")
            if failure.get("launch_id") == record["launch_id"]:
                child.wait(timeout=max(1, deadline - time.monotonic()))
                raise RuntimeFailure(failure.get("code", "internal_error"), "start_failed")
        if (root / "runtime.json").exists():
            try:
                health = _health(root, record["stamp"])
            except ServiceError as exc:
                if exc.code != "companion_unavailable":
                    raise
            else:
                if health["launch_id"] != record["launch_id"]:
                    raise ServiceError("unauthorized", 401)
                return health
        if child.poll() is not None:
            raise RuntimeFailure("companion_unavailable", "start_failed")
        time.sleep(0.05)
    raise RuntimeFailure("companion_unavailable", "start_timeout")


def _backup(root: Path) -> str | None:
    source = root / "state.sqlite3"
    if not source.exists():
        return None
    check_private(source)
    private_directory(root / "backups")
    name = "upgrade-" + secrets.token_hex(16) + ".sqlite3"
    destination = root / "backups" / name
    write_private(destination, b"")
    try:
        with closing(sqlite3.connect("file:" + quote(str(source)) + "?mode=ro", uri=True, timeout=5)) as old:
            with closing(sqlite3.connect(destination)) as backup:
                old.backup(backup)
    except sqlite3.Error:
        destination.unlink()
        raise RuntimeFailure("companion_unavailable", "backup_failed") from None
    return name


def _restore(root: Path, name: str | None) -> None:
    for suffix in ("-wal", "-shm", "-journal"):
        sidecar = root / ("state.sqlite3" + suffix)
        if sidecar.exists():
            check_private(sidecar)
            sidecar.unlink()
    destination = root / "state.sqlite3"
    if destination.exists():
        check_private(destination)
    if name is None:
        destination.unlink(missing_ok=True)
        return
    if not isinstance(name, str) or not re.fullmatch(r"upgrade-[0-9a-f]{32}\.sqlite3", name):
        raise ServiceError("invalid_request")
    source = root / "backups" / name
    check_private(source)
    descriptor, temporary = tempfile.mkstemp(prefix=".restore-", dir=root)
    try:
        with os.fdopen(descriptor, "wb") as output, source.open("rb") as input_file:
            shutil.copyfileobj(input_file, output)
            output.flush()
            os.fsync(output.fileno())
        check_private(Path(temporary))
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)


def _rollback(root: Path, journal: dict) -> str:
    restoring = journal.get("phase") == "rollback"
    if _running(root):
        # A late-ready candidate can be stopped only after authenticated health.
        try:
            metadata = _health(root)
        except ServiceError:
            raise RuntimeFailure("companion_unavailable", "recovery_pending") from None
        if metadata["launch_id"] != journal["launch_id"]:
            raise RuntimeFailure("companion_unavailable", "recovery_pending")
        if restoring and _stamp(metadata) == journal["previous"]["stamp"]:
            _finish(root, journal, prune=False)
            return "upgrade_rolled_back"
        _shutdown(root, metadata)
    # Journals from older builds have no "restore" flag; they always backed up.
    if not restoring and journal.get("restore", True):
        with OSLock(root / "instance.lock", timeout=STOP_SECONDS):
            _restore(root, journal.get("backup"))
    previous = journal.get("previous")
    if previous is not None:
        previous = _launch_record(root, previous)
        previous["launch_id"] = secrets.token_urlsafe(32)
        journal.update(phase="rollback", launch_id=previous["launch_id"], previous=previous)
        write_private(root / "upgrade.json", encode(journal))
        _start(root, previous)
        state = "upgrade_rolled_back"
    else:
        for name in ("runtime.json", "launch.json", "local.token"):
            path = root / name
            if path.exists():
                check_private(path)
                path.unlink()
        state = "start_failed"
    # A rollback keeps the candidate's release/environment so a retry needs no new install.
    _finish(root, journal, prune=False)
    return state


def _finish(root: Path, journal: dict, *, prune: bool = True) -> None:
    """Close a settled upgrade journal: drop its backup and, after a confirmed
    candidate start, every release/environment launch.json does not reference."""
    (root / "upgrade.json").unlink()
    backups = root / "backups"
    if backups.is_dir():
        check_private(backups)
        for path in backups.iterdir():
            if _BACKUP.fullmatch(path.name) and not path.is_symlink():
                path.unlink()
    if not prune or not (root / "launch.json").exists():
        return
    record = _json_file(root / "launch.json")
    stamp = _stamp(record.get("stamp"))
    keep = {"releases": stamp["source_digest"], "environments": record.get("environment")}
    for directory, name in keep.items():
        parent = root / directory
        if not parent.is_dir():
            continue
        check_private(parent)
        for path in parent.iterdir():
            if path.name == name or path.name.startswith("."):
                continue
            if path.is_symlink() or not path.is_dir():
                path.unlink()
            else:
                shutil.rmtree(path)


def _recover(root: Path, expected: dict) -> None:
    path = root / "upgrade.json"
    if not path.exists():
        return
    journal = _json_file(path)
    if (not isinstance(journal.get("launch_id"), str) or not _TOKEN.fullmatch(journal["launch_id"])
            or journal.get("phase") not in ("candidate", "rollback")):
        raise ServiceError("invalid_request")
    if _running(root):
        try:
            health = _health(root, expected)
        except ServiceError:
            health = None
        if health is not None and health["launch_id"] == journal["launch_id"] and journal["phase"] == "candidate":
            _finish(root, journal)
            return
    _rollback(root, journal)


def _client(request: dict) -> tuple[str, str]:
    client = request.get("client_id")
    kind = request.get("client_kind")
    if (not isinstance(client, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", client)
            or kind not in ("host", "window")):
        raise ServiceError("invalid_request")
    return client, kind


def ensure(root: Path, request: dict) -> dict:
    client, kind = _client(request)
    consent = request.get("install_dependencies", False)
    if type(consent) is not bool or set(request) - {"client_id", "client_kind", "install_dependencies"}:
        raise ServiceError("invalid_request")
    root = Path(root).absolute()
    private_directory(root)
    with OSLock(root / "bootstrap.lock", timeout=LOCK_SECONDS):
        files = _sources(PACKAGE_ROOT)
        stamp = _stamp_of(files)
        _recover(root, stamp)
        health = _health(root) if _running(root) else None
        if health is not None and _stamp(health) == stamp:
            _request(root, health, "POST", "/rpc", {"operation": "register_client",
                     "payload": {"client_id": client, "kind": kind, "ttl_seconds": CLIENT_LEASE_SECONDS}})
            return _public(health)
        # Refuse without consent before making an immutable release or environment.
        env_name = _environment_name(stamp)
        if not (root / "environments" / env_name).exists() and not consent:
            raise RuntimeFailure("setup_required", "dependency_consent_required")
        release = _stage_release(root, files, stamp)
        env_name = _stage_environment(root, release, stamp, consent)
        previous = _launch_record(root) if (root / "launch.json").exists() else None
        if health is not None:
            if previous is None or previous["launch_id"] != health["launch_id"] or previous["stamp"] != _stamp(health):
                raise ServiceError("unauthorized", 401)
            _shutdown(root, health)
        # Restarting the same build (idle exit, sleep, Tern relaunch) runs no migration.
        upgrade = previous is None or previous["stamp"] != stamp
        try:
            with OSLock(root / "instance.lock", timeout=STOP_SECONDS):
                backup = _backup(root) if upgrade else None
                record = {"stamp": stamp, "environment": env_name, "launch_id": secrets.token_urlsafe(32),
                          "root_identity": _root_identity(root)}
                journal = {"backup": backup, "restore": upgrade, "previous": previous,
                           "launch_id": record["launch_id"], "phase": "candidate"}
                write_private(root / "upgrade.json", encode(journal))
        except Exception:
            # No migration has run yet: the stopped release can resume unchanged.
            if health is not None and previous is not None and not _running(root):
                previous["launch_id"] = secrets.token_urlsafe(32)
                _start(root, previous)
            raise RuntimeFailure("companion_unavailable", "backup_failed") from None
        try:
            health = _start(root, record)
            _request(root, health, "POST", "/rpc", {"operation": "register_client",
                     "payload": {"client_id": client, "kind": kind, "ttl_seconds": CLIENT_LEASE_SECONDS}})
        except Exception as exc:
            try:
                state = _rollback(root, journal)
            except Exception:
                raise RuntimeFailure("companion_unavailable", "recovery_pending") from None
            code = exc.code if isinstance(exc, ServiceError) else "companion_unavailable"
            raise RuntimeFailure(code, state) from None
        _finish(root, journal)
        return _public(health)


def rpc(root: Path, request: dict) -> dict:
    if set(request) != {"operation", "payload"} or not isinstance(request.get("operation"), str) or request["operation"] not in _OPERATIONS or not isinstance(request.get("payload"), dict):
        raise ServiceError("invalid_request")
    check_private(root)
    if not _running(root):
        raise RuntimeFailure("companion_unavailable", "stopped")
    # ensure (run by every new VM) performs the full source digest check.
    health = _health(root)
    if (health["build"], health["protocol"], health["schema"]) != (BUILD, PROTOCOL, SCHEMA):
        raise ServiceError("incompatible_version", 409)
    return _request(root, health, "POST", "/rpc", request)


def stop(root: Path) -> dict:
    if not root.exists():
        return {"ok": True, "state": "stopped"}
    check_private(root)
    with OSLock(root / "bootstrap.lock", timeout=LOCK_SECONDS):
        if _running(root):
            _shutdown(root, _health(root))
    return {"ok": True, "state": "stopped"}


def doctor(root: Path) -> dict:
    if not root.exists():
        return {"ok": True, "state": "not_initialized"}
    check_private(root)
    if not _running(root):
        return {"ok": True, "state": "stopped"}
    return _public(_health(root, source_stamp()))


async def _serve_async(root: Path, record: dict) -> None:
    from .server import serve

    async def readiness_deadline():
        await asyncio.sleep(START_SECONDS - 5)
        path = root / "runtime.json"
        if not path.exists() or _runtime(root)["launch_id"] != record["launch_id"]:
            raise RuntimeFailure("companion_unavailable", "start_timeout")
        await asyncio.Future()

    serving = asyncio.create_task(serve(root, record["stamp"]))
    watchdog = asyncio.create_task(readiness_deadline())
    try:
        done, _ = await asyncio.wait((serving, watchdog), return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            await task
    finally:
        serving.cancel()
        watchdog.cancel()
        await asyncio.gather(serving, watchdog, return_exceptions=True)


def serve_process(root: Path) -> dict:
    check_private(root)
    with OSLock(root / "instance.lock"):
        record = _launch_record(root)
        try:
            if record["stamp"] != source_stamp() or Path(sys.prefix).resolve() != _environment(root, record["environment"], record["stamp"]).resolve():
                raise ServiceError("incompatible_version", 409)
            asyncio.run(_serve_async(root, record))
            return {"ok": True, "state": "stopped"}
        except Exception as exc:
            write_private(root / "startup.json", encode({"launch_id": record["launch_id"],
                          "code": exc.code if isinstance(exc, ServiceError) else "internal_error"}))
            raise
        finally:
            path = root / "runtime.json"
            if path.exists() and _runtime(root)["launch_id"] == record["launch_id"]:
                path.unlink()


def main(argv: list[str] | None = None) -> int:
    """Exactly one bounded JSON object in/out; never echo exceptions or argv."""
    try:
        arguments = list(sys.argv[1:] if argv is None else argv)
        if len(arguments) != 3 or arguments[1] != "--data-root" or arguments[0] not in {"ensure", "rpc", "stop", "doctor", "_serve"}:
            raise ServiceError("invalid_request")
        if not arguments[2] or "\0" in arguments[2]:
            raise ServiceError("invalid_request")
        root = Path(arguments[2]).absolute()
        command = arguments[0]
        if command == "_serve":
            result = serve_process(root)
        else:
            request = decode(sys.stdin.buffer.read(MAX_BODY + 1))
            if not isinstance(request, dict):
                raise ServiceError("invalid_request")
            if command == "ensure":
                result = ensure(root, request)
            elif command == "rpc":
                result = rpc(root, request)
            else:
                if request:
                    raise ServiceError("invalid_request")
                result = stop(root) if command == "stop" else doctor(root)
    except ServiceError as exc:
        result = exc.public()
    except Exception:
        result = ServiceError("internal_error", 500).public()
    output = encode(result)
    if len(output) > MAX_BODY:
        result = ServiceError("snapshot_too_large", 413).public()
        output = encode(result)
    sys.stdout.buffer.write(output + b"\n")
    sys.stdout.buffer.flush()
    return 0 if result.get("ok") is True else 1

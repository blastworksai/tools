"""Checked setup file reads, replacement, and locking. Blastworks.ai, MIT."""
from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
import errno
import hashlib
import os
from pathlib import Path
import secrets
import stat
import time

LIMIT = 2 * 1024 * 1024
LOCK_TIMEOUT = 2


class Refused(ValueError):
    """A bounded diagnostic that can safely go to the plug-in host log."""


@dataclass(frozen=True)
class Snapshot:
    data: bytes | None
    stamp: tuple[int, ...]
    mode: int

    @property
    def digest(self) -> str | None:
        return _digest(self.data) if self.data is not None else None


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _absolute(path: Path) -> Path:
    if not path.is_absolute() or '..' in path.parts or str(path).startswith('//'):
        raise Refused('TODO setup requires an absolute local path.')
    return path


def _private_primary_group() -> int | None:
    import grp
    import pwd

    account = pwd.getpwuid(os.geteuid())
    gid = account.pw_gid
    try:
        named_members = set(grp.getgrgid(gid).gr_mem)
    except KeyError:
        return None
    if named_members - {account.pw_name} or any(
        entry.pw_gid == gid and entry.pw_uid != account.pw_uid for entry in pwd.getpwall()
    ):
        return None
    return gid


def _private_group_write(info: os.stat_result, fd: int, private_group: int | None) -> bool:
    if (private_group is None or info.st_gid != private_group or info.st_uid != os.geteuid()
            or info.st_mode & 0o002):
        return False
    try:
        os.getxattr(fd, 'system.posix_acl_access')
    except OSError as error:
        return error.errno in (errno.ENODATA, errno.ENOTSUP)
    return False


@contextmanager
def _directory(path: Path, *, create: bool = False, owned: bool = False,
               trusted_from: Path | None = None, private_group: int | None = None) -> Iterator[int]:
    """Open through trusted directory descriptors, rejecting linked components."""
    _absolute(path)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    current = os.open('/', flags)
    owner = os.geteuid()
    location = Path('/')
    try:
        for part in path.parts[1:]:
            location /= part
            try:
                child = os.open(part, flags, dir_fd=current)
            except FileNotFoundError:
                if not create:
                    raise
                try:
                    os.mkdir(part, 0o700, dir_fd=current)
                except FileExistsError:
                    pass
                child = os.open(part, flags, dir_fd=current)
            os.close(current)
            current = child
            if trusted_from is not None and not location.is_relative_to(trusted_from):
                continue
            info = os.fstat(current)
            trusted_sticky = info.st_uid == 0 and bool(info.st_mode & stat.S_ISVTX)
            if info.st_uid not in (0, owner):
                raise Refused('TODO setup found an unsafe directory owner or write permission.')
            if info.st_mode & 0o022 and not (trusted_sticky or _private_group_write(info, current, private_group)):
                raise Refused('TODO setup found an unsafe directory owner or write permission.')
        info = os.fstat(current)
        if owned and (info.st_uid != owner or info.st_mode & 0o022):
            raise Refused('TODO setup needs a private configuration directory owned by this account.')
        yield current
    finally:
        os.close(current)


def _snapshot_at(folder: int, name: str, *, trusted: bool = False) -> Snapshot:
    parent = os.fstat(folder)
    stamp = (parent.st_dev, parent.st_ino)
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK | os.O_NOFOLLOW
    try:
        fd = os.open(name, flags, dir_fd=folder)
    except FileNotFoundError:
        return Snapshot(None, stamp, 0o600)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        owners = (0, os.geteuid()) if trusted else (os.geteuid(),)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid not in owners
                or info.st_nlink != 1 or info.st_mode & 0o7022):
            raise Refused('TODO setup found an unsafe file owner, mode, type, or hard link.')
        data = stream.read(LIMIT + 1)
        final = os.fstat(stream.fileno())
    if len(data) > LIMIT or (info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (
        final.st_size, final.st_mtime_ns, final.st_ctime_ns
    ):
        raise Refused('TODO setup found an oversized or changing file.')
    stamp += (info.st_dev, info.st_ino, info.st_mode, info.st_mtime_ns, info.st_ctime_ns)
    return Snapshot(data, stamp, stat.S_IMODE(info.st_mode))


def _snapshot(path: Path, *, trusted: bool = False) -> Snapshot:
    with _directory(path.parent) as folder:
        return _snapshot_at(folder, path.name, trusted=trusted)


def _write(path: Path, expected: Snapshot, value: bytes | None) -> None:
    """Replace only the observed file through its checked parent directory."""
    if value is not None and len(value) > LIMIT:
        raise Refused('TODO setup would exceed the configuration size limit.')
    with _directory(path.parent, owned=True) as folder:
        if _snapshot_at(folder, path.name) != expected:
            raise Refused('TODO setup found a configuration file changed during setup.')
        if value is None:
            if expected.data is not None:
                os.unlink(path.name, dir_fd=folder)
                os.fsync(folder)
            return
        temporary = '.todo-setup-' + secrets.token_hex(12)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
        fd = os.open(temporary, flags, 0o600, dir_fd=folder)
        try:
            with os.fdopen(fd, 'wb') as stream:
                os.fchmod(stream.fileno(), expected.mode)
                stream.write(value)
                stream.flush()
                os.fsync(stream.fileno())
            if _snapshot(path) != expected:
                raise Refused('TODO setup found a configuration file replaced during setup.')
            os.replace(temporary, path.name, src_dir_fd=folder, dst_dir_fd=folder)
            os.fsync(folder)
        finally:
            try:
                os.unlink(temporary, dir_fd=folder)
            except FileNotFoundError:
                pass
    saved = _snapshot(path)
    if saved.data != value or saved.mode != expected.mode:
        raise Refused('TODO setup could not verify its configuration write.')


@contextmanager
def _locked(home: Path) -> Iterator[None]:
    import fcntl

    with _directory(home, owned=True) as folder:
        flags = os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
        descriptor = os.open('install.lock', flags, 0o600, dir_fd=folder)
        try:
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or info.st_nlink != 1 or info.st_mode & 0o077):
                raise Refused('TODO setup found an unsafe setup lock.')
            deadline = time.monotonic() + LOCK_TIMEOUT
            while True:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise Refused('Another TODO setup operation is still running.') from None
                    time.sleep(0.025)
            yield
        finally:
            os.close(descriptor)

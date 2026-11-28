"""Handle and ACL checks for the Windows setup filesystem. Blastworks.ai, MIT."""
from collections.abc import Iterator
from contextlib import contextmanager, ExitStack
import ctypes
from ctypes import wintypes as w
import errno
from functools import lru_cache
import msvcrt
import os
from pathlib import Path
import stat
import tempfile
import time

from install_files import LIMIT, LOCK_TIMEOUT, Refused, Snapshot
from publication import owner, _windows_checked_handle, _windows_security


@lru_cache(maxsize=1)
def _identity() -> str:
    return owner()


def _kernel():
    api = ctypes.WinDLL('kernel32', use_last_error=True)
    api.CreateFileW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.c_void_p, w.DWORD, w.DWORD, w.HANDLE]
    api.CreateFileW.restype = w.HANDLE
    api.CloseHandle.argtypes = [w.HANDLE]
    api.GetFileInformationByHandleEx.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
    api.ReadFile.argtypes = [w.HANDLE, ctypes.c_void_p, w.DWORD, ctypes.POINTER(w.DWORD), ctypes.c_void_p]
    api.ReplaceFileW.argtypes = [w.LPCWSTR, w.LPCWSTR, w.LPCWSTR, w.DWORD, ctypes.c_void_p, ctypes.c_void_p]
    return api


@contextmanager
def _checked_directory(path: Path, *, inspect_acl: bool, owned: bool) -> Iterator[None]:
    api = _kernel()
    # Existing directory, READ_CONTROL | FILE_READ_ATTRIBUTES, without share-delete.
    # Open the reparse point itself so a junction cannot redirect setup.
    handle = api.CreateFileW(str(path), 0x20080, 3, None, 3, 0x02200000, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        attributes_and_tag = (w.DWORD * 2)()
        if not api.GetFileInformationByHandleEx(handle, 9, attributes_and_tag, ctypes.sizeof(attributes_and_tag)):
            raise ctypes.WinError(ctypes.get_last_error())
        attributes = attributes_and_tag[0]
        if not attributes & 0x10 or attributes & 0x400:
            raise Refused('TODO setup found a linked or invalid configuration directory.')
        if inspect_acl:
            try:
                # An elevated desktop install can leave Administrators as the owner.
                # The ACL still must grant writes only to this user and OS principals.
                _windows_security(path, _identity(), handle=handle, trusted_installation=not owned)
            except ValueError as error:
                raise Refused('TODO setup found an unsafe directory owner or write permission.') from error
        yield
    finally:
        api.CloseHandle(handle)


@contextmanager
def directory(path: Path, *, create: bool, owned: bool, trusted_from: Path | None) -> Iterator[None]:
    with ExitStack() as handles:
        location = Path(path.anchor)
        handles.enter_context(_checked_directory(location, inspect_acl=False, owned=False))
        for part in path.parts[1:]:
            location /= part
            if create:
                location.mkdir(exist_ok=True)
            inspect = trusted_from is None or location.is_relative_to(trusted_from)
            handles.enter_context(_checked_directory(location, inspect_acl=inspect, owned=owned and location == path))
        yield


def _stamp(info: os.stat_result) -> tuple[int, ...]:
    return info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def snapshot(path: Path, *, trusted: bool = False) -> Snapshot:
    parent = path.parent.stat()
    parent_stamp = parent.st_dev, parent.st_ino
    try:
        before = path.lstat()
    except FileNotFoundError:
        return Snapshot(None, parent_stamp, 0o600)
    try:
        with _windows_checked_handle(path, _identity(), 0x80000000, trusted_installation=trusted) as (_, handle):
            buffer = ctypes.create_string_buffer(LIMIT + 1)
            count = w.DWORD()
            if not _kernel().ReadFile(handle, buffer, len(buffer), ctypes.byref(count), None):
                raise ctypes.WinError(ctypes.get_last_error())
            after = path.lstat()
    except ValueError as error:
        raise Refused('TODO setup found an unsafe file owner, ACL, type, or hard link.') from error
    if count.value > LIMIT or _stamp(before) != _stamp(after):
        raise Refused('TODO setup found an oversized or changing file.')
    return Snapshot(buffer.raw[:count.value], parent_stamp + _stamp(after), stat.S_IMODE(after.st_mode))


def write(path: Path, expected: Snapshot, value: bytes | None) -> None:
    with directory(path.parent, create=False, owned=True, trusted_from=None):
        if snapshot(path) != expected:
            raise Refused('TODO setup found a configuration file changed during setup.')
        if value is None:
            if expected.data is not None:
                path.unlink()
            return
        descriptor, name = tempfile.mkstemp(prefix='.todo-setup-', dir=path.parent)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(value)
                stream.flush()
                os.fsync(stream.fileno())
            if snapshot(path) != expected:
                raise Refused('TODO setup found a configuration file replaced during setup.')
            if expected.data is None:
                temporary.rename(path)
            elif not _kernel().ReplaceFileW(str(path), str(temporary), None, 0, None, None):
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            temporary.unlink(missing_ok=True)
        saved = snapshot(path)
        if saved.data != value or (expected.data is not None and saved.mode != expected.mode):
            raise Refused('TODO setup could not verify its configuration write.')


@contextmanager
def locked(home: Path) -> Iterator[None]:
    with directory(home, create=False, owned=True, trusted_from=None):
        target = home / 'install.lock'
        try:
            descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_BINARY, 0o600)
        except FileExistsError:
            snapshot(target)
            descriptor = os.open(target, os.O_RDWR | os.O_BINARY)
        try:
            _windows_security(target, _identity(), handle=msvcrt.get_osfhandle(descriptor))
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise Refused('TODO setup found an unsafe setup lock.')
            deadline = time.monotonic() + LOCK_TIMEOUT
            while True:
                try:
                    msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
                    break
                except OSError as error:
                    if error.errno != errno.EACCES:
                        raise
                    if time.monotonic() >= deadline:
                        raise Refused('Another TODO setup operation is still running.') from None
                    time.sleep(0.025)
            yield
        finally:
            os.close(descriptor)

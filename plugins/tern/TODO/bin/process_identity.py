"""Native process birth/ownership facts, no provider or pane input. Blastworks.ai; MIT.

Uses existing OS interfaces only: Linux procfs, macOS libproc's public
proc_bsdinfo ABI, and Windows Toolhelp/GetProcessTimes/token APIs.
No third-party module or OS header implementation is bundled.
"""
import ctypes
import errno
import os
from pathlib import Path
import stat
import struct
import sys


class ProcessEnded(ValueError):
    """The requested PID no longer names the same live process."""
    terminal = True


def _darwin_bsd_info(pid):
    # Public libproc ABI, PROC_PIDTBSDINFO, from XNU bsd/sys/proc_info.h.
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidinfo.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(136)
    if lib.proc_pidinfo(pid, 3, 0, buffer, len(buffer)) != len(buffer):
        error = ctypes.get_errno()
        if error == errno.ESRCH:
            raise ProcessEnded('process has ended')
        raise OSError(error or errno.EIO, 'cannot read native process identity')
    return lib, buffer.raw


def process(pid):
    pid = int(pid)
    if pid <= 0:
        raise ValueError('invalid process id')
    if sys.platform.startswith('linux'):
        folder = Path('/proc') / str(pid)
        try:
            text = (folder/'stat').read_text()
        except FileNotFoundError:
            raise ProcessEnded('process has ended') from None
        rest = text[text.rfind(')')+2:].split()
        if rest[0] == 'Z':
            raise ProcessEnded('process has ended')
        try:
            uid = folder.stat().st_uid
        except FileNotFoundError:
            raise ProcessEnded('process has ended') from None
        boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        return {'pid': pid, 'ppid': int(rest[1]), 'owner': str(uid),
                'birth': 'linux:'+boot+':'+rest[19], 'name': text[text.find('(')+1:text.rfind(')')]}
    if sys.platform == 'darwin':
        _, record = _darwin_bsd_info(pid)
        fields = struct.unpack_from('=12I', record)
        if fields[3] != pid or fields[1] == 5:
            raise ProcessEnded('process has ended or changed')
        sec, usec = struct.unpack_from('=QQ', record, 120)
        return {'pid': pid, 'ppid': fields[4], 'owner': str(fields[5]),
                'birth': 'darwin:'+str(sec)+':'+str(usec),
                'name': record[48:64].split(b'\0', 1)[0].decode('utf-8', 'replace')}
    if os.name == 'nt':
        return _windows_process(pid)
    raise ValueError('native process identity is unsupported on this OS')


def _darwin_invocation(pid):
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    image = ctypes.create_string_buffer(4096)
    if lib.proc_pidpath(pid, image, len(image)) <= 0:
        raise OSError(ctypes.get_errno(), 'cannot read native executable path')
    libc = ctypes.CDLL(None, use_errno=True)
    libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                            ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    # KERN_PROCARGS2 returns argc, the executable path, padding, then argv.
    mib = (ctypes.c_int * 3)(1, 49, pid)
    buffer = ctypes.create_string_buffer(256 * 1024)
    size = ctypes.c_size_t(len(buffer))
    if libc.sysctl(mib, len(mib), buffer, ctypes.byref(size), None, 0) or size.value < 5:
        raise OSError(ctypes.get_errno(), 'cannot read native process arguments')
    raw = buffer.raw[:size.value]
    count = struct.unpack_from('=i', raw)[0]
    executable, separator, arguments = raw[4:].partition(b'\0')
    words = arguments.lstrip(b'\0').split(b'\0', count)
    if not executable or not separator or not 0 < count < len(words):
        raise ValueError('cannot verify native process arguments')
    return Path(os.fsdecode(image.value)), [os.fsdecode(word) for word in words[1:count]]


def _darwin_terminal(pid):
    lib, record = _darwin_bsd_info(pid)
    group, _, device, foreground = struct.unpack_from('=4I', record, 100)
    if not group or group != foreground or device == 0xFFFFFFFF:
        return False
    # PROC_PIDFDVNODEINFO returns proc_fileinfo followed by vinfo_stat.
    lib.proc_pidfdinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    buffer = ctypes.create_string_buffer(512)
    size = lib.proc_pidfdinfo(pid, 0, 1, buffer, len(buffer))
    if size < 144:
        return False
    mode = struct.unpack_from('=H', buffer.raw, 28)[0]
    stdin_device = struct.unpack_from('=I', buffer.raw, 140)[0]
    return stat.S_ISCHR(mode) and device == stdin_device


def invocation(pid):
    """Return the kernel's executable path and argv without its environment."""
    if sys.platform.startswith('linux'):
        folder = Path('/proc') / str(pid)
        image = (folder / 'exe').readlink()
        with (folder / 'cmdline').open('rb') as stream:
            raw = stream.read(64 * 1024 + 1)
        if not raw.endswith(b'\0') or len(raw) > 64 * 1024:
            raise ValueError('cannot verify native process arguments')
        return image, [os.fsdecode(part) for part in raw[:-1].split(b'\0')][1:]
    if sys.platform == 'darwin':
        return _darwin_invocation(pid)
    if os.name == 'nt':
        return _windows_invocation(pid)
    raise ValueError('native execute process verification is unavailable on this OS')


def interactive_terminal(pid):
    if sys.platform == 'darwin':
        return _darwin_terminal(pid)
    if os.name == 'nt':
        return _windows_terminal(pid)
    raise ValueError('native terminal verification is unavailable on this OS')


def _windows_snapshot_parent(kernel, entry_type, pid):
    kernel.CreateToolhelp32Snapshot.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    kernel.CreateToolhelp32Snapshot.restype = ctypes.c_void_p
    kernel.Process32FirstW.argtypes = [ctypes.c_void_p, ctypes.POINTER(entry_type)]
    kernel.Process32NextW.argtypes = [ctypes.c_void_p, ctypes.POINTER(entry_type)]
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    parent = None
    complete = False
    enumeration_error = None
    try:
        entry = entry_type(); entry.size = ctypes.sizeof(entry)
        more = kernel.Process32FirstW(snapshot, ctypes.byref(entry))
        if not more:
            error = ctypes.get_last_error()
            if error == 18: complete = True
            else: enumeration_error = error
        while more:
            if entry.pid == pid:
                parent = entry.parent
                break
            more = kernel.Process32NextW(snapshot, ctypes.byref(entry))
            if not more:
                error = ctypes.get_last_error()
                if error == 18: complete = True
                else: enumeration_error = error
    finally:
        kernel.CloseHandle(snapshot)
    return parent, complete, enumeration_error


def _windows_open_error(parent, complete, enumeration_error, open_error):
    if enumeration_error is not None:
        raise ctypes.WinError(enumeration_error)
    if open_error == 87 and (parent is not None or complete):
        raise ProcessEnded('process has ended')
    if open_error is not None:
        raise ctypes.WinError(open_error)
    raise OSError('native process is present but its parent snapshot is inaccessible')


def _windows_image(kernel, handle):
    from ctypes import wintypes as w

    kernel.QueryFullProcessImageNameW.argtypes = [w.HANDLE, w.DWORD, w.LPWSTR, ctypes.POINTER(w.DWORD)]
    image = ctypes.create_unicode_buffer(32768)
    length = w.DWORD(len(image))
    if not kernel.QueryFullProcessImageNameW(handle, 0, image, ctypes.byref(length)):
        raise ctypes.WinError(ctypes.get_last_error())
    return Path(image.value)


def _windows_invocation(pid):
    from ctypes import wintypes as w

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    ntdll = ctypes.WinDLL('ntdll')
    shell = ctypes.WinDLL('shell32', use_last_error=True)
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.CloseHandle.argtypes = [w.HANDLE]
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    ntdll.NtQueryInformationProcess.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.ULONG,
                                               ctypes.POINTER(w.ULONG)]
    shell.CommandLineToArgvW.argtypes = [w.LPCWSTR, ctypes.POINTER(ctypes.c_int)]
    shell.CommandLineToArgvW.restype = ctypes.POINTER(w.LPWSTR)

    class UnicodeString(ctypes.Structure):
        _fields_ = [('size', w.USHORT), ('capacity', w.USHORT), ('data', ctypes.c_void_p)]

    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        image = _windows_image(kernel, handle)
        # ProcessCommandLineInformation returns a bounded copy, never the remote PEB.
        buffer = ctypes.create_string_buffer(64 * 1024 + ctypes.sizeof(UnicodeString))
        size = w.ULONG()
        if ntdll.NtQueryInformationProcess(handle, 60, buffer, len(buffer), ctypes.byref(size)) != 0:
            raise OSError('cannot read native process arguments')
        command = UnicodeString.from_buffer(buffer)
        base = ctypes.addressof(buffer)
        if (not command.size or command.size % 2 or not command.data
                or command.data < base or command.data + command.size > base + len(buffer)):
            raise ValueError('cannot verify native process arguments')
        argument_count = ctypes.c_int()
        words = shell.CommandLineToArgvW(ctypes.wstring_at(command.data, command.size // 2),
                                        ctypes.byref(argument_count))
        if not words or argument_count.value < 1:
            raise OSError('cannot parse native process arguments')
        try:
            return image, words[1:argument_count.value]
        finally:
            kernel.LocalFree(ctypes.cast(words, ctypes.c_void_p))
    finally:
        kernel.CloseHandle(handle)


def _windows_terminal(pid):
    from ctypes import wintypes as w

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetConsoleProcessList.argtypes = [ctypes.POINTER(w.DWORD), w.DWORD]
    kernel.GetConsoleProcessList.restype = w.DWORD
    kernel.AttachConsole.argtypes = [w.DWORD]
    members = (w.DWORD * 256)()
    count = kernel.GetConsoleProcessList(members, len(members))
    if 0 < count <= len(members) and pid in members[:count]:
        return True
    if count and not kernel.FreeConsole():
        return False
    if not kernel.AttachConsole(pid):
        return False
    # The launcher can give command hooks their own console. Attaching to
    # the independently verified Tern descendant proves it has a console.
    kernel.FreeConsole()
    return True


def _windows_process(pid):
    from ctypes import wintypes as w
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    advapi = ctypes.WinDLL('advapi32', use_last_error=True)
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.CloseHandle.argtypes = [w.HANDLE]
    kernel.GetProcessTimes.argtypes = [w.HANDLE]+[ctypes.POINTER(w.FILETIME)]*4
    advapi.OpenProcessToken.argtypes = [w.HANDLE, w.DWORD, ctypes.POINTER(w.HANDLE)]
    advapi.GetTokenInformation.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.POINTER(w.DWORD)]
    advapi.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(w.LPWSTR)]
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    class Entry(ctypes.Structure):
        _fields_ = [('size', w.DWORD), ('usage', w.DWORD), ('pid', w.DWORD),
                    ('heap', ctypes.c_size_t), ('module', w.DWORD), ('threads', w.DWORD),
                    ('parent', w.DWORD), ('priority', w.LONG), ('flags', w.DWORD), ('exe', w.WCHAR*260)]
    parent, complete, enumeration_error = _windows_snapshot_parent(kernel, Entry, pid)
    handle = kernel.OpenProcess(0x1000, False, pid)
    error = ctypes.get_last_error() if not handle else None
    if not handle:
        _windows_open_error(parent, complete, enumeration_error, error)
    token = w.HANDLE()
    try:
        times = [w.FILETIME() for _ in range(4)]
        if not kernel.GetProcessTimes(handle, *(ctypes.byref(t) for t in times)):
            raise ctypes.WinError(ctypes.get_last_error())
        # An exited process can remain open while Toolhelp no longer lists it.
        # Its handle-bound exit time is definitive; missing parent data is not.
        if times[1].dwLowDateTime or times[1].dwHighDateTime:
            raise ProcessEnded('process has ended')
        if enumeration_error is not None or parent is None:
            _windows_open_error(parent, complete, enumeration_error, None)
        image = _windows_image(kernel, handle)
        if not advapi.OpenProcessToken(handle, 8, ctypes.byref(token)):
            raise ctypes.WinError(ctypes.get_last_error())
        needed = w.DWORD()
        advapi.GetTokenInformation(token, 1, None, 0, ctypes.byref(needed))
        data = ctypes.create_string_buffer(needed.value)
        if not advapi.GetTokenInformation(token, 1, data, needed, ctypes.byref(needed)):
            raise ctypes.WinError(ctypes.get_last_error())
        sid = ctypes.cast(data, ctypes.POINTER(ctypes.c_void_p))[0]
        result = w.LPWSTR()
        if not advapi.ConvertSidToStringSidW(sid, ctypes.byref(result)):
            raise ctypes.WinError(ctypes.get_last_error())
        try: owner = result.value
        finally: kernel.LocalFree(ctypes.cast(result, ctypes.c_void_p))
        born = times[0].dwLowDateTime | (times[0].dwHighDateTime << 32)
        return {'pid': pid, 'ppid': parent, 'owner': owner, 'birth': 'windows:'+str(born), 'name': image.name}
    finally:
        if token: kernel.CloseHandle(token)
        kernel.CloseHandle(handle)


def ancestors(pid):
    result, seen = [], set()
    for _ in range(48):
        if pid <= 0 or pid in seen:
            break
        seen.add(pid)
        item = process(pid)
        if result and os.name == 'nt' and int(item['birth'].split(':')[1]) > int(result[-1]['birth'].split(':')[1]):
            raise ValueError('parent process identity has been reused')
        result.append(item); pid = item['ppid']
        if item['name'].lower().removesuffix('.exe') == 'tern':
            return result
    raise ValueError('the caller is not inside a verifiable native Tern process tree')


def session_process(agent_pid):
    """Bind the caller's explicitly identified agent, never infer it from a name."""
    if type(agent_pid) is not int or agent_pid <= 0:
        raise ValueError('identify this interactive agent process explicitly')
    identity = process(os.getpid())['owner']
    chain = ancestors(os.getppid())
    for index, item in enumerate(chain[:-1]):
        if item['pid'] == agent_pid and item['owner'] == identity:
            return chain[index:]
    raise ValueError('the declared agent must be this caller or an ancestor owned by this account')

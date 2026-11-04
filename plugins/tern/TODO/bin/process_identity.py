"""Native process birth/ownership facts, no provider or pane input. CodexBWAI; MIT.

Uses existing OS interfaces only: Linux procfs, macOS libproc's public
proc_bsdinfo ABI, and Windows Toolhelp/GetProcessTimes/token APIs.
No third-party module or OS header implementation is bundled.
"""
import ctypes
import os
from pathlib import Path
import struct
import sys


def process(pid):
    pid = int(pid)
    if pid <= 0:
        raise ValueError('invalid process id')
    if sys.platform.startswith('linux'):
        folder = Path('/proc') / str(pid)
        text = (folder/'stat').read_text()
        rest = text[text.rfind(')')+2:].split()
        if rest[0] == 'Z':
            raise ValueError('process has ended')
        boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        return {'pid': pid, 'ppid': int(rest[1]), 'owner': str(folder.stat().st_uid),
                'birth': 'linux:'+boot+':'+rest[19], 'name': text[text.find('(')+1:text.rfind(')')]}
    if sys.platform == 'darwin':
        # Public libproc ABI: fixed-size process facts, not copied OS implementation.
        # Reference: apple-oss-distributions/xnu bsd/sys/proc_info.h, PROC_PIDTBSDINFO.
        lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        lib.proc_pidinfo.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(136)
        if lib.proc_pidinfo(pid, 3, 0, buffer, len(buffer)) != len(buffer):
            raise OSError('cannot read native process identity')
        fields = struct.unpack_from('=12I', buffer.raw)
        if fields[3] != pid or fields[1] == 5:
            raise ValueError('process has ended')
        sec, usec = struct.unpack_from('=QQ', buffer.raw, 120)
        return {'pid': pid, 'ppid': fields[4], 'owner': str(fields[5]),
                'birth': 'darwin:'+str(sec)+':'+str(usec),
                'name': buffer.raw[48:64].split(b'\0', 1)[0].decode('utf-8', 'replace')}
    if os.name == 'nt':
        return _windows_process(pid)
    raise ValueError('native process identity is unsupported on this OS')


def _windows_process(pid):
    from ctypes import wintypes as w
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    advapi = ctypes.WinDLL('advapi32', use_last_error=True)
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.CloseHandle.argtypes = [w.HANDLE]
    kernel.GetProcessTimes.argtypes = [w.HANDLE]+[ctypes.POINTER(w.FILETIME)]*4
    kernel.QueryFullProcessImageNameW.argtypes = [w.HANDLE, w.DWORD, w.LPWSTR, ctypes.POINTER(w.DWORD)]
    advapi.OpenProcessToken.argtypes = [w.HANDLE, w.DWORD, ctypes.POINTER(w.HANDLE)]
    advapi.GetTokenInformation.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.POINTER(w.DWORD)]
    advapi.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(w.LPWSTR)]
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    class Entry(ctypes.Structure):
        _fields_ = [('size', w.DWORD), ('usage', w.DWORD), ('pid', w.DWORD),
                    ('heap', ctypes.c_size_t), ('module', w.DWORD), ('threads', w.DWORD),
                    ('parent', w.DWORD), ('priority', w.LONG), ('flags', w.DWORD), ('exe', w.WCHAR*260)]
    kernel.CreateToolhelp32Snapshot.argtypes = [w.DWORD, w.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = w.HANDLE
    kernel.Process32FirstW.argtypes = [w.HANDLE, ctypes.POINTER(Entry)]
    kernel.Process32NextW.argtypes = [w.HANDLE, ctypes.POINTER(Entry)]
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        raise OSError('cannot read native process list')
    parent = None
    try:
        entry = Entry(); entry.size = ctypes.sizeof(entry)
        more = kernel.Process32FirstW(snapshot, ctypes.byref(entry))
        while more:
            if entry.pid == pid:
                parent = entry.parent; break
            more = kernel.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel.CloseHandle(snapshot)
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle or parent is None:
        if handle: kernel.CloseHandle(handle)
        raise OSError('cannot read native process identity')
    token = w.HANDLE()
    try:
        times = [w.FILETIME() for _ in range(4)]
        if not kernel.GetProcessTimes(handle, *(ctypes.byref(t) for t in times)):
            raise OSError('cannot read native process birth')
        image = ctypes.create_unicode_buffer(32768); length = w.DWORD(len(image))
        if not kernel.QueryFullProcessImageNameW(handle, 0, image, ctypes.byref(length)):
            raise OSError('cannot read native process image')
        if not advapi.OpenProcessToken(handle, 8, ctypes.byref(token)):
            raise OSError('cannot read native process owner')
        needed = w.DWORD()
        advapi.GetTokenInformation(token, 1, None, 0, ctypes.byref(needed))
        data = ctypes.create_string_buffer(needed.value)
        if not advapi.GetTokenInformation(token, 1, data, needed, ctypes.byref(needed)):
            raise OSError('cannot read native process owner')
        sid = ctypes.cast(data, ctypes.POINTER(ctypes.c_void_p))[0]
        result = w.LPWSTR()
        if not advapi.ConvertSidToStringSidW(sid, ctypes.byref(result)):
            raise OSError('cannot read native process owner')
        try: owner = result.value
        finally: kernel.LocalFree(ctypes.cast(result, ctypes.c_void_p))
        born = times[0].dwLowDateTime | (times[0].dwHighDateTime << 32)
        return {'pid': pid, 'ppid': parent, 'owner': owner, 'birth': 'windows:'+str(born), 'name': Path(image.value).name}
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

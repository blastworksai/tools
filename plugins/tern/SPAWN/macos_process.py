"""Read-only macOS terminal continuation capability; Python 3 stdlib only.

ABI sources (not an approximate ps timestamp):
https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h
https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/param.h
https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/sysctl.h

No provider launch, signal, filesystem write, credentials, installation or sudo.
Only the requested processes' argv are retained; environment bytes returned by
KERN_PROCARGS2 are neither parsed, emitted nor hashed.
"""
import ctypes
import ctypes.util
import hashlib
import json
import os
import sys

MAX_BYTES = 65536
PROC_PIDTBSDINFO = 3
CTL_KERN, KERN_PROCARGS2 = 1, 49


class BsdInfo(ctypes.Structure):
    _fields_ = [
        (name, ctypes.c_uint32) for name in (
            "flags", "status", "xstatus", "pid", "ppid", "uid", "gid",
            "ruid", "rgid", "svuid", "svgid", "reserved",
        )
    ] + [
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
        ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
        ("pjobc", ctypes.c_uint32), ("tty", ctypes.c_uint32),
        ("foreground_group", ctypes.c_uint32), ("nice", ctypes.c_int32),
        ("start_seconds", ctypes.c_uint64), ("start_microseconds", ctypes.c_uint64),
    ]


def positive(value):
    return isinstance(value, int) and not isinstance(value, bool) and 0 < value <= 2147483647


class Observer:
    def __init__(self):
        if sys.platform != "darwin" or ctypes.sizeof(ctypes.c_void_p) != 8:
            raise RuntimeError("A supported 64-bit macOS Python 3 interpreter is required")
        if ctypes.sizeof(BsdInfo) != 136 or BsdInfo.start_seconds.offset != 120 or BsdInfo.start_microseconds.offset != 128:
            raise RuntimeError("Native proc_bsdinfo ABI size/alignment is unsupported")
        library = ctypes.util.find_library("proc")
        if not library:
            raise RuntimeError("The native macOS libproc capability is unavailable")
        self.libproc = ctypes.CDLL(library, use_errno=True)
        self.libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.libproc.proc_pidinfo.restype = ctypes.c_int
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
        self.libc.sysctl.restype = ctypes.c_int

    def bsd(self, pid):
        if not positive(pid):
            raise ValueError("Invalid requested native PID")
        result = BsdInfo()
        length = self.libproc.proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ctypes.byref(result), ctypes.sizeof(result))
        if length != ctypes.sizeof(result) or result.pid != pid:
            raise RuntimeError("Complete matching native process information is unavailable")
        if result.uid != os.geteuid() or result.flags & 4 or not result.start_seconds or result.start_microseconds >= 1000000:
            raise RuntimeError("Same-user live process creation identity is unavailable")
        return result

    @staticmethod
    def identity(info):
        return f"{info.pid}:{info.start_seconds}:{info.start_microseconds}"

    def argv(self, pid):
        mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
        buffer = ctypes.create_string_buffer(MAX_BYTES)
        size = ctypes.c_size_t(MAX_BYTES)
        if self.libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0 or not 4 < size.value <= MAX_BYTES:
            raise RuntimeError("Bounded native argv observation is unavailable")
        raw = buffer.raw[:size.value]
        argc = int.from_bytes(raw[:4], sys.byteorder, signed=True)
        if not 1 <= argc <= 256:
            raise RuntimeError("Native argv count is outside its supported bound")
        offset = raw.find(b"\0", 4)
        if offset < 4:
            raise RuntimeError("Native executable path is incomplete")
        offset += 1
        while offset < len(raw) and raw[offset] == 0:
            offset += 1
        words = []
        for _ in range(argc):
            end = raw.find(b"\0", offset)
            if end < offset:
                raise RuntimeError("Native argv is incomplete")
            words.append(raw[offset:end].decode("utf-8", "strict"))
            offset = end + 1
        argv_bytes = b"\0".join(word.encode("utf-8") for word in words) + b"\0"
        return words, hashlib.sha256(argv_bytes).hexdigest()

    def ancestor_chain(self, leaf, root):
        chain = []
        for _ in range(64):
            info = self.bsd(leaf)
            chain.append(info)
            if leaf == root:
                return chain
            if not positive(info.ppid) or info.ppid == leaf:
                break
            leaf = info.ppid
        raise RuntimeError("Current native foreground ancestry does not reach the retained terminal root")

    def capture(self, root_pid, foreground_pid, expected):
        root = self.bsd(root_pid)
        chain = self.ancestor_chain(foreground_pid, root_pid)
        provider = None
        for info in chain:
            words, _ = self.argv(info.pid)
            offset = len(words) - len(expected["arguments"])
            if 1 <= offset <= 3:
                actual = words[offset - 1]
                name_matches = actual == expected["executable"] if "/" in expected["executable"] else os.path.basename(actual) == expected["executable"]
                if name_matches and words[offset:] == expected["arguments"]:
                    provider = info
        if provider is None:
            raise RuntimeError("The exact configured provider argv is not in current native foreground ancestry")
        if not provider.flags & 0x40 or provider.tty in (0, 0xffffffff) or provider.tty != root.tty or provider.pgid != provider.foreground_group:
            raise RuntimeError("The configured provider is not associated with the original foreground tty")
        root_session, provider_session = os.getsid(root_pid), os.getsid(provider.pid)
        if root_session != provider_session:
            raise RuntimeError("Provider and terminal process sessions differ")
        return {
            "root_pid": root_pid, "root_identity": self.identity(root),
            "provider_pid": provider.pid, "provider_identity": self.identity(provider),
            "tty": str(provider.tty), "group": str(provider.pgid), "process_session": str(provider_session),
            "root_argv_sha256": self.argv(root_pid)[1], "provider_argv_sha256": self.argv(provider.pid)[1],
        }

    def verify(self, root_pid, foreground_pid, proof):
        root, provider = self.bsd(root_pid), self.bsd(proof["provider_pid"])
        if root_pid != proof["root_pid"] or self.identity(root) != proof["root_identity"] or self.identity(provider) != proof["provider_identity"]:
            raise RuntimeError("The retained native root/provider process creation identity changed")
        if not provider.flags & 0x40 or str(root.tty) != proof["tty"] or str(provider.tty) != proof["tty"] or str(provider.pgid) != proof["group"] or str(provider.foreground_group) != proof["group"] or str(os.getsid(provider.pid)) != proof["process_session"] or os.getsid(root_pid) != os.getsid(provider.pid):
            raise RuntimeError("The retained tty/session/foreground association changed")
        if self.argv(root_pid)[1] != proof["root_argv_sha256"] or self.argv(provider.pid)[1] != proof["provider_argv_sha256"]:
            raise RuntimeError("The retained terminal/provider exec image or argv changed")
        if provider.pid not in [info.pid for info in self.ancestor_chain(foreground_pid, root_pid)]:
            raise RuntimeError("The current native foreground is unrelated to the retained provider")
        self.ancestor_chain(provider.pid, root_pid)
        return {"verified": True}


def main():
    observer = Observer()
    if sys.argv[1:] == ["capability"]:
        observer.bsd(os.getpid())
        print(json.dumps({"available": True, "abi_bytes": ctypes.sizeof(BsdInfo)}))
        return
    raw = sys.stdin.buffer.read(MAX_BYTES + 1)
    if not raw or len(raw) > MAX_BYTES:
        raise ValueError("Bounded process observation input is required")
    request = json.loads(raw)
    if not isinstance(request, dict) or not positive(request.get("root_pid")) or not positive(request.get("foreground_pid")):
        raise ValueError("Exact native terminal root and foreground PIDs are required")
    mode = request.get("mode")
    if mode == "capture" and set(request) == {"mode", "root_pid", "foreground_pid", "expected"}:
        expected = request["expected"]
        if not isinstance(expected, dict) or set(expected) != {"executable", "arguments"} or not isinstance(expected["executable"], str) or not expected["executable"] or not isinstance(expected["arguments"], list) or len(expected["arguments"]) > 256 or any(not isinstance(word, str) or "\0" in word for word in [expected["executable"]] + expected["arguments"]):
            raise ValueError("The exact configured executable/argv is required")
        result = observer.capture(request["root_pid"], request["foreground_pid"], expected)
    elif mode == "verify" and set(request) == {"mode", "root_pid", "foreground_pid", "proof"}:
        result = observer.verify(request["root_pid"], request["foreground_pid"], request["proof"])
    else:
        raise ValueError("Unknown or malformed process observation")
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("macOS terminal process observation unavailable: " + str(error)[:512], file=sys.stderr)
        raise SystemExit(1)

"""Platform-independent fixtures for the actual macOS observer; no native Mac calls."""
import ctypes
import hashlib
import importlib.util
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

package = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("spawn_macos_process", package / "macos_process.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeFixtures:
    def __init__(self):
        self.records = {}
        self.payloads = {}
        self.short = False
        for pid, parent, group, seconds, microseconds in ((100, 1, 100, 10, 1), (200, 100, 200, 11, 2), (300, 200, 200, 12, 3), (400, 100, 200, 13, 4)):
            record = module.BsdInfo()
            record.flags = 0x40
            record.pid, record.ppid, record.pgid = pid, parent, group
            record.uid = os.geteuid()
            record.tty, record.foreground_group = 123, 200
            record.start_seconds, record.start_microseconds = seconds, microseconds
            self.records[pid] = record
        self.set_argv(100, ["/bin/sh", "-c", "approved command"])
        self.set_argv(200, ["/tools/provider", "--task", "literal assignment Ω"])
        self.set_argv(300, ["/bin/sh", "report-helper", "literal assignment Ω"])
        self.set_argv(400, ["/tools/unrelated"])

    def set_argv(self, pid, words, environment=b"PRIVATE_TOKEN=must-not-be-retained\0"):
        self.payloads[pid] = len(words).to_bytes(4, sys.byteorder, signed=True) + b"/observed/executable\0\0\0" + b"\0".join(word.encode() for word in words) + b"\0" + environment

    def proc_pidinfo(self, pid, flavor, argument, buffer, size):
        assert flavor == 3 and argument == 0 and size == 136
        record = self.records.get(pid)
        if record is None:
            return 0
        ctypes.memmove(buffer, ctypes.byref(record), ctypes.sizeof(record))
        return size - 1 if self.short else size

    def sysctl(self, mib, length, buffer, size, replacement, replacement_size):
        assert length == 3 and mib[0] == 1 and mib[1] == 49
        assert replacement is None and replacement_size == 0
        payload = self.payloads.get(mib[2])
        if payload is None:
            return -1
        ctypes.memmove(buffer, payload, len(payload))
        ctypes.cast(size, ctypes.POINTER(ctypes.c_size_t)).contents.value = len(payload)
        return 0


class ProcessIdentityTests(unittest.TestCase):
    def setUp(self):
        self.native = NativeFixtures()
        self.observer = module.Observer.__new__(module.Observer)
        self.observer.libproc = self.native
        self.observer.libc = self.native
        self.session = patch.object(module.os, "getsid", return_value=100)
        self.session.start()
        self.addCleanup(self.session.stop)
        self.expected = {"executable": "/tools/provider", "arguments": ["--task", "literal assignment Ω"]}

    def capture(self):
        return self.observer.capture(100, 300, self.expected)

    def test_apple_abi_layout_and_complete_matching_pid(self):
        self.assertEqual(ctypes.sizeof(module.BsdInfo), 136)
        self.assertEqual(module.BsdInfo.start_seconds.offset, 120)
        self.assertEqual(module.BsdInfo.start_microseconds.offset, 128)
        self.assertEqual(self.observer.bsd(200).pid, 200)
        self.native.short = True
        with self.assertRaises(RuntimeError):
            self.observer.bsd(200)
        self.native.short = False
        self.native.records[200].pid = 999
        with self.assertRaises(RuntimeError):
            self.observer.bsd(200)

    def test_exact_provider_not_transient_helper(self):
        proof = self.capture()
        self.assertEqual(proof["provider_pid"], 200)
        self.assertEqual(proof["provider_identity"], "200:11:2")
        self.assertEqual(self.observer.verify(100, 300, proof), {"verified": True})

    def test_same_second_changed_microseconds_is_not_same_process(self):
        proof = self.capture()
        self.native.records[200].start_microseconds += 1
        with self.assertRaises(RuntimeError):
            self.observer.verify(100, 300, proof)

    def test_tty_foreground_parent_and_exec_changes_hold(self):
        for mutation in (
            lambda: setattr(self.native.records[200], "tty", 456),
            lambda: setattr(self.native.records[200], "foreground_group", 400),
            lambda: setattr(self.native.records[200], "ppid", 999),
            lambda: self.native.set_argv(200, ["/tools/provider", "--task", "different conversation"]),
        ):
            self.native = NativeFixtures()
            self.observer.libproc = self.native
            self.observer.libc = self.native
            proof = self.capture()
            mutation()
            with self.assertRaises(RuntimeError):
                self.observer.verify(100, 300, proof)

    def test_unrelated_foreground_and_missing_process_hold(self):
        proof = self.capture()
        with self.assertRaises(RuntimeError):
            self.observer.verify(100, 400, proof)
        del self.native.records[200]
        with self.assertRaises(RuntimeError):
            self.observer.verify(100, 300, proof)

    def test_environment_is_not_retained_or_hashed(self):
        words, before = self.observer.argv(200)
        self.native.set_argv(200, words, environment=b"PRIVATE_TOKEN=different-secret\0")
        self.assertEqual(self.observer.argv(200), (words, before))
        self.assertEqual(before, hashlib.sha256(b"\0".join(word.encode() for word in words) + b"\0").hexdigest())
        self.assertNotIn("PRIVATE_TOKEN", str(self.capture()))

    def test_argv_count_truncation_and_cross_user_are_not_success(self):
        self.native.payloads[200] = (257).to_bytes(4, sys.byteorder, signed=True) + b"x\0"
        with self.assertRaises(RuntimeError):
            self.observer.argv(200)
        self.native.payloads[200] = (2).to_bytes(4, sys.byteorder, signed=True) + b"/bin/x\0\0x\0unterminated"
        with self.assertRaises(RuntimeError):
            self.observer.argv(200)
        self.native.records[200].uid = os.geteuid() + 1
        with self.assertRaises(RuntimeError):
            self.observer.bsd(200)


if __name__ == "__main__":
    unittest.main()

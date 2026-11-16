#!/usr/bin/env python3
"""Real offline helper lifetime tests; native pane ownership is tested separately."""

import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


PACKAGE = Path(__file__).resolve().parents[1]


class SetupRouteLifetime(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="spawn route Ω 雪 ")
        self.addCleanup(self.directory.cleanup)
        base = Path(self.directory.name).resolve()
        self.output = base / "result Ω"
        self.nonce = "fixture-offline-route"
        self.value = 'literal "quoted" \\ Ω 雪 diagnostic'
        installed = base / "installed tools Ω"
        installed.mkdir()
        self.helper = installed / ("setup_route.ps1" if os.name == "nt" else "setup_route.sh")
        shutil.copyfile(PACKAGE / self.helper.name, self.helper)
        self.environment = dict(os.environ, HOME=str(base), USERPROFILE=str(base), TMPDIR=str(base))
        if os.name != "nt":
            self.environment["LOCALAPPDATA"] = "must-not-be-used-on-posix"
        if os.name == "nt":
            executable = shutil.which("powershell.exe")
            if not executable:
                self.skipTest("Windows PowerShell is unavailable")
            self.identity = subprocess.check_output(
                [executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                 "[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);"
                 "[Console]::Write([Security.Principal.WindowsIdentity]::GetCurrent().Name)"],
                encoding="utf-8").strip()
            self.command = [executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
                            str(self.helper), "-Output:", str(self.output),
                            "-Nonce:", self.nonce, "-Value:", self.value]
        else:
            self.identity = subprocess.check_output(["whoami"], text=True).strip()
            self.command = ["sh", str(self.helper), str(self.output),
                            self.nonce, self.value]
        self.process = subprocess.Popen(self.command, cwd=self.directory.name, env=self.environment,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                        start_new_session=os.name != "nt")
        self.addCleanup(self.stop)

    def stop(self):
        if self.process.poll() is None:
            if os.name == "nt":
                self.process.terminate()
            else:
                os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                if os.name == "nt":
                    self.process.kill()
                else:
                    os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        self.process.stderr.close()

    def published(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.output.exists():
                try:
                    lines = self.output.read_text(encoding="utf-8").splitlines()
                except PermissionError:  # Windows publisher still holds its write handle.
                    lines = []
                if len(lines) == 3:
                    self.assertEqual(lines[:2], [self.nonce, hashlib.sha256(self.value.encode()).hexdigest()])
                    observed_identity = lines[2]
                    if os.name == "nt":
                        self.assertEqual(observed_identity.casefold(), self.identity.casefold())
                    else:
                        self.assertEqual(observed_identity, self.identity)
                    self.assertIsNone(self.process.poll(), "publisher exited before native identity could be inspected")
                    return self.output.read_bytes()
            if self.process.poll() is not None:
                self.fail("helper exited before publishing: " + self.process.stderr.read().decode(errors="replace"))
            time.sleep(0.02)
        self.fail("helper did not publish its offline observation")

    def test_publication_retains_original_process_until_early_cleanup(self):
        expected = self.published()
        time.sleep(0.25)
        self.assertIsNone(self.process.poll())
        if os.name != "nt":
            argv = subprocess.check_output(["ps", "-p", str(self.process.pid), "-o", "args="], text=True)
            self.assertIn(str(self.helper), argv,
                          "the original helper shell must not exec-replace itself with sleep")
        collision = subprocess.run(self.command, cwd=self.directory.name, env=self.environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=5)
        self.assertNotEqual(collision.returncode, 0, "a repeated invocation must not overwrite or extend the observation")
        self.assertEqual(self.output.read_bytes(), expected)
        self.stop()  # Process-boundary fixture, not a substitute for native owner cleanup proof.
        self.assertIsNotNone(self.process.returncode)
        self.assertEqual(self.output.read_bytes(), expected)

    def test_published_helper_exits_after_one_bounded_lifetime(self):
        expected = self.published()
        published_at = time.monotonic()
        self.assertEqual(self.process.wait(timeout=48), 0)
        elapsed = time.monotonic() - published_at
        self.assertGreaterEqual(elapsed, 43, "the diagnostic lifetime ended before its inspection interval")
        self.assertLess(elapsed, 48, "the diagnostic lifetime was extended")
        self.assertEqual(self.output.read_bytes(), expected)

    def test_relative_and_traversal_paths_refuse_without_publication(self):
        self.published()
        for invalid in ("relative-result", self.directory.name + "/../unexpected-result"):
            command = list(self.command)
            output_index = command.index("-Output:") + 1 if os.name == "nt" else 2
            command[output_index] = invalid
            refused = subprocess.run(command, cwd=self.directory.name, env=self.environment,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=5)
            self.assertNotEqual(refused.returncode, 0)
        self.assertFalse((Path(self.directory.name) / "relative-result").exists())


if __name__ == "__main__":
    unittest.main()

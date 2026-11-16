"""Windows command records are executable-only; arguments remain structured."""
from __future__ import annotations

from pathlib import PureWindowsPath
import unittest
from unittest.mock import patch

from usage_service.protocol import ServiceError
from usage_service.refresh import Refresh
from usage_service import refresh as refresh_module


class WindowsCommandTests(unittest.TestCase):
    def setUp(self):
        self.refresh = object.__new__(Refresh)
        self.addCleanup(patch.stopall)
        patch.object(refresh_module.os, "name", "nt").start()
        patch.object(refresh_module.helper, "Path", PureWindowsPath).start()

    def spec(self, command, arguments, provider="claude"):
        item = {"provider": provider, "source_uid": "S-1-5-21-1000",
                "definition": {"backend": "local-terminal", "command": command,
                               "arguments": arguments}}
        return self.refresh._spec(item)

    def spec_error(self, command, arguments, provider="claude"):
        with self.assertRaises(ServiceError) as caught:
            self.spec(command, arguments, provider)
        return caught.exception.code

    def test_drive_unc_and_unicode_executables_with_structured_arguments(self):
        cases = [
            (r"C:\tools\claude.exe", ["--config-dir", "D:\\Profiles\\Account % & ^ 配置\\"],
             "claude", "CLAUDE_CONFIG_DIR"),
            ("\\\\server\\share\\工具\\codex.exe",
             ["--codex-home", "\\\\server\\profiles\\用户 home % & ^\\"],
             "openai", "CODEX_HOME"),
        ]
        with patch.object(refresh_module.shlex, "split", side_effect=AssertionError("POSIX parsing on Windows")):
            for command, arguments, provider, selector in cases:
                with self.subTest(command=command):
                    result = self.spec(command, arguments, provider)
                    self.assertEqual(result["selectors"], {selector: arguments[1]})
                    self.assertEqual(result["source_uid"], "S-1-5-21-1000")

    def test_structured_and_executable_only_forms_are_equivalent(self):
        cases = [
            ("claude", r"D:\tools\claude.exe", ["--config-dir=D:\\Profiles\\Account\\"], "claude",
             "CLAUDE_CONFIG_DIR"),
            ("codex", "\\\\server\\share\\codex.exe", ["--codex-home=\\\\server\\profiles\\account\\"], "openai",
             "CODEX_HOME"),
        ]
        for executable, absolute, arguments, provider, selector in cases:
            with self.subTest(executable=executable):
                self.assertEqual(self.spec(executable, arguments, provider), self.spec(absolute, arguments, provider))
                self.assertEqual(self.spec(absolute, arguments, provider)["selectors"],
                                 {selector: arguments[0].partition("=")[2]})

    def test_combined_commands_fail_closed_without_posix_parsing(self):
        commands = [
            r"claude --config-dir C:\Profiles\Account",
            r"claude --config-dir=C:\Profiles\Account & whoami",
            r"claude %USERNAME% ^ &",
            r"C:\tools\claude.exe --config-dir C:\Profiles\Account",
            r'"C:\tools\claude.exe" --config-dir "C:\Profiles\Account\\"',
            r"\\server\share\codex.exe --codex-home \\server\profiles\account",
        ]
        with patch.object(refresh_module.shlex, "split", side_effect=AssertionError("POSIX parsing on Windows")):
            for command in commands:
                with self.subTest(command=command):
                    provider = "openai" if "codex" in command else "claude"
                    self.assertEqual(self.spec_error(command, [], provider), "source_context_ambiguous")

    def test_executable_paths_with_spaces_are_ambiguous_and_fail_closed(self):
        commands = [
            r"C:\Provider Tools\Claude\claude.exe",
            r'"C:\Provider Tools\Claude\claude.exe"',
            r"\\server\Provider Tools\Claude\claude.exe",
            "C:\\Provider\tTools\\claude.exe",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(self.spec_error(command, []), "source_context_ambiguous")

    def test_shell_metacharacters_and_trailing_backslashes_are_literal_arguments(self):
        value = "D:\\Profiles\\%USERNAME% & ^ 配置\\"
        result = self.spec(r"C:\tools\claude.exe", ["--config-dir", value])
        self.assertEqual(result["selectors"]["CLAUDE_CONFIG_DIR"], value)

    def test_selector_validation_remains_fail_closed(self):
        ambiguous = [
            ["--config-dir"],
            ["--profile", "work"],
            ["--settings", "D:\\settings.json"],
            ["--api-key", "not-a-real-credential"],
            ["--codex-home", "D:\\codex"],
        ]
        for arguments in ambiguous:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.spec_error("claude", arguments), "source_context_ambiguous")
        for arguments in (["--config-dir", "relative\\profile"], ["--config-dir", ""]):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.spec_error("claude", arguments), "source_profile_invalid")
        self.assertEqual(self.spec_error("codex", ["--config", "model_provider=other"], "openai"),
                         "source_context_ambiguous")


if __name__ == "__main__":
    unittest.main()

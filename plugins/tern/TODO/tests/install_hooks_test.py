"""TODO installer contracts against owned Glitch roots and harness homes."""

from contextlib import redirect_stdout
import errno
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch


PACKAGE = Path(__file__).resolve().parents[1]
INSTALLER = PACKAGE / 'integrations/glitch-plan-session-view/install_hooks.py'


@unittest.skipUnless(sys.platform.startswith('linux'), 'installer qualification uses the Linux host')
class InstallHooksContract(unittest.TestCase):
    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory(prefix='todo-install-')
        self.addCleanup(scratch.cleanup)
        self.base = Path(scratch.name).resolve()
        self.root = self.base / 'Glitch brain'
        self.home = self.base / 'account'
        self.codex_home = self.home / 'custom Codex'
        self.companion = self.root / '_local/tern-todo'
        self.claude = self.root / '.claude/settings.local.json'
        self.codex = self.codex_home / 'hooks.json'
        for directory in (self.root, self.home, self.codex_home, self.root / 'plans', self.root / '_local',
                          self.root / '.claude', self.root / '.claude/skills'):
            directory.mkdir(mode=0o700)
        for relative in ('.claude/scripts/plan_check.py', '.claude/skills/glitch-execute/SKILL.md'):
            marker = self.root / relative
            marker.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            marker.write_text('fixture only\n', encoding='utf-8')
        fake_bin = self.home / 'bin'
        fake_bin.mkdir(mode=0o700)
        self.claude_binary = self.fake_version(fake_bin / 'claude', '2.1.332 (Claude Code)')
        self.codex_binary = self.fake_version(fake_bin / 'codex', 'codex-cli 0.172.0')
        self.env = {'HOME': str(self.home), 'CODEX_HOME': str(self.codex_home),
                    'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'}

    def fake_version(self, path: Path, version: str) -> Path:
        path.write_text('#!/bin/sh\n[ "$1" = --version ] || exit 2\nprintf "%s\\n" ' + shlex.quote(version) + '\n',
                        encoding='utf-8')
        path.chmod(0o700)
        return path

    def arguments(self, action: str = 'install') -> list[str]:
        return ['--root', str(self.root), '--action', action,
                '--claude-executable', str(self.claude_binary), '--codex-executable', str(self.codex_binary)]

    def run_installer(self, action: str = 'install', *, env: dict | None = None,
                      extra: tuple[str, ...] = (), executable: Path = INSTALLER) -> tuple[int, dict]:
        result = subprocess.run(
            [sys.executable, '-I', str(executable), *self.arguments(action), *extra],
            capture_output=True, text=True, env=self.env if env is None else env, timeout=8,
        )
        self.assertTrue(result.stdout, result.stderr)
        return result.returncode, json.loads(result.stdout)

    def successful(self, action: str = 'install') -> dict:
        code, response = self.run_installer(action)
        self.assertEqual((code, response['ok']), (0, True), response)
        return response

    def write_json(self, path: Path, value: dict, *, mode: int = 0o640) -> None:
        path.write_text(json.dumps(value, sort_keys=True) + '\n', encoding='utf-8')
        path.chmod(mode)

    def read_json(self, path: Path) -> dict:
        return json.loads(path.read_text(encoding='utf-8'))

    def mode(self, path: Path) -> int:
        return stat.S_IMODE(path.stat().st_mode)

    def command_group(self, command: str, *, matcher: str | None = None) -> dict:
        group = {'hooks': [{'type': 'command', 'command': command, 'timeout': 5}]}
        if matcher is not None:
            group['matcher'] = matcher
        return group

    def old_claude_configuration(self) -> dict:
        legacy = self.companion / 'entry_hook.py'
        self.companion.mkdir(mode=0o700)
        legacy.write_text('# existing TODO companion\n', encoding='utf-8')
        old = shlex.join(['python3', '-I', str(legacy)])
        unrelated = self.command_group('unrelated-safety-hook', matcher='Read')
        return {
            'permissions': {'allow': ['Read'], 'deny': ['Bash(rm:*)']},
            'hooks': {
                'SessionStart': [self.command_group(old, matcher='startup|resume|clear')],
                'UserPromptSubmit': [self.command_group(old)],
                'PreToolUse': [unrelated, self.command_group(old, matcher='Skill')],
                'Stop': [self.command_group('unrelated-stop-hook')],
            },
        }

    def routed_commands(self, config: Path, runtime: str) -> dict[str, list[list[str]]]:
        owned = {}
        for event, groups in self.read_json(config)['hooks'].items():
            for group in groups:
                for hook in group['hooks']:
                    arguments = shlex.split(hook['command'])
                    if '--harness' in arguments and arguments[arguments.index('--harness') + 1] == runtime:
                        owned.setdefault(event, []).append(arguments)
        return owned

    def test_first_install_uses_custom_home_and_keeps_unrelated_config_and_modes(self) -> None:
        claude_original = {'permissions': {'allow': ['Read']}, 'unknown': ['retained']}
        codex_original = {'hooks': {'PreToolUse': [self.command_group('other-codex-hook')]}, 'unknown': 'retained'}
        self.write_json(self.claude, claude_original)
        self.write_json(self.codex, codex_original, mode=0o600)
        codex_config = self.codex_home / 'config.toml'
        codex_config.write_text('# account-owned settings and trust are out of scope\n', encoding='utf-8')
        home_before = {path.relative_to(self.home) for path in self.home.rglob('*')}
        self.assertEqual(self.successful()['state'], 'installed')
        claude_hooks = self.routed_commands(self.claude, 'claude')
        codex_hooks = self.routed_commands(self.codex, 'codex')
        self.assertEqual(set(claude_hooks), {'UserPromptExpansion', 'PreToolUse', 'SessionStart', 'SessionEnd'})
        self.assertEqual(set(codex_hooks), {'UserPromptSubmit', 'SessionStart', 'SessionEnd'})
        for commands in (*claude_hooks.values(), *codex_hooks.values()):
            self.assertEqual(len(commands), 1)
            command = commands[0]
            self.assertEqual(command[command.index('--root') + 1], str(self.root))
            staged = Path(command[command.index('-I') + 1])
            self.assertTrue(staged.is_relative_to(self.companion / 'versions'))
            self.assertEqual(staged.read_bytes(), (INSTALLER.parent / 'entry_hook.py').read_bytes())
            self.assertEqual((staged.parent / 'bin/todo.py').read_bytes(), (PACKAGE / 'bin/todo.py').read_bytes())
        self.assertEqual({k: self.read_json(self.claude)[k] for k in claude_original}, claude_original)
        self.assertEqual(self.read_json(self.codex)['hooks']['PreToolUse'], codex_original['hooks']['PreToolUse'])
        self.assertEqual((self.mode(self.claude), self.mode(self.codex)), (0o640, 0o600))
        self.assertEqual({path.relative_to(self.home) for path in self.home.rglob('*')}, home_before)
        self.assertEqual(codex_config.read_bytes(), b'# account-owned settings and trust are out of scope\n')

    def test_legacy_upgrade_repeat_and_rollback_keep_unrelated_hooks(self) -> None:
        original = self.old_claude_configuration()
        self.write_json(self.claude, original)
        self.successful()
        current = self.read_json(self.claude)
        self.assertNotIn('UserPromptSubmit', current['hooks'])
        self.assertEqual(current['hooks']['PreToolUse'][0], original['hooks']['PreToolUse'][0])
        prior = [(path.read_bytes(), path.stat().st_ino) for path in (self.claude, self.codex)]
        self.assertEqual((self.successful()['state'], self.successful('check')['state']), ('current', 'checked'))
        self.assertEqual([(path.read_bytes(), path.stat().st_ino) for path in (self.claude, self.codex)], prior)
        after_install = self.command_group('unrelated-post-install')
        current['hooks']['SessionEnd'].append(after_install)
        self.write_json(self.claude, current)
        self.assertEqual(self.successful('rollback')['state'], 'rolled-back')
        self.assertEqual(self.read_json(self.claude), {
            **original, 'hooks': {**original['hooks'], 'SessionEnd': [after_install]},
        })
        if self.codex.exists():
            self.assertFalse(self.read_json(self.codex).get('hooks'))

    def test_remove_does_not_claim_similar_commands_or_touch_other_config(self) -> None:
        self.successful()
        codex = self.read_json(self.codex)
        lookalike = self.command_group('other-wrapper --harness codex --root ' + shlex.quote(str(self.root)))
        codex['hooks']['UserPromptSubmit'].append(lookalike)
        codex['unknown'] = 'retain'
        self.write_json(self.codex, codex, mode=0o600)
        self.assertEqual(self.successful('remove')['state'], 'removed')
        self.assertEqual(self.read_json(self.codex), {'unknown': 'retain', 'hooks': {'UserPromptSubmit': [lookalike]}})
        if self.claude.exists():
            self.assertEqual(self.read_json(self.claude).get('hooks', {}), {})

    def test_malformed_and_linked_config_fail_before_touching_other_target(self) -> None:
        self.write_json(self.claude, {'permissions': {'deny': ['Bash']}})
        prior = self.claude.read_bytes()
        victim = self.base / 'outside.json'
        self.write_json(victim, {'protected': True})
        for variant in ('malformed', 'wrong-shape', 'symlink', 'hardlink'):
            with self.subTest(variant=variant):
                if variant == 'malformed':
                    self.codex.write_bytes(b'{invalid')
                elif variant == 'wrong-shape':
                    self.write_json(self.codex, {'hooks': {'UserPromptSubmit': 'invalid'}})
                elif variant == 'symlink':
                    self.codex.symlink_to(victim)
                else:
                    os.link(victim, self.codex)
                before = self.codex.read_bytes()
                code, result = self.run_installer()
                self.assertEqual((code != 0, result['ok']), (True, False), result)
                self.assertEqual((self.claude.read_bytes(), self.codex.read_bytes()), (prior, before))
                self.codex.unlink()
        self.assertEqual(self.read_json(victim), {'protected': True})

    def test_direct_and_aliased_codex_home_cannot_target_engine_hooks(self) -> None:
        engine = self.root / '.codex'
        engine.mkdir(mode=0o700)
        managed = engine / 'hooks.json'
        self.write_json(managed, {'hooks': {'PreToolUse': [self.command_group('managed-engine-hook')]}})
        prior = managed.read_bytes()
        alias = self.home / 'codex alias'
        alias.symlink_to(engine, target_is_directory=True)
        for value in (engine, alias):
            with self.subTest(target=value):
                code, result = self.run_installer(env={**self.env, 'CODEX_HOME': str(value)})
                self.assertEqual((code != 0, result['ok']), (True, False), result)
                self.assertEqual(managed.read_bytes(), prior)
                self.assertFalse(self.claude.exists())

    def test_codex_disabled_hooks_setting_does_not_get_overridden(self) -> None:
        config = self.codex_home / 'config.toml'
        disabled = b'[features]\nhooks = false\n'
        config.write_bytes(disabled)
        config.chmod(0o600)
        code, result = self.run_installer()
        self.assertEqual((code != 0, result['ok']), (True, False), result)
        self.assertEqual(config.read_bytes(), disabled)
        self.assertFalse(self.claude.exists() or self.codex.exists())

    def test_automatic_route_requires_the_owning_native_tern_process(self) -> None:
        tern = self.base / 'tern'
        data = tern / 'plugin-data/todo'
        for folder in (tern, data.parent, data, tern / 'plugins'):
            folder.mkdir(mode=0o700)
        installed = tern / 'plugins/todo'
        shutil.copytree(PACKAGE, installed, ignore=shutil.ignore_patterns('tests', '__pycache__'))
        env = {**self.env, 'TERN_CONFIG_DIR': str(tern), 'TERN_DAEMON_SOCKET': str(tern / 'absent.sock')}
        code, result = self.run_installer(
            env=env, extra=('--plugin-data', str(data)), executable=installed / INSTALLER.relative_to(PACKAGE),
        )
        self.assertEqual((code != 0, result['ok']), (True, False), result)
        self.assertIn('native Tern daemon', result['message'])
        self.assertFalse(self.claude.exists() or self.codex.exists())

    def module(self) -> ModuleType:
        spec = importlib.util.spec_from_file_location('todo_install_contract', INSTALLER)
        installer = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {spec.name: installer}):
            spec.loader.exec_module(installer)
        return installer

    def run_in_process(self, installer: ModuleType) -> tuple[int, dict]:
        stdout = io.StringIO()
        with patch.dict(os.environ, self.env, clear=True), redirect_stdout(stdout):
            code = installer.main(self.arguments())
        return code, json.loads(stdout.getvalue())

    def test_exclusive_primary_group_relaxation_applies_only_to_executable_paths(self) -> None:
        installer = self.module()
        executable_dir = self.codex_binary.parent
        executable_dir.chmod(0o770)
        group_id = executable_dir.stat().st_gid
        account = SimpleNamespace(pw_gid=group_id, pw_uid=os.geteuid(), pw_name='fixture-owner')
        other = SimpleNamespace(pw_gid=group_id, pw_uid=account.pw_uid + 1, pw_name='fixture-other')
        no_access_acl = OSError(errno.ENODATA, 'no fixture access ACL')
        with (
            patch('pwd.getpwuid', return_value=account),
            patch('pwd.getpwall', return_value=[account]) as accounts,
            patch('grp.getgrgid', return_value=SimpleNamespace(gr_mem=[])),
            patch.object(os, 'getxattr', side_effect=no_access_acl),
        ):
            self.assertEqual(installer._system_executable(self.codex_binary), self.codex_binary)
            accounts.return_value = [account, other]
            with self.assertRaisesRegex(installer.Refused, 'unsafe directory owner or write permission'):
                installer._system_executable(self.codex_binary)
            accounts.return_value = [account]
            self.codex_home.chmod(0o770)
            code, result = self.run_in_process(installer)
        self.assertEqual((code != 0, result['ok'], self.claude.exists(), self.codex.exists()),
                         (True, False, False, False), result)

    def test_interruption_after_a_real_config_write_retries_without_duplicate_entries(self) -> None:
        old_claude = self.old_claude_configuration()
        self.write_json(self.claude, old_claude)
        codex_original = {'unknown': 'retain'}
        self.write_json(self.codex, codex_original)
        installer = self.module()
        apply_change = installer._apply_change

        def stop_after_write(change: dict, observed: object) -> None:
            apply_change(change, observed)
            raise SystemExit('disposable interruption after a durable config write')

        with patch.object(installer, '_apply_change', side_effect=stop_after_write):
            with self.assertRaisesRegex(SystemExit, 'disposable interruption'):
                self.run_in_process(installer)
        changed = [self.read_json(path) != old for path, old in (
            (self.claude, old_claude), (self.codex, codex_original),
        )]
        self.assertEqual(sum(changed), 1)
        self.successful()
        for path, runtime in ((self.claude, 'claude'), (self.codex, 'codex')):
            self.assertEqual({len(commands) for commands in self.routed_commands(path, runtime).values()}, {1})
        self.assertEqual((self.read_json(self.claude)['permissions'], self.read_json(self.codex)['unknown']),
                         (old_claude['permissions'], codex_original['unknown']))

    def test_target_replaced_after_preflight_is_preserved_and_other_changes_are_recovered(self) -> None:
        old_claude = self.old_claude_configuration()
        self.write_json(self.claude, old_claude)
        self.write_json(self.codex, {'unknown': 'original'})
        replacement = self.codex_home / 'writer-new.json'
        self.write_json(replacement, {'unknown': 'independent writer'})
        replacement_bytes = replacement.read_bytes()
        installer = self.module()
        apply_change = installer._apply_change

        def replace_before_validation(change: dict, observed: object) -> None:
            if change['harness'] == 'codex' and replacement.exists():
                os.replace(replacement, self.codex)
            apply_change(change, observed)

        with patch.object(installer, '_apply_change', side_effect=replace_before_validation):
            code, result = self.run_in_process(installer)
        self.assertEqual((code != 0, result['ok']), (True, False), result)
        self.assertEqual((self.codex.read_bytes(), self.read_json(self.claude)), (replacement_bytes, old_claude))

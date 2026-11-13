"""One shared install for several OS accounts: modes, config, read-only at run time, two accounts on one store."""
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

PACKAGE = Path(__file__).resolve().parents[1] / 'glitch-idea'
SCRIPTS = PACKAGE / 'scripts'
INSTALLER = Path(__file__).resolve().parents[1] / 'install.py'
sys.path.insert(0, str(SCRIPTS))
import idea
import idea_tern
from idea_runtime import Runtime, RuntimeError as OwnerError

try:
    import pwd
except ImportError:  # Windows
    pwd = None


def free_ports(count):
    sockets = [socket.socket(socket.AF_INET, socket.SOCK_STREAM) for _ in range(count)]
    try:
        for sock in sockets:
            sock.bind(('127.0.0.1', 0))
        return [sock.getsockname()[1] for sock in sockets]
    finally:
        for sock in sockets:
            sock.close()


def mode(path):
    return stat.S_IMODE(Path(path).stat().st_mode)


def snapshot(root):
    """Every file's hash and every folder, so a new .pyc, cache, lock or log is a difference."""
    result = {}
    for path in sorted(Path(root).rglob('*')):
        relative = path.relative_to(root).as_posix()
        result[relative] = 'dir' if path.is_dir() else hashlib.sha256(path.read_bytes()).hexdigest()
    return result


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source' / 'glitch-idea'
        shutil.copytree(PACKAGE, self.source, ignore=shutil.ignore_patterns('__pycache__', '*.pyc', 'config.json', '.glitch-idea-*'))
        self.skills = self.root / 'skills'
        self.skills.mkdir()
        self.destination = self.skills / 'glitch-idea'
        self.store = self.root / 'ideas'
        self.registry = self.root / 'ports.json'
        self.store.mkdir()  # a shared install never creates the store: the operator does, as the README says
        os.chmod(self.store, 0o2770)

    def write_registry(self, rows):
        self.registry.write_text(json.dumps({'schema': 1, 'host': 'testhost', 'seats': rows}))

    def install(self, *args, success=True):
        result = subprocess.run([sys.executable, str(INSTALLER), '--source', str(self.source), '--skills-root', str(self.skills),
                                 '--store', str(self.store), '--runtime-python', sys.executable, *map(str, args)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['ok'], success)
        return json.loads(result.stdout), result.stderr

    def config(self):
        return json.loads((self.destination / 'config.json').read_text())

    def marker(self):
        return json.loads((self.destination / '.glitch-idea-install.json').read_text())


@unittest.skipUnless(os.name == 'posix', 'shared modes are POSIX')
class SharedInstallTests(Base):
    def test_shared_modes_config_and_marker(self):
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        result, _ = self.install('--shared', '--account-ports-file', self.registry)
        self.assertEqual(result['action'], 'installed')
        self.assertEqual(self.marker()['shared'], True)
        config = self.config()
        self.assertEqual(config['account_ports_file'], str(self.registry))
        self.assertNotIn('browser_port', config)
        self.assertNotIn('prototype_port', config)
        folders = [self.destination, *[p for p in self.destination.rglob('*') if p.is_dir()]]
        files = [p for p in self.destination.rglob('*') if p.is_file()]
        self.assertTrue(files)
        self.assertEqual({oct(mode(p)) for p in folders}, {oct(0o2750)})
        self.assertEqual({oct(mode(p)) for p in files}, {oct(0o640)})
        group = self.skills.stat().st_gid
        self.assertEqual({p.stat().st_gid for p in [*folders, *files]}, {group})

    def test_shared_group_is_the_group_of_the_skills_root(self):
        others = [gid for gid in os.getgroups() if gid != os.getgid()]
        if not others:
            self.skipTest('this account has no second group to prove the group choice with')
        os.chown(self.skills, -1, others[0])
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        self.install('--shared', '--account-ports-file', self.registry)
        self.assertEqual({p.stat().st_gid for p in [self.destination, *self.destination.rglob('*')]}, {others[0]})
        self.assertEqual(mode(self.destination), 0o2750)

    def test_execute_bit_of_a_source_script_is_kept_with_group_read(self):
        runner = self.source / 'scripts' / 'run_me.sh'
        runner.write_text('#!/bin/sh\n')
        runner.chmod(0o755)
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        self.install('--shared', '--account-ports-file', self.registry)
        self.assertEqual(mode(self.destination / 'scripts' / 'run_me.sh'), 0o750)
        self.assertEqual(mode(self.destination / 'scripts' / 'idea.py'), 0o640)

    def test_without_shared_the_install_is_owner_only_and_unmarked(self):
        self.install()
        self.assertNotIn('shared', self.marker())
        self.assertNotIn('account_ports_file', self.config())
        self.assertEqual(mode(self.destination), 0o700)
        self.assertEqual(mode(self.destination) & 0o2077, 0)

    def test_fresh_shared_install_without_a_registry_is_refused(self):
        result, _ = self.install('--shared', success=False)
        self.assertEqual(result['error']['code'], 'install_error')
        self.assertIn('--account-ports-file', result['error']['message'])
        self.assertFalse(self.destination.exists())

    def test_relative_registry_is_refused(self):
        result, _ = self.install('--shared', '--account-ports-file', 'ports.json', success=False)
        self.assertIn('absolute', result['error']['message'])

    def test_upgrade_from_a_non_shared_config_drops_inline_ports_and_says_so(self):
        (self.source / 'config.json').write_text(json.dumps({'store_path': str(self.store), 'browser_port': 41500,
                                                             'prototype_port': 41501}))
        self.install()
        self.assertEqual(self.config()['browser_port'], 41500)
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        result, stderr = self.install('--shared', '--account-ports-file', self.registry)
        self.assertEqual(result['action'], 'upgraded')
        config = self.config()
        self.assertNotIn('browser_port', config)
        self.assertNotIn('prototype_port', config)
        self.assertEqual(config['account_ports_file'], str(self.registry))
        self.assertEqual(self.marker()['shared'], True)
        lines = [line for line in stderr.splitlines() if 'Dropped' in line]
        self.assertEqual(len(lines), 1, stderr)
        self.assertIn('browser_port', lines[0])

    def test_an_installed_config_that_has_the_key_needs_no_flag_to_stay_shared(self):
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        self.install('--shared', '--account-ports-file', self.registry)
        result, _ = self.install('--shared')
        self.assertEqual(result['action'], 'unchanged')
        self.assertEqual(self.config()['account_ports_file'], str(self.registry))

    def test_going_shared_again_changes_a_non_shared_install_even_with_equal_files(self):
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        self.install('--account-ports-file', self.registry)
        self.assertNotIn('shared', self.marker())
        result, _ = self.install('--shared')
        self.assertEqual(result['action'], 'upgraded')
        self.assertEqual(mode(self.destination), 0o2750)

    def test_key_beside_inline_ports_is_refused_without_shared(self):
        (self.source / 'config.json').write_text(json.dumps({'store_path': str(self.store), 'browser_port': 41500}))
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        result, _ = self.install('--account-ports-file', self.registry, success=False)
        self.assertIn('two sources of one fact', result['error']['message'])

    def test_shared_takes_no_runtime_root(self):
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        result, _ = self.install('--shared', '--account-ports-file', self.registry,
                                 '--runtime-root', self.root / 'rt', success=False)
        self.assertIn('runtime_root', result['error']['message'])
        self.assertFalse(self.destination.exists())

    def test_dry_run_reports_the_shared_facts_and_writes_nothing(self):
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        result, _ = self.install('--shared', '--account-ports-file', self.registry, '--dry-run')
        self.assertTrue(result['dry_run'])
        self.assertEqual(result['action'], 'installed')
        self.assertEqual(result['shared']['account_ports_file'], str(self.registry))
        self.assertEqual((result['shared']['folder_mode'], result['shared']['file_mode']), ('2750', '640'))
        self.assertTrue(result['shared']['group'])
        self.assertFalse(self.destination.exists())
        plain, _ = self.install('--dry-run')
        self.assertNotIn('shared', plain)

    def test_an_owner_only_store_is_refused_with_the_command_to_run(self):
        os.chmod(self.store, 0o700)
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        result, _ = self.install('--shared', '--account-ports-file', self.registry, success=False)
        message = result['error']['message']
        self.assertIn('chmod 2770', message)
        self.assertIn(str(self.store), message)
        self.assertFalse(self.destination.exists())
        self.assertEqual(mode(self.store), 0o700)

    def test_a_group_safe_store_is_accepted_and_left_alone(self):
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        result, _ = self.install('--shared', '--account-ports-file', self.registry)
        self.assertEqual(result['store']['status'], 'ready')
        self.assertEqual(mode(self.store), 0o2770)

    def tree(self):
        """Every path under the temp root with its mode, group and content hash: any change on disk shows."""
        result = {}
        for path in sorted([self.root, *self.root.rglob('*')]):
            info = path.lstat()
            result[str(path)] = (stat.S_IMODE(info.st_mode), info.st_gid,
                                 None if path.is_dir() or path.is_symlink() else hashlib.sha256(path.read_bytes()).hexdigest())
        return result

    def refused(self, *needles, dry_run=False):
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        before = self.tree()
        args = ['--shared', '--account-ports-file', self.registry] + (['--dry-run'] if dry_run else [])
        result, _ = self.install(*args, success=False)
        for needle in needles:
            self.assertIn(needle, result['error']['message'])
        self.assertEqual(self.tree(), before, 'a refused install changes nothing on disk')
        self.assertFalse(self.destination.exists())
        return result['error']['message']

    def test_an_absent_store_is_refused_and_nothing_is_created(self):
        self.store.rmdir()
        message = self.refused('does not', 'mkdir', 'chgrp', 'chmod 2770')
        self.assertIn(self.store.name, message)
        self.assertFalse(self.store.exists())

    def test_a_dry_run_changes_nothing_and_reports_the_store(self):
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        before = self.tree()
        result, _ = self.install('--shared', '--account-ports-file', self.registry, '--dry-run')
        self.assertEqual(result['store']['status'], 'ready')
        self.assertEqual(self.tree(), before)

    def test_a_refused_dry_run_also_changes_nothing(self):
        os.chmod(self.store, 0o700)
        self.refused('chmod 2770', dry_run=True)

    def test_a_group_unsafe_root_is_refused_whatever_the_contents(self):
        for wanted in (0o700, 0o750, 0o770, 0o2750):
            os.chmod(self.store, wanted)
            self.refused('chmod 2770')

    def test_a_private_file_or_folder_inside_is_refused_with_its_path(self):
        (self.store / 'state.json').write_text('{}')
        os.chmod(self.store / 'state.json', 0o600)
        (self.store / 'sub').mkdir()
        os.chmod(self.store / 'sub', 0o700)
        message = self.refused(str(self.store / 'state.json'), str(self.store / 'sub'), '2 entries', 'chgrp -R', 'find')
        self.assertIn('-exec chmod 2770', message)
        self.assertIn('chmod 660', message)

    def test_an_entry_in_another_group_is_refused_even_with_good_modes(self):
        others = [gid for gid in os.getgroups() if gid != os.getgid()]
        if not others:
            self.skipTest('this account has no second group')
        stray = self.store / 'stray.json'
        stray.write_text('{}')
        os.chmod(stray, 0o660)
        os.chown(stray, -1, others[0])
        self.refused(str(stray), 'belongs to group')

    def test_the_refusal_lists_at_most_five_examples_and_counts_all(self):
        for index in range(8):
            (self.store / f'f{index}').write_text('x')
            os.chmod(self.store / f'f{index}', 0o600)
        message = self.refused('8 entries')
        self.assertEqual(message.count(str(self.store / 'f')), 5)

    def test_a_symlink_inside_is_refused_and_a_linked_root_is_judged_at_its_target(self):
        (self.store / 'link').symlink_to(self.root)
        self.refused('symlink', str(self.store / 'link'))
        (self.store / 'link').unlink()
        real = self.root / 'real-store'
        self.store.rmdir()
        real.mkdir()
        os.chmod(real, 0o2770)
        self.store.symlink_to(real)
        # The installer stores the resolved location (as it always has), so the runtime never meets the link:
        # the gate judges the real folder it will use.
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        self.install('--shared', '--account-ports-file', self.registry)
        self.assertEqual(self.config()['store_path'], str(real))

    def test_the_entry_count_is_bounded(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('installer_bound', INSTALLER)
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        for index in range(6):
            (self.store / f'f{index}').write_text('x')
            os.chmod(self.store / f'f{index}', 0o660)
        installer.STORE_ENTRY_LIMIT = 5
        with self.assertRaises(installer.InstallError) as caught:
            installer._store_gate(self.store, self.skills)
        self.assertIn('more than 5 entries', str(caught.exception))
        installer.STORE_ENTRY_LIMIT = 6
        self.assertEqual(installer._store_gate(self.store, self.skills)['entries'], 6)

    def test_a_control_character_in_the_registry_path_is_refused_at_install(self):
        for bad in ('/tmp/a\nb.json', '/tmp/a\x01b.json', '/tmp/a\x7fb.json'):
            result, _ = self.install('--shared', '--account-ports-file', bad, success=False)
            self.assertIn('clean text', result['error']['message'])
            self.assertFalse(self.destination.exists())

    def test_the_installers_clean_text_rule_agrees_with_the_helpers(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('installer_clean', INSTALLER)
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        samples = ['/a/b', '/a\nb', '/a\x00b', '/a\x1fb', '/a b', '/a\x7fb', '/a\ud800b', '', '   ', '/é/ü', '/' + 'x' * 4096,
                   '/' + 'x' * 4095, 7, None]
        for sample in samples:
            self.assertEqual(installer._clean_text(sample), idea._clean_text(sample), repr(sample))
            self.assertEqual(installer._clean_text(sample, 256), idea._clean_text(sample, 256), repr(sample))

    def test_the_installers_store_rule_agrees_with_the_platforms_definition(self):
        import importlib.util
        import idea_platform
        spec = importlib.util.spec_from_file_location('installer_under_test', INSTALLER)
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        for index, wanted in enumerate((0o700, 0o750, 0o770, 0o775, 0o2700, 0o2750, 0o2770, 0o2775, 0o1770, 0o3770)):
            folder = self.root / f'store-{index}'
            folder.mkdir()
            os.chmod(folder, wanted)
            try:
                installer._store_gate(folder, self.skills)
                accepted = True
            except installer.InstallError:
                accepted = False
            self.assertEqual(accepted, idea_platform.is_shared_root(folder), oct(wanted))

    def test_a_rerun_repairs_drifted_modes_group_and_executable_bits(self):
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        self.install('--shared', '--account-ports-file', self.registry)
        target = self.destination / 'scripts' / 'idea.py'
        os.chmod(target, 0o600)
        result, _ = self.install('--shared')
        self.assertEqual(result['action'], 'repaired')
        self.assertEqual(mode(target), 0o640)
        os.chmod(self.destination / 'scripts', 0o755)
        self.assertEqual(self.install('--shared')[0]['action'], 'repaired')
        self.assertEqual(mode(self.destination / 'scripts'), 0o2750)
        self.assertEqual(self.install('--shared')[0]['action'], 'unchanged')
        runner = self.source / 'scripts' / 'run_me.sh'
        runner.write_text('#!/bin/sh\n')
        self.install('--shared')
        runner.chmod(0o755)
        self.assertEqual(self.install('--shared')[0]['action'], 'repaired')
        self.assertEqual(mode(self.destination / 'scripts' / 'run_me.sh'), 0o750)
        runner.chmod(0o644)
        self.assertEqual(self.install('--shared')[0]['action'], 'repaired')
        self.assertEqual(mode(self.destination / 'scripts' / 'run_me.sh'), 0o640)

    def test_a_rerun_repairs_a_drifted_group(self):
        others = [gid for gid in os.getgroups() if gid != os.getgid()]
        if not others:
            self.skipTest('this account has no second group')
        self.write_registry({'alice': {'browser_port': 41001, 'prototype_port': 41002}})
        self.install('--shared', '--account-ports-file', self.registry)
        os.chown(self.destination / 'config.json', -1, others[0])
        self.assertEqual(self.install('--shared')[0]['action'], 'repaired')
        self.assertEqual((self.destination / 'config.json').stat().st_gid, self.skills.stat().st_gid)


@unittest.skipUnless(os.name == 'posix', 'accounts and symlinks are POSIX')
class SharedRunTimeTests(Base):
    def setUp(self):
        super().setUp()
        try:
            import yaml  # noqa: F401
        except ImportError:
            self.skipTest('the runtime interpreter needs PyYAML')
        for name, value in (('default_is_tern', False), ('find_terminal', None)):
            patcher = patch.object(idea_tern, name, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.ports = free_ports(4)
        self.account = pwd.getpwuid(os.getuid()).pw_name

    def stop(self, store, runtime):
        client = Runtime(store, runtime)
        try:
            client.request_owned_stop(timeout=3)
        except OwnerError as exc:
            if exc.code != 'owner_unavailable':
                raise
        deadline = time.monotonic() + 4
        while (client.path / 'discovery.json').exists() and time.monotonic() < deadline:
            time.sleep(.02)

    def request(self, opened, operation, payload=None, cookie=None, csrf=None, tab=None):
        port = int(opened['origin'].split(':')[-1].rstrip('/'))
        headers = {'X-Idea-Binding': opened['binding_id']}
        if cookie:
            headers['Cookie'] = cookie
            headers['X-Idea-Tab'] = tab
        if payload is not None:
            headers.update({'Content-Type': 'application/json', 'Origin': opened['origin'].rstrip('/')})
            if csrf:
                headers['X-CSRF-Token'] = csrf
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
        try:
            connection.request('POST' if payload is not None else 'GET', '/api/v1/' + operation,
                               None if payload is None else json.dumps(payload), headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read()), response.getheader('Set-Cookie')
        finally:
            connection.close()

    def capture(self, opened, text, request_id):
        status, paired, cookie = self.request(opened, 'pair', {'code': opened['pairing_code']})
        self.assertEqual(status, 200, paired)
        cookie, csrf, tab = cookie.split(';', 1)[0], paired['csrf_token'], paired['tab_secret']
        workspace = self.root / 'workspace'
        workspace.mkdir(exist_ok=True)
        payload = dict(request_id=request_id, raw_text=text, workspace=dict(name='Explicit', path=str(workspace), confirmed=True))
        status, captured, _ = self.request(opened, 'capture', payload, cookie, csrf, tab)
        return status, captured

    def shared_install(self, rows):
        self.write_registry(rows)
        self.install('--shared', '--account-ports-file', self.registry)

    def test_nothing_is_written_inside_a_shared_install_while_it_runs(self):
        self.shared_install({self.account: {'browser_port': self.ports[0], 'prototype_port': self.ports[1]}})
        link_home = self.root / 'account-skills'
        link_home.mkdir()
        link = link_home / 'glitch-idea'
        link.symlink_to(self.destination)
        before = snapshot(self.destination)
        env = {key: value for key, value in os.environ.items() if key != 'PYTHONDONTWRITEBYTECODE'}
        env['HOME'] = str(self.root / 'home')
        runtime = self.root / 'runtime'

        def cli(*args, ok=True):
            result = subprocess.run([sys.executable, str(link / 'scripts' / 'idea.py'), '--store', str(self.store), *map(str, args)],
                                    capture_output=True, timeout=30, env=env)
            self.assertEqual(result.returncode, 0 if ok else 1, result.stdout + result.stderr)
            return json.loads(result.stdout)
        try:
            opened = cli('session-open', '--runtime-root', runtime)
            self.assertEqual(int(opened['origin'].rstrip('/').rsplit(':', 1)[1]), self.ports[0])
            status, captured = self.capture(opened, 'A shared idea', 'read-only-sweep')
            self.assertEqual(status, 200, captured)
            self.assertEqual(cli('list')['order'], [captured['idea_id']])
        finally:
            self.stop(self.store, runtime)
        after = snapshot(self.destination)
        self.assertEqual(after, before)
        self.assertEqual([name for name in after if name.endswith('.pyc') or '__pycache__' in name], [])

    def installer(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('installer_runtime', INSTALLER)
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        return installer

    def test_a_store_the_runtime_wrote_under_a_shared_root_passes_the_gate(self):
        self.shared_install({self.account: {'browser_port': self.ports[0], 'prototype_port': self.ports[1]}})
        runtime = self.root / 'runtime'
        output = type('Output', (), {'buffer': io.BytesIO()})()
        installed_script = self.destination / 'scripts' / 'idea.py'
        try:
            with patch.object(idea, '__file__', str(installed_script)), patch.object(idea.sys, 'stdout', output):
                self.assertEqual(idea.main(['session-open', '--runtime-root', str(runtime), '--readiness-timeout', '5']), 0)
            opened = json.loads(output.buffer.getvalue())
            self.assertEqual(self.capture(opened, 'Written by the runtime', 'gate-proof')[0], 200)
        finally:
            self.stop(self.store, runtime)
        entries = [p for p in self.store.rglob('*')]
        self.assertGreater(len(entries), 3, 'the runtime wrote a real store')
        facts = self.installer()._store_gate(self.store, self.skills)
        self.assertEqual(facts['status'], 'ready')
        self.assertEqual(facts['entries'], len(entries))

    def test_a_sealed_read_only_file_is_what_the_runtime_writes_for_blobs_and_passes(self):
        installer = self.installer()
        blobs = self.store / 'assets' / 'blobs'
        blobs.mkdir(parents=True)
        os.chmod(self.store / 'assets', 0o2770)
        os.chmod(blobs, 0o2770)
        sealed = blobs / 'a.bin'
        sealed.write_bytes(b'x')
        os.chmod(sealed, 0o440)
        self.assertEqual(installer._store_gate(self.store, self.skills)['status'], 'ready')
        os.chmod(sealed, 0o400)  # owner-only seal of a single-account store: the group cannot read it
        with self.assertRaises(installer.InstallError) as caught:
            installer._store_gate(self.store, self.skills)
        self.assertIn(str(sealed), str(caught.exception))

    def test_the_sweep_would_catch_a_bytecode_write(self):
        """The sweep's own control: a non-shared install does write bytecode when it runs, and the snapshot sees it."""
        self.install()
        before = snapshot(self.destination)
        env = {key: value for key, value in os.environ.items() if key != 'PYTHONDONTWRITEBYTECODE'}
        subprocess.run([sys.executable, str(self.destination / 'scripts' / 'idea.py'), '--store', str(self.store), 'list'],
                       capture_output=True, timeout=30, env=env, check=True)
        self.assertNotEqual(snapshot(self.destination), before)

    def test_two_accounts_on_one_store_both_save_an_idea(self):
        self.shared_install({'alice': {'browser_port': self.ports[0], 'prototype_port': self.ports[1]},
                             'bob': {'browser_port': self.ports[2], 'prototype_port': self.ports[3]}})
        roots = {'alice': self.root / 'runtime-alice', 'bob': self.root / 'runtime-bob'}
        self.addCleanup(lambda: [self.stop(self.store, root) for root in roots.values()])
        installed_script = self.destination / 'scripts' / 'idea.py'
        opened = {}
        for account in ('alice', 'bob'):
            output = type('Output', (), {'buffer': io.BytesIO()})()
            with patch.object(idea, '__file__', str(installed_script)), \
                    patch.object(idea, '_account_name', lambda account=account: account), \
                    patch.object(idea.sys, 'stdout', output):
                status = idea.main(['session-open', '--runtime-root', str(roots[account]), '--readiness-timeout', '5'])
            body = json.loads(output.buffer.getvalue())
            self.assertEqual(status, 0, body)
            opened[account] = body
        self.assertEqual(int(opened['alice']['origin'].rstrip('/').rsplit(':', 1)[1]), self.ports[0])
        self.assertEqual(int(opened['bob']['origin'].rstrip('/').rsplit(':', 1)[1]), self.ports[2])
        self.assertNotEqual(opened['alice']['identity']['instance_nonce'], opened['bob']['identity']['instance_nonce'])
        saved = {}
        for account in ('alice', 'bob'):
            status, captured = self.capture(opened[account], f'Idea from {account}', f'two-accounts-{account}')
            self.assertEqual(status, 200, captured)
            self.assertNotIn(captured.get('error', {}).get('code'), ('runtime_busy', 'busy'))
            saved[account] = captured['idea_id']
        output = type('Output', (), {'buffer': io.BytesIO()})()
        with patch.object(idea, '__file__', str(installed_script)), \
                patch.object(idea, '_account_name', lambda: 'bob'), patch.object(idea.sys, 'stdout', output):
            idea.main(['list'])
        listed = json.loads(output.buffer.getvalue())
        self.assertEqual(sorted(listed['order']), sorted(saved.values()))


if __name__ == '__main__':
    unittest.main()

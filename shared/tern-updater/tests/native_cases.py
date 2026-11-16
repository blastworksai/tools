#!/usr/bin/env python3
"""One selected updater scenario in a supervised private native runtime.

No default all-cases pass. Every run keeps its owned files, including failures.
Git installation uses the product's literal GitHub source, redirected by an
owned HOME's Git configuration to an actual local default-branch repository.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

TESTS = Path(__file__).resolve().parent
REPORT_TESTS = TESTS.parents[1] / 'report-files-v1/tests'
if str(REPORT_TESTS) not in sys.path:
    sys.path.insert(0, str(REPORT_TESTS))
from owned_runtime import owned_runtime
from native_smoke import supervisor
from product_scenario import window_diagnostics


def library():
    spec = importlib.util.spec_from_file_location('updater_case_isolation', TESTS / 'updater_smoke.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.get('children', []):
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def label(node):
    return ' '.join(str(child['text']) for child in nodes(node) if child.get('text')).strip()


class Scenario:
    def __init__(self, lib, base, evidence, processes, sweep):
        self.lib, self.base, self.evidence, self.sweep = lib, base, evidence, sweep
        self.runtime = owned_runtime(lib, base, 'runtime', evidence, processes, capture_desktop=True)
        self.runtime.root.chmod(0o700)
        self.pub = base / 'preview'
        self.pub.mkdir()
        self.server = lib.Server(self.pub)
        self.raw = f'http://127.0.0.1:{self.server.port}/'
        self.gate = base / 'git-gate'
        self.gate.mkdir()

    def prepare(self, *, linked=False, legacy=False, gated=False, consumer=None, response_delay=False):
        lib, base = self.lib, self.base
        self.repo = base / 'git-origin'
        self.repo.mkdir()
        self.git_binary = shutil.which('git')
        if self.git_binary is None:
            raise RuntimeError('actual Git is required for the Git-source fixture')
        self.git('init', '--initial-branch=main')
        self.git('config', 'user.name', 'Updater isolated fixture')
        self.git('config', 'user.email', 'updater-fixture@example.invalid')
        self.bare = base / 'origin.git'
        subprocess.run([self.git_binary, 'init', '--bare', '--initial-branch=main', str(self.bare)],
                       env=self.runtime.env, capture_output=True, text=True, timeout=30, check=True)
        self.git('remote', 'add', 'origin', str(self.bare))
        self.directory = consumer.name if consumer else 'FIXTURE'
        self.package = base / 'initial-package'
        self.source = self.repo / 'plugins/tern' / self.directory
        self.source.parent.mkdir(parents=True)
        if consumer:
            shutil.copytree(consumer, self.package, ignore=shutil.ignore_patterns('.git', '__pycache__', '*.local'))
            lib.vendor(self.package, False)
            lib.rewrite_base(self.package / 'updater/source.luau', 'RAW_BASE', self.raw)
            self.plugin_id = lib.manifest_value(self.package / 'plugin.toml', 'id')
            self.initial = lib.manifest_value(self.package / 'plugin.toml', 'version')
            version = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)', self.initial)
            if version is None:
                raise RuntimeError('consumer fixture requires an exact three-component version')
            self.preview = f'{version[1]}.{version[2]}.{int(version[3]) + 1}'
            self.name = consumer.name
            self.install_dependencies(consumer)
        else:
            lib.build_fixture(self.package, '0.1.0', self.raw)
            self.plugin_id, self.initial, self.preview, self.name = lib.FIXTURE_ID, '0.1.0', '0.2.0', 'FIXTURE'
        if response_delay:
            cli = self.package / 'updater/cli.luau'
            content = cli.read_text()
            marker = 'local ok, err = pcall(tern.process.run, argv, { timeout_ms = timeout_ms, env = environment(route) }, function(result, cx)'
            assert content.count(marker) == 1
            supervisor_argv = [sys.executable, str(TESTS / 'install_response_gate.py'), str(self.gate)]
            instrumented = ('local actual_argv = argv\n'
                            '\tif argv[2] == "plugin" and argv[3] == "install" then\n'
                            '\t\tactual_argv = { ' + ', '.join(json.dumps(value) for value in supervisor_argv) + ' }\n'
                            '\t\tfor _, value in ipairs(argv) do table.insert(actual_argv, value) end\n'
                            '\tend\n\t' + marker.replace('run, argv,', 'run, actual_argv,'))
            cli.write_text(content.replace(marker, instrumented))
            self.evidence['response_delay_fixture'] = {
                'supervisor': supervisor_argv, 'unchanged_native_timeout_ms': 180000,
                'scope': 'Only the private install invocation is supervised; the real native child performs replacement and returns its own stdout/stderr/status.',
                'fixture_cli_sha256': hashlib.sha256(cli.read_bytes()).hexdigest(),
                'supervisor_sha256': hashlib.sha256((TESTS / 'install_response_gate.py').read_bytes()).hexdigest(),
            }
        shutil.copytree(self.package, self.source)
        lib.set_manifest(self.source / 'plugin.toml', version=self.preview)
        self.commit('Initial preview on actual default branch')
        self.publish_preview()
        self.data = self.runtime.config / 'plugin-data' / self.plugin_id
        self.journal = self.data / 'updater'
        self.home = Path(self.runtime.env['HOME'])
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        self.git_url = f'git://127.0.0.1:{port}/origin.git'
        daemon = self.runtime.spawn([self.git_binary, 'daemon', '--reuseaddr', '--listen=127.0.0.1',
                                     '--port=' + str(port), '--base-path=' + str(base), '--export-all', str(self.bare)])
        def listening():
            if daemon.poll() is not None:
                raise AssertionError('owned loopback Git daemon exited before readiness')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=1):
                    return True
            except (ConnectionRefusedError, TimeoutError):
                return False
        self.lib.wait_for(listening, 'owned read-only loopback Git service', 10)
        advertised = subprocess.run([self.git_binary, 'ls-remote', self.git_url, 'refs/heads/main'],
                                    env=self.runtime.env, capture_output=True, text=True, timeout=10, check=True).stdout
        assert advertised.split()[0] == self.commits[-1]['commit']
        # Both native URL spellings resolve to this owned repository. No source
        # literal or installer implementation is replaced for Git success cases.
        (self.home / '.gitconfig').write_text(
            '[url ' + json.dumps(self.git_url) + ']\n'
            '\tinsteadOf = https://github.com/blastworksai/tools.git\n'
            '\tinsteadOf = https://github.com/blastworksai/tools\n'
            '[protocol "git"]\n\tallow = always\n', encoding='utf-8')
        self.command_prefix = self.name + (': ' if self.directory in ('SPAWN', 'TODO') else ' ')
        self.install_git_gate(gated)
        if legacy:
            self.data.mkdir(parents=True, exist_ok=True)
            self.legacy = {'pending_from': self.initial, 'pending_to': self.preview, 'pending_at': 1}
            (self.data / 'kv.json').write_text(json.dumps({'updater.v1': self.legacy}) + '\n')
        self.runtime.start()
        self.lib.wait_for(lambda: 'tn-signin-x' in json.dumps(self.runtime.ctl('tree')),
                          'fresh private HOME first-run close control rendered', 20)
        self.runtime.ctl('click', '.tn-signin-x')
        self.lib.wait_for(lambda: self.runtime.checked_state().get('account', {}).get('phase') == 'off'
                          and 'tn-signin-x' not in json.dumps(self.runtime.ctl('tree')),
                          'owned first-run sign-in overlay dismissed without authentication', 10)
        offset = self.runtime.log_offset()
        self.runtime.command('plugin', 'link' if linked else 'install', self.package, timeout=60)
        self.lib.wait_for(lambda: self.runtime.plugins_dir_lines(offset), 'actual consumer updater registration', 45)
        self.runtime.assert_scratch_plugins_dir()
        self.runtime.checked_state()
        self.evidence.update(plugin=self.plugin_id, initial_version=self.initial, preview_version=self.preview,
                             owned_repository=str(self.repo), installed_source='github.com/blastworksai/tools/plugins/tern/' + self.directory)
        self.evidence.update(bare_repository=str(self.bare), loopback_git_url=self.git_url,
                             advertised_default_branch_commit=advertised.split()[0])
        self.evidence['source_commits'] = self.commits
        self.check('private daemon, HOME and actual window are isolated')

    def git(self, *args):
        result = subprocess.run([self.git_binary, '-C', str(self.repo), *args], env=self.runtime.env,
                                capture_output=True, text=True, timeout=30, check=True)
        return result.stdout.strip()

    def commit(self, message):
        self.git('add', 'plugins')
        self.git('commit', '-q', '-m', message)
        self.git('push', 'origin', 'HEAD:refs/heads/main')
        if not hasattr(self, 'commits'):
            self.commits = []
        self.commits.append({'commit': self.git('rev-parse', 'HEAD'), 'branch': self.git('branch', '--show-current'), 'message': message})
        assert self.commits[-1]['branch'] == 'main'

    def publish_preview(self):
        target = self.pub / self.directory
        target.mkdir(exist_ok=True)
        shutil.copy2(self.source / 'plugin.toml', target / 'plugin.toml')
        requirement = self.source / 'requires.json'
        if requirement.exists():
            shutil.copy2(requirement, target / 'requires.json')
        else:
            (target / 'requires.json').unlink(missing_ok=True)

    def install_dependencies(self, consumer):
        requirement = consumer / 'requires.json'
        required = json.loads(requirement.read_text()).get('plugins', {}) if requirement.exists() else {}
        candidates = {}
        for path in consumer.parent.iterdir():
            if path.is_dir() and (path / 'plugin.toml').is_file():
                candidates[self.lib.manifest_value(path / 'plugin.toml', 'id')] = path
        for plugin_id in sorted(required):
            source = candidates.get(plugin_id)
            if source is None:
                raise RuntimeError('required consumer dependency has no owned source: ' + plugin_id)
            copied = self.base / 'dependencies' / source.name
            copied.parent.mkdir(exist_ok=True)
            shutil.copytree(source, copied, ignore=shutil.ignore_patterns('.git', '__pycache__', '*.local'))
            self.lib.vendor(copied, False)
            self.lib.rewrite_base(copied / 'updater/source.luau', 'RAW_BASE', self.raw)
            self.runtime.command('plugin', 'install', copied, timeout=60)

    def install_git_gate(self, gated):
        tools = self.base / 'owned-bin'
        tools.mkdir()
        script = tools / 'git'
        # Only the fixture clone is gated. Version/config commands still execute
        # actual Git. The bounded wait never retries a clone or an installation.
        code = '#!' + sys.executable + '\n'
        code += 'import json, os, pathlib, sys, time\n'
        code += 'root = pathlib.Path(' + repr(str(self.gate)) + ')\n'
        code += 'args = sys.argv[1:]\n'
        code += 'with (root / "calls.jsonl").open("a") as stream: stream.write(json.dumps(args) + "\\n")\n'
        code += 'if (root / "unavailable").exists(): sys.exit(127)\n'
        code += 'if "clone" in args:\n'
        code += '    with (root / "clones.jsonl").open("a") as stream: stream.write(json.dumps(args) + "\\n")\n'
        code += '    identities = []\n'
        code += '    for pid in (os.getpid(), os.getppid()):\n'
        code += '        stat = pathlib.Path("/proc", str(pid), "stat").read_text().rsplit(")", 1)[1].split()\n'
        code += '        identities.append({"pid": pid, "start_ticks": int(stat[19])})\n'
        code += '    (root / "installer-processes.json").write_text(json.dumps(identities))\n'
        if gated:
            code += '    (root / "started").write_text("clone admitted\\n")\n'
            code += '    deadline = time.monotonic() + 300\n'
            code += '    while not (root / "release").exists():\n'
            code += '        if time.monotonic() >= deadline: sys.exit(124)\n'
            code += '        time.sleep(0.1)\n'
        code += 'os.execv(' + repr(self.git_binary) + ', [' + repr(self.git_binary) + '] + args)\n'
        script.write_text(code)
        script.chmod(0o700)
        self.runtime.env['PATH'] = str(tools) + os.pathsep + self.runtime.env['PATH']

    def clones(self):
        path = self.gate / 'clones.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def records(self):
        rows = []
        if self.journal.exists():
            for path in sorted(self.journal.iterdir()):
                raw = path.read_bytes()
                try:
                    value = json.loads(raw)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    value = None
                rows.append({'path': str(path), 'sha256': hashlib.sha256(raw).hexdigest(), 'record': value})
        return rows

    def retained(self, label):
        rows = self.records()
        self.evidence.setdefault('journal_observations', []).append({'label': label, 'rows': rows})
        return rows

    def check(self, description):
        self.sweep.check(description)
        self.evidence['checks'].append(description)

    def action(self, name):
        return self.runtime.run('plugin.' + self.plugin_id + '.' + name)

    def choose(self, starts_with, *, second=False):
        def control(*parts):
            if not second:
                return self.runtime.ctl(*parts)
            return second_control(self, *parts)
        def offered():
            matches = [node for node in nodes(control('tree').get('tree', []))
                       if node.get('role') == 'option' and label(node).startswith(starts_with)]
            return matches[0] if len(matches) == 1 else None
        row = self.lib.wait_for(offered, 'unique rendered choice: ' + starts_with, 40)
        x, y, width, height = row['rect']
        self.evidence.setdefault('native_inputs', []).append({'choice': label(row), 'rect': row['rect'], 'second_window': second})
        return control('click', str(x + width / 2), str(y + height / 2))

    def ready_update(self):
        self.action('check_updates')
        self.lib.wait_for(lambda: self.runtime.shows(self.command_prefix + 'Update', self.name), 'update action available', 40)

    def confirmation(self):
        self.ready_update()
        self.action('install_update')
        self.lib.wait_for(self.runtime.picker, 'native update confirmation', 40)
        self.runtime.assert_scratch_plugins_dir()
        self.check('pre-effect native confirmation points only at owned package directory')
        self.evidence['confirmation'] = self.runtime.picker()

    def accept(self):
        self.choose('Update ' + self.name + ' ' + self.initial + ' → ' + self.preview)

    def release(self):
        (self.gate / 'release').write_text('one admitted clone may continue\n')

    def installed(self, version):
        return self.lib.wait_for(lambda: self.runtime.version(self.plugin_id) == version, 'actual installed version ' + version, 90)

    def resolved(self):
        self.lib.wait_for(lambda: not self.records(), 'all presented updater outcomes released their exact journal files', 60)

    def settle_or_resolve_unknown(self, expected_version=None):
        expected_version = expected_version or self.preview
        def observed():
            rows = self.records()
            if not rows:
                return {'settled': True}
            if len(rows) == 1 and rows[0]['record']:
                target = rows[0]['record']['payload']['targets'][0]
                if target.get('phase') == 'unknown' and target.get('observed'):
                    return {'settled': False, 'target': target, 'rows': rows}
            return None
        outcome = self.lib.wait_for(observed, 'fresh installed outcome or explicit retained uncertainty', 60)
        self.evidence.setdefault('installation_outcomes', []).append(outcome)
        if outcome['settled']:
            return
        evidence = outcome['target']['observed']
        assert evidence['installed']['version'] == expected_version
        assert evidence['requirements']['satisfied'] is True and evidence['host']['status'] == 'ready'
        assert evidence['window']['registered'] is True and evidence['window']['version'] == expected_version
        assert evidence['operation'] == 'unknown'
        identities = json.loads((self.gate / 'installer-processes.json').read_text())
        self.lib.wait_for(lambda: not any(process_alive(identity) for identity in identities),
                          'fixture-owned installer process incarnations ended before explicit attestation', 20)
        self.evidence.setdefault('fixture_quiescence_proofs', []).append(identities)
        self.action('resolve_update')
        self.choose('Resolve window ')
        def offered():
            choices = [label(node) for node in nodes(self.runtime.ctl('tree').get('tree', []))
                       if node.get('role') == 'option' and label(node).startswith(
                           ('I confirm the original operation stopped', 'Resolve this target as unverified'))]
            return choices[0] if len(choices) == 1 else None
        choice = self.lib.wait_for(offered, 'explicit unverified outcome choice', 40)
        assert not any(process_alive(identity) for identity in identities)
        self.choose(choice)
        self.resolved()
        self.check('incomplete native inventory stays unknown until explicit fixture-proven stopped-operation resolution')

    def observe(self, title):
        self.evidence.setdefault('native_captures', {})[title] = window_diagnostics(self.runtime, title)
        self.retained(title)

    def close(self):
        self.evidence['server_requests'] = self.server.requests
        self.evidence['git_clone_invocations'] = self.clones()
        self.server.close()
        self.runtime.stop()


def case_git(s):
    initial_hash = s.lib.tree_hash(s.runtime.plugins_dir / s.plugin_id)
    s.confirmation()
    s.choose('Cancel')
    s.lib.wait_for(lambda: not s.runtime.picker(), 'native Cancel actually dismisses the update confirmation', 10)
    assert not s.records() and not s.clones()
    assert s.lib.tree_hash(s.runtime.plugins_dir / s.plugin_id) == initial_hash
    s.check('native cancellation leaves package bytes and install ownership untouched')
    s.confirmation()
    s.accept()
    s.installed(s.preview)
    s.settle_or_resolve_unknown()
    assert len(s.clones()) == 1, s.clones()
    s.observe('git-success')
    s.check('one real default-branch Git installation reaches exact preview and fresh load; any quiescence gap remains explicitly unverified')


def case_tip_movement(s, moved='9.9.9'):
    s.confirmation()
    s.lib.set_manifest(s.source / 'plugin.toml', version=moved)
    s.commit('Move default branch after observed confirmation')
    offset = s.runtime.log_offset()
    s.accept()
    s.installed(moved)
    s.lib.wait_for(lambda: any('preview ' + s.preview in part and 'installed ' + moved in part
                              for notice in s.runtime.notices(offset) for part in notice), 'mismatch outcome presented', 60)
    assert not any('installed on' in part and s.preview in part for notice in s.runtime.notices(offset) for part in notice)
    rows = s.retained('moved-tip-outcome')
    if rows:
        target = rows[0]['record']['payload']['targets'][0]
        assert target['preview'] == s.preview and target['observed']['installed']['version'] == moved
        assert target['phase'] == 'unknown' and target.get('result') is None
    s.settle_or_resolve_unknown(moved)
    assert len(s.clones()) == 1
    s.observe('tip-mismatch')
    s.check('actual moved default branch is disclosed separately from the preview; incomplete quiescence stays held, never preview success')


def case_requirements_pre(s):
    s.ready_update()
    before = s.lib.tree_hash(s.runtime.plugins_dir / s.plugin_id)
    (s.pub / s.directory / 'requires.json').write_text(json.dumps({'schema': 1, 'plugins': {'absent-dependency': '99.0.0'}}))
    offset = s.runtime.log_offset()
    s.action('install_update')
    s.lib.wait_for(lambda: any('absent-dependency' in part for notice in s.runtime.notices(offset) for part in notice),
                   'unmet preview requirements refuse before mutation', 40)
    assert not s.runtime.picker() and not s.records() and not s.clones()
    assert s.lib.tree_hash(s.runtime.plugins_dir / s.plugin_id) == before
    s.observe('requirements-refusal')
    s.check('unmet preview requirements cannot acquire install ownership or alter package bytes')


def case_requirements_post(s):
    s.confirmation()
    (s.source / 'requires.json').write_text(json.dumps({'schema': 1, 'plugins': {'absent-dependency': '99.0.0'}}))
    s.commit('Change actual requirements after preview')
    s.accept()
    s.installed(s.preview)
    def unverified():
        rows = s.records()
        return rows if len(rows) == 1 and rows[0]['record'] and any(
            target.get('phase') == 'unknown' and target.get('observed', {}).get('requirements', {}).get('satisfied') is False
            for target in rows[0]['record']['payload']['targets']) else None
    s.lib.wait_for(unverified, 'fresh actual requirements retain unresolved outcome', 60)
    assert len(s.clones()) == 1
    s.observe('actual-requirements-unverified')
    s.check('same preview version with incompatible actual requirements remains held')


def case_callback_loss(s):
    s.confirmation()
    s.accept()
    s.lib.wait_for((s.gate / 'started').exists, 'real clone is admitted before VM reload', 60)
    before = s.retained('before-callback-loss')
    assert len(before) == 1 and before[0]['record']['payload']['targets'][0]['install']['kind'] == 'install'
    offset = s.runtime.log_offset()
    s.runtime.command('plugin', 'reload', s.plugin_id)
    s.lib.wait_for(lambda: s.runtime.plugins_dir_lines(offset), 'replacement window VM loads retained owner journal', 45)
    rows = s.retained('after-callback-loss')
    assert len(rows) == 1 and rows[0]['record']['attempt'] == before[0]['record']['attempt']
    assert len(s.clones()) == 1
    s.release()
    s.installed(s.preview)
    s.settle_or_resolve_unknown()
    assert len(s.clones()) == 1
    s.observe('callback-loss-recovered')
    s.check('VM callback loss retains the same attempt and observes one real install without replay')


def case_timeout(s):
    s.confirmation()
    s.accept()
    s.lib.wait_for((s.gate / 'started').exists, 'real clone admitted before timeout', 60)
    def timed_out():
        rows = s.records()
        return rows if len(rows) == 1 and rows[0]['record'] and any(
            target.get('install', {}).get('timed_out') is True for target in rows[0]['record']['payload']['targets']) else None
    retained = s.lib.wait_for(timed_out, 'actual native process timeout is retained, not released', 210)
    assert len(s.clones()) == 1 and retained[0]['record']['payload']['targets'][0].get('result') is None
    s.observe('native-timeout-held')
    s.check('actual timeout retains command identity and ownership without automatic retry')
    s.release()


def case_timeout_after_replacement(s):
    s.confirmation()
    s.accept()
    result_path = s.gate / 'real-install-result.json'
    s.lib.wait_for(result_path.exists, 'real installer completed replacement before response delay', 90)
    result = json.loads(result_path.read_text())
    assert result['status'] == 0, result
    s.installed(s.preview)
    supervisor = json.loads((s.gate / 'response-supervisor.json').read_text())
    assert process_alive(supervisor['identity'])
    before = s.retained('replacement-before-native-timeout')
    assert len(before) == 1
    attempt = before[0]['record']['attempt']
    s.lib.wait_for(lambda: not process_alive(supervisor['identity']),
                   'unchanged native timeout ends delayed response supervisor after actual replacement', 210)
    elapsed = time.monotonic() - supervisor['started_monotonic']
    assert 170 <= elapsed < 230, elapsed
    assert not (s.gate / 'response-safety-limit-reached').exists()
    after = s.retained('replacement-after-native-timeout')
    assert len(after) == 1 and after[0]['record']['attempt'] == attempt
    target = after[0]['record']['payload']['targets'][0]
    assert target.get('result') is None and len(s.clones()) == 1
    assert target['observed']['installed']['version'] == s.preview
    assert target['observed']['window']['registered'] is True
    s.evidence['post_replacement_timeout'] = {'real_install_result': result, 'supervisor': supervisor,
                                             'observed_elapsed_seconds': elapsed}
    s.observe('timeout-after-replacement-held')
    s.check('actual replacement and fresh registration survive a lost callback and native response timeout without replay or false success')
    s.settle_or_resolve_unknown()


def case_corrupt(s):
    s.ready_update()
    s.journal.mkdir(parents=True, exist_ok=True)
    path = s.journal / 'unknown.json'
    original = b'{interrupted updater evidence'
    path.write_bytes(original)
    offset = s.runtime.log_offset()
    s.action('install_update')
    s.lib.wait_for(lambda: any('existing update outcome' in part for n in s.runtime.notices(offset) for part in n), 'corrupt journal blocks a new installation', 40)
    assert path.read_bytes() == original and not s.clones()
    s.observe('corrupt-held')
    s.check('corrupt updater evidence is preserved and blocks a competing install')
    s.action('resolve_update')
    s.choose('Resolve unknown updater record')
    s.choose('I confirm the original owner and every original operation stopped')
    s.resolved()
    assert not s.clones() and s.runtime.version(s.plugin_id) == s.initial
    s.check('unknown bytes are removed only through explicit unverified resolution, without an install')


def case_legacy(s):
    s.action('resolve_update')
    s.choose('Adopt legacy updater.v1 outcome')
    s.choose('I confirm the legacy owner and its original operations stopped')
    def adopted():
        rows = s.records()
        return rows if len(rows) == 1 and rows[0]['record'] and rows[0]['record']['payload'].get('legacy') else None
    s.lib.wait_for(adopted, 'file-backed legacy adoption', 40)
    s.lib.wait_for(lambda: s.runtime.kv(s.plugin_id) is None, 'host-owned migration removes only adopted legacy KV', 40)
    assert not s.clones()
    s.retained('host-migrated-legacy')
    s.action('resolve_update')
    s.choose('Resolve window ')
    s.choose('Resolve this target as unverified')
    s.resolved()
    assert not s.clones()
    s.observe('legacy-explicitly-resolved')
    s.check('legacy pending state migrates through its host owner and remains unverified without an install')


def case_link(s):
    path_file = s.runtime.plugins_dir / (s.plugin_id + '.path')
    before = (s.lib.tree_hash(s.package), path_file.read_bytes(), path_file.stat().st_mtime_ns)
    requests = list(s.server.requests)
    offset = s.runtime.log_offset()
    s.action('check_updates')
    s.lib.wait_for(lambda: any('development copy' in part for n in s.runtime.notices(offset) for part in n), 'development link refusal', 40)
    assert not s.runtime.picker() and not s.clones() and not s.records()
    assert before == (s.lib.tree_hash(s.package), path_file.read_bytes(), path_file.stat().st_mtime_ns)
    assert s.server.requests == requests
    s.observe('development-link-protected')
    s.check('linked source, path marker and package bytes remain untouched without a preview fetch')


def second_control(s, *parts):
    if hasattr(s, 'second_socket'):
        result = json.loads(s.runtime.command('ctl', '--control', s.second_socket, *parts))
        assert result.get('ok') is not False, result
        return result
    if parts[0] in ('state', 'plugins'):
        raise AssertionError('second-window actions must use rendered native controls, not root-app dispatch')
    s.runtime.ctl('target', 'window')
    try:
        return s.runtime.ctl(*parts)
    finally:
        s.runtime.ctl('target', 'main')


def prepare_second_window(s):
    before = json.loads(s.runtime.command('inspect', '--json'))['clients']
    original = {(row['window'], row['conn'], row['since']) for row in before if row['kind'] == 'window'}
    s.second_socket = s.runtime.root / 'c2.sock'
    s.runtime.spawn(['xvfb-run', '-a', s.lib.TERN, '--control', str(s.second_socket)], cwd=s.runtime.root)
    s.lib.wait_for(s.second_socket.exists, 'independent second native control socket', 40)
    second_control(s, 'state')
    def appeared():
        clients = json.loads(s.runtime.command('inspect', '--json'))['clients']
        added = [row for row in clients if row['kind'] == 'window'
                 and (row['window'], row['conn'], row['since']) not in original]
        return added[0] if len(added) == 1 else None
    s.evidence['second_window'] = s.lib.wait_for(appeared, 'distinct second native owner incarnation', 40)
    def available(title):
        second_control(s, 'palette', title)
        offered = any(node.get('role') == 'option' and label(node).startswith(title)
                      for node in nodes(second_control(s, 'tree').get('tree', [])))
        second_control(s, 'key', 'Escape')
        return offered
    title = s.command_prefix + 'Check for updates'
    s.lib.wait_for(lambda: available(title), 'second window registers updater controls', 40)
    second_control(s, 'palette', title)
    s.choose(title, second=True)
    s.lib.wait_for(lambda: available(s.command_prefix + 'Update'), 'second independent preview', 40)


def case_competing(s):
    s.ready_update()
    prepare_second_window(s)
    s.confirmation()
    second_control(s, 'palette', s.command_prefix + 'Update')
    s.choose(s.command_prefix + 'Update', second=True)
    prefix = 'Update ' + s.name + ' ' + s.initial + ' → ' + s.preview
    def second_confirmation():
        choices = [node for node in nodes(second_control(s, 'tree').get('tree', []))
                   if node.get('role') == 'option' and label(node).startswith(prefix)]
        return choices[0] if len(choices) == 1 else None
    s.lib.wait_for(second_confirmation, 'second pre-effect confirmation before the first claim', 40)
    s.accept()
    s.lib.wait_for((s.gate / 'started').exists, 'first window owns the admitted real install', 60)
    original = s.retained('first-window-installing')
    assert len(original) == 1
    offset = s.runtime.log_offset()
    choice = second_confirmation()
    assert choice is not None, 'rendered second confirmation disappeared before its owned click'
    x, y, width, height = choice['rect']
    second_control(s, 'click', str(x + width / 2), str(y + height / 2))
    s.lib.wait_for(lambda: any(n and n[0] == 'error' for n in s.runtime.notices(offset)),
                   'second window refuses pending first-window ownership', 40)
    assert len(s.clones()) == 1 and s.records() == original
    second_control(s, 'palette', s.command_prefix + 'Resolve update outcome')
    s.choose(s.command_prefix + 'Resolve update outcome', second=True)
    s.choose('Resolve window ', second=True)
    s.lib.wait_for(lambda: any('owner is still live' in part for n in s.runtime.notices(offset) for part in n),
                   'live original window cannot be overridden by resolution', 40)
    assert s.records() == original and len(s.clones()) == 1
    s.observe('competing-owner-refused')
    s.release()
    s.installed(s.preview)
    s.settle_or_resolve_unknown()
    assert len(s.clones()) == 1
    s.check('two actual windows preserve one install and refuse live-owner takeover')


def case_concurrent_claims(s):
    s.ready_update()
    prepare_second_window(s)
    s.confirmation()
    second_control(s, 'palette', s.command_prefix + 'Update')
    s.choose(s.command_prefix + 'Update', second=True)
    prefix = 'Update ' + s.name + ' ' + s.initial + ' → ' + s.preview
    def offered(control):
        choices = [node for node in nodes(control('tree').get('tree', []))
                   if node.get('role') == 'option' and label(node).startswith(prefix)]
        return choices[0] if len(choices) == 1 else None
    choices = [s.lib.wait_for(lambda: offered(s.runtime.ctl), 'first pre-effect confirmation', 40),
               s.lib.wait_for(lambda: offered(lambda *parts: second_control(s, *parts)),
                              'second pre-effect confirmation', 40)]
    assert not s.records() and not s.clones()
    notice_offset = s.runtime.log_offset()
    barrier = threading.Barrier(2, timeout=10)
    def accept(index):
        x, y, width, height = choices[index]['rect']
        barrier.wait()
        started = time.monotonic_ns()
        control = s.runtime.ctl if index == 0 else lambda *parts: second_control(s, *parts)
        result = control('click', str(x + width / 2), str(y + height / 2))
        return {'window': index, 'started_monotonic_ns': started, 'result': result}
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(accept, index) for index in (0, 1)]
        s.evidence['concurrent_confirmations'] = [future.result(timeout=45) for future in futures]
    def settled_claims():
        notices = s.runtime.notices(notice_offset)
        errors = [notice for notice in notices if notice and notice[0] == 'error']
        return errors and (s.clones() or len(errors) == 2)
    s.lib.wait_for(settled_claims, 'concurrent native claims produce visible exclusion', 60)
    assert len(s.clones()) <= 1, s.clones()
    s.retained('concurrent-claims-excluded')
    s.observe('concurrent-claims')
    if s.clones():
        s.release()
        s.installed(s.preview)
    assert len(s.clones()) <= 1
    s.check('two independently controlled native windows accept concurrently; claim exclusion permits at most one real installer')


def process_alive(identity):
    try:
        stat = Path('/proc', str(identity['pid']), 'stat').read_text().rsplit(')', 1)[1].split()
    except FileNotFoundError:
        return False
    return int(stat[19]) == identity['start_ticks'] and stat[0] != 'Z'


def case_owner_gone(s, interrupted=False):
    s.confirmation()
    s.accept()
    s.lib.wait_for((s.gate / 'started').exists, 'original window journals its admitted clone', 60)
    retained = s.retained('original-owner-before-close')
    assert len(retained) == 1
    identities = json.loads((s.gate / 'installer-processes.json').read_text())
    windows = [entry for entry in s.runtime.own if Path(entry['argv'][0]).name == 'xvfb-run']
    assert len(windows) == 1
    s.lib.stop_entry(windows[0])
    s.runtime.own.remove(windows[0])
    s.evidence['intentionally_closed_window_pid'] = windows[0]['process'].pid
    s.lib.wait_for(lambda: not any(process_alive(identity) for identity in identities),
                   'exact owned installer incarnations ended with the original window', 20)
    s.evidence['original_installer_processes_ended'] = identities
    assert s.records() == retained
    def replacement(name):
        s.runtime.control = s.runtime.root / (name + '.sock')
        metadata = s.runtime.root / (name + '-display.json')
        offset = s.runtime.log_offset()
        s.runtime.spawn(['xvfb-run', '-a', '-s', '-screen 0 1920x1080x24',
                         sys.executable, str(REPORT_TESTS / 'owned_window.py'), str(metadata),
                         s.lib.TERN, '--control', str(s.runtime.control)], cwd=s.runtime.root)
        s.lib.wait_for(s.runtime.control.exists, 'replacement native window control', 40)
        s.runtime.checked_state()
        s.lib.wait_for(lambda: s.runtime.plugins_dir_lines(offset), 'replacement updater observes retained owners', 45)
    replacement('r2')
    original_owner = retained[0]['record']['owner']
    clients = json.loads(s.runtime.command('inspect', '--json'))['clients']
    assert not any(row['kind'] == 'window' and all(row[key] == original_owner[key] for key in ('window', 'conn', 'since'))
                   for row in clients)
    s.evidence['replacement_inventory'] = clients
    s.action('resolve_update')
    s.choose('Resolve window ')
    def resolution_choice():
        choices = [node for node in nodes(s.runtime.ctl('tree').get('tree', [])) if node.get('role') == 'option']
        accepted = [label(node) for node in choices if label(node).startswith(('Resolve this target as unverified',
                                                                            'I confirm the original operation stopped'))]
        return accepted[0] if len(accepted) == 1 else None
    choice = s.lib.wait_for(resolution_choice, 'explicit unverified outcome after ended-owner proof', 40)
    if interrupted:
        pending = s.retained('resolver-before-interruption')
        assert len(pending) == 2 and retained[0] in pending
        resolver = next(row for row in pending if row['path'] != retained[0]['path'])
        assert resolver['record']['phase'] == 'resolving'
        windows = [entry for entry in s.runtime.own if Path(entry['argv'][0]).name == 'xvfb-run']
        assert len(windows) == 1
        s.lib.stop_entry(windows[0])
        s.runtime.own.remove(windows[0])
        assert s.records() == pending
        replacement('r3')
        clients = json.loads(s.runtime.command('inspect', '--json'))['clients']
        for row in pending:
            owner = row['record']['owner']
            assert not any(client['kind'] == 'window' and all(client[key] == owner[key] for key in ('window', 'conn', 'since'))
                           for client in clients)
        s.evidence['interrupted_resolver_absence_inventory'] = clients
        s.action('resolve_update')
        owner_label = resolver['record']['owner']['window'] or '(first)'
        s.choose('Resolve window ' + owner_label + ' resolving')
        s.lib.wait_for(lambda: s.records() == retained, 'only abandoned resolver removed; original install bytes unchanged', 40)
        assert len(s.clones()) == 1
        s.check('interrupted takeover preserves original installation evidence; explicit cleanup removes only the ended resolver')
        s.action('resolve_update')
        s.choose('Resolve window ')
        choice = s.lib.wait_for(resolution_choice, 'fresh explicit resolution after abandoned-claim cleanup', 40)
    assert not any(process_alive(identity) for identity in identities)
    s.choose(choice)
    s.resolved()
    assert len(s.clones()) == 1 and s.runtime.version(s.plugin_id) == s.initial
    s.observe('ended-owner-explicit-resolution')
    s.check('a fresh native owner resolves the ended attempt explicitly without replay or false installation success')


def case_missing_git(s):
    s.ready_update()
    before = s.lib.tree_hash(s.runtime.plugins_dir / s.plugin_id)
    (s.gate / 'unavailable').write_text('owned Git executable fault: exit 127\n')
    offset = s.runtime.log_offset()
    s.action('install_update')
    s.lib.wait_for(lambda: any('needs Git' in part for n in s.runtime.notices(offset) for part in n),
                   'Git preflight refuses unavailable executable', 40)
    assert not s.runtime.picker() and not s.clones() and not s.records()
    assert s.lib.tree_hash(s.runtime.plugins_dir / s.plugin_id) == before
    s.observe('git-preflight-refusal')
    s.check('unavailable Git refuses before confirmation, ownership or package mutation')


def case_clone_failure(s):
    s.confirmation()
    before = s.lib.tree_hash(s.runtime.plugins_dir / s.plugin_id)
    config = s.home / '.gitconfig'
    config.write_text(config.read_text().replace(s.git_url, s.git_url.replace('/origin.git', '/absent.git')))
    offset = s.runtime.log_offset()
    s.accept()
    s.lib.wait_for(lambda: any('installer failed' in part for n in s.runtime.notices(offset) for part in n),
                   'actual Git clone failure has a correlated outcome', 60)
    s.resolved()
    assert len(s.clones()) == 1 and s.lib.tree_hash(s.runtime.plugins_dir / s.plugin_id) == before
    s.observe('git-clone-failure')
    s.check('real Git failure leaves installed bytes intact and reports failure without replay')


def case_load_failure(s, component):
    s.confirmation()
    (s.source / (component + '.luau')).write_text('error("owned fixture: expected ' + component + ' load failure")\n')
    s.commit('Actual ' + component + ' entry-point failure after confirmation')
    offset = s.runtime.log_offset()
    s.accept()
    manifest = s.runtime.plugins_dir / s.plugin_id / 'plugin.toml'
    s.lib.wait_for(lambda: s.lib.manifest_value(manifest, 'version') == s.preview,
                   'actual package installed despite entry-point failure', 90)
    def failed_load():
        for log in (s.runtime.logs / 'tern.log', s.runtime.logs / 'tern-daemon.log'):
            if log.exists() and 'owned fixture: expected ' + component + ' load failure' in log.read_text(errors='replace'):
                return True
        return False
    s.lib.wait_for(failed_load, 'native runtime reports the injected entry-point failure', 40)
    assert s.records() and len(s.clones()) == 1
    assert not any(s.preview + ' installed on' in part for n in s.runtime.notices(offset) for part in n)
    s.observe(component + '-load-failure-held')
    s.check('actual ' + component + ' load failure cannot be settled by installed version or catalog alone')


def case_no_daemon(s):
    s.ready_update()
    before = s.lib.tree_hash(s.runtime.plugins_dir / s.plugin_id)
    daemons = [entry for entry in s.runtime.own if entry['argv'][:2] == [s.lib.TERN, 'daemon']]
    assert len(daemons) == 1
    s.lib.stop_entry(daemons[0])
    s.runtime.own.remove(daemons[0])
    s.evidence['intentionally_stopped_private_daemon'] = daemons[0]['process'].pid
    inspection = subprocess.run([s.lib.TERN, 'inspect', '--json'], env=s.runtime.env,
                                capture_output=True, text=True, timeout=15)
    assert inspection.returncode != 0, inspection.stdout
    s.evidence['absent_daemon_inspect'] = {'status': inspection.returncode,
                                         'stdout': inspection.stdout, 'stderr': inspection.stderr}
    s.evidence['manifest_only_catalog'] = json.loads(s.runtime.command('plugin', 'list', '--json'))
    offset = s.runtime.log_offset()
    s.action('install_update')
    s.lib.wait_for(lambda: any(n and n[0] == 'error' for n in s.runtime.notices(offset)),
                   'missing native daemon refuses updater before installation', 40)
    assert not s.records() and not s.clones()
    assert s.lib.tree_hash(s.runtime.plugins_dir / s.plugin_id) == before
    s.observe('daemon-absent-refusal')
    s.check('manifest catalog without a live native daemon cannot authorize installation or imply host health')


CASES = {'git': case_git, 'tip-movement': case_tip_movement, 'requirements-pre': case_requirements_pre,
         'older-version': lambda s: case_tip_movement(s, moved='0.0.9'),
         'requirements-post': case_requirements_post, 'callback-loss': case_callback_loss,
         'timeout': case_timeout, 'corrupt': case_corrupt, 'legacy': case_legacy, 'development-link': case_link,
         'timeout-after-replacement': case_timeout_after_replacement,
         'competing-windows': case_competing, 'owner-gone': case_owner_gone,
         'interrupted-takeover': lambda s: case_owner_gone(s, interrupted=True),
         'concurrent-claims': case_concurrent_claims,
         'missing-git': case_missing_git, 'clone-failure': case_clone_failure, 'consumer': case_git,
         'no-daemon': case_no_daemon,
         'host-load-failure': lambda s: case_load_failure(s, 'host'),
         'window-load-failure': lambda s: case_load_failure(s, 'window')}


def run_suite(lib, base, evidence, processes, sweep, groups=None):
    runtime = owned_runtime(lib, base, 'library-runtime', evidence, processes)
    runtime.root.chmod(0o700)
    package = lib.build_fixture(base / 'suite-package', '0.1.0', suite=True)
    if groups is not None:
        (package / 'updater/tests/selection.json').write_text(json.dumps(groups) + '\n')
    try:
        runtime.spawn([lib.TERN, 'daemon', '--socket', str(runtime.sock)])
        lib.wait_for(runtime.sock.exists, 'private suite daemon', 20)
        runtime.command('plugin', 'link', package)
        path = runtime.config / 'plugin-data' / lib.FIXTURE_ID / 'library-tests.json'
        lib.wait_for(path.exists, 'actual native Luau suite results', 20)
        result = json.loads(path.read_text())
        evidence['native_library'] = result
        assert result['failures'] in ([], {}) and result['passed'] > 0, result
        sweep.check('native Luau contracts')
        evidence['checks'].append('changed updater contracts execute in the actual native Luau VM')
    finally:
        runtime.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--case', choices=sorted(CASES))
    mode.add_argument('--suite-only', action='store_true')
    parser.add_argument('--suite-groups', help='comma-separated affected native groups; requires --suite-only')
    parser.add_argument('--plugin', type=Path, help='actual consumer package; required only for --case consumer')
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    if (args.case == 'consumer') != (args.plugin is not None):
        parser.error('--case consumer and --plugin must be supplied together')
    groups = args.suite_groups.split(',') if args.suite_groups else None
    if groups is not None and (not args.suite_only or len(set(groups)) != len(groups)
                               or not all((TESTS / (group + '_test.luau')).is_file()
                                          and re.fullmatch('[a-z]+', group) for group in groups)):
        parser.error('--suite-groups requires distinct existing native test groups and --suite-only')
    evidence = {'case': args.case or 'suite-only', 'checks': [], 'passed': False}
    processes, scenario, base, sweep = [], None, None, None
    lib = library()
    try:
        evidence['supervisor'] = supervisor()
        if lib.TERN is None:
            raise RuntimeError('native Tern is not on PATH')
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        base = Path(tempfile.mkdtemp(prefix='updater-native-', dir=args.evidence.parent))
        base.chmod(0o700)
        evidence['retained_directory'] = str(base)
        sweep = lib.Sweep(base)
        if args.suite_only:
            run_suite(lib, base, evidence, processes, sweep, groups)
        else:
            scenario = Scenario(lib, base, evidence, processes, sweep)
            scenario.prepare(linked=args.case == 'development-link', legacy=args.case == 'legacy',
                             gated=args.case in ('callback-loss', 'timeout', 'competing-windows', 'concurrent-claims', 'owner-gone', 'interrupted-takeover'),
                             consumer=args.plugin, response_delay=args.case == 'timeout-after-replacement')
            CASES[args.case](scenario)
        sweep.check('selected scenario finished')
        evidence['passed'] = True
    except Exception as error:
        evidence['error'] = f'{type(error).__name__}: {error}'
        evidence['traceback'] = traceback.format_exc()
        if scenario is not None:
            try:
                scenario.observe('failed')
            except Exception as capture_error:
                evidence['failure_capture_error'] = f'{type(capture_error).__name__}: {capture_error}'
    finally:
        if scenario is not None:
            try:
                scenario.close()
            except Exception as error:
                evidence['cleanup_error'] = f'{type(error).__name__}: {error}'
                evidence['passed'] = False
        for entry in reversed(processes):
            lib.stop_entry(entry)
        evidence['own_processes_reaped'] = all(entry['process'].poll() is not None for entry in processes)
        evidence['process_exit_codes'] = [entry['process'].poll() for entry in processes]
        if sweep is not None:
            try:
                sweep.check('after owned-process cleanup')
                evidence['real_tern_untouched'] = True
            except Exception as error:
                evidence['real_tern_untouched'] = False
                evidence['passed'] = False
                evidence['isolation_error'] = f'{type(error).__name__}: {error}'
        evidence['source_hashes'] = {name + '.luau': hashlib.sha256((lib.ROOT / (name + '.luau')).read_bytes()).hexdigest()
                                     for name in lib.MODULES}
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({key: evidence.get(key) for key in ('case', 'passed', 'error', 'checks', 'retained_directory',
                                                       'own_processes_reaped', 'real_tern_untouched')}, indent=2))
    return 0 if evidence['passed'] and evidence['own_processes_reaped'] and evidence.get('real_tern_untouched') else 1


if __name__ == '__main__':
    raise SystemExit(main())

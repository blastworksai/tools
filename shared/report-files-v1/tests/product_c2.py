"""C2 ordinary native UI qualification; no reducers or authority seeding.

The worker is deliberately deterministic. Provider-backed readiness is a separate
native product action and never inferred from this driver's outcome.
"""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import traceback

from owned_runtime import owned_runtime
from product_scenario import (TESTS, UI, instrument, read_json, registry, trace,
                              select_native_dark, window_diagnostics)

MODES = {
    'cross_family_review': ('Require review from a different provider family', True, True, 'c2-other-reviewer'),
    'helper_checks': ('Require review; same provider family allowed', True, False, 'c2-same-reviewer'),
    'review_disabled': ('Disable code review; retain all declared checks', False, False, None),
}
RECORDS = (('c2-builder', 'Codex'), ('c2-same-reviewer', 'Codex'),
           ('c2-other-reviewer', 'Claude'), ('c2-release', 'OMP'))
ASSETS = ('mailbox_target.sh', 'mailbox_worker.sh', 'mailbox_json.awk',
          'mailbox_reply.jq', 'mailbox_target.ps1', 'mailbox_worker.ps1', 'setup_argv.ps1',
          'setup_route.sh', 'setup_route.ps1')


def native_nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.get('children', []):
            yield from native_nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from native_nodes(child)


def surface_nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.get('c', []):
            yield from surface_nodes(child)


class NativeUI(UI):
    """Only inputs exposed by the real native UI; no hand-built product requests."""
    def __init__(self, runtime, lib, window_key=None):
        super().__init__(runtime, lib)
        self.window_key = window_key
        self.serial = time.time_ns() // 1000
        self.inputs = []
        self.action_map = self.data/('ui-actions-'+str(self.serial)+'.jsonl')

    def record_input(self, value):
        value = {'epoch_ns': time.time_ns(), 'monotonic_ns': time.monotonic_ns(),
                 'window_key': self.window_key, **value}
        self.inputs.append(value)
        with self.action_map.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(value, ensure_ascii=False)+'\n')

    def __call__(self, op, **fields):
        if getattr(self, 'window_key', None) is not None:
            fields['window_key'] = self.window_key
        if op == 'preferences':
            def rendered():
                observed = super(NativeUI, self).__call__(op, **fields)
                return observed if not observed.get('pending') else None
            result = self.lib.wait_for(rendered, 'native preferences surface rendered', 30)
        else:
            result = super().__call__(op, **fields)
        if op not in ('surface', 'preferences', 'panes', 'agents', 'context'):
            self.record_input({'op': op, 'fields': fields, 'result': result})
        return result

    def choose(self, title, label, observe=None):
        def offered():
            tree = self.runtime.ctl('tree')
            if observe is not None:
                observe(tree)
            if title not in json.dumps(tree, ensure_ascii=False):
                return None
            rows = [node for node in native_nodes(tree.get('tree', []))
                    if node.get('role') == 'option' and
                    any(child.get('text') == label for child in native_nodes(node))]
            return rows[0] if len(rows) == 1 else None
        node = self.lib.wait_for(offered, 'native choice '+title+' / '+label, 40)
        x, y, width, height = node['rect']
        answer = self.runtime.ctl('click', str(x+width/2), str(y+height/2))
        self.record_input({'op': 'native_picker', 'title': title, 'label': label, 'control': node})
        return answer

    def mouse_click(self, pane, label):
        self('focus', pane=pane)
        state = self.runtime.checked_state()
        if any(tab['active'] and tab['zoomed'] for tab in state['tabs']):
            self.runtime.ctl('zoom')
        def visible():
            tree = self.runtime.ctl('tree')
            controls = [node for node in native_nodes(tree.get('tree', []))
                        if (node.get('tag') == 'button' or node.get('role') == 'button')
                        and any(child.get('text') == label for child in native_nodes(node))]
            if len(controls) != 1:
                return None
            node = controls[0]
            x, y, width, height = node['rect']
            viewport = self.runtime.checked_state()['viewport']
            if width <= 0 or height <= 0 or not 0 <= x+width/2 < viewport[0]:
                return None
            if y < 45 or y+height >= viewport[1]-10:
                self.runtime.ctl('move', str(x+width/2), str(viewport[1]/2))
                self.runtime.ctl('wheel', '0', str(max(-700, min(700, y-viewport[1]/2))))
                return None
            return node
        node = self.lib.wait_for(visible, 'visible native mouse control '+label, 40)
        x, y, width, height = node['rect']
        result = self.runtime.ctl('click', str(x+width/2), str(y+height/2))
        self.record_input({'op': 'native_mouse', 'pane': pane, 'label': label, 'control': node})
        return result

    def enter(self, title, value, previous='', observe=None):
        def visible():
            tree = self.runtime.ctl('tree')
            if observe is not None:
                observe(tree)
            return title in json.dumps(tree, ensure_ascii=False)
        self.lib.wait_for(visible, 'native prompt '+title, 40)
        # Native prompt selects its initial value. Explicit select-all applies to
        # this focused ordinary prompt, never a hidden host settings request.
        if previous:
            self.runtime.ctl('key', 'Ctrl+a')
        if value:
            self.runtime.ctl('type', json.dumps(value, ensure_ascii=False))
        self.runtime.ctl('key', 'Enter')
        self.record_input({'op': 'native_prompt', 'title': title, 'value': value})

    def prompt(self, label, text):
        return self.enter(label, text)

    def preference(self, pane, row=None, value=None, label=None, page=None):
        self('focus', pane=pane)
        self('preferences', pane=pane)  # Wait for a real owner surface before sending one mutation.
        result = self('preference', pane=pane, row=row, value=value, label=label, page=page)
        if result.get('editing'):
            self.lib.wait_for(lambda: self('preferences', pane=pane)['properties'].get('editing'),
                              'native preference editor', 10)
            # SPAWN's native prefs text editor starts at the end and does not
            # implement select-all. Delete the observed original characters.
            for _ in result.get('previous') or '':
                self.runtime.ctl('key', 'Backspace')
            if value:
                self.runtime.ctl('type', json.dumps(value, ensure_ascii=False))
            self.runtime.ctl('key', 'Enter')
        return result

    def machine(self, pane, role, key=None):
        tree = self('surface', pane=pane, **({'root': 'main.'+key} if key else {}))
        if tree is None:
            return None
        for node in surface_nodes(tree.get('main')):
            props = node.get('p', {})
            if props.get('role') == role:
                text = props.get('text')
                if text is None:
                    text = ''.join(span if isinstance(span, str) else span.get('t', '')
                                   for span in props.get('spans', []))
                return json.loads(text)
        return None

    def click_match(self, pane, fragment):
        def find():
            tree = self('surface', pane=pane)
            labels = []
            for node in surface_nodes(tree.get('main')):
                props = node.get('p', {})
                if props.get('actions', {}).get('click'):
                    text = props.get('text', ''.join(span if isinstance(span, str) else span.get('t', '')
                                                   for span in props.get('spans', [])))
                    if fragment in text:
                        labels.append(text)
            return labels[0] if len(labels) == 1 else None
        return self.click(pane, self.lib.wait_for(find, 'unique visible button '+fragment, 30))


def spawn_authority(runtime):
    return (read_json(runtime.config/'plugin-data/spawn/kv.json') or {}).get('authority')


def saved_records(runtime):
    authority = spawn_authority(runtime)
    return authority['config']['hosts'][authority['host_key']]['agents'] if authority else []


def git(runtime, repository, *args):
    result = subprocess.run(['git', '-C', str(repository), *args], env=runtime.env,
                            check=True, capture_output=True, text=True, timeout=20)
    return result.stdout.strip()


class Product:
    def __init__(self, base, root, evidence, processes, lib, name, args, provider=False):
        self.lib, self.root, self.args, self.provider = lib, root, args, provider
        self.runtime = runtime = owned_runtime(lib, base, name, evidence, processes,
                                               capture_desktop=args.capture_desktop,
                                               provider_agent_dir=args.provider_agent_dir if provider else None)
        self.result = {'status': 'failed', 'source': str(root), 'route': 'ordinary native SPAWN/ORCH entrypoints; no seeded authorities',
                       'worker_kind': 'deterministic managed local-terminal fixture, not provider-backed task proof',
                       'checks': [], 'captures': {}, 'limits': ['Linux owned desktop only',
                       'No provider credentials copied or provider workers launched by this harness',
                       'Native pixel captures require separate visual inspection for final media'],
                       'endpoints': {'config': str(runtime.config), 'daemon_socket': str(runtime.sock),
                                     'control_socket': str(runtime.control), 'logs': str(runtime.logs)}}
        if provider:
            self.result['worker_kind'] = 'actual approved native OMP/provider workers; authentication used in place'
            self.result['limits'][1] = 'Explicit provider mode: existing authenticated accounts only; no credential copies, new accounts, unsafe approval flags or automatic native permission answers'
            self.result['provider_models'] = {'builder': 'openai-codex/gpt-6-astra',
                                              'same_family_reviewer': 'openai-codex/gpt-6-astra',
                                              'other_family_reviewer': 'anthropic/claude-opus-5-5',
                                              'release_manager': 'openai-codex/gpt-6-astra'}
        self.repository = runtime.root/'repository'
        self.repository.mkdir()
        for parts in (('init', '-q', '-b', 'main'), ('config', 'user.name', 'C2 deterministic fixture'),
                      ('config', 'user.email', 'c2-fixture@example.invalid')):
            git(runtime, self.repository, *parts)
        (self.repository/'fixture.txt').write_text('good\n')
        git(runtime, self.repository, 'add', 'fixture.txt')
        git(runtime, self.repository, 'commit', '-q', '-m', 'Disposable C2 root')
        self.control = runtime.root/'worker-control'
        self.control.mkdir()
        packages = runtime.root/'product-packages'
        packages.mkdir()
        self.spawn, self.orch = packages/'SPAWN', packages/'ORCH+'
        if provider:
            shutil.copytree(root/'plugins/tern/SPAWN', self.spawn)
            shutil.copytree(root/'plugins/tern/ORCH+', self.orch)
            self.result['package_instrumentation'] = 'none; exact source packages'
        else:
            # Observational wrappers only; C1 record injection is not enabled.
            instrument(root/'plugins/tern/SPAWN', self.spawn,
                       {'orch_kv': str(runtime.config/'plugin-data/orchplus/kv.json')})
            instrument(root/'plugins/tern/ORCH+', self.orch, {})
            self.result['package_instrumentation'] = 'observational entrypoint wrappers; not byte-identical final-package capture'
        self.worker = packages/'policy_worker.py'
        shutil.copy2(TESTS/'policy_worker.py', self.worker)
        driver = packages/'driver'
        driver.mkdir()
        shutil.copy2(TESTS/'product_driver.luau', driver/'window.luau')
        (driver/'plugin.toml').write_text('schema = 1\nid = "report-product-driver"\nname = "Native product UI driver"\nversion = "0.1.0"\nwindow = "window.luau"\n')
        self.driver = driver
        self.result['fixture_sources'] = {str(path.relative_to(TESTS)): hashlib.sha256(path.read_bytes()).hexdigest()
                                          for path in (TESTS/'policy_worker.py', TESTS/'product_driver.luau', TESTS/'product_probe.luau',
                                                       TESTS/'product_c2.py', TESTS/'owned_runtime.py', TESTS/'owned_window.py')}
        self.result['disposable_repository'] = str(self.repository)

    def start(self, installed=False):
        runtime = self.runtime
        runtime.start()
        for package in (self.spawn, self.orch, self.driver):
            runtime.command('plugin', 'install' if installed and package != self.driver else 'link', package)
        self.ui = NativeUI(runtime, self.lib)
        if self.provider:
            installed_root = Path(json.loads(runtime.command('plugin', 'dir', '--json'))['dir'])
            def hashes(directory):
                return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in sorted(directory.rglob('*')) if path.is_file()}
            self.result['installed_package_provenance'] = {}
            for name, plugin_id, copied in (('SPAWN', 'spawn', self.spawn), ('ORCH+', 'orchplus', self.orch)):
                expected = hashes(self.root/'plugins/tern'/name)
                assert hashes(copied) == expected, 'provider copy differs from product source: '+name
                assert hashes(installed_root/plugin_id) == expected, 'native installed package differs from product source: '+name
                self.result['installed_package_provenance'][plugin_id] = {
                    'files': len(expected), 'installed': str(installed_root/plugin_id),
                    'manifest_sha256': hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest()}
        if self.args.capture_desktop:
            self.result['native_capture_controls'] = [
                {'command': list(command), 'response': runtime.ctl(*command)}
                for command in (('size', '1920', '1080'), ('font', '17'), ('ui-font-size', '17'))]
        if 'tn-signin-x' in json.dumps(runtime.ctl('tree')):
            runtime.ctl('click', '.tn-signin-x')
        for command in (('theme', 'dark', 'obsidian'), ('appearance', 'dark'), ('style', 'solid')):
            runtime.ctl(*command)
        self.result['native_dark_selection'] = select_native_dark(runtime)
        self.result['owned_environment'] = runtime.owned_environment
        self.result['native_context'] = self.ui('context')
        self.metadata('started')
        if self.args.capture_start_hold:
            self.metadata('capture-start-hold')
            deadline = time.monotonic()+self.args.capture_start_hold
            while time.monotonic() < deadline and not (runtime.root/'capture-start-release').exists():
                runtime.checked_state()
                self.lib.idle(.5)

    def metadata(self, phase):
        runtime = self.runtime
        value = {'schema': 1, 'phase': phase, 'pid': os.getpid(), 'runtime_root': str(runtime.root),
                 'endpoints': self.result['endpoints'], 'owned_environment': runtime.owned_environment,
                 'display': read_json(runtime.capture_metadata) if hasattr(runtime, 'capture_metadata') else None,
                 'action_map': str(self.ui.action_map), 'capture_epoch_ns': time.time_ns(),
                 'command_file': str(self.ui.data/'command.json'), 'response_file': str(self.ui.data/'response.json'),
                 'command_protocol': {'id': 'unique integer < 2^53', 'op': 'open|focus|close|surface|click|click_gate|preferences|preference|panes|agents|context',
                                      'window_key': 'optional exact native key for multiwindow routing'},
                 'native_action_command': ['tern', 'ctl', '--control', str(runtime.control), 'plugins', 'run', 'ACTION'],
                 'input_rule': 'C2 uses only visible buttons/preferences and ordinary registered actions; event/settings are not C2 inputs',
                 'release_file': str(runtime.root/'capture-release'), 'deadline_seconds': self.args.capture_hold,
                 'start_release_file': str(runtime.root/'capture-start-release'),
                 'start_deadline_seconds': self.args.capture_start_hold,
                 'provider_readiness_action': 'plugin.orchplus.orch_readiness',
                 'provider_prerequisites': 'explicitly approved existing authentication used in place' if self.provider else 'private HOME contains no provider authentication; provider mode is separate'}
        path = runtime.root/'interactive-control.json'
        path.write_text(json.dumps(value, indent=2)+'\n')
        self.result['interactive_control'] = str(path)
        if self.args.control_metadata:
            self.args.control_metadata.parent.mkdir(parents=True, exist_ok=True)
            self.args.control_metadata.write_text(json.dumps(value, indent=2)+'\n')

    def capture(self, label):
        self.result['captures'][label] = window_diagnostics(self.runtime, label)
        self.metadata(label)

    def hold(self):
        if self.args.capture_hold:
            self.metadata('capture-hold')
            deadline = time.monotonic()+self.args.capture_hold
            while time.monotonic() < deadline and not (self.runtime.root/'capture-release').exists():
                self.runtime.checked_state()
                self.lib.idle(.5)

    def close(self):
        if self.result.get('error') and getattr(self, 'spawn_pane', None) is not None:
            try:
                self.result['failure_spawn_surface'] = self.ui('surface', pane=self.spawn_pane)
            except Exception as error:
                self.result['failure_spawn_surface_error'] = str(error)
        self.result['orch_authority'] = registry(self.runtime)
        self.result['spawn_authority'] = spawn_authority(self.runtime)
        self.result['inputs'] = getattr(getattr(self, 'ui', None), 'inputs', [])
        if not self.provider:
            self.result['traces'] = {plugin+'/'+realm: trace(self.runtime, plugin, realm)
                                     for plugin in ('spawn', 'orchplus') for realm in ('host', 'window')}
        (self.control/'stop').write_text('owned supervisor cleanup\n')
        for wake in getattr(self, 'extra_wakers', []):
            if wake in self.lib.WAKERS:
                self.lib.WAKERS.remove(wake)
        self.runtime.stop()

    def open_spawn(self):
        self.ui('action', action='plugin.spawn.spawn_managed_setup')
        def pane():
            for candidate in self.ui('panes'):
                # PaneInfo.block is plugin-qualified; kind is the native kind.
                if candidate.get('block') == 'spawn.spawner':
                    return candidate['pane']
            return None
        self.spawn_pane = self.lib.wait_for(pane, 'ordinary SPAWN managed setup pane', 30)
        self.lib.wait_for(lambda: spawn_authority(self.runtime), 'SPAWN own first-use authority', 30)
        return self.spawn_pane

    def check_native_navigation(self):
        config = spawn_authority(self.runtime)['config']
        lifecycle = spawn_authority(self.runtime)['setup']
        orch_setup = registry(self.runtime)['setup']
        closed_target = self.spawn_pane
        self.ui('close', pane=closed_target)
        self.lib.wait_for(lambda: all(p['pane'] != closed_target for p in self.ui('panes')),
                          'closed native SPAWN target', 20)
        self.ui.mouse_click(self.controller, 'SPAWN managed setup…')
        def managed_page():
            panes = [p['pane'] for p in self.ui('panes') if p.get('block') == 'spawn.spawner']
            if len(panes) != 1 or panes[0] == closed_target:
                return None
            prefs = self.ui('preferences', pane=panes[0])['properties']
            return panes[0] if prefs.get('page') == 'managed' and self.runtime.checked_state()['focused']['id'] == panes[0] else None
        self.spawn_pane = self.lib.wait_for(managed_page, 'clicked ORCH to SPAWN owned managed page', 30)
        self.capture('native-cross-link-new-spawn')
        self.ui.preference(self.spawn_pane, page='agents')
        self.ui.mouse_click(self.controller, 'SPAWN managed setup…')
        assert self.lib.wait_for(managed_page, 'clicked existing SPAWN page navigation', 30) == self.spawn_pane
        self.ui.mouse_click(self.spawn_pane, 'Open optional readiness exercise in ORCH+')
        self.lib.wait_for(lambda: self.runtime.checked_state()['focused']['id'] == self.controller,
                          'clicked SPAWN return to ORCH native view', 30)
        def readiness_receiver():
            alias = self.ui.machine(self.controller, 'orchplus.alias')
            intent = self.ui.machine(self.controller, 'orchplus.intent')
            return alias if alias and alias.get('config_open') is True and intent is None else None
        receiver = self.lib.wait_for(readiness_receiver, 'ORCH owner consumes readiness page entry', 30)
        assert registry(self.runtime)['setup'] == orch_setup
        self.assert_no_controller()
        assert spawn_authority(self.runtime)['config'] == config
        assert spawn_authority(self.runtime)['setup'] == lifecycle
        self.capture('native-cross-link-return-orch')
        self.ui.mouse_click(self.controller, 'Setup wizard…')
        label = 'Open SPAWN managed setup first'
        self.lib.wait_for(lambda: label in json.dumps(self.runtime.ctl('tree')), 'native navigation picker', 30)
        before = {p['pane'] for p in self.ui('panes')}
        closed_source = self.controller
        self.ui('close', pane=closed_source)
        picker_remained = label in json.dumps(self.runtime.ctl('tree'))
        if picker_remained:
            self.ui.choose('ORCH+ setup', label)
        assert {p['pane'] for p in self.ui('panes')} == before-{closed_source}, 'closed-source choice opened a pane'
        assert spawn_authority(self.runtime)['config'] == config
        self.controller = self.ui('open', kind='orchplus.orchestrator')
        self.result['native_navigation'] = {'closed_target': closed_target, 'new_target': self.spawn_pane,
                                            'closed_source': closed_source, 'picker_remained': picker_remained,
                                            'closed_source_case': 'delayed choice refused' if picker_remained else 'native close dismissed picker; delayed callback not exercised',
                                            'readiness_receiver': receiver, 'orch_setup_unchanged': orch_setup,
                                            'inputs': 'actual native mouse controls; no fabricated page-entry events'}
        self.result['checks'].append('clicked ORCH/SPAWN native cross-links open/reuse owner pages; closed target is not reused, closed source cannot navigate, return creates no controller or readiness result')

    def create_record(self, record_id, provider, interrupt=False):
        initial_lifecycle = spawn_authority(self.runtime)['setup']['state']
        expected_lifecycle = 'adopted_existing' if initial_lifecycle == 'adopted_existing' else 'completed'
        interruptions = (('draft', 'resources', 'cli-attestation', 'committed') if interrupt is True
                         else tuple(interrupt) if interrupt else ())
        def interrupt_at(boundary):
            if not interruptions or interruptions[0] != boundary:
                return False
            records = saved_records(self.runtime)
            lifecycle = spawn_authority(self.runtime)['setup']
            boot = trace(self.runtime, 'spawn')['boot']
            self.capture('spawn-interrupt-'+boundary)
            self.runtime.command('plugin', 'reload', 'spawn', '--json')
            self.lib.wait_for(lambda: trace(self.runtime, 'spawn').get('boot', 0) > boot,
                              'native setup interruption '+boundary, 30)
            self.open_spawn()
            assert saved_records(self.runtime) == records, 'interruption changed saved records at '+boundary
            assert spawn_authority(self.runtime)['setup'] == lifecycle, 'interruption rewrote setup lifecycle'
            if boundary != 'committed':
                assert not any(record['id'] == record_id for record in records), 'uncommitted setup became a record'
            self.result.setdefault('setup_interruptions', []).append({'boundary': boundary, 'state': lifecycle, 'record_ids': [row['id'] for row in records]})
            return True
        pane = self.spawn_pane
        self.ui.preference(pane, row='managed-existing', value='')
        self.ui.preference(pane, row='managed-begin')
        values = {'id': record_id, 'provider': provider, 'account_label': 'Deterministic fixture — no provider account',
                  'backend': 'local-terminal', 'executable': sys.executable,
                  'arguments': shlex.join([str(self.worker), str(self.control), record_id]),
                  'cwd': str(self.repository), 'root': str(self.runtime.root/'mailboxes'), 'user': ''}
        if self.provider:
            other = record_id == 'c2-other-reviewer'
            model = 'anthropic/claude-opus-5-5' if other else 'openai-codex/gpt-6-astra'
            session_dir = self.runtime.root/'provider-sessions'/record_id
            session_dir.mkdir(parents=True, exist_ok=True)
            values.update(provider='OMP', account_label='Approved '+model+' route — shared OS account',
                          backend='native-agent', executable=shutil.which('omp'),
                          arguments=shlex.join(['--model', model, '--thinking', 'low' if other else 'minimal',
                                                '--session-dir', str(session_dir), '--max-time', '300']))
        for key, value in values.items():
            self.ui.preference(pane, row='managed:'+key, value=value)
        self.capture('spawn-'+record_id+'-draft')
        if interrupt_at('draft'):
            return self.create_record(record_id, provider, interruptions[1:])
        self.ui.preference(pane, row='managed-probe')
        def attestation_available():
            prefs = self.ui('preferences', pane=pane)['properties']
            for section in prefs['sections']:
                for row in section['rows']:
                    if row['id'] == 'managed-attest' and not row.get('disabled'):
                        return prefs
            return None
        observed = self.lib.wait_for(attestation_available, 'actual resources and prerequisite observations', 90)
        self.result.setdefault('probes', {})[record_id] = observed
        self.capture('spawn-'+record_id+'-attestation')
        self.probe_native_route(pane, record_id)
        if interrupt_at('resources'):
            return self.create_record(record_id, provider, interruptions[1:])
        self.ui.preference(pane, row='managed-cli-attest')
        if interrupt_at('cli-attestation'):
            return self.create_record(record_id, provider, interruptions[1:])
        self.ui.preference(pane, row='managed-attest')
        record = self.lib.wait_for(lambda: next((row for row in saved_records(self.runtime) if row['id'] == record_id), None),
                                   'native attested managed record '+record_id, 40)
        assert record['mailbox']['verified'] is True
        assert record['account_label'] == values['account_label'], 'native text input changed the account label bytes'
        assert spawn_authority(self.runtime)['setup']['state'] == expected_lifecycle, 'record creation changed the established setup lifecycle'
        assert spawn_authority(self.runtime)['setup']['readiness']['state'] == 'not_run'
        helper = Path(record['mailbox']['helper_path'])
        assert helper.is_relative_to(self.runtime.config/'plugin-data/spawn/helper-bundles')
        hashes = {}
        for asset in ASSETS:
            installed = helper.parent/asset
            assert installed.read_bytes() == (self.spawn/asset).read_bytes(), 'stable bundle byte mismatch: '+asset
            hashes[asset] = hashlib.sha256(installed.read_bytes()).hexdigest()
        probes = list(Path(record['mailbox']['permitted_root']).glob('setup-*/provision.json'))
        assert probes, 'native wizard did not create an actual provision probe'
        self.result.setdefault('created_resources', {})[record_id] = {'record': record, 'bundle_sha256': hashes,
                                                                    'provisions': [str(path) for path in probes]}
        interrupt_at('committed')
        return record

    def probe_native_route(self, pane, record_id):
        self.ui.preference(pane, row='managed-route-probe')
        def completed():
            route = self.ui.machine(pane, 'spawn.managed.route')
            observations = self.result.setdefault('native_route_observations', {}).setdefault(record_id, [])
            if route is not None and (not observations or observations[-1]['route'] != route):
                observations.append({'at': time.time(), 'route': route})
            prefs = self.ui('preferences', pane=pane)['properties']
            for section in prefs['sections']:
                for row in section['rows']:
                    if row['id'] == 'managed-route-status':
                        state = (row.get('hint') or '').split('\n', 1)[0].strip()
                        if state == 'failed':
                            raise AssertionError('actual native route diagnostic failed: '+row['hint'])
                        if state == 'passed':
                            return row
            return None
        observed = self.lib.wait_for(completed, 'actual consented native route diagnostic '+record_id, 120)
        self.result.setdefault('native_route_probes', {})[record_id] = observed
        self.capture('spawn-'+record_id+'-native-route')

    def add_catalog_padding(self):
        # Real ordinary editor records intentionally exceed one public catalog
        # frame. They are not managed/eligible and no workers are launched.
        pane = self.spawn_pane
        padding = []
        for index in range(3):
            prior = {record['id'] for record in saved_records(self.runtime)}
            self.ui.preference(pane, page='setup')
            self.ui.preference(pane, row='setup-add-local')
            record = self.lib.wait_for(lambda: next((row for row in saved_records(self.runtime) if row['id'] not in prior), None),
                                       'native pagination fixture record', 30)
            self.ui.preference(pane, page='agents')
            def label_row():
                prefs = self.ui('preferences', pane=pane)['properties']
                for section in prefs['sections']:
                    for row in section['rows']:
                        if row['id'].startswith('agent:'+record['id']+':account_label:'):
                            return row['id']
                return None
            row_id = self.lib.wait_for(label_row, 'ordinary saved-record label editor', 20)
            label = 'Pagination fixture '+str(index+1)+' '+'p'*1900
            self.ui.preference(pane, row=row_id, value=label)
            self.lib.wait_for(lambda: any(row['id'] == record['id'] and row['account_label'] == label for row in saved_records(self.runtime)),
                              'native pagination label save', 30)
            padding.append(record['id'])
        self.ui.preference(pane, page='managed')
        self.result['pagination_fixture_record_ids'] = padding

    def initialize_orch(self, cold_navigation=False):
        self.controller = self.ui('open', kind='orchplus.orchestrator')
        if cold_navigation:
            config = spawn_authority(self.runtime)['config']
            closed = self.spawn_pane
            self.ui('close', pane=closed)
            self.ui.mouse_click(self.controller, 'SPAWN managed setup…')
            def opened():
                panes = [pane['pane'] for pane in self.ui('panes')
                         if pane.get('block') == 'spawn.spawner' and pane['pane'] != closed]
                return panes[0] if len(panes) == 1 else None
            self.spawn_pane = self.lib.wait_for(opened, 'cold ORCH native SPAWN cross-link', 30)
            self.lib.wait_for(lambda: 'Managed local setup' in json.dumps(self.ui('preferences', pane=self.spawn_pane)),
                              'cold-link owner Config bootstrap', 30)
            assert registry(self.runtime) is None, 'native navigation initialized ORCH authority'
            assert spawn_authority(self.runtime)['config'] == config
            self.capture('cold-orch-spawn-cross-link')
            self.result['checks'].append('actual cold ORCH cross-link opens owner SPAWN setup while ORCH authority remains absent')
        for label in ('Initialize first-use authority…', 'Confirm first use — no prior owners or lost store'):
            self.ui.click(self.controller, label)
        self.lib.wait_for(lambda: registry(self.runtime), 'genuine first-use ORCH authority', 30)
        self.assert_no_controller()

    def assert_no_controller(self):
        authority = registry(self.runtime)
        assert authority is not None
        assert not authority.get('sessions'), 'setup fabricated a logical session before controller registration'
        assert not authority.get('owners'), 'setup fabricated an owner before controller registration'

    def configure_orch(self, mode, wizard=True, previous=None):
        ui = self.ui
        ui('action', pane=self.controller, action='plugin.orchplus.orch_setup' if wizard else 'plugin.orchplus.installation_defaults')
        ui.choose('ORCH+ setup', 'Configure ORCH installation defaults')
        ui.choose('Choose review policy explicitly', MODES[mode][0])
        ui.enter('Repository checkout path', str(self.repository), str(self.repository) if previous else '')
        ui.enter('Existing target ref', 'refs/heads/main', 'refs/heads/main' if previous else '')
        ui.choose('Owner-declared landing queue', 'orch_queue')
        ui.choose('Select Builder', 'c2-builder')
        if self.provider and MODES[mode][1]:
            ui.enter('Declare provider family for c2-builder', 'openai')
        ui.choose('Select Release manager', 'c2-release')
        if MODES[mode][1]:
            ui.choose('Select Reviewer', MODES[mode][3])
            if self.provider:
                ui.enter('Declare provider family for '+MODES[mode][3],
                         'anthropic' if mode == 'cross_family_review' else 'openai')
        ui.choose('Select Coordinator (optional)', 'None — optional')
        ui.choose('Select Labeller (optional)', 'None — optional')
        if wizard:
            ui.choose('Required setup complete', 'Finish setup')
        def saved():
            value = registry(self.runtime)
            defaults = value and value.get('installation_defaults')
            if defaults and defaults['policy']['require_code_review'] == MODES[mode][1] and defaults['policy']['require_other_family'] == MODES[mode][2]:
                if not wizard or value['setup']['state'] in ('completed', 'adopted_existing'):
                    return defaults
            return None
        defaults = self.lib.wait_for(saved, 'native installation defaults '+mode, 40)
        self.result.setdefault('defaults', {})[mode] = defaults
        self.capture('orch-defaults-'+mode)
        return defaults

    def claim(self):
        for label in ('Register a distinct logical session…', 'Confirm distinct session registration', 'Claim controller in this pane'):
            self.ui.click(self.controller, label)
        def controller_scope():
            state = self.ui.machine(self.controller, 'orchplus.dispatch', 'dispatch-state')
            if not state or state.get('controller_phase') != 'active':
                return None
            return {key: state.get(key) for key in
                    ('source_nonce', 'host_pane_id', 'orch_session_id', 'owner_id', 'owner_generation')}
        scope = self.lib.wait_for(controller_scope, 'native claimed controller scope', 30)
        last_read = 0.0
        def catalog_ready():
            nonlocal last_read
            assert controller_scope() == scope, 'controller scope changed during catalog navigation'
            state = registry(self.runtime)
            busy = [action for action in state.get('dispatch', {}).get('actions', {}).values()
                    if action.get('request', {}).get('op') == 'catalog' and action.get('phase') != 'complete']
            intent = self.ui.machine(self.controller, 'orchplus.intent', 'operator-intent')
            if busy or intent is not None:
                return None
            catalog = self.ui.machine(self.controller, 'orchplus.catalog', 'catalog-index')
            if catalog and any(record['id'] == 'c2-builder' for record in catalog.get('records', [])):
                return catalog
            if time.monotonic() - last_read >= 2:
                last_read = time.monotonic()
                # Re-read navigation only; assignment and authority acquisition
                # are never repeated on an unconfirmed control submission.
                self.ui.click(self.controller, 'Load configured SPAWN catalog')
            return None
        self.lib.wait_for(catalog_ready, 'native configured builder catalog projection', 30)


def prerequisites():
    required = ('xvfb-run', 'git', 'sh', 'jq', 'awk', 'iconv', 'base64', 'sha256sum')
    missing = [binary for binary in required if not shutil.which(binary)]
    if sys.platform != 'linux' or missing:
        return {'status': 'unavailable', 'platform': sys.platform, 'missing': missing,
                'reason': 'C2 ordinary desktop adapter requires Linux; no mock platform qualification'}
    return None


def additional_window(product):
    runtime, lib = product.runtime, product.lib
    first_key = product.ui('context')['window']
    product.ui.window_key = first_key
    runtime.ctl('palette', 'New window')
    def offered():
        tree = runtime.ctl('tree')
        choices = [node for node in native_nodes(tree.get('tree', [])) if node.get('role') == 'option' and any(
            ' '.join(child.get('text', '') for child in native_nodes(label) if child.get('text')).casefold() == 'new window'
            for label in native_nodes(node) if label.get('class') == 'ck-label')]
        return choices[0] if len(choices) == 1 else None
    node = lib.wait_for(offered, 'native New window palette option', 30)
    x, y, width, height = node['rect']
    runtime.ctl('click', str(x+width/2), str(y+height/2))
    product.ui.record_input({'op': 'native_picker', 'title': 'Native command palette', 'label': 'New window', 'control': node})

    class Window:
        def __getattr__(self, name):
            return getattr(runtime, name)

        def ctl(self, *parts):
            if parts[0] in ('state', 'plugins'):
                raise AssertionError('native root-app command is not retargeted to the second window; use its rendered controls')
            runtime.ctl('target', 'window')
            try:
                return runtime.ctl(*parts)
            finally:
                runtime.ctl('target', 'main')

    window = Window()
    wake = lambda: window.ctl('tree')
    lib.WAKERS.append(wake)
    product.extra_wakers = [*getattr(product, 'extra_wakers', []), wake]
    def announced():
        for path in product.ui.data.glob('ready-window-*.json'):
            value = read_json(path)
            if value and value['window_key'] != first_key:
                return value
        return None
    observed = lib.wait_for(announced, 'second native UI driver registration', 40)
    second = NativeUI(window, lib, observed['window_key'])
    if 'tn-signin-x' in json.dumps(second.runtime.ctl('tree')):
        second.runtime.ctl('click', '.tn-signin-x')
    product.result['second_window'] = {'control_socket': str(runtime.control), 'native_target': 'window', 'native': observed,
                                       'control_limit': 'state and plugins run remain root-app scoped; second-window actions use its rendered owner controls'}
    return second


def finish_defaults_inputs(product, ui, mode):
    ui.enter('Repository checkout path', str(product.repository), str(product.repository))
    ui.enter('Existing target ref', 'refs/heads/main', 'refs/heads/main')
    ui.choose('Owner-declared landing queue', 'orch_queue')
    ui.choose('Select Builder', 'c2-builder')
    ui.choose('Select Release manager', 'c2-release')
    if MODES[mode][1]:
        ui.choose('Select Reviewer', MODES[mode][3])
    ui.choose('Select Coordinator (optional)', 'None — optional')
    ui.choose('Select Labeller (optional)', 'None — optional')


def product_setup(base, root, evidence, processes, lib, args):
    unavailable = prerequisites()
    if unavailable:
        return unavailable
    product = Product(base, root, evidence, processes, lib, 'setup-product', args)
    result, runtime = product.result, product.runtime
    try:
        product.start()
        product.open_spawn()
        assert registry(runtime) is None, 'standalone SPAWN setup required an ORCH controller'
        product.capture('cold-standalone-spawn')
        assert spawn_authority(runtime)['setup']['state'] == 'not_started'
        product.ui.preference(product.spawn_pane, row='managed-begin')
        lib.wait_for(lambda: spawn_authority(runtime)['setup']['state'] == 'in_progress', 'native setup begin', 30)
        product.ui.preference(product.spawn_pane, row='managed-dismiss')
        lib.wait_for(lambda: spawn_authority(runtime)['setup']['state'] == 'dismissed', 'persisted native setup dismissal', 30)
        assert not saved_records(runtime) and spawn_authority(runtime)['setup']['readiness']['state'] == 'not_run'
        result['checks'].append('native begin/dismiss lifecycle persists without creating records or claiming readiness')
        product.add_catalog_padding()
        product.create_record(*RECORDS[0], interrupt=True)
        for record in RECORDS[1:]:
            product.create_record(*record)
        result['checks'].append('cold standalone wizard creates and probes exact stable helper bundles/resources before any ORCH authority/controller')
        product.initialize_orch(cold_navigation=True)
        product.check_native_navigation()
        product.ui('action', pane=product.controller, action='plugin.orchplus.orch_setup')
        product.ui.choose('ORCH+ setup', 'Configure ORCH installation defaults')
        lib.wait_for(lambda: registry(runtime)['setup']['state'] == 'in_progress', 'persisted ORCH wizard start', 30)
        runtime.ctl('key', 'Escape')
        boot = trace(runtime, 'orchplus')['boot']
        runtime.command('plugin', 'reload', 'orchplus', '--json')
        lib.wait_for(lambda: trace(runtime, 'orchplus').get('boot', 0) > boot, 'interrupted ORCH wizard reload', 30)
        assert registry(runtime)['setup']['state'] == 'in_progress'
        product.configure_orch('review_disabled')
        product.assert_no_controller()
        setup = registry(runtime)['setup']
        assert setup['readiness']['state'] == 'not_run'
        result['checks'].append('precontroller defaults/repository/catalog roles saved; both setup lifecycles complete without provider readiness')
        previous_defaults = dict(registry(runtime)['installation_defaults'])
        previous_defaults.pop('revision')
        product.configure_orch('review_disabled', previous=True)
        identical_defaults = dict(registry(runtime)['installation_defaults'])
        identical_defaults.pop('revision')
        assert identical_defaults == previous_defaults and registry(runtime)['setup']['state'] == 'completed'
        product.assert_no_controller()
        catalog_requests = [json.loads(event['data']['value']) for event in trace(runtime, 'spawn')['events']
                            if event['kind'] == 'bridge_event' and event['data']['act'] == 'catalog']
        paged = [request for request in catalog_requests if request.get('setup_origin') and request.get('cursor')]
        builder_index = next(index for index, record in enumerate(saved_records(runtime), 1) if record['id'] == 'c2-builder')
        assert paged and min(request['cursor']['index'] for request in paged) <= builder_index, 'setup roles were not fetched beyond the first actual catalog page'
        result['setup_catalog_pagination'] = paged
        result['checks'].append('ORCH in-progress wizard survives reload; identical defaults still complete; real paginated catalog resolves roles beyond first page')

        # Existing-record adoption uses the ordinary managed editor and its
        # fresh probe; it does not fabricate a pre-migration store.
        pane = product.spawn_pane
        before = saved_records(runtime)
        lifecycle_before_adoption = spawn_authority(runtime)['setup']['state']
        product.ui.preference(pane, row='managed-existing', value='c2-builder')
        product.ui.preference(pane, row='managed:account_label', value='Manually edited deterministic fixture')
        product.ui.preference(pane, row='managed-probe')
        lib.wait_for(lambda: 'managed-adopt' in json.dumps(product.ui('preferences', pane=pane)),
                     'native existing-record adoption attestation', 90)
        product.probe_native_route(pane, 'c2-builder-adoption')
        product.ui.preference(pane, row='managed-cli-attest')
        product.ui.preference(pane, row='managed-adopt')
        lib.wait_for(lambda: next((record for record in saved_records(runtime)
                                  if record['id'] == 'c2-builder' and record['account_label'] == 'Manually edited deterministic fixture'), None),
                     'persisted native adopted record edit', 30)
        assert spawn_authority(runtime)['setup']['state'] == lifecycle_before_adoption, 'editing an existing record reopened completed setup'
        after = saved_records(runtime)
        assert len(after) == len(before) and {row['id'] for row in after} == {row['id'] for row in before}
        assert next(row for row in after if row['id'] == 'c2-builder')['account_label'] == 'Manually edited deterministic fixture'
        assert spawn_authority(runtime)['setup']['readiness']['state'] == 'not_run'
        result['checks'].append('manual native edit and fresh probe/adoption preserve stable IDs and independent readiness')

        # A real second window opens an ordinary defaults prompt with the old
        # revision. Another window commits; the stale prompt must not overwrite.
        second = additional_window(product)
        second_pane = second('open', kind='orchplus.orchestrator')
        second.click(second_pane, 'Edit Installation defaults…')
        second.choose('ORCH+ setup', 'Configure ORCH installation defaults')
        second.choose('Choose review policy explicitly', MODES['cross_family_review'][0])
        old_revision = registry(runtime)['installation_defaults']['revision']
        product.configure_orch('helper_checks', wizard=False, previous=True)
        winner = registry(runtime)['installation_defaults']
        assert winner['revision'] > old_revision
        # Repository observations do not advance the stale writer's revision.
        # Complete its real pickers, then observe the final authority refusal.
        finish_defaults_inputs(product, second, 'cross_family_review')
        def stale_result():
            data = second.machine(second_pane, 'orchplus.setup') or {}
            response = data.get('setup_result') or {}
            return response if response.get('ok') is False else None
        refused = lib.wait_for(stale_result, 'two-window stale defaults revision refusal', 40)
        assert registry(runtime)['installation_defaults'] == winner
        result['two_window_refusal'] = refused
        result['second_window']['inputs'] = second.inputs
        product.assert_no_controller()
        result['checks'].append('two real desktop windows: stale ordinary defaults prompt cannot overwrite the winning revision')

        # Session one inherits current defaults. Later installation edits leave
        # it unchanged; an explicitly registered second logical session inherits
        # the new defaults instead.
        product.claim()
        policies = registry(runtime)['dispatch']['policies']
        assert len(policies) == 1
        first_id, first_policy = next(iter(policies.items()))
        assert first_policy['require_code_review'] and not first_policy['require_other_family']
        product.configure_orch('review_disabled', wizard=False, previous=True)
        assert registry(runtime)['dispatch']['policies'][first_id] == first_policy
        for label in ('Register a distinct logical session…', 'Confirm distinct session registration', 'Claim controller in this pane'):
            second.click(second_pane, label)
        lib.wait_for(lambda: len(registry(runtime)['dispatch']['policies']) == 2,
                     'second logical session seeds installation defaults', 30)
        new_policy, = [policy for sid, policy in registry(runtime)['dispatch']['policies'].items() if sid != first_id]
        assert not new_policy['require_code_review'] and not new_policy['require_other_family']
        result['checks'].append('manual installation defaults do not rewrite existing session; second logical session inherits current defaults')

        # Decline actual readiness using the native consent surface. No worker,
        # fake report or readiness pass is created by refusing the exercise.
        second.click(second_pane, 'Optional readiness exercise…')
        second.choose('readiness', 'Not now — keep completed setup')
        assert registry(runtime)['setup']['state'] == 'completed'
        assert registry(runtime)['setup']['readiness']['state'] != 'passed'
        result['checks'].append('optional actual readiness refusal leaves required setup completed')
        saved = {plugin: read_json(runtime.config/'plugin-data'/plugin/'kv.json')
                 for plugin in ('spawn', 'orchplus')}
        for plugin in ('spawn', 'orchplus'):
            old_boot = trace(runtime, plugin)['boot']
            runtime.command('plugin', 'reload', plugin, '--json')
            lib.wait_for(lambda: trace(runtime, plugin).get('boot', 0) > old_boot, 'native '+plugin+' reload', 30)
        assert spawn_authority(runtime)['config'] == saved['spawn']['authority']['config']
        assert registry(runtime)['installation_defaults'] == saved['orchplus']['authority_state']['installation_defaults']
        assert registry(runtime)['setup']['state'] == 'completed'
        product.capture('setup-after-native-reload')
        result['checks'].append('native host/window reload preserves one saved configuration/defaults/lifecycle')
        result['corrupt_store'] = corrupt_store_refusal(product)
        result['unverified_matrix'] = [
            'Lost-store recovery and immutable outstanding-grant migration require dedicated qualification',
            'Successive changed-helper package digest rollover remains separate qualification; native setup interruptions are exercised at draft, resource/probe, CLI-attestation and committed-record boundaries',
            'Provider-backed readiness/task/check/landing and actual macOS/Windows/cross-user routes remain separate qualification',
        ]
        result['status'] = 'passed'
        result['status_scope'] = 'listed ordinary native setup observations only; unverified_matrix is not accepted as covered'
        product.hold()
    except Exception as error:
        result['error'] = f'{type(error).__name__}: {error}'
        result['failure_traceback'] = traceback.format_exc()
        result['failure_diagnostics'] = window_diagnostics(runtime, 'setup-failure')
        if hasattr(product, 'ui'):
            product.hold()
    finally:
        product.close()
    if args.legacy_archive:
        result['legacy_update_adoption'] = product_legacy_setup(base, root, evidence, processes, lib, args)
        if result['legacy_update_adoption']['status'] != 'passed':
            result['status'] = result['legacy_update_adoption']['status']
    else:
        result['legacy_update_adoption'] = {'status': 'unavailable', 'reason': '--legacy-archive must identify actual prior-version source for native create/update/adoption'}
        if result['status'] == 'passed':
            result['status'] = 'unavailable'
    return result


def worker_observations(product, handle):
    error = read_json(product.control/handle/'error.json')
    assert not error, error
    return read_json(product.control/handle/'observations.json') or {'events': []}


def worker_command(product, handle, operation):
    directory = product.control/handle
    serial = time.time_ns()//1000
    pending = directory/'command.pending'
    pending.write_text(json.dumps({'id': serial, 'op': operation}))
    os.replace(pending, directory/'command.json')
    def completed():
        product.runtime.assert_running()
        worker_observations(product, handle)
        value = read_json(directory/'command-result.json')
        return value if value and value['id'] == serial else None
    return product.lib.wait_for(completed, 'actual deterministic worker '+operation, 600, .1)


def landing_for(product, worker_id, snapshot=None):
    state = registry(product.runtime) if snapshot is None else snapshot
    items = ((state or {}).get('dispatch', {}).get('landing') or {}).get('items', {})
    candidates = [item for item in items.values() if item['worker_id'] == worker_id]
    # Latest native request; do not manufacture a landing record when none exists.
    return candidates[-1] if candidates else None


def approve_landing(product, worker, expected_item=None):
    ui, pane = product.ui, product.controller
    scope = ui.machine(pane, 'orchplus.dispatch', 'dispatch-state')
    assert scope and scope.get('controller_phase') == 'active', 'landing control requires current controller'
    scope_keys = ('source_nonce', 'host_pane_id', 'orch_session_id', 'owner_id', 'owner_generation')
    original_origin = (scope.get('command_cursor') or {}).get('origin')
    def pending():
        state = registry(product.runtime)
        item = landing_for(product, worker['worker_id'], state)
        if not item or not item.get('gate_id'):
            return None
        if expected_item is not None:
            assert item['id'] == expected_item['id'] and item['gate_id'] == expected_item['gate_id'] and item['request'] == expected_item['request'], 'owner decision changed after scoped approval; refusing a different request'
        gate = state['dispatch'].get('gates', {}).get(item['gate_id'])
        return (item, gate) if gate and gate['phase'] == 'pending' else None
    pinned_item, gate = product.lib.wait_for(pending, 'actual landing owner decision', 40)
    last_select = 0.0
    def selected_gate():
        nonlocal last_select
        current_scope = ui.machine(pane, 'orchplus.dispatch', 'dispatch-state')
        assert current_scope and all(current_scope.get(key) == scope.get(key) for key in scope_keys)
        assert (current_scope.get('command_cursor') or {}).get('origin') == original_origin, 'controller origin changed during exact-gate navigation'
        current = pending()
        assert current, 'original landing question is no longer pending'
        item, observed = current
        assert item['id'] == pinned_item['id'] and item['request'] == pinned_item['request'] and item['gate_id'] == gate['id'], 'landing request changed; no approval submitted'
        assert all(observed.get(key) == gate.get(key) for key in
                   ('id', 'revision', 'worker_id', 'worker_generation', 'question', 'options')), 'exact landing question changed'
        visible = ui.machine(pane, 'orchplus.gate', 'workflow-gate-'+gate['id'])
        content = ui.machine(pane, 'orchplus.gate-content', 'workflow-gate-content-'+gate['id'])
        if visible and content and all(visible.get(key) == gate.get(key) for key in
                                      ('id', 'revision', 'worker_id', 'worker_generation')):
            assert content.get('question') == gate['question'] and content.get('options') == gate['options']
            return True
        if time.monotonic() - last_select >= 2:
            last_select = time.monotonic()
            ui.click_match(pane, worker['work_id']+' · ')
        return None
    product.lib.wait_for(selected_gate, 'same worker exact gate projection rendered', 40)
    # Gate pages are native visible controls. The chosen worker can have other
    # open gates; target only the button in the exact gate's visible card.
    observations = product.result.setdefault('gate_picker_observations', [])
    observed_at = 0.0
    def observe_picker(tree):
        nonlocal observed_at
        now = time.monotonic()
        if now - observed_at < .5 or len(observations) >= 80:
            return
        observed_at = now
        roots = ('dispatch-state', 'operator-intent', 'workflow-worker-'+worker['worker_id'],
                 'workflow-gate-'+gate['id'], 'workflow-gate-content-'+gate['id'])
        # Private read-only evidence: do not retry the click, refresh its gate
        # revision, or submit any decision while diagnosing a missing picker.
        observations.append({
            'monotonic_ns': time.monotonic_ns(), 'gate_id': gate['id'],
            'gate_revision': gate['revision'],
            'question_visible': gate['question'] in json.dumps(tree, ensure_ascii=False),
            'surfaces': {root: ui('surface', pane=pane, root='main.'+root) for root in roots},
        })
    ui('click_gate', pane=pane, gate_id=gate['id'], label='Answer exact question…')
    choice, = [option for option in gate['options'] if option['id'] == 'approve']
    ui.choose(gate['question'], choice['label'], observe=observe_picker)
    ui.enter('Explicit owner answer', 'Approve only this exact disposable qualification landing.')
    def committed_answer():
        state = registry(product.runtime)
        item = landing_for(product, worker['worker_id'], state)
        assert item and item['id'] == pinned_item['id'] and item['request'] == pinned_item['request'], 'landing request changed while awaiting the submitted decision'
        current = state['dispatch']['gates'].get(gate['id'])
        assert current and all(current.get(key) == gate.get(key) for key in
                               ('id', 'revision', 'worker_id', 'worker_generation', 'question', 'options')), 'submitted decision no longer names the original gate'
        answer = current.get('answer')
        if answer is None:
            assert current['phase'] == 'pending', 'submitted owner decision was not accepted'
            return None
        assert answer['choice_id'] == 'approve' and answer['source']['kind'] == 'owner'
        assert all(answer['source'].get(key) == value for key, value in (original_origin or {}).items()), 'decision came from another controller origin'
        return current
    return product.lib.wait_for(committed_answer, 'exact submitted owner decision committed', 40)


def policy_cell(base, root, evidence, processes, lib, args, mode, case):
    product = Product(base, root, evidence, processes, lib, 'policy-'+mode+'-'+case, args)
    result, runtime = product.result, product.runtime
    result.update(mode=mode, declared_checks=case)
    def worker_health():
        for path in product.control.glob('*/error.json'):
            error = read_json(path)
            if error:
                result.setdefault('worker_failures', {})[str(path)] = error
                raise AssertionError('actual deterministic worker failed; see '+str(path))
    try:
        product.start()
        lib.WAKERS.append(worker_health)
        product.open_spawn()
        required = {'c2-builder', 'c2-release', MODES[mode][3]}
        for record in RECORDS:
            if record[0] in required:
                product.create_record(*record)
        product.initialize_orch()
        product.configure_orch(mode)
        product.assert_no_controller()
        product.claim()
        ui, pane = product.ui, product.controller
        ui.click(pane, 'Assign explicit task to c2-builder')
        assignment_observed_at = 0.0
        def observe_assignment(tree):
            nonlocal assignment_observed_at
            now = time.monotonic()
            rows = result.setdefault('assignment_observations', [])
            if now - assignment_observed_at < .5 or len(rows) >= 80:
                return
            assignment_observed_at = now
            messages = [node['text'] for node in native_nodes(tree) if isinstance(node.get('text'), str)
                        and len(node['text']) < 500 and not node['text'].startswith('{')
                        and any(word in node['text'].lower() for word in ('refus', 'stale', 'control', 'catalog', 'assignment'))]
            rows.append({'monotonic_ns': time.monotonic_ns(), 'messages': messages,
                         'dispatch': ui.machine(pane, 'orchplus.dispatch', 'dispatch-state'),
                         'intent': ui.machine(pane, 'orchplus.intent', 'operator-intent')})
        check = '' if case == 'empty' else 'fixture: '+shlex.join([
            sys.executable, '-c', "from pathlib import Path; raise SystemExit(0 if Path('fixture.txt').read_text().splitlines()[0]=='good' else 7)"])
        for title, value in (
            ('Explicit assignment for c2-builder', 'C2_CASE='+case+' Create only the controlled fixture.txt artifact. Both good and bad check inputs are intentional. Review verifies committed fixture shape; actual declared checks independently gate landing.'),
            ('Declared files', 'fixture.txt'), ('Checks (one per line', check), ('Base ref', 'refs/heads/main')):
            ui.enter(title, value, observe=observe_assignment if title.startswith('Explicit assignment') else None)
        def launched():
            for path in product.control.glob('*/launched.json'):
                value = read_json(path)
                if value and value['record_id'] == 'c2-builder':
                    return value
            return None
        launch = lib.wait_for(launched, 'actual native managed policy builder', 90)
        handle = launch['transport']['mailbox_handle']
        def accepted():
            for worker in (registry(runtime) or {}).get('dispatch', {}).get('workers', {}).values():
                if worker.get('mailbox_handle') == handle and worker['phase'] == 'accepted':
                    return worker
            return None
        worker = lib.wait_for(accepted, 'actual ACCEPTED report intake', 60)
        worker_command(product, handle, 'prepare')
        item = lib.wait_for(lambda: landing_for(product, worker['worker_id']), 'actual landing request intake', 30)
        initial_decision = approve_landing(product, worker)
        if case in ('failed', 'missing', 'stale'):
            def held():
                current = landing_for(product, worker['worker_id'])
                return current if current and (current.get('hold') or {}).get('code') == 'check_'+case else None
            blocked = lib.wait_for(held, 'declared-check hold independent of review', 90)
            assert not blocked.get('grants'), 'declared check failure/missing/stale evidence granted'
            result['initial_hold'] = blocked
            if MODES[mode][1]:
                approved = lib.wait_for(lambda: next((review for review in registry(runtime)['dispatch'].get('reviews', {}).values()
                                                     if review['builder_worker_id'] == worker['worker_id'] and review['status'] == 'approved'), None),
                                        'real reviewer approval still cannot override declared-check hold', 90)
                assert not landing_for(product, worker['worker_id']).get('grants')
                result['approved_review_did_not_override_checks'] = approved
            if case == 'failed':
                def rework():
                    observations = worker_observations(product, handle)
                    return [event for event in observations['events'] if event['kind'] == 'rework_received'
                            and 'review_id' not in event['payload']]
                first = lib.wait_for(rework, 'real check-only rework delivery without reviewer dependency', 60)
                assert len(first) == 1 and first[0]['payload']['failed_checks']
                worker_command(product, handle, 'repeat-ready')
                lib.idle(2)
                assert len(rework()) == 1, 'unchanged revision issued duplicate check-only rework'
                result['check_only_rework'] = first
                product.capture(mode+'-failed-check-only-repair')
                worker_command(product, handle, 'repair')
                approve_landing(product, worker)
            else:
                assert not [event for event in worker_observations(product, handle)['events']
                            if event['kind'] == 'rework_received' and 'review_id' not in event['payload']], 'missing/stale evidence fabricated failed-check rework'
                product.capture(mode+'-'+case+'-hold')
                worker_command(product, handle, 'run-current-check')
        def landed():
            current = landing_for(product, worker['worker_id'])
            return current if current and current['status'] == 'landed' else None
        final = lib.wait_for(landed, 'real release-manager grant, expected-old Git landing and report intake', 150)
        if case in ('missing', 'stale'):
            assert final['id'] == blocked['id'] and final['request'] == blocked['request'], 'check repair replaced the existing landing request'
            approval = final['approval']
            assert approval['gate_id'] == initial_decision['id'] and approval['gate_revision'] == initial_decision['revision'] and approval['at_ms'] == initial_decision['answer']['at_ms'], 'check repair changed the exact existing owner decision'
            result['repaired_existing_request'] = {'landing_id': final['id'], 'unchanged_request': True,
                                                   'unchanged_owner_approval': True}
        proof = final['proof']
        assert proof['mode'] == mode and proof['artifact_revision'] == final['request']['source_revision']
        assert git(runtime, product.repository, 'rev-parse', 'refs/heads/main') == final['request']['source_revision']
        authority = registry(runtime)
        builder = authority['dispatch']['workers'][worker['worker_id']]
        reviews = [review for review in authority['dispatch'].get('reviews', {}).values()
                   if review['builder_worker_id'] == worker['worker_id']]
        if mode == 'review_disabled':
            assert not reviews and 'review_id' not in proof
            assert not [gate for gate in authority['dispatch']['gates'].values()
                        if gate.get('worker_id') == worker['worker_id'] and gate['kind'] == 'reviewer_unavailable']
        else:
            reviewed = next(review for review in reviews if review['review_id'] == proof['review_id'])
            assert reviewed['status'] == 'approved' and reviewed['reviewer_worker_id'] != worker['worker_id']
            assert (reviewed['builder_family'] != reviewed['reviewer_family']) == (mode == 'cross_family_review')
        if case == 'empty':
            assert not proof['check_refs'] and not builder.get('check_results')
        else:
            assert len(proof['check_refs']) == 1
            check_result = builder['check_results']['fixture']
            assert check_result['exit_code'] == 0 and check_result['head'] == proof['artifact_revision']
        result['landing'] = final
        result['worker_observations'] = {path.parent.name: read_json(path) for path in product.control.glob('*/observations.json')}
        grants = [event['reply'] for value in result['worker_observations'].values()
                  for event in value['events'] if event['kind'] == 'reply' and event['reply']['kind'] == 'landing_grant']
        assert grants, 'no release manager consumed real immutable grant'
        for grant in grants:
            if mode == 'review_disabled':
                assert all(key not in grant['payload'] for key in ('review_id', 'reviewer_family'))
                assert 'review_id' not in grant['payload']['proof']
        result['checks'].append('actual native task/check/review policy/grant/Git landing/report path: '+mode+' / '+case)
        result['status'] = 'passed'
        result['status_scope'] = 'deterministic actual managed-terminal behavior; NOT provider-backed task/review qualification'
        product.capture(mode+'-'+case+'-landed')
        product.hold()
    except Exception as error:
        if worker_health in lib.WAKERS:
            lib.WAKERS.remove(worker_health)
        result['error'] = f'{type(error).__name__}: {error}'
        result['failure_diagnostics'] = window_diagnostics(runtime, 'policy-failure')
        if hasattr(product, 'ui'):
            product.hold()
    finally:
        if worker_health in lib.WAKERS:
            lib.WAKERS.remove(worker_health)
        product.close()
    return result


def product_policy(base, root, evidence, processes, lib, args):
    unavailable = prerequisites()
    if unavailable:
        return unavailable
    if args.provider_readiness:
        return product_provider_readiness(base, root, evidence, processes, lib, args)
    modes, cases = args.policy_modes.split(','), args.policy_cases.split(',')
    if len(set(modes)) != len(modes) or any(mode not in MODES for mode in modes):
        raise ValueError('--policy-modes requires unique '+','.join(MODES))
    valid_cases = ('passed', 'failed', 'missing', 'stale', 'empty')
    if len(set(cases)) != len(cases) or any(case not in valid_cases for case in cases):
        raise ValueError('--policy-cases requires unique '+','.join(valid_cases))
    cells = {}
    result = {'status': 'failed', 'cells': cells,
              'provider_qualification': {'status': 'unavailable', 'reason': 'deterministic native workers are not provider-backed task/review proof; use approved auth-in-place ordinary readiness action separately'},
              'selected_matrix': {'modes': modes, 'checks': cases},
              'unverified_matrix': ['explicit coordinator review proposal refusal', 'reviewer absent/unavailable matrix',
                                    'immutable pre-cutover outstanding-grant drain/block migration', 'actual provider-backed review families']}
    for mode in modes:
        for case in cases:
            cells[mode+'/'+case] = policy_cell(base, root, evidence, processes, lib, args, mode, case)
    if all(cell['status'] == 'passed' for cell in cells.values()):
        result['status'] = 'passed'
    result['status_scope'] = 'selected actual deterministic managed-worker cells only; remaining acceptance is explicit above'
    return result


def product_legacy_setup(base, root, evidence, processes, lib, args):
    from native_smoke import baseline_source
    archive_root = base/'legacy-setup-source'
    archive_root.mkdir()
    legacy = baseline_source(args.legacy_archive, archive_root)
    product = Product(base, legacy, evidence, processes, lib, 'setup-legacy-update-product', args)
    result, runtime = product.result, product.runtime
    result['archive'] = {'path': str(args.legacy_archive.resolve()),
                         'sha256': hashlib.sha256(args.legacy_archive.read_bytes()).hexdigest(),
                         'provenance': 'Caller verifies prior-version source identity; hash alone does not authenticate a commit'}
    try:
        product.start(installed=True)
        ui = product.ui
        pane = ui('open', kind='spawn.spawner')
        lib.wait_for(lambda: spawn_authority(runtime), 'prior-version native SPAWN authority creation', 30)
        ui.preference(pane, page='setup')
        ui.preference(pane, row='setup-add-local')
        original = lib.wait_for(lambda: saved_records(runtime), 'prior-version ordinary manually added record', 30)
        assert len(original) == 1
        legacy_record_id = original[0]['id']
        # Complete the old ordinary editor's review gate before testing adoption.
        # A newly added placeholder has no command and is not a configured route.
        ui.preference(pane, page='agents')
        for label, key, value, expected in (
            ('Command', 'command', sys.executable, sys.executable),
            ('Arguments', 'arguments', shlex.join([str(product.worker), str(product.control), legacy_record_id]),
             [str(product.worker), str(product.control), legacy_record_id]),
            ('Working directory', 'cwd', str(product.repository), str(product.repository)),
        ):
            ui.preference(pane, label=label, value=value)
            lib.wait_for(lambda: next((row for row in saved_records(runtime)
                                      if row['id'] == legacy_record_id and row.get(key) == expected), None),
                         'durable prior-version ordinary edit '+key, 30)
        ui.preference(pane, row='approve-'+legacy_record_id)
        original = lib.wait_for(lambda: saved_records(runtime) if all(
            row.get('command') == sys.executable and not row.get('review_required')
            for row in saved_records(runtime)) else None, 'prior-version configured and explicitly approved ordinary record', 30)
        assert 'setup' not in spawn_authority(runtime), 'legacy source already has setup; select a real prior-version source'
        product.initialize_orch()
        assert 'setup' not in registry(runtime), 'legacy ORCH source already has setup'
        result['old_authorities'] = {'spawn': spawn_authority(runtime), 'orch': registry(runtime)}
        product.capture('actual-prior-version-native-config')

        # Native installer replaces actual owned installed packages, preserving
        # their existing data paths. No final authority state is copied or seeded.
        updated = runtime.root/'updated-packages'
        updated.mkdir()
        product.spawn, product.orch = updated/'SPAWN', updated/'ORCH+'
        instrument(root/'plugins/tern/SPAWN', product.spawn,
                   {'orch_kv': str(runtime.config/'plugin-data/orchplus/kv.json')})
        instrument(root/'plugins/tern/ORCH+', product.orch, {})
        for package in (product.spawn, product.orch):
            runtime.command('plugin', 'install', package, '--force', '--json')
        product.open_spawn()
        assert saved_records(runtime) == original, 'native update destroyed existing records'
        setup = lib.wait_for(lambda: ui.machine(product.controller, 'orchplus.setup'), 'updated native existing-setup projection', 30)
        assert setup['setup']['review_existing'] is True, 'existing ORCH authority was treated as destructive first use'
        assert spawn_authority(runtime).get('setup_adoption_required') is True
        pane = product.spawn_pane
        ui.preference(pane, row='managed-existing', value=legacy_record_id)
        for field, value in {'provider': 'Codex', 'account_label': 'Adopted native legacy fixture',
                             'backend': 'local-terminal', 'executable': sys.executable,
                             'arguments': shlex.join([str(product.worker), str(product.control), legacy_record_id]),
                             'cwd': str(product.repository), 'root': str(runtime.root/'mailboxes'), 'user': ''}.items():
            ui.preference(pane, row='managed:'+field, value=value)
        ui.preference(pane, row='managed-probe')
        lib.wait_for(lambda: 'managed-adopt' in json.dumps(ui('preferences', pane=pane)),
                     'actual upgraded legacy record prerequisite probe', 90)
        product.probe_native_route(pane, legacy_record_id)
        ui.preference(pane, row='managed-cli-attest')
        ui.preference(pane, row='managed-adopt')
        lib.wait_for(lambda: spawn_authority(runtime)['setup']['state'] == 'adopted_existing', 'legacy adoption commit', 30)
        assert any(record['id'] == legacy_record_id for record in saved_records(runtime))
        for record in (RECORDS[0], RECORDS[3]):
            product.create_record(*record)
        # ORCH's true migration flag selects the native Review existing setup
        # entry. The same defaults writer commits the required setup.
        ui('action', pane=product.controller, action='plugin.orchplus.orch_setup')
        ui.choose('Review existing setup', 'Configure ORCH installation defaults')
        ui.choose('Choose review policy explicitly', MODES['review_disabled'][0])
        ui.enter('Repository checkout path', str(product.repository))
        ui.enter('Existing target ref', 'refs/heads/main')
        ui.choose('Owner-declared landing queue', 'orch_queue')
        ui.choose('Select Builder', 'c2-builder')
        ui.choose('Select Release manager', 'c2-release')
        ui.choose('Select Coordinator (optional)', 'None — optional')
        ui.choose('Select Labeller (optional)', 'None — optional')
        ui.choose('Required setup complete', 'Finish setup')
        lib.wait_for(lambda: registry(runtime)['setup']['state'] == 'adopted_existing', 'actual old ORCH authority adopted', 30)
        assert registry(runtime)['setup']['readiness']['state'] == 'not_run'
        product.assert_no_controller()
        result['checks'].append('old source ordinary UI creates real old stores; native package replacement migrates to explicit adoption without resetting records or creating controllers')
        result['status'] = 'passed'
        result['status_scope'] = 'actual prior-version creation/native update/adoption; no outstanding grant migration claimed'
        product.capture('native-update-adopted-existing')
        product.hold()
    except Exception as error:
        result['error'] = f'{type(error).__name__}: {error}'
        result['failure_traceback'] = traceback.format_exc()
        result['failure_diagnostics'] = window_diagnostics(runtime, 'legacy-setup-failure')
        if hasattr(product, 'ui'):
            product.hold()
    finally:
        product.close()
    return result


def corrupt_store_refusal(product):
    """Negative fault only: malformed owned bytes, then exact original restore."""
    runtime = product.runtime
    path = runtime.config/'plugin-data/orchplus/kv.json'
    original = path.read_bytes()
    backup = runtime.root/'before-corrupt-store.bytes'
    backup.write_bytes(original)
    malformed = b'{"deliberate_owned_runtime_corruption":'
    evidence = {'fault': 'malformed bytes, not a seeded valid authority',
                'original_sha256': hashlib.sha256(original).hexdigest(), 'backup': str(backup)}
    try:
        path.write_bytes(malformed)
        runtime.command('plugin', 'reload', 'orchplus', '--json', check=False)
        def refused():
            tree = product.ui('surface', pane=product.controller)
            text = json.dumps(tree, ensure_ascii=False)
            return tree if 'Authority store:' in text and ('corrupt' in text.lower() or 'unreadable' in text.lower() or 'failed' in text.lower()) else None
        evidence['surface'] = product.lib.wait_for(refused, 'actual native corrupt-store refusal', 30)
        assert path.read_bytes() == malformed, 'product overwrote corrupt store with a fresh authority'
        evidence['capture'] = window_diagnostics(runtime, 'owned-corrupt-store-refusal')
    finally:
        temporary = path.with_suffix('.restore')
        temporary.write_bytes(original)
        os.replace(temporary, path)
        runtime.command('plugin', 'reload', 'orchplus', '--json')
        product.lib.wait_for(lambda: registry(runtime), 'restored exact previously-created authority bytes', 30)
    evidence['restored_defaults'] = registry(runtime)['installation_defaults']
    return evidence


def provider_session_identity(session_dir, model, worker):
    """Qualify actual provider responses, not a native human-readable label."""
    files = sorted(session_dir.glob('*.jsonl'))
    assert len(files) == 1, 'missing or ambiguous owned provider session'
    payload = files[0].read_bytes()
    lines = payload.splitlines(keepends=True)
    # A still-idle worker may append another event. Never parse an incomplete
    # final append or claim it was part of this observed transcript snapshot.
    complete = [line for line in lines if line.endswith(b'\n')]
    rows = [json.loads(line) for line in complete]
    messages = [row['message'] for row in rows if row.get('type') == 'message']
    first_user = next(message for message in messages if message.get('role') == 'user')
    content = first_user['content']
    parts = [{'text': content}] if isinstance(content, str) else content
    transports = [json.loads(line.removeprefix('report-files-v1: '))
                  for part in parts if isinstance(part, dict)
                  for line in part.get('text', '').splitlines()
                  if line.startswith('report-files-v1: ')]
    assert len(transports) == 1, 'missing or ambiguous native startup transport'
    binding = {key: worker[key] for key in ('logical_session_id', 'worker_id',
               'worker_generation', 'work_id', 'launch_request_id', 'enrolment_token')}
    assert transports[0]['binding'] == binding, 'provider session belongs to a different worker incarnation'
    assert transports[0]['assignment_sha256'] == worker['assignment_sha256'], 'provider assignment differs from the actual authorized assignment'
    provider, model_id = model.split('/', 1)
    responses = [message for message in messages if message.get('role') == 'assistant']
    assert responses, 'selected route produced no actual provider response'
    assert all(message.get('provider') == provider and message.get('model') == model_id
               for message in responses), 'actual provider/model differs from the selected route'
    return {'session_file': str(files[0]), 'snapshot_sha256': hashlib.sha256(payload).hexdigest(),
            'provider': provider, 'model_id': model_id, 'assistant_responses': len(responses),
            'worker_id': worker['worker_id'], 'worker_generation': worker['worker_generation'],
            'exact_startup_binding': True, 'exact_assignment': True,
            'incomplete_final_event_excluded': bool(lines and not lines[-1].endswith(b'\n'))}


def provider_readiness_cell(base, root, evidence, processes, lib, args, mode):
    product = Product(base, root, evidence, processes, lib, 'provider-readiness-'+mode, args, provider=True)
    result, runtime = product.result, product.runtime
    result.update(mode=mode, explicit_provider_consent=True, automatic_native_permission_answers=False)
    try:
        # Real installed copies, not development links, bind capture endpoints,
        # source observation and this actual provider run to the same packages.
        product.start(installed=True)
        product.open_spawn()
        required = {'c2-builder', 'c2-release', MODES[mode][3]}
        for record in RECORDS:
            if record[0] in required:
                product.create_record(*record)
        product.initialize_orch()
        product.configure_orch(mode)
        product.assert_no_controller()
        product.claim()
        product.capture('provider-'+mode+'-saved-policy')
        ui, pane = product.ui, product.controller
        ui('action', pane=pane, action='plugin.orchplus.orch_readiness')
        product.capture('provider-'+mode+'-explicit-readiness-consent')
        ui.choose('Optional readiness', 'Run real readiness exercise')
        deadline = time.monotonic()+900
        observed_agents, observed_workers, observed_identities, captured, approved = {}, {}, {}, set(), set()
        result['native_worker_observations'] = observed_workers
        last_phase = None
        while time.monotonic() < deadline:
            runtime.assert_running()
            state = registry(runtime)
            readiness = state['setup']['readiness']
            if readiness['state'] == 'failed':
                raise AssertionError('actual product readiness failed: '+readiness['summary'])
            agents = ui('agents')
            for agent in agents:
                observed_agents[str(agent['pane'])] = agent
                if agent.get('delivery_error'):
                    raise AssertionError('native managed startup delivery refused: '+agent['delivery_error'])
            waiting = [agent for agent in agents if agent['state'] == 'waiting_input']
            if waiting:
                # Never approve native permission/auth/billing questions. Expose
                # the exact owned window for Main, with no retry or extra launch.
                result['native_input_required'] = waiting
                if 'native-input' not in captured:
                    product.capture('provider-native-input-required')
                    captured.add('native-input')
                product.metadata('provider-native-input-required')
                lib.idle(.5)
                continue
            workers = state.get('dispatch', {}).get('workers', {})
            native = {str(agent['pane']): agent for agent in agents}
            for worker_id, worker in workers.items():
                observed_identities[worker_id] = worker
                binding = worker.get('pane_binding') or {}
                agent = native.get(binding.get('pane_id'))
                if agent and agent.get('model') and agent.get('command'):
                    observed_workers[worker_id] = {'record_id': worker['record_id'],
                                                   'binding': binding, 'native_agent': agent}
            builders = [worker for worker in workers.values() if worker['record_id'] == 'c2-builder']
            builder = builders[0] if len(builders) == 1 else None
            item = landing_for(product, builder['worker_id'], state) if builder else None
            phase = 'landed' if item and item['status'] == 'landed' else 'decision' if item and item.get('gate_id') else 'worker-activity' if builders else 'assignment'
            if phase != last_phase:
                product.capture('provider-'+mode+'-'+phase)
                last_phase = phase
            if item and item.get('gate_id'):
                gate = state['dispatch']['gates'][item['gate_id']]
                if gate['phase'] == 'pending':
                    product.metadata('provider-awaiting-owner-landing')
                    if args.provider_approve_landing and gate['id'] not in approved:
                        # This is the same displayed native owner question. It
                        # is restricted to the actual owned readiness repository.
                        requested = Path(item['request']['repo_ref']).resolve()
                        assert requested.is_relative_to((runtime.config/'plugin-data/orchplus').resolve())
                        assert requested.name.startswith('readiness-') and item['request']['target_ref'] == 'refs/heads/main'
                        result.setdefault('owner_decisions', []).append(approve_landing(product, builder, expected_item=item))
                        approved.add(gate['id'])
            if readiness['state'] == 'passed':
                assert item and item['status'] == 'landed', 'readiness passed without actual matching landing'
                repository = Path(item['request']['repo_ref']).resolve()
                assert repository.is_relative_to((runtime.config/'plugin-data/orchplus').resolve())
                assert git(runtime, repository, 'show', 'refs/heads/main:readiness.txt') == 'ready'
                assert git(runtime, repository, 'rev-parse', 'refs/heads/main') == item['request']['source_revision']
                proof = item['proof']
                assert proof['mode'] == mode and proof['check_refs']
                if mode == 'review_disabled':
                    assert 'review_id' not in proof
                    assert not [review for review in state['dispatch'].get('reviews', {}).values()
                                if review['builder_worker_id'] == builder['worker_id']]
                else:
                    review = state['dispatch']['reviews'][proof['review_id']]
                    assert review['status'] == 'approved'
                    assert review['reviewer_worker_id'] != builder['worker_id']
                    assert review['builder_family'] == 'openai'
                    assert review['reviewer_family'] == ('anthropic' if mode == 'cross_family_review' else 'openai')
                    result['review'] = review
                landed_grants = [grant for grant in item['grants']
                                 if (grant.get('result') or {}).get('outcome') == 'landed']
                assert len(landed_grants) == 1, 'actual release-manager landed result is missing or ambiguous'
                roles = {'builder': (builder['worker_id'], 'c2-builder', 'openai-codex/gpt-6-astra'),
                         'release_manager': (landed_grants[0]['worker_id'], 'c2-release', 'openai-codex/gpt-6-astra')}
                if mode != 'review_disabled':
                    roles['reviewer'] = (review['reviewer_worker_id'], MODES[mode][3],
                                         'anthropic/claude-opus-5-5' if mode == 'cross_family_review' else 'openai-codex/gpt-6-astra')
                role_observations = {}
                for role, (worker_id, record_id, model) in roles.items():
                    observed = observed_workers.get(worker_id)
                    assert observed and observed['record_id'] == record_id, 'missing exact native worker binding for '+role
                    session_dir = runtime.root/'provider-sessions'/record_id
                    identity = provider_session_identity(session_dir, model, observed_identities[worker_id])
                    argv = shlex.split(observed['native_agent']['command'])
                    assert argv.count('--model') == 1 and argv[argv.index('--model')+1] == model, 'actual selected provider command mismatch for '+role
                    assert argv.count('--session-dir') == 1 and Path(argv[argv.index('--session-dir')+1]).resolve() == session_dir.resolve(), 'actual native session storage mismatch for '+role
                    role_observations[role] = {'worker_id': worker_id, 'provider_identity': identity, **observed}
                result['native_role_observations'] = role_observations
                result.update(status='passed', readiness=readiness, landing=item,
                              observed_native_agents=list(observed_agents.values()),
                              status_scope='actual native provider task, helper checks, configured review mode, ordinary owner decision and release-manager landing with Git readback')
                product.capture('provider-'+mode+'-final-landing')
                break
            lib.idle(.5)
        else:
            raise AssertionError('bounded actual provider readiness did not finish; inspect retained native workflow/permission gates; no retry or provider fallback was attempted')
        product.hold()
    except Exception as error:
        result['error'] = f'{type(error).__name__}: {error}'
        result['failure_diagnostics'] = window_diagnostics(runtime, 'provider-readiness-failure')
        if hasattr(product, 'ui'):
            product.hold()
    finally:
        product.close()
    return result


def product_provider_readiness(base, root, evidence, processes, lib, args):
    modes = args.policy_modes.split(',')
    if len(set(modes)) != len(modes) or any(mode not in MODES for mode in modes):
        raise ValueError('--policy-modes requires unique '+','.join(MODES))
    if not shutil.which('omp') or not args.provider_agent_dir.is_absolute() or not args.provider_agent_dir.is_dir():
        return {'status': 'unavailable', 'reason': 'explicit provider mode requires installed OMP and the approved absolute existing native agent directory; no credentials are copied'}
    cells = {}
    for mode in modes:
        cells[mode] = provider_readiness_cell(base, root, evidence, processes, lib, args, mode)
        if cells[mode]['status'] != 'passed':
            break  # Auth/billing/permission failures never trigger another provider run.
    return {'status': 'passed' if len(cells) == len(modes) and all(cell['status'] == 'passed' for cell in cells.values()) else 'failed',
            'cells': cells, 'provider_qualification': True,
            'status_scope': 'actual fixed product readiness task for selected modes; failed/missing/stale/empty check matrix is the separately labelled deterministic native scenario'}

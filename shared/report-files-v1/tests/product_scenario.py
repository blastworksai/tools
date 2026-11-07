"""Actual ORCH+/SPAWN GUI report path. No reducer or runtime-driver substitutes."""
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import uuid
from owned_runtime import owned_runtime

TESTS = Path(__file__).resolve().parent


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


class UI:
    def __init__(self, runtime, lib):
        self.runtime, self.lib, self.serial = runtime, lib, 0
        self.data = runtime.config/'plugin-data/report-product-driver'
        lib.wait_for(lambda: read_json(self.data/'ready.json'), 'real product UI controller', 30)

    def __call__(self, op, **fields):
        if op == 'action':
            # Ordinary native action dispatch, outside a plugin callback. Cross-plugin
            # product navigation is exercised through its actual clicked controls.
            if fields.get('pane') is not None:
                self('focus', pane=fields['pane'])
            self.runtime.ctl('plugins', 'run', fields['action'])
            return True
        self.serial += 1
        request = {'id': self.serial, 'op': op, **fields}
        temporary = self.data/'command.pending'
        temporary.write_text(json.dumps(request))
        os.replace(temporary, self.data/'command.json')
        def ready():
            result = read_json(self.data/'response.json')
            return result if result and result.get('id') == self.serial else None
        result = self.lib.wait_for(ready, 'native UI '+op, 20, .05)
        if not result['ok']:
            raise AssertionError(result['error'])
        return result.get('result')

    def click(self, pane, label):
        self.lib.wait_for(lambda: label in json.dumps(self('surface', pane=pane), ensure_ascii=False), 'native button '+label, 40)
        return self('click', pane=pane, label=label)

    def prompt(self, label, text):
        self.lib.wait_for(lambda: label in json.dumps(self.runtime.ctl('tree'), ensure_ascii=False), 'native prompt '+label, 30)
        if text:
            self.runtime.ctl('type', json.dumps(text, ensure_ascii=False))
        self.runtime.ctl('key', 'Enter')


def instrument(source, target, configuration):
    shutil.copytree(source, target)
    original = target/'host.luau'
    original.rename(target/'product_original_host.luau')
    original.write_text('return require("./product_probe").run("product_original_host", "host")\n')
    shutil.copy2(TESTS/'product_probe.luau', target/'product_probe.luau')
    (target/'product-probe.json').write_text(json.dumps(configuration))
    window = target/'window.luau'
    window.rename(target/'product_original_window.luau')
    window.write_text('local product = require("./product_probe").run("product_original_window", "window")\n'
                      'local path = tern.plugin.data .. "/product-window-load.json"\n'
                      'local ok, bytes = pcall(tern.fs.read, path)\n'
                      'local generation = if ok then tern.json.decode(bytes).generation + 1 else 1\n'
                      'tern.fs.write(path, tern.json.encode({generation=generation, registered=true}))\n'
                      'return product\n')


def trace(runtime, plugin, realm='host'):
    filename = 'product-window-trace.json' if realm == 'window' else 'product-trace.json'
    return read_json(runtime.config/'plugin-data'/plugin/filename) or {'events': []}


def registry(runtime):
    return (read_json(runtime.config/'plugin-data/orchplus/kv.json') or {}).get('authority_state')


def measurements(runtime):
    observations = {plugin+'/'+realm: trace(runtime, plugin, realm)
                    for plugin in ('orchplus', 'spawn') for realm in ('host', 'window')}
    if any('metrics' not in value for value in observations.values()):
        return None  # A native trace write may be in progress; never invent zeroes.
    keys = ('helper_processes', 'codec_hashed_bytes', 'codec_hash_calls', 'bridge_events', 'kv_writes')
    return {'totals': {key: sum(value.get('metrics', {}).get(key, 0) for value in observations.values()) for key in keys},
            'contexts': {context: {'metrics': value.get('metrics', {}), 'codec_modules': value.get('codec_modules', {})}
                         for context, value in observations.items()}}


def select_native_dark(runtime):
    runtime.ctl('prefs', 'appearance')
    runtime.ctl('prefs', 'search', 'Appearance')
    tree = runtime.ctl('tree')
    path = runtime.root/'native-appearance-preferences.json'
    path.write_text(json.dumps(tree, indent=2))
    def nodes(items):
        for item in items:
            yield item
            yield from nodes(item.get('children', []))
    dark, = [node for node in nodes(tree['tree']) if node.get('tag') == 'button' and node.get('text') == 'Dark']
    x, y, width, height = dark['rect']
    response = runtime.ctl('click', str(x+width/2), str(y+height/2))
    runtime.ctl('prefs', 'close')
    return {'control': dark, 'click_response': response, 'preferences_tree': str(path), 'state': runtime.checked_state()}


def observe_appearance(runtime, lib, result, label):
    # Native appearance is a separate final-media qualification, never a
    # configured-slot substitute or a barrier to functional report-path proof.
    diagnostic = result.setdefault('appearance_diagnostics', {})[label] = {'observed_appearance_changes': []}
    def active():
        state = runtime.checked_state()
        diagnostic['last_observed_state'] = state
        appearance = {key: state.get(key) for key in ('theme', 'theme_dark', 'theme_light', 'theme_preview', 'material')}
        changes = diagnostic['observed_appearance_changes']
        if not changes or changes[-1] != appearance:
            changes.append(appearance)
        return state if state.get('theme') in ('dark', 'obsidian') and state.get('theme_dark') == 'obsidian' and state.get('material') == 'Solid' else None
    first = active()
    lib.idle(.5)
    stable = active()
    diagnostic['native_state_qualified'] = first is not None and stable is not None
    diagnostic['status'] = 'requires_visual_review' if diagnostic['native_state_qualified'] else 'unresolved'
    diagnostic['capture'] = window_diagnostics(runtime, 'appearance-'+label)
    result['final_media_qualification'] = {
        'status': 'unresolved',
        'required': 'actual resolved Dark Obsidian / Solid native state AND inspection of ordinary-GUI pixels; configured slots alone do not qualify',
        'functional_barrier': False,
    }
    return diagnostic['last_observed_state']


def window_diagnostics(runtime, label='failure'):
    """Keep actual owned-window evidence before supervisor cleanup."""
    shot_name = 'report-'+label+'-'+uuid.uuid4().hex
    observed = {'shot_name': shot_name}
    for name, capture in (
        ('state', runtime.checked_state),
        ('tree', lambda: runtime.ctl('tree')),
        ('shot', lambda: runtime.ctl('shot', shot_name)),
    ):
        try:
            observed[name] = capture()
        except Exception as error:
            observed[name+'_error'] = f'{type(error).__name__}: {error}'
    artifacts = []
    for key in ('png', 'layout'):
        returned = observed.get('shot', {}).get(key)
        if returned:
            path = (runtime.root/returned).resolve()
            if not path.is_relative_to(runtime.root.resolve()):
                observed['shot_path_error'] = 'native shot returned a path outside its owned runtime'
            elif path.is_file():
                artifacts.append(str(path))
    observed['shot_artifacts'] = artifacts
    return observed


def product_reports(base, root, evidence, processes, lib, name='reports-product-current'):
    required = ('xvfb-run', 'git', 'sh', 'jq', 'awk', 'iconv', 'base64', 'sha256sum')
    missing = [name for name in required if not shutil.which(name)]
    if sys.platform != 'linux' or missing:
        return {'status': 'unavailable', 'prerequisites': missing, 'platform': sys.platform,
                'reason': 'this actual local-terminal scenario qualifies Linux only; Windows-native OMP/cross-user remain unsupported'}
    runtime = owned_runtime(lib, base, name, evidence, processes)
    result = {'status': 'failed', 'route': 'real ORCH+/SPAWN host and window entrypoints; real staged bridge; actual managed local-terminal producer',
              'provider': 'deterministic local terminal, not a provider-backed agent',
              'source': str(root), 'run': name,
              'endpoints': {'config': str(runtime.config), 'daemon_socket': str(runtime.sock), 'control_socket': str(runtime.control), 'logs': str(runtime.logs)},
              'checks': []}
    control = runtime.root/'worker-control'
    control.mkdir()
    mailbox = runtime.root/'mailboxes'
    mailbox.mkdir()
    repository = runtime.root/'repository'
    repository.mkdir()
    for args in (('init', '-q', '-b', 'main'), ('config', 'user.name', 'Native report fixture'),
                 ('config', 'user.email', 'report-fixture@example.invalid')):
        subprocess.run(['git', '-C', str(repository), *args], env=runtime.env, check=True, capture_output=True, timeout=15)
    (repository/'fixture.txt').write_text('Disposable native report qualification.\n')
    for args in (('add', 'fixture.txt'), ('commit', '-q', '-m', 'Disposable report fixture')):
        subprocess.run(['git', '-C', str(repository), *args], env=runtime.env, check=True, capture_output=True, timeout=15)
    result['disposable_repository'] = str(repository)
    packages = runtime.root/'product-packages'
    packages.mkdir()
    worker = packages/'product_worker.py'
    shutil.copy2(TESTS/'product_worker.py', worker)
    spawn = packages/'SPAWN'
    orch = packages/'ORCH+'
    record = dict(id='native-report-worker', provider='Deterministic test producer', account_label='isolated same-user terminal',
                  backend='local-terminal', enabled=True, include_all=False, placement='tab', cwd=str(repository),
                  command=sys.executable, arguments=[str(worker), str(control)], fresh_executable=sys.executable,
                  fresh_arguments=[str(worker), str(control)], task_argument_index=3,
                  mailbox=dict(verified=True, permitted_root=str(mailbox), helper_path=str(spawn/'mailbox_target.sh'),
                               producer_helper_path=str(spawn/'mailbox_worker.sh'), worker_identity=pwd.getpwuid(os.getuid()).pw_name,
                               evidence_ref='isolated reviewed packaged helper fixture; not setup-wizard qualification', wake='worker-poll-v1',
                               capabilities=['report-files-v1', 'worker-poll-v1', 'argv-v1'],
                               producer=dict(read=True, write=True, hash=True, journal=True, poll=True)))
    instrument(root/'plugins/tern/SPAWN', spawn, {'record': record, 'orch_kv': str(runtime.config/'plugin-data/orchplus/kv.json')})
    instrument(root/'plugins/tern/ORCH+', orch, {})
    driver = packages/'driver'
    driver.mkdir()
    shutil.copy2(TESTS/'product_driver.luau', driver/'window.luau')
    (driver/'plugin.toml').write_text('schema = 1\nid = "report-product-driver"\nname = "Report product UI driver"\nversion = "0.1.0"\nwindow = "window.luau"\n')
    try:
        runtime.start()
        runtime.command('plugin', 'link', spawn)
        runtime.command('plugin', 'link', orch)
        runtime.command('plugin', 'link', driver)
        ui = UI(runtime, lib)
        if 'tn-signin-x' in json.dumps(runtime.ctl('tree')):
            result['optional_signin_dismissal'] = runtime.ctl('click', '.tn-signin-x')
        result['appearance_commands'] = []
        for command in (('theme', 'dark', 'obsidian'), ('appearance', 'dark'), ('style', 'solid')):
            result['appearance_commands'].append({'command': list(command), 'response': runtime.ctl(*command)})
        result['native_appearance_selection'] = select_native_dark(runtime)
        lib.idle(.5)
        result['appearance'] = observe_appearance(runtime, lib, result, 'initial')
        result['owned_environment'] = runtime.owned_environment
        result['native_context'] = ui('context')
        result['spawn_config_pane'] = ui('open', kind='spawn.spawner')
        lib.wait_for(lambda: any(event['kind'] == 'configured_fixture_record' for event in trace(runtime, 'spawn')['events']), 'host-authority configured fixture record', 30)
        controller = ui('open', kind='orchplus.orchestrator')
        result['controller_pane'] = controller
        for label in ('Initialize first-use authority…', 'Confirm first use — no prior owners or lost store',
                      'Register a distinct logical session…', 'Confirm distinct session registration', 'Claim controller in this pane'):
            result['checks'].append(ui.click(controller, label))
        ui.click(controller, 'Load configured SPAWN catalog')
        def eligible_catalog():
            authority = registry(runtime)
            catalogs = authority and authority.get('dispatch', {}).get('catalogs', {})
            for catalog in (catalogs or {}).values():
                for configured in catalog.get('records', []):
                    if configured.get('id') == record['id']:
                        result['catalog_record'] = configured
                        assert configured.get('eligible'), 'actual SPAWN catalog refused fixture record: '+json.dumps(configured.get('unsupported'))
                        return configured
            return None
        lib.wait_for(eligible_catalog, 'actual eligible SPAWN catalog record', 30)
        ui.click(controller, 'Assign explicit task to native-report-worker')
        for label, text in (
            ('Explicit assignment for native-report-worker', 'Publish the deterministic report qualification; do not modify any repository.'),
            ('Declared files', ''), ('Checks (one per line', ''), ('Base ref', '')):
            ui.prompt(label, text)
        def worker_result(name):
            runtime.assert_running()
            failure = read_json(control/'worker-error.json')
            if failure:
                raise AssertionError(failure)
            return read_json(control/(name+'.json'))
        launched = lib.wait_for(lambda: worker_result('launched'), 'actual SPAWN managed terminal launch', 90)
        result['launch'] = launched
        accepted = lib.wait_for(lambda: worker_result('accepted'), 'actual ACCEPTED intake and helper ACK', 90)
        lib.idle(.3)  # Flush passive counters before releasing the real producer.
        result['measurement_before'] = lib.wait_for(lambda: measurements(runtime), 'complete native pre-report counters', 20)
        (control/'publish').write_text('publish the measured real report\n')
        reported = lib.wait_for(lambda: worker_result('reported'), 'actual multi-chunk report publication', 60)
        acknowledged = lib.wait_for(lambda: worker_result('ack-published'), 'actual ORCH report cursor and published ACK', 120)
        result['published_report'] = reported
        result['ack_before_reload'] = acknowledged
        before = registry(runtime)
        workers = [worker for worker in before['dispatch']['workers'].values() if worker['mailbox_handle'] == launched['transport']['mailbox_handle']]
        assert len(workers) == 1 and workers[0]['accepted_seq'] == 2, 'actual ORCH cursor did not consume exactly two reports'
        spawn_trace = trace(runtime, 'spawn')['events']
        operations = [event['data'] for event in spawn_trace if event['kind'] == 'adapter_execute']
        reads = [item for item in operations if item['mode'] == 'read' and item.get('path', '').startswith('reports/2/')]
        acknowledgments = [item for item in operations if item.get('ack', {}).get('seq') == 2]
        assert len(reads) >= 2 and acknowledgments and all(item['cursor_before_ack'] for item in acknowledgments), 'actual adapter did not observe durable ORCH cursor before ACK'
        authorizations = [event['data'] for event in spawn_trace if event['kind'] == 'bridge_event' and event['data']['act'] == 'spawn.authorize']
        assert authorizations, 'no actual SPAWN window authorization was observed'
        actual_reads = []
        for event in authorizations:
            payload = json.loads(event['value'])
            request = json.loads(payload['request_json'])
            if request['op'] == 'mailbox_read' and request.get('selector', {}).get('stream') == 'report':
                actual_reads.append((event, payload, request))
        assert actual_reads, 'report reads bypassed the staged origin authorization path'
        authorized_ids = {request['request_id'] for _, _, request in actual_reads}
        assert all(item['request_id'] in authorized_ids for item in reads), 'an actual report helper read had no native window authorization event'
        result['checks'].append('real SPAWN window authorized staged report reads; real ORCH dispatch persisted cursor before ACK adapter execution')
        ack_ids = {item['id'] for item in acknowledgments}
        lib.wait_for(lambda: any(event['kind'] == 'adapter_result' and event['data']['id'] in ack_ids and event['data']['status'] == 'published'
                                for event in trace(runtime, 'spawn')['events']), 'actual ACK helper completion callback', 30)
        lib.idle(.3)
        result['measurement_after'] = lib.wait_for(lambda: measurements(runtime), 'complete native post-ACK counters', 20)
        start, finish = result['measurement_before']['totals'], result['measurement_after']['totals']
        metrics = {key: finish[key]-start[key] for key in start}
        assert all(value >= 0 for value in metrics.values()), 'passive counters moved backwards during report delivery'
        producer_calls = len(reported['helper_invocations'])-len(accepted['helper_invocations'])
        metrics['native_helper_processes'] = metrics['helper_processes']
        metrics['producer_helper_processes'] = producer_calls
        metrics['helper_processes'] += producer_calls
        metrics['report_to_ack_ms'] = acknowledged['report_to_ack_ms']
        metrics['publication_return_to_ack_ms'] = acknowledged['publication_return_to_ack_ms']
        assert all(metrics[key] > 0 for key in ('helper_processes', 'codec_hash_calls', 'bridge_events', 'kv_writes')), 'actual product measurement omitted a required report-path effect'
        result['metrics'] = metrics
        result['measurement_scope'] = {
            'interval': 'after ACCEPTED receipt consumption, before measured report release, through real seq=2 ACK helper completion; excludes forged-origin and reload exercises',
            'helper_processes': 'actual native packaged helper launches plus producer helper subprocesses; excludes shell-tool descendants and the managed terminal itself',
            'codec_hashed_bytes': 'input bytes of observed loaded-module sha256 calls in both native host/window contexts; excludes shell-tool hashes, Python fixture hashes and native internal hashes',
            'bridge_events': 'actual incoming SPAWN dispatch action events, including authorization; not synthetic fixture events',
            'kv_writes': 'actual successful native kv.set calls from both instrumented product host/window entrypoints, including any background writes during the interval',
            'report_to_ack_ms': 'same worker monotonic clock: immediately before report helper invocation to observation of the actual ACK file (50ms polling); producer report/ACK epoch timestamps and ACK filesystem mtime retained separately',
            'instrumentation': 'identical forwarding probes on baseline/current; bounded trace records and 250ms dirty-counter file flushes add measurement overhead',
        }
        # New bridge, valid wire shape, deliberately absent live ORCH action. The
        # product window must not turn a host-staged challenge into permission.
        original_event, authorization, original_request = actual_reads[-1]
        forged = json.loads(json.dumps(original_request))
        forged['request_id'] = 'native-forged-report-read'
        forged['action_id'] = 'native-forged-report-action'
        forged['origin_binding']['alias_nonce'] = 'native-forged-alias'
        attack_bridge = ui('open', kind='spawn.dispatch')
        ui('event', pane=attack_bridge, event={'ev': 'action', 'id': 'main.spawn-dispatch-response', 'act': forged['op'], 'value': json.dumps(forged)})
        lib.idle(3)
        forged_surface = ui('surface', pane=attack_bridge)
        assert not any(event['kind'] == 'adapter_execute' and event['data'].get('request_id') == forged['request_id'] for event in trace(runtime, 'spawn')['events']), 'forged origin executed a helper'
        assert forged['request_id'] in json.dumps(forged_surface), 'forged request never reached the actual bridge surface'
        result['forged_origin_surface'] = forged_surface
        # A consumed challenge nonce, even with its original exact signature, may
        # not execute on a fresh bridge. The original genuine effect already ran.
        ui('event', pane=attack_bridge, event={'ev': 'action', 'id': 'main.spawn-dispatch-response', 'act': 'spawn.authorize', 'value': json.dumps(authorization)})
        replay = lib.wait_for(lambda: next((event['data'] for event in reversed(trace(runtime, 'spawn')['events']) if event['kind'] == 'authorize_result' and event['data']['pane'] == attack_bridge), None), 'consumed authorization replay refusal', 20)
        assert replay.get('body', {}).get('status') in ('rejected', 'uncertain'), replay
        result['authorization_replay'] = replay
        result['checks'].append('forged live-origin request produced no helper effect; consumed nonce replay refused on a different bridge')
        # ACK exists, but this real producer has deliberately not consumed it.
        # Reload real ORCH host/window entrypoints, then deliver the outstanding ACK.
        box = mailbox/launched['transport']['mailbox_handle']
        journal = read_json(box/'producer/journal.json')
        assert any(entry['seq'] == 2 for entry in journal['pending']), 'reload boundary lost outstanding report delivery'
        boot = trace(runtime, 'orchplus')['boot']
        window_load = runtime.config/'plugin-data/orchplus/product-window-load.json'
        window_generation = read_json(window_load)['generation']
        runtime.command('plugin', 'reload', 'orchplus', '--json')
        lib.wait_for(lambda: trace(runtime, 'orchplus').get('boot', 0) > boot, 'real ORCH host reload', 30)
        lib.wait_for(lambda: (read_json(window_load) or {}).get('generation', 0) > window_generation, 'real ORCH window re-registration', 30)
        restored = registry(runtime)
        restored_worker = restored['dispatch']['workers'][workers[0]['worker_id']]
        assert restored_worker['accepted_seq'] == 2, 'reload lost or repeated report intake'
        (control/'consume').write_text('consume already-published ACK\n')
        settled = lib.wait_for(lambda: worker_result('settled'), 'real producer consumes outstanding ACK after reload', 30)
        assert settled['ack_sha256'] == acknowledged['ack_sha256'], 'reload changed immutable ACK bytes'
        assert settled['journal']['next_seq'] == reported['journal']['next_seq'], 'reload allocated another report sequence'
        assert worker_result('launched')['pid'] == launched['pid'], 'reload launched another managed producer'
        result['settled_after_reload'] = settled
        result['checks'].append('actual host/window reload retained cursor and immutable outstanding ACK; real producer settled without another report sequence')
        result['final_surface'] = ui('surface', pane=controller)
        result['final_window'] = observe_appearance(runtime, lib, result, 'after_reload')
        failures = [line for path in runtime.logs.glob('*.log') for line in path.read_text(errors='replace').splitlines()
                    if 'tern::plugin' in line and ('ERROR' in line or 'exceeded' in line or 'failed to load' in line)]
        assert not failures, failures
        result['status'] = 'passed'
        result['status_scope'] = 'functional native product report path; final-media appearance qualification is separate'
    except Exception as error:
        result['error'] = f'{type(error).__name__}: {error}'
        result['failure_diagnostics'] = window_diagnostics(runtime)
    finally:
        result['orch_trace'] = trace(runtime, 'orchplus')
        result['spawn_trace'] = trace(runtime, 'spawn')
        result['orch_window_trace'] = trace(runtime, 'orchplus', 'window')
        result['spawn_window_trace'] = trace(runtime, 'spawn', 'window')
        (control/'stop').write_text('supervisor cleanup\n')
        runtime.stop()
    return result

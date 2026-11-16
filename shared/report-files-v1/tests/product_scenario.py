"""Actual ORCH+/SPAWN GUI report path. No reducer or runtime-driver substitutes."""
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import time
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

    def remaining(self, seconds):
        deadline = getattr(self, 'operation_deadline', None)
        return seconds if deadline is None else min(seconds, max(0, deadline-time.monotonic()))

    def __call__(self, op, **fields):
        if self.remaining(20) <= 0:
            raise TimeoutError('original native owner-input deadline expired; no new input sent')
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
        result = self.lib.wait_for(ready, 'native UI '+op, self.remaining(20), .05)
        if not result['ok']:
            raise AssertionError(result['error'])
        return result.get('result')

    def click(self, pane, label):
        self.lib.wait_for(lambda: label in json.dumps(self('surface', pane=pane), ensure_ascii=False),
                          'native button '+label, self.remaining(40))
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


def dismiss_signin(runtime):
    """Close Tern's first-run sign-in dialog (new tn-signin-card or legacy tn-signin-x) if shown."""
    tree = json.dumps(runtime.ctl('tree'))
    if 'tn-signin-card' in tree:
        selector = '.tn-signin-layer .mdl-x'
    elif 'tn-signin-x' in tree:
        selector = '.tn-signin-x'
    else:
        return None
    response = runtime.ctl('click', selector)
    after = json.dumps(runtime.ctl('tree'))
    assert 'tn-signin-card' not in after and 'tn-signin-x' not in after, 'Tern sign-in dialog still present after clicking '+selector
    return response


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
        dismissed = dismiss_signin(runtime)
        if dismissed is not None:
            result['optional_signin_dismissal'] = dismissed
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


def _usage_cache_process(product, operation, **fields):
    """Only fixture observations are writable; authority/consent/bindings are not.

    Import the candidate's real Python consumer in a separate private process.
    Native source_collect, not this driver, normalizes and publishes the saved
    provider observations. Status reads use SQLite read-only mode.
    """
    program = r'''
import json, sqlite3, sys
from pathlib import Path
sys.dont_write_bytecode = True
package, root, operation = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
sys.path.insert(0, str(package))
fields = json.loads(sys.stdin.read())
if operation == "writer":
    from usage_service.spawn_roster import read_roster
    source = Path(fields["fixture"])
    authority = json.loads(source.read_text())
    assert authority["version"] == 4, "requires current native SPAWN writer output"
    detached = Path(fields["detached"])
    detached.mkdir()
    path = detached / "kv.json"
    path.write_text(json.dumps({"authority": authority}))
    roster, definitions = read_roster(path, "native-display-writer-consumer")
    scope, = roster["scopes"]
    assert {row["id"] for row in scope["accounts"]} == {"claude-demo", "codex-demo"}
    assert [row["id"] for row in scope["consumers"]] == ["omp-demo"]
    assert {row["id"] for row in definitions} == {"claude-demo", "codex-demo"}
    assert "foreign-demo" not in json.dumps(roster)
    assert scope["spawn_join"] == {key: authority[key] for key in ("namespace", "host_key", "config_revision")}
    print(json.dumps({"roster": roster, "source_version": authority["version"]}))
elif operation == "status":
    path = root / "state.sqlite3"
    assert path.is_file(), "USAGE native Setup has not created its private store"
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
        settings = {key: json.loads(value) for key, value in db.execute(
            "SELECT key,value FROM settings WHERE key IN ('display_enabled','metadata_enabled','capacity_enabled','role')")}
        state = {key: json.loads(value) for key, value in db.execute(
            "SELECT key,value FROM local_state WHERE key IN ('usage_results','usage_publication','account_bindings','usage_preferences')")}
        identity = db.execute("SELECT device_id FROM installations WHERE id=1").fetchone()[0]
    print(json.dumps({"settings": settings, "source_id": identity, **state}))
elif operation == "cache":
    from usage_service.store import Store
    from usage_service.refresh import Refresh, RESULTS
    assert (root / "state.sqlite3").is_file(), "never bootstrap authority from a fixture"
    store = Store(root)
    try:
        refresh = Refresh(store, root)
        _, _, roster, definitions = refresh.configuration()
        definition, = [row for row in definitions if row["id"] == fields["record_id"]]
        assert definition["provider"] == "claude"
        assert store.settings()["metadata_enabled"], "headless consent must be visible"
        observed = fields["observed_at_ms"]
        item = {key: definition[key] for key in ("scope_id", "id", "provider", "label", "revision")}
        item["response"] = {"version": 1,
            "metadata": {"principal": "synthetic-display@example.invalid", "principal_kind": "email",
                         "label": "Synthetic cached display observation"},
            "usage": {"provider": "claude", "observed_at_ms": observed,
                      "windows": [{"key": "seven_day", "pool": "default", "used": 37, "remaining": 63,
                                   "observed_at_ms": observed, "resets_at_ms": fields["resets_at_ms"]}]}}
        store.set_local_state(RESULTS, {"items": [item]})
        print(json.dumps({"item": item, "roster": roster,
                          "evidence_limit": "synthetic cached provider observation; no provider request or quota proof"}))
    finally:
        store.close()
else:
    raise AssertionError("unknown fixture operation")
'''
    process = subprocess.run(
        [sys.executable, '-B', '-c', program, str(product.root/'plugins/tern/USAGE'),
         str(product.runtime.config/'plugin-data/usage/companion'), operation],
        input=json.dumps(fields), text=True, capture_output=True, check=True,
        env=product.runtime.env, timeout=40)
    return json.loads(process.stdout)


def product_usage_display(base, root, evidence, processes, lib, args):
    """Owned-native SPAWN -> USAGE -> channel -> ordinary ORCH picker.

    Register as ``usage-display-product`` in native_smoke, forwarding the same
    argparse namespace as product_c2 (capture/provider/control options). Required
    args.usage_spawn_fixture is the *raw* authority JSON emitted by the current
    native SPAWN authority/usage_roster_fixture test, supplied explicitly via
    --usage-spawn-fixture. Missing output fails; there is no checked-in fallback.
    It is read in a detached consumer fixture, not installed into the native
    profile.

    Requires Product.create_orchestration and NativeUI.agent_picker from the
    conversation-first driver, Linux native prerequisites, Python 3.11+, and
    access to the shipped hash-locked USAGE dependencies for the visible private
    runtime installation. No provider account, credentials or worker is used.
    """
    import base64
    import hashlib
    import threading
    from product_c2 import Product, prerequisites, spawn_authority

    unavailable = prerequisites()
    if unavailable:
        return unavailable
    product = Product(base, root, evidence, processes, lib, 'usage-display-product',
                      args, instrumented=False)
    runtime, result = product.runtime, product.result
    usage = root/'plugins/tern/USAGE'
    companion_root = runtime.config/'plugin-data/usage/companion'
    writer_fixture = getattr(args, 'usage_spawn_fixture', None)
    fixture = Path(writer_fixture) if writer_fixture is not None else None
    result.update(route='actual SPAWN writer and USAGE source collector/display export; shipped pane-free channel; ordinary ORCH agent picker',
                  worker_kind='no launched worker; synthetic cached provider observations only',
                  usage_display={'phases': {}, 'transport_frames': [], 'topology': []})
    result['limits'].extend([
        '37% is a deterministic cached fixture, not real provider quota or a provider acquisition test.',
        'Only usage_results is fixture-written. Native Setup owns all consent and account bindings.',
        'Native pane topology is sampled during every display wait; carrier frames are passively observed from owned files.',
        'This scenario qualifies local Linux, not attached remote hosts or native Windows/macOS.'])
    output = result['usage_display']
    stopped, seen = threading.Event(), set()
    observer_errors = []
    observer = None

    def observe_carrier():
        paths = []
        for sender, receiver in (('orchplus', 'usage'), ('usage', 'orchplus')):
            for slot in range(1, 25):
                paths.extend((runtime.config/f'plugin-data/{sender}/plugin-channel-v1/m-{slot:03}.json',
                              runtime.config/f'plugin-data/{receiver}/plugin-channel-v1/a-{sender}-{slot:03}.json'))
        while not stopped.is_set():
            try:
                for path in paths:
                    frame = read_json(path)
                    if not isinstance(frame, dict):
                        continue
                    if frame.get('kind') == 'ack':
                        frame = frame.get('message', {})
                    if not str(frame.get('route', '')).startswith('usage.'):
                        continue
                    key = (frame.get('from'), frame.get('incarnation'), frame.get('id'),
                           frame.get('binding'), frame.get('body'))
                    if key in seen:
                        continue
                    # Read the immutable actual producer bytes, never supply a response.
                    raw = base64.b64decode(frame['body'], validate=True)
                    assert len(raw) == frame['body_bytes']
                    body = json.loads(raw)
                    seen.add(key)
                    output['transport_frames'].append({
                        'observed_at_ns': time.time_ns(), 'path': str(path),
                        'frame': frame, 'body': body, 'body_sha256': hashlib.sha256(raw).hexdigest()})
            except Exception as error:
                observer_errors.append(f'{type(error).__name__}: {error}')
                return
            stopped.wait(.025)

    def state():
        return _usage_cache_process(product, 'status')

    def setting(key, expected):
        def saved():
            current = state()
            return current if current['settings'].get(key) == expected else None
        return lib.wait_for(saved, 'native USAGE saves '+key, 40, .5)

    def setup_choice(label, confirm=None):
        product.ui('action', pane=product.controller if hasattr(product, 'controller') else product.spawn_pane,
                   action='plugin.usage.setup')
        product.ui.choose('USAGE Setup', label)
        if confirm:
            product.ui.choose(confirm, 'Confirm')

    def topology(picker):
        panes = product.ui('panes')
        assert not any(row.get('block') in ('usage.display', 'usage.capacity', 'spawn.dispatch',
                                            'usage.config', 'usage.accounts', 'usage.account')
                       for row in panes), 'display journey created a transport/USAGE pane'
        ids = {row['pane'] for row in panes}
        assert ids == baseline_panes | {picker}, 'display read changed native pane topology'
        snapshot = {'panes': panes, 'observed_at_ns': time.time_ns()}
        if not output['topology'] or output['topology'][-1]['panes'] != panes:
            output['topology'].append(snapshot)
        return panes

    def wait_display(label, picker, predicate, timeout=65):
        # Native picker reads pause while its tab is hidden by SPAWN preferences.
        product.ui('focus', pane=picker)
        def rendered():
            topology(picker)
            surface = product.ui('surface', pane=picker)
            text = json.dumps(surface, ensure_ascii=False)
            return surface if predicate(text) else None
        surface = lib.wait_for(rendered, 'ordinary picker '+label, timeout, .1)
        output['phases'][label] = {'surface': surface, 'state': state(),
                                   'observed_at_ns': time.time_ns()}
        product.capture('usage-display-'+label)
        return surface

    def response_since(mark, predicate):
        return lib.wait_for(lambda: next((entry for entry in list(output['transport_frames'])
                                         if entry['observed_at_ns'] >= mark
                                         and entry['frame']['route'] == 'usage.display.response'
                                         and predicate(entry['body'])), None),
                            'actual USAGE display response bytes', 65, .05)

    def assert_current_join(entry):
        authority = spawn_authority(runtime)
        response = entry['body']
        assert set(response) <= {'version', 'display_only', 'request_id', 'op', 'ok', 'status',
                                 'revision', 'as_of_ms', 'source_id', 'records', 'complete', 'next_cursor'}
        assert response['version'] == 1 and response['display_only'] is True
        assert response['ok'] is True and response['status'] == 'current'
        assert response['source_id'] == state()['source_id']
        expected = {key: authority[key] for key in ('namespace', 'host_key', 'config_revision')}
        assert response['records'], 'snapshot omitted current configured accounts'
        allowed_record = {'record_id', 'record_revision', 'definition_revision', 'scope_id', 'roster_revision',
                          'namespace', 'host_key', 'config_revision', 'provider', 'provider_label',
                          'account_label', 'icon', 'used', 'observed_at_ms', 'resets_at_ms',
                          'age_ms', 'state', 'reason', 'text', 'underlying_record_id'}
        for row in response['records']:
            assert set(row) <= allowed_record, 'display record leaked an undeclared field'
            assert {key: row[key] for key in expected} == expected
            assert type(row['record_revision']) is int and row['record_revision'] == authority['config_revision']
            assert row['scope_id'] and len(row['definition_revision']) == 64
        assert {row['record_id'] for row in response['records']} == {'usage-measured', 'usage-unavailable'}
        return expected

    try:
        # Never replace this input with a hand-written authority approximation.
        assert fixture is not None, 'supply the current SPAWN usage_roster_fixture output explicitly'
        assert fixture.is_file(), 'missing actual SPAWN usage_roster_fixture output: '+str(fixture)
        output['writer_fixture'] = _usage_cache_process(
            product, 'writer', fixture=str(fixture.resolve()), detached=str(runtime.root/'writer-consumer'))
        output['writer_fixture'].update(path=str(fixture), sha256=hashlib.sha256(fixture.read_bytes()).hexdigest())
        product.start()
        product.open_spawn()
        measured = product.create_record('usage-measured', 'Claude')
        product.create_record('usage-unavailable', 'Codex')
        observer = threading.Thread(target=observe_carrier, name='owned-usage-frame-observer', daemon=True)
        observer.start()
        runtime.command('plugin', 'install', usage)
        installed = Path(json.loads(runtime.command('plugin', 'dir', '--json'))['dir'])/'usage'
        expected_files = {str(path.relative_to(usage)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in usage.rglob('*') if path.is_file()}
        actual_files = {str(path.relative_to(installed)): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in installed.rglob('*') if path.is_file()}
        assert actual_files == expected_files, 'native USAGE differs from candidate package'
        output['usage_package_sha256'] = hashlib.sha256(json.dumps(expected_files, sort_keys=True).encode()).hexdigest()
        product.ui('action', pane=product.spawn_pane, action='plugin.usage.setup')
        def setup_ready():
            tree = json.dumps(runtime.ctl('tree'), ensure_ascii=False)
            return 'ready' if 'USAGE Setup' in tree else ('install' if 'Install private dependencies' in tree else None)
        if lib.wait_for(setup_ready, 'native USAGE runtime or setup menu', 60) == 'install':
            product.ui.choose('USAGE runtime', 'Install private dependencies')
            product.ui.choose("Install USAGE's private runtime?", 'Confirm')
            lib.wait_for(lambda: 'USAGE Setup' in json.dumps(runtime.ctl('tree')),
                         'native private dependency installation', 240)
        product.ui.choose('USAGE Setup', 'Allow headless usage reads')
        product.ui.choose('Allow headless usage reads on this installation?', 'Confirm')
        initial = setting('metadata_enabled', True)
        assert initial['settings']['display_enabled'] is False
        assert initial['settings']['capacity_enabled'] is False and initial['settings']['role'] == 'standalone'
        assert initial.get('usage_preferences', {}).get('refresh_interval_seconds', 0) == 0

        # This is the sole synthetic seam: stored provider observation, not a
        # snapshot, display API answer, binding, catalog or domain authority.
        fresh_at = int(time.time()*1000)-60000
        reset_at = int(time.time()*1000)+3600000
        output['cache_fresh'] = _usage_cache_process(product, 'cache', record_id=measured['id'],
                                                     observed_at_ms=fresh_at, resets_at_ms=reset_at)
        def published(expected_time, bound=False):
            current = state()
            publication = current.get('usage_publication', {})
            for scope in publication.get('roster', {}).get('scopes', []):
                for account in scope['accounts']:
                    if account['id'] != measured['id'] or (bound and not account.get('profile_binding')):
                        continue
                    for reading_id in account['reading_ids']:
                        reading = publication.get('readings', {}).get(reading_id, {})
                        if any(window.get('used') == 37 and window.get('observed_at_ms') == expected_time
                               for window in reading.get('windows', [])):
                            return current
            return None
        publication = lib.wait_for(lambda: published(fresh_at), 'actual source collector publishes fixture cache', 65, .5)
        scope = publication['usage_publication']['roster']['scopes'][0]
        account = next(row for row in scope['accounts'] if row['id'] == measured['id'])
        reading = publication['usage_publication']['readings'][account['reading_ids'][0]]
        setup_choice('Bind SPAWN accounts…')
        product.ui.choose('Bind SPAWN accounts',
                          account['provider_label']+' · '+account['account_label']+' → '+reading['account_label'])
        product.ui.choose('Bind this SPAWN account to its signed-in login?', 'Confirm')
        output['native_bound_publication'] = lib.wait_for(lambda: published(fresh_at, True),
                                                         'native owner binding and source republish', 65, .5)

        product.create_orchestration('Usage display fixture')
        picker = product.ui.agent_picker('Choose your orchestrator')
        # Provider-labelled terminal fixtures are workers, not eligible coordinators.
        product.ui.mouse_click(picker, 'Cancel')
        lib.wait_for(lambda: all(row['pane'] != picker for row in product.ui('panes')),
                     'Cancel closes the ineligible coordinator picker', 10)
        product.ui.command(product.controller, 'new_conversation')
        product.ui.choose('Existing orchestrated project or New', 'Usage display fixture')
        picker = product.ui.agent_picker('Choose an agent')
        baseline_panes = {row['pane'] for row in product.ui('panes')} - {picker}
        disabled = wait_display('default-disabled', picker,
                                lambda text: 'Show usage in ORCH+' in text and '37% used' not in text)
        assert 'Claude' in json.dumps(disabled) and 'Codex' in json.dumps(disabled)
        off = response_since(0, lambda body: body.get('status') == 'display_disabled')
        assert off['body']['records'] == [] and off['body']['ok'] is False
        mark = time.time_ns()
        setup_choice('Show usage in ORCH+', 'Show usage in ORCH+?')
        setting('display_enabled', True)
        wait_display('fresh-cache', picker, lambda text: '37% used · current' in text and 'Usage unavailable' in text)
        fresh = response_since(mark, lambda body: any(row.get('state') == 'fresh' and row.get('used') == 37
                                                     for row in body.get('records', [])))
        output['initial_join'] = assert_current_join(fresh)
        catalog = product.ui.machine(product.controller, 'orchplus.catalog', key='catalog-index')
        assert catalog and catalog['loaded'] is True
        assert {key: catalog[key] for key in output['initial_join']} == output['initial_join']
        for reading in fresh['body']['records']:
            configured, = [row for row in catalog['records'] if row['id'] == reading['record_id']]
            assert configured['revision'] == reading['record_revision']
            if configured.get('definition_revision') is not None:
                assert configured['definition_revision'] == reading['definition_revision']
        output['native_catalog'] = catalog
        assert next(row for row in fresh['body']['records'] if row['record_id'] == 'usage-unavailable')['state'] == 'unavailable'
        assert next(row for row in fresh['body']['records'] if row['record_id'] == measured['id'])['observed_at_ms'] == fresh_at

        stale_at = int(time.time()*1000)-20*60000
        mark = time.time_ns()
        output['cache_stale'] = _usage_cache_process(product, 'cache', record_id=measured['id'],
                                                     observed_at_ms=stale_at, resets_at_ms=reset_at)
        lib.wait_for(lambda: published(stale_at, True), 'native stale observation publication', 65, .5)
        wait_display('stale-cache', picker,
                     lambda text: '37% used · stale' in text and '37% used · current' not in text)
        stale = response_since(mark, lambda body: any(row.get('used') == 37 and row.get('state') == 'stale'
                                                     for row in body.get('records', [])))
        assert_current_join(stale)
        stale_row = next(row for row in stale['body']['records'] if row['record_id'] == measured['id'])
        assert stale_row['observed_at_ms'] == stale_at and stale_row['age_ms'] >= 20*60000

        mark = time.time_ns()
        setup_choice('Stop showing usage in ORCH+', 'Stop showing usage in ORCH+?')
        setting('display_enabled', False)
        wait_display('revoked', picker, lambda text: 'Show usage in ORCH+' in text and '37% used' not in text)
        revoked = response_since(mark, lambda body: body.get('status') == 'display_disabled')
        assert revoked['body']['records'] == [] and revoked['body']['ok'] is False
        setup_choice('Show usage in ORCH+', 'Show usage in ORCH+?')
        setting('display_enabled', True)
        wait_display('reenabled-stays-stale', picker, lambda text: '37% used · stale' in text
                     and '37% used · current' not in text)

        # A visible current-record edit changes both the catalog revision and
        # semantic fingerprint. Old cached quota must not rejoin by its label.
        before_edit = spawn_authority(runtime)
        product.ui.preference(product.spawn_pane, page='agents')
        prefs = product.ui('preferences', pane=product.spawn_pane)['properties']
        label_rows = [row['id'] for section in prefs['sections'] for row in section['rows']
                      if row['id'].startswith('agent:'+measured['id']+':account_label:')]
        assert len(label_rows) == 1
        mark = time.time_ns()
        product.ui.preference(product.spawn_pane, row=label_rows[0], value='Edited synthetic account')
        lib.wait_for(lambda: spawn_authority(runtime)['config_revision'] > before_edit['config_revision'],
                     'visible SPAWN config edit', 30)
        wait_display('changed-definition-unavailable', picker,
                     lambda text: '37% used' not in text and 'Usage unavailable' in text)
        changed = response_since(mark, lambda body: body.get('op') == 'snapshot'
                                 and any(row.get('config_revision', -1) > before_edit['config_revision']
                                         for row in body.get('records', [])))
        output['changed_join'] = assert_current_join(changed)
        changed_row = next(row for row in changed['body']['records'] if row['record_id'] == measured['id'])
        assert changed_row['state'] == 'unavailable' and changed_row.get('used') is None
        assert changed_row['definition_revision'] != stale_row['definition_revision']
        setup_choice('Stop showing usage in ORCH+', 'Stop showing usage in ORCH+?')
        final = setting('display_enabled', False)
        wait_display('final-disabled', picker, lambda text: 'Show usage in ORCH+' in text and '37% used' not in text)
        assert final['settings']['capacity_enabled'] is False and final['settings']['role'] == 'standalone'
        assert final.get('usage_preferences', {}).get('refresh_interval_seconds', 0) == 0
        product.ui.click(picker, 'Cancel')
        lib.wait_for(lambda: {row['pane'] for row in product.ui('panes')} == baseline_panes,
                     'ordinary picker closes without a transport pane', 30)

        # Each displayed revision must have an actual, separately correlated
        # native validate exchange. Matching labels or retained old frames fail.
        frames = list(output['transport_frames'])
        assert not observer_errors, observer_errors
        assert frames and all(entry['frame']['route'] in ('usage.display.request', 'usage.display.response')
                              for entry in frames), 'display journey issued a non-display USAGE request'
        requests = {(entry['frame']['binding'], entry['body']['request_id']): entry for entry in frames
                    if entry['frame']['route'] == 'usage.display.request'}
        assert len({entry['body']['request_id'] for entry in requests.values()}) == len(requests), 'read identity reused'
        for entry in requests.values():
            body, frame = entry['body'], entry['frame']
            assert frame['from'] == 'orchplus' and frame['to'] == 'usage'
            assert body['version'] == 1
            fields = {'version', 'request_id', 'op'}
            if body['op'] in ('page', 'validate'):
                fields.add('revision')
            if body['op'] == 'page':
                fields.add('cursor')
            assert body['op'] in ('snapshot', 'page', 'validate') and set(body) == fields
        validated = []
        for entry in frames:
            body, frame = entry['body'], entry['frame']
            if frame['route'] != 'usage.display.response' or body.get('op') != 'validate' or body.get('ok') is not True:
                continue
            request = requests.get((frame['binding'], body['request_id']))
            assert request is not None, 'missed actual request bytes; cannot claim correlated validation'
            assert request['body']['op'] == 'validate' and request['body']['revision'] == body['revision']
            assert frame['from'] == 'usage' and frame['to'] == 'orchplus'
            assert body['records'] == [] and body['complete'] is True
            validated.append(body['revision'])
        assert fresh['body']['revision'] in validated and stale['body']['revision'] in validated
        output['validated_revisions'] = validated
        assert not (registry(runtime) or {}).get('dispatch', {}).get('workers'), 'display exercise launched a worker'
        result['checks'].extend([
            'Actual current SPAWN writer fixture read by shipped USAGE consumer; foreign host records excluded.',
            'Visible native SPAWN setup and USAGE consent/binding, no seeded domain authority.',
            'Default-disabled, fresh synthetic cache, unavailable account, stale cache, revocation, re-enable and definition-change honesty.',
            'Exact current host/config/numeric record revision and semantic fingerprint from native display frames.',
            'Distinct correlated snapshot/validate over shipped channel; no capacity request or sampled transport pane.',
            'Revocation removes received percentages on the existing picker; closing picker leaves only original panes.'])
        result['status'] = 'passed'
        result['status_scope'] = 'local owned-native display integration with explicitly synthetic cached provider observations'
    except Exception as error:
        result['error'] = f'{type(error).__name__}: {error}'
        if hasattr(product, 'ui'):
            result['failure_diagnostics'] = window_diagnostics(runtime)
    finally:
        stopped.set()
        if observer is not None:
            observer.join(timeout=5)
        output['observer_errors'] = observer_errors
        try:
            product.close()
        finally:
            # Stop only this owned companion, after native hosts can no longer
            # renew/restart it. No live profile or system daemon is touched.
            if companion_root.exists():
                try:
                    cleanup = subprocess.run(
                        [sys.executable, '-B', str(usage/'usage_service.py'), 'stop', '--data-root', str(companion_root)],
                        input='{}', text=True, capture_output=True, env=runtime.env, timeout=60)
                    output['companion_stop'] = json.loads(cleanup.stdout)
                    if cleanup.returncode or output['companion_stop'].get('ok') is not True:
                        result['status'] = 'failed'
                        result['cleanup_error'] = 'owned USAGE companion stop failed'
                except Exception as error:
                    result['status'] = 'failed'
                    result['cleanup_error'] = f'{type(error).__name__}: {error}'
    return result

"""C3 ordinary-window qualification; fault injection never fabricates an effect."""
import hashlib
import json
import os
from pathlib import Path
import signal
import time
import traceback

from product_c2 import Product, RECORDS, ensure_fixture_coordinator, owner_assignment, prerequisites
from product_scenario import read_json, registry, trace


def select_runtime_cases(args, namespace, names):
    """Select bounded runs while retaining the complete required-cell inventory."""
    required = [namespace+'/'+name for name in names]
    requested = getattr(args, 'runtime_cases', None)
    if requested is None:
        selected = required[:]
    else:
        scoped = [name for name in requested if name.rpartition('/')[0] == namespace]
        unknown = sorted(set(scoped)-set(required))
        if unknown:
            raise ValueError('unknown runtime cells: '+','.join(unknown)
                             +'; required cells: '+','.join(required))
        selected = [name for name in required if name in scoped]
    return {name.rpartition('/')[2] for name in selected}, {
        'required': required, 'selected': selected,
        'unrun': [name for name in required if name not in selected],
    }


def write_json(path, value):
    pending = path.with_name(path.name + '.pending')
    pending.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
    os.replace(pending, path)


def spawn_dispatch(product):
    return (read_json(product.runtime.config/'plugin-data/spawn/kv.json') or {}).get('dispatch-v1')


def spawn_request(product, request):
    store = spawn_dispatch(product) or {}
    matches = [entry for entry in store.get('requests', {}).values()
               if entry.get('request', {}).get('request_id') == request['request_id']
               and entry['request'].get('logical_session_id') == request['logical_session_id']
               and entry['request'].get('admission_seq') == request['admission_seq']]
    assert len(matches) <= 1, 'multiple current SPAWN entries for one immutable request'
    return matches[0] if matches else None


def orch_action(product, request):
    return ((registry(product.runtime) or {}).get('dispatch', {}).get('actions', {})
            .get(request['action_id']))


def native_launches(product, record='c2-builder'):
    path = product.control/'native-launches.jsonl'
    if not path.exists():
        return []
    lines = path.read_bytes().splitlines(keepends=True)
    return [value for line in lines if line.endswith(b'\n')
            for value in [json.loads(line)] if value['record_id'] == record]


def process_identity(pid):
    """Actual Linux incarnation, without publishing its token-bearing argv."""
    directory = Path('/proc')/str(pid)
    stat = (directory/'stat').read_text().rsplit(') ', 1)[1].split()
    assert stat[0] != 'Z', 'native worker exited during the effect observation'
    return {'pid': pid, 'start_ticks': int(stat[19]),
            'argv_sha256': hashlib.sha256((directory/'cmdline').read_bytes()).hexdigest()}


def captured_payload(entry):
    """Decode observed original bytes without manufacturing a native UI event."""
    return json.loads(entry['body'] if entry.get('kind') == 'carrier_receive' else entry['input']['value'])


class EventLoss:
    """Suppress an exact native event before its original handler, not its result."""
    def __init__(self, product):
        assert product.instrumented and not product.provider
        self.product = product
        self.path = product.runtime.root/'native-event-loss.json'
        self.set([])
        for package in (product.spawn, product.orch):
            path = package/'product-probe.json'
            configuration = json.loads(path.read_text(encoding='utf-8'))
            configuration['held_events_path'] = str(self.path)
            write_json(path, configuration)
        product.result['package_instrumentation'] = (
            'exact native event-loss injection in private entrypoint wrappers; '
            'product handlers/effects/results are never substituted')

    def set(self, holds):
        assert len(holds) <= 4
        previous = read_json(self.path) or {}
        released = set(previous.get('releases', []))
        retained = set(previous.get('retained', [])) - released
        for plugin in ('orchplus', 'spawn'):
            observed = read_json(self.product.runtime.config/'plugin-data'/plugin/'product-held-host.json') or {}
            retained.update(name for name, entry in observed.items()
                            if entry.get('kind') == 'carrier_receive' and not entry.get('forwarded_at_ms')
                            and name not in released)
        assert len(retained) <= 64
        # Replacing future selectors must not race explicit release of an
        # already captured carrier frame. Pane-local events remain unchanged.
        write_json(self.path, {'holds': holds, 'retained': sorted(retained)})

    def observed(self, plugin, name):
        path = self.product.runtime.config/'plugin-data'/plugin/'product-held-host.json'
        entry = (read_json(path) or {}).get(name)
        if entry:
            assert not entry.get('conflict'), 'event-loss selector matched different original inputs'
            entry['_plugin'], entry['_hold_id'] = plugin, name
        return entry

    def wait(self, plugin, name):
        return self.product.lib.wait_for(lambda: self.observed(plugin, name),
                                         'captured original native event '+name, 90)

    def deliver_original_once(self, entry):
        if entry.get('kind') != 'carrier_receive':
            # Exact previously suppressed pane-local input (including old-source
            # migration cells), never a newly constructed authority request.
            return self.product.ui('event', pane=entry['pane'], event=entry['input'])
        raw = entry['producer_bytes'].encode('utf-8')
        frame = json.loads(raw)
        assert frame['kind'] == 'message' and frame['route'] == entry['frame']['route']
        assert frame['from'] in ('orchplus', 'spawn', 'usage') and frame['to'] in ('orchplus', 'spawn', 'usage')
        assert type(frame['slot']) is int and 1 <= frame['slot'] <= 24
        runtime = self.product.runtime
        path = runtime.config/f"plugin-data/{frame['from']}/plugin-channel-v1/m-{frame['slot']:03}.json"
        ack = runtime.config/f"plugin-data/{frame['to']}/plugin-channel-v1/a-{frame['from']}-{frame['slot']:03}.json"
        assert str(path) == entry['producer_path']
        assert runtime.config.resolve().is_relative_to(runtime.root.resolve())
        assert path.resolve().is_relative_to(runtime.config.resolve())
        assert ack.resolve().is_relative_to(runtime.config.resolve())
        receipt = {'kind': 'retained-original-release', 'path': str(path),
                   'sha256': hashlib.sha256(raw).hexdigest(),
                   'identity': {key: frame[key] for key in ('from', 'to', 'incarnation', 'id', 'route', 'binding', 'slot')}}
        if path.exists():
            assert path.read_bytes() == raw, 'original carrier slot now holds a different obligation'
            assert not ack.exists(), 'already-ACKed frame is not a retained unhandled input'
        else:
            # Explicit stale-storage fault, separately authorized by the parent:
            # freeze only our owned daemon so no channel writer can reuse this
            # empty slot between the checks and exclusive restoration.
            daemons = [owned for owned in runtime.own
                       if 'daemon' in [str(value) for value in owned['argv']]
                       and str(runtime.sock) in [str(value) for value in owned['argv']]]
            assert len(daemons) == 1, 'cannot identify exactly one owned fixture daemon'
            daemon = daemons[0]['process']
            assert daemon.poll() is None
            identity = process_identity(daemon.pid)
            frozen = False
            try:
                os.kill(daemon.pid, signal.SIGSTOP)
                frozen = True
                deadline = time.monotonic()+5
                while True:
                    proc_state = (Path('/proc')/str(daemon.pid)/'stat').read_text().rsplit(') ', 1)[1].split()[0]
                    if proc_state in ('T', 't'):
                        break
                    assert time.monotonic() < deadline, 'owned fixture daemon did not stop'
                    time.sleep(.01)
                assert process_identity(daemon.pid) == identity
                assert not os.path.lexists(path), 'carrier slot reused before fixture producer stopped'
                assert not os.path.lexists(ack), 'original slot still has an ACK obligation'
                assert path.parent.is_dir() and not path.parent.is_symlink()
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0)
                with os.fdopen(os.open(path, flags, 0o600), 'wb') as stream:
                    stream.write(raw)
                    stream.flush()
                    os.fsync(stream.fileno())
                assert path.read_bytes() == raw
                receipt.update(kind='exact-producer-file-rollback', daemon=identity,
                               original_observation=entry.get('first_at_ms'),
                               original_boot=entry.get('boot'), restored_at_ns=time.time_ns(),
                               empty_original_slot=True, absent_original_ack=True)
            finally:
                if frozen:
                    os.kill(daemon.pid, signal.SIGCONT)
        control = read_json(self.path)
        assert control is not None
        hold_id = entry.get('_hold_id')
        if hold_id:
            control['retained'] = [name for name in control.get('retained', []) if name != hold_id]
            releases = control.setdefault('releases', [])
            if hold_id not in releases:
                releases.append(hold_id)
            write_json(self.path, control)
        self.product.result.setdefault('carrier_fault_deliveries', []).append(receipt)
        return receipt


def show_advanced(product):
    """Expose actual diagnostic/recovery controls, without changing authority."""
    surface = product.ui('surface', pane=product.controller)
    if 'Hide Advanced' not in json.dumps(surface, ensure_ascii=False):
        product.ui.click(product.controller, 'Advanced')


def initialize(product, *, assignment=False):
    product.start()
    product.open_spawn()
    for record in RECORDS:
        if record[0] in ('c2-builder', 'c2-release'):
            product.create_record(*record)
    product.initialize_orch()
    product.configure_orch('review_disabled')
    product.claim()
    if not getattr(product, 'legacy_source', False):
        show_advanced(product)
    if assignment and not product.provider and not getattr(product, 'legacy_source', False):
        # Establish the real proposing conversation before a target-effect fault
        # is armed, so its own native launch cannot satisfy the target selector.
        ensure_fixture_coordinator(product, deadline=time.monotonic()+180)


def assign_idle_worker(product):
    fields = (
        ('Explicit assignment for c2-builder',
         'C3 native recovery qualification. Do not modify the repository; wait for the bounded controlled scenario.'),
        ('Declared files', 'fixture.txt'), ('Checks (one per line', ''), ('Base ref', 'refs/heads/main'))
    if getattr(product, 'legacy_source', False):
        # Prior-version cells deliberately exercise that version's visible UI.
        product.ui.click(product.controller, 'Assign explicit task to c2-builder')
        for title, value in fields:
            product.ui.enter(title, value)
        return None
    return owner_assignment(product, 'c2-builder', fields, deadline=time.monotonic()+90)


def restore_spawn_snapshot(product, snapshot):
    """Explicit one-sided fault, preserving all other current plugin KV keys."""
    path = product.runtime.config/'plugin-data/spawn/kv.json'
    assert path.is_file() and not path.is_symlink()
    before = read_json(path)
    assert before and before.get('dispatch-v1'), 'missing initialized SPAWN store is not first use'
    assert snapshot['namespace'] == before['dispatch-v1']['namespace']
    replacement = dict(before)
    replacement['dispatch-v1'] = snapshot
    write_json(path, replacement)
    observed = read_json(path)
    assert observed == replacement, 'one-sided fault was not applied exactly'
    return {'restored_dispatch_sha256': hashlib.sha256(json.dumps(snapshot, sort_keys=True).encode()).hexdigest(),
            'unrelated_kv_keys_preserved': sorted(key for key in before if key != 'dispatch-v1')}


def native_rollback_case(base, root, evidence, processes, lib, args, snapshot_phase):
    assert snapshot_phase in ('resolved', 'claimed', 'launching')
    name = 'recovery-spawn-'+snapshot_phase
    result = {'status': 'failed', 'snapshot_phase': snapshot_phase}
    evidence.setdefault('c3_cases', {})[name] = result
    product = None
    try:
        product = Product(base, root, evidence, processes, lib, name, args)
        result.update(product.result)
        product.result = result
        loss = EventLoss(product)
        initialize(product, assignment=True)
        initial_act = {'resolved': 'spawn.claim', 'claimed': 'spawn.begin',
                       'launching': 'spawn.result'}[snapshot_phase]
        loss.set([{'id': 'snapshot-boundary', 'block': 'dispatch', 'act': initial_act,
                   'request': {'op': 'launch', 'record_id': 'c2-builder'}}])
        assign_idle_worker(product)
        held = loss.wait('spawn', 'snapshot-boundary')
        native_input = captured_payload(held)
        request_json = native_input['request_json']
        request = json.loads(request_json)
        assert request['schema'] == 2 and request['op'] == 'launch'
        retained = spawn_request(product, request)
        assert retained and retained['body']['status'] == snapshot_phase
        assert retained['request_json'] == request_json
        if snapshot_phase == 'resolved':
            assert retained.get('claim') is None, 'required snapshot is resolved and UNCLAIMED'
        else:
            assert retained.get('claim'), 'claimed/launching snapshot lost its native claim'
        snapshot = spawn_dispatch(product)
        assert snapshot['version'] == 2
        snapshot_file = product.runtime.root/('spawn-'+snapshot_phase+'-snapshot.json')
        write_json(snapshot_file, snapshot)
        action = orch_action(product, request)
        assert action and action['request_bytes'] == request_json
        grant = action['claim']['grant_id']
        delivery_act = 'dispatch-result/'+grant+'/'+request['origin_binding']['window_epoch']
        result_hold = {'id': 'unconsumed-launch-result', 'block': 'orchestrator', 'act': delivery_act}
        if snapshot_phase == 'resolved':
            loss.set([result_hold, {'id': 'first-begin', 'block': 'dispatch', 'act': 'spawn.begin'}])
            loss.deliver_original_once(held)
            held_begin = loss.wait('spawn', 'first-begin')
            first_claim = spawn_request(product, request)['claim']
            loss.set([result_hold])
            loss.deliver_original_once(held_begin)
        else:
            first_claim = retained['claim']
            loss.set([result_hold])
            loss.deliver_original_once(held)
        launch = lib.wait_for(lambda: next(iter(native_launches(product)), None),
                              'first actual managed native worker invocation', 60)
        assert len(native_launches(product)) == 1
        first_process = process_identity(launch['pid'])
        loss.wait('orchplus', 'unconsumed-launch-result')
        action = orch_action(product, request)
        assert action and action['phase'] == 'claimed', 'ORCH consumed the result before rollback'
        witness = action['claim']['spawn_claim']
        first_entry = spawn_request(product, request)
        assert witness == {key: first_claim[key] for key in ('spawn_namespace', 'claim_nonce')}
        assert first_entry['body']['status'] in ('awaiting_acceptance', 'launched', 'accepted')
        prior_status = None
        if snapshot_phase == 'resolved':
            # Restore only an actually observed prior read's immutable carrier
            # bytes; never manufacture a new status request from saved authority.
            # The lost result keeps the original delivery awaiting its receipt.
            for event in trace(product.runtime, 'spawn').get('events', []):
                data = event.get('data', {})
                if event.get('kind') != 'carrier_receive' or data.get('act') != 'status':
                    continue
                query = captured_payload(data)
                if (query.get('target_request_id') == request['request_id']
                        and query.get('target_request_serial') == request['request_serial']
                        and query.get('logical_session_id') == request['logical_session_id']):
                    prior_status = data
            assert prior_status and prior_status.get('producer_bytes'), 'no original native read-only status frame was captured'
            result['original_read_only_status'] = prior_status
        result['before_restore'] = {
            'request_serial': request['request_serial'], 'action_id': request['action_id'],
            'request_sha256': hashlib.sha256(request_json.encode()).hexdigest(),
            'snapshot': str(snapshot_file), 'first_process': first_process,
            'native_launches': native_launches(product), 'orch_witness': witness,
            'native_claim': first_claim, 'result_not_consumed': True,
        }
        boot = trace(product.runtime, 'spawn')['boot']
        result['fault'] = restore_spawn_snapshot(product, snapshot)
        product.runtime.command('plugin', 'reload', 'spawn', '--json')
        lib.wait_for(lambda: trace(product.runtime, 'spawn').get('boot', 0) > boot,
                     'actual owned SPAWN plugin reload after one-sided restore', 30)
        if snapshot_phase == 'resolved':
            observation_deadline = time.monotonic()+60
            result['post_restore_read_only_status'] = loss.deliver_original_once(prior_status)
            def changed_nonce_uncertain():
                entry, current = spawn_request(product, request), orch_action(product, request)
                if not entry or not current or current.get('phase') != 'uncertain':
                    return None
                claim = entry.get('claim')
                if not claim or claim['claim_nonce'] == first_claim['claim_nonce']:
                    return None
                assert claim['spawn_namespace'] == first_claim['spawn_namespace']
                assert current['claim']['spawn_claim'] == witness, 'first peer witness was overwritten'
                assert entry['body']['status'] in ('claimed', 'uncertain'), 'restored claim began a second effect'
                return {'spawn_phase': entry['body']['status'], 'orch_phase': current['phase'],
                        'restored_claim': claim, 'first_witness_preserved': True}
            observed = lib.wait_for(changed_nonce_uncertain,
                                    'changed native nonce causes visible ORCH uncertainty',
                                    max(.1, observation_deadline-time.monotonic()))
        else:
            def reload_uncertain():
                entry = spawn_request(product, request)
                if not entry or entry['body']['status'] != 'uncertain':
                    return None
                assert entry['claim'] == snapshot['requests'][next(
                    key for key, value in snapshot['requests'].items()
                    if value['request']['request_id'] == request['request_id'])]['claim']
                return {'spawn_phase': entry['body']['status'], 'restored_claim': entry['claim']}
            observed = lib.wait_for(reload_uncertain,
                                    'at/after-claim native reload preserves uncertainty', 30)
        result['after_restore'] = observed
        result['native_observations'] = []
        for _ in range(3):
            assert len(native_launches(product)) == 1, 'one-sided restore invoked another native worker'
            assert process_identity(launch['pid']) == first_process, 'original worker incarnation changed'
            assert spawn_dispatch(product)['namespace'] == snapshot['namespace']
            result['native_observations'].append({
                'context': product.ui('context'), 'panes': product.ui('panes'),
                'spawn_phase': spawn_request(product, request)['body']['status'],
                'native_launch_count': len(native_launches(product)),
            })
            lib.idle(.3)
        product.capture(name+'-uncertain-one-effect')
        result['checks'].append('actual first effect, one-sided persisted restore, native reload and uncertainty; exactly one observed native invocation')
        result['status'] = 'passed'
    except Exception as error:
        result['error'] = f'{type(error).__name__}: {error}'
        result['failure_traceback'] = traceback.format_exc()
        if product:
            try:
                product.capture(name+'-failure')
            except Exception as capture_error:
                result['capture_error'] = str(capture_error)
    finally:
        if product:
            product.close()
    return result


def lifecycle(base, root, evidence, processes, lib, args):
    """Both native migration and lifetime retention are mandatory, not alternatives."""
    from product_paired_migration import paired_migration
    from product_retention import retention
    result = {'status': 'failed', 'cases': {}, 'limits': [
        'Actual owned Linux native runtime qualification; not cross-platform GUI proof',
        'Fault instrumentation and exact-package retention are reported separately']}
    for name, run in (('paired_migration', paired_migration), ('retention', retention)):
        try:
            result['cases'][name] = run(base, root, evidence, processes, lib, args)
        except Exception as error:
            result['cases'][name] = {
                'status': 'failed', 'error': f'{type(error).__name__}: {error}',
                'failure_traceback': traceback.format_exc()}
    executed = [case for case in result['cases'].values() if case.get('status') != 'not_run']
    if not executed:
        result['status'] = 'not_run'
    elif all(case.get('status') == 'passed' for case in executed):
        result['status'] = 'passed'
    result['qualification_complete'] = (result['status'] == 'passed'
        and all(case.get('qualification_complete') for case in result['cases'].values()))
    return result

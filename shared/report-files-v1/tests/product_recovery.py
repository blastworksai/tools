"""C3 recovery: native effects and retained failure receipts, never seeded authority.

All fault bytes originate in this run. Hybrid cells use a genuine Native OMP
coordinator and deterministic task workers; the separate provider cell retains
its provider-only meaning. Combinatorial reducer reload/placement/capacity grids
belong to owner suites and are not counted as runtime observations here.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import time
import traceback

from product_c2 import (Product, additional_window, native_nodes, owner_assignment, owner_setup_input, prerequisites,
                        provider_coordinator_identity, provider_coordinator_prompt, saved_records, spawn_authority,
                        surface_nodes)
from product_c3 import (EventLoss, captured_payload, initialize, native_launches, native_rollback_case,
                        orch_action, process_identity, restore_spawn_snapshot,
                        select_runtime_cases, show_advanced, spawn_dispatch, spawn_request, write_json)
from product_scenario import TESTS, read_json, registry, trace


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def _case(base, root, evidence, processes, lib, args, name, body, provider=False):
    receipt = {'status': 'failed', 'case': name, 'checks': [], 'captures': {}}
    evidence.setdefault('c3_cases', {})[name] = receipt
    product = None
    try:
        product = Product(base, root, evidence, processes, lib, name, args, provider=provider)
        receipt.update(product.result)
        product.result = receipt
        receipt['fixture_sources']['product_recovery.py'] = hashlib.sha256((TESTS/'product_recovery.py').read_bytes()).hexdigest()
        if not provider:
            target = product.worker.with_name('recovery_worker.py')
            shutil.copy2(TESTS/'recovery_worker.py', target)
            product.worker = target
            receipt['fixture_sources']['recovery_worker.py'] = hashlib.sha256(target.read_bytes()).hexdigest()
            for package in (product.spawn, product.orch):
                path = package/'product-probe.json'
                config = read_json(path)
                config['recovery_trace'] = True
                write_json(path, config)
        body(product, receipt)
        assert receipt['checks'], 'a recovery case cannot pass without observed acceptance'
        receipt['status'] = 'passed'
    except Exception as error:
        receipt['error'] = f'{type(error).__name__}: {error}'
        receipt['failure_traceback'] = traceback.format_exc()
        if product and hasattr(product, 'ui'):
            try:
                product.capture(name+'-failure')
            except Exception as capture_error:
                receipt['capture_error'] = str(capture_error)
    finally:
        if product:
            try:
                product.close()
            except Exception as error:
                receipt['status'] = 'failed'
                receipt['cleanup_error'] = f'{type(error).__name__}: {error}'
                # Product.close can fail while collecting evidence; the owned
                # process supervisor must still be stopped, not just its pane.
                try:
                    product.runtime.stop()
                except Exception as stop_error:
                    receipt['supervisor_cleanup_error'] = str(stop_error)
    return receipt


def import_terminal_record(product, record_id, worker_path=None):
    """Review a fresh ordinary terminal record without adding native capabilities."""
    originals = saved_records(product.runtime)
    assert not any(row['id'] == record_id for row in originals)
    template = next(row for row in originals if row['id'] == 'c2-builder')
    assert template['backend'] == 'local-terminal'
    record = copy.deepcopy(template)
    record['id'] = record_id
    record['account_label'] = 'Explicit deterministic terminal participant'
    argv = [str(worker_path or product.worker), str(product.control), record_id]
    record['arguments'] = argv
    record['fresh_arguments'] = argv
    record['task_argument_index'] = len(argv)+1
    assert record['mailbox']['wake'] == 'worker-poll-v1'
    caps = record['mailbox']['capabilities']
    assert all(cap in caps for cap in ('argv-v1', 'report-files-v1', 'worker-poll-v1'))
    assert 'coordinator-control-v1' not in caps
    # The owner reviews every byte through the supported setup import path.
    product.ui.preference(product.spawn_pane, page='setup')
    product.ui.preference(product.spawn_pane, row='manual-json',
                          value=json.dumps({'schema': 2, 'agents': [record]}))
    product.ui.preference(product.spawn_pane, row='manual-review')
    product.ui.preference(product.spawn_pane, row='manual-confirm')
    actual = product.lib.wait_for(lambda: next((row for row in saved_records(product.runtime)
                                               if row['id'] == record_id), None),
                                  'explicit new terminal record import', 40)
    for original in originals:
        assert next(row for row in saved_records(product.runtime) if row['id'] == original['id']) == original
    assert 'coordinator-control-v1' not in actual['mailbox']['capabilities']
    product.result.setdefault('explicit_new_records', {})[record_id] = actual
    return actual


def _assign(product, record='c2-builder', coordinator=False, prompt=None):
    fields = (
        ('Explicit assignment for '+record, prompt or
         'C3 bounded recovery participant. Preserve fixture.txt and all Git refs. Use only your issued transport; wait for the explicit owner-controlled checkpoint/retirement. No proposals or other work.'),
        ('Declared files', 'fixture.txt'), ('Checks (one per line', ''), ('Base ref', 'refs/heads/main'))
    return owner_assignment(product, record, fields, coordinator=coordinator,
                            deadline=getattr(product.ui, 'operation_deadline', None) or time.monotonic()+180)


def _workers(product):
    return (registry(product.runtime) or {}).get('dispatch', {}).get('workers', {})


def _accepted(product, record='c2-builder', exclude=None):
    def ready():
        for worker in _workers(product).values():
            if (worker['record_id'] == record and worker['worker_id'] != exclude
                    and worker.get('phase') == 'accepted' and not worker.get('accept_pending', True)):
                return worker
        return None
    return product.lib.wait_for(ready, 'real accepted native worker '+record, 180)


def _request(held):
    value = captured_payload(held)
    return json.loads(value['request_json']), value['request_json']


def _boundary(loss, name, act='spawn.begin', request=None):
    return {'id': name, 'block': 'dispatch', 'act': act, 'request': request or {'op': 'launch'}}


def _result_hold(request, action, name):
    return {'id': name, 'block': 'orchestrator',
            'act': 'dispatch-result/'+action['claim']['grant_id']+'/'+request['origin_binding']['window_epoch']}


def _reload(product, plugin, *, deadline=None):
    before = {realm: trace(product.runtime, plugin, realm).get('boot', 0) for realm in ('host', 'window')}
    starts = ({worker_id: worker.get('workflow', {}).get('started', {}).get('epoch')
               for worker_id, worker in _workers(product).items()
               if worker['phase'] == 'accepted'} if plugin == 'orchplus' else {})
    product.runtime.command('plugin', 'reload', plugin, '--json')
    after = product.lib.wait_for(lambda: {realm: trace(product.runtime, plugin, realm).get('boot', 0)
                                         for realm in ('host', 'window')}
                                if all(trace(product.runtime, plugin, realm).get('boot', 0) > before[realm]
                                       for realm in ('host', 'window')) else None,
                                'actual old host/window executors replaced: '+plugin,
                                40 if deadline is None else min(40, max(0, deadline-time.monotonic())))
    product.result.setdefault('executor_reloads', []).append({
        'plugin': plugin, 'before': before, 'after': after, 'previous_worker_start_epochs': starts})


def _pick_fragment(product, title, fragment):
    def label():
        tree = product.runtime.ctl('tree')
        if title not in json.dumps(tree, ensure_ascii=False):
            return None
        labels = []
        for node in native_nodes(tree.get('tree', [])):
            if node.get('role') == 'option':
                texts = [child.get('text', '') for child in native_nodes(node)]
                matches = [text for text in texts if fragment in text]
                if len(matches) == 1:
                    labels.append(matches[0])
        return labels[0] if len(labels) == 1 else None
    product.ui.choose(title, product.lib.wait_for(label, 'one offered recovery choice '+fragment, product.ui.remaining(40)))


def _post_reload_epoch(product, deadline):
    reloaded = next(item for item in reversed(product.result['executor_reloads']) if item['plugin'] == 'orchplus')
    previous = reloaded['previous_worker_start_epochs']
    def initial_tick_settled():
        source = registry(product.runtime)
        starts = {}
        for worker_id, old_epoch in previous.items():
            worker = source['dispatch']['workers'].get(worker_id)
            assert worker, 'restored worker disappeared before its first continuation'
            if worker['phase'] != 'accepted':
                continue
            started = worker.get('workflow', {}).get('started', {})
            if not isinstance(started.get('epoch'), str) or started['epoch'] == old_epoch:
                return None
            starts[worker_id] = started
        rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
        if (rendered and rendered.get('authority_namespace') == source['authority_namespace']
                and rendered.get('authority_revision') == source['revision']
                and registry(product.runtime)['revision'] == source['revision']):
            return {'source_revision': source['revision'], 'previous_worker_start_epochs': previous,
                    'current_worker_starts': starts}
        return None
    return product.lib.wait_for(initial_tick_settled, 'post-reload accepted-worker host-epoch initialization',
                                max(0, deadline-time.monotonic()))


def _continue_controller(product):
    # Reload refreshes health without a clock. Its first real workflow tick then
    # stamps accepted workers' new host epoch, a separate observed revision edge.
    # Observe that exact edge before FIRST attestation, within its original budget.
    # Never reopen or refresh an attestation after it has been captured.
    deadline = time.monotonic()+40
    settled = _post_reload_epoch(product, deadline)
    product.result.setdefault('continuation_preflights', []).append(settled)
    product.ui('focus', pane=product.controller)
    product.ui('action', action='plugin.orchplus.continue_controller')
    product.ui.choose('Continue controller ', 'I independently verified previous ORCH+/SPAWN executors stopped or retired',
                      deadline=deadline)
    product.lib.wait_for(lambda: (product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state') or {}).get('controller_phase') == 'active',
                         'explicit current controller continuation', 40)
    # Continuation itself opens the same guide. Dismissing it is not recovery.
    _pick_fragment(product, 'Reload recovery:', 'Close')


def _restore_orch(product, snapshot):
    path = product.runtime.config/'plugin-data/orchplus/kv.json'
    current = read_json(path)
    assert current and current.get('authority_state') and not path.is_symlink()
    assert current['authority_state']['authority_namespace'] == snapshot['authority_namespace']
    replacement = dict(current, authority_state=snapshot)
    write_json(path, replacement)
    assert read_json(path) == replacement
    return {'snapshot_sha256': _digest(snapshot),
            'other_keys_preserved': sorted(key for key in current if key != 'authority_state')}


def _reverse(product, result, phase):
    loss = EventLoss(product)
    initialize(product, assignment=True)
    low = None
    if phase == 'claimed-hole':
        loss.set([_boundary(loss, 'low-begin')])
        _assign(product)
        held_low = loss.wait('spawn', 'low-begin')
        low, _ = _request(held_low)
        low_hold = _result_hold(low, orch_action(product, low), 'low-result')
        loss.set([low_hold])
        loss.deliver_original_once(held_low)
        loss.wait('orchplus', 'low-result')
        ready_deadline = time.monotonic()+60
        product.lib.wait_for(lambda: len(native_launches(product)) == 1, 'actual low outstanding native effect', 60)
        # The retained failure captured the second approval before the first
        # automatic reconciliation, which then legitimately invalidated it.
        # Finish that real admission observation before the FIRST second input;
        # preserve the low result hold and the original readiness deadline.
        observed_revision = registry(product.runtime)['revision']
        def low_admission_ready():
            current = registry(product.runtime)
            session = current['sessions'][low['logical_session_id']]
            return current if (session.get('admitted') and not session.get('bridge_control')
                               and session.get('last_authority_revision', 0) >= observed_revision) else None
        ready = product.lib.wait_for(low_admission_ready, 'current admission before second native assignment',
                                     max(.001, ready_deadline-time.monotonic()), .2)
        assert orch_action(product, low), 'the original low effect must remain outstanding'
        assert len(native_launches(product)) == 1, 'admission observation must not relaunch the low worker'
        result['low_admission_preflight'] = {
            'observed_revision': observed_revision, 'settled_revision': ready['revision'],
            'peer_authority_revision': ready['sessions'][low['logical_session_id']]['last_authority_revision'],
            'original_low_request_outstanding': True, 'native_process_count': 1}
    else:
        low_hold = None
    snapshot = registry(product.runtime)
    record = 'c2-release' if low else 'c2-builder'
    original_claim = None
    if phase == 'before-claim':
        # Capture the actual ORCH claim before ISSUE. Provisioning also claims
        # ordinary actions; release each exact non-launch input once, never
        # synthesize its successful result or predict an action identifier.
        claim_id = 'pre-issue-0'
        loss.set([{'id': claim_id, 'block': 'orchestrator', 'act': 'dispatch-command', 'match': {'command': 'claim'}}])
        _assign(product, record)
        for ordinal in range(8):
            candidate = loss.wait('orchplus', claim_id)
            command = json.loads(candidate['input']['value'])
            action = registry(product.runtime)['dispatch']['actions'][command['action_id']]
            if action['request']['op'] == 'launch':
                assert action['phase'] == 'ready' and not action.get('claim')
                original_claim = candidate
                snapshot = registry(product.runtime)
                loss.set([_boundary(loss, 'high-boundary')])
                loss.deliver_original_once(candidate)
                break
            claim_id = 'pre-issue-'+str(ordinal+1)
            loss.set([{'id': claim_id, 'block': 'orchestrator', 'act': 'dispatch-command',
                       'match': {'command': 'claim'}, 'exclude_match': {'action_id': command['action_id']}}])
            loss.deliver_original_once(candidate)
        else:
            raise AssertionError('no native unissued launch claim within bounded provisioning steps')
    else:
        gate = _boundary(loss, 'high-boundary', 'spawn.begin' if phase == 'claimed-hole' else 'spawn.claim')
        loss.set(([low_hold] if low_hold else [])+[gate])
        _assign(product, record)
    if low:
        # Both deterministic participants preserve fixture.txt. Keep the real
        # overlap gate and answer it once, rather than weakening declared scope.
        # Its first approval and capture share the original 90-second boundary.
        assert getattr(product.ui, 'operation_deadline', None) is None
        product.ui.operation_deadline = time.monotonic()+90
        try:
            def high_overlap():
                current = registry(product.runtime)['dispatch']
                workers = [item for item in current['workers'].values() if item['record_id'] == record]
                if not workers:
                    return None
                assert len(workers) == 1
                high_worker = workers[0]
                gates = [item for item in current['gates'].values()
                         if item['worker_id'] == high_worker['worker_id'] and item['phase'] == 'pending']
                if not gates:
                    return None
                assert len(gates) == 1 and gates[0]['kind'] == 'file_overlap', 'unexpected gate requires inspection'
                return high_worker, gates[0]
            high_worker, overlap = product.lib.wait_for(
                high_overlap, 'actual overlap gate for the second controlled participant', product.ui.remaining(40))
            result['overlap_approval'] = {'original_gate': copy.deepcopy(overlap), 'attempts': 1}
            answer_trace_start = len(trace(product.runtime, 'orchplus')['events'])
            product.ui.question_click(product.controller, overlap['question'])
            product.ui.choose(overlap['question'], 'Launch anyway')
            def approved():
                for event in trace(product.runtime, 'orchplus')['events'][answer_trace_start:]:
                    data = event.get('data', {})
                    outcome = data.get('command_result', {})
                    if (event['kind'] == 'native_owner_outcome' and data.get('act') == 'dispatch-operator-command'
                            and outcome.get('command') == 'answer'
                            and data.get('request_id') == outcome.get('request_id')):
                        return outcome
                return None
            answer = product.lib.wait_for(approved, 'first native overlap approval outcome', product.ui.remaining(40))
            assert answer.get('ok') and answer.get('code') == 'launch_released', answer
            assert answer['worker_id'] == high_worker['worker_id']
            result['overlap_approval']['native_outcome'] = answer
            released = registry(product.runtime)['dispatch']
            assert overlap['id'] not in released['gates'] and not released['workers'][high_worker['worker_id']].get('launch_gates')
            held = product.lib.wait_for(lambda: loss.observed('spawn', 'high-boundary'),
                                       'captured original native event high-boundary', product.ui.remaining(90))
        finally:
            product.ui.operation_deadline = None
    else:
        held = loss.wait('spawn', 'high-boundary')
    request, request_bytes = _request(held)
    if phase == 'claimed-hole':
        snapshot = registry(product.runtime)
        assert snapshot['dispatch']['actions'][request['action_id']]['request_bytes'] == request_bytes
    if low:
        assert low['request_serial'] < request['request_serial']
        assert orch_action(product, low), 'low request must remain genuinely outstanding'
    snapshot_path = product.runtime.root/'reverse-orch-snapshot.json'
    write_json(snapshot_path, snapshot)
    result['snapshot'] = {'path': str(snapshot_path), 'phase': phase, 'request': request,
                          'request_sha256': hashlib.sha256(request_bytes.encode()).hexdigest(), 'low_request': low}
    loss.set([low_hold] if low_hold else [])
    loss.deliver_original_once(held)
    launched = product.lib.wait_for(lambda: next(iter(native_launches(product, record)), None), 'actual high native effect', 60)
    identity = process_identity(launched['pid'])
    _accepted(product, record)
    product.lib.wait_for(lambda: orch_action(product, request) is None and spawn_request(product, request) is None,
                         'actual consumed and reclaimed high peer result', 120)
    before = registry(product.runtime)
    result['reclaimed'] = {'orch_revision': before['revision'], 'peer_absent': True, 'native_process': identity,
                           'low_still_outstanding': bool(low and orch_action(product, low))}
    if low:
        assert orch_action(product, low), 'completed hole lost its low outstanding action'
    result['fault'] = _restore_orch(product, snapshot)
    _reload(product, 'orchplus')
    _continue_controller(product)
    # Deliberate, unrelated policy toggles are new native owner operations, not
    # revision edits or a replay rebound onto a fresher grant.
    catches = []
    for index in range(256):
        current = registry(product.runtime)
        if current['revision'] > before['revision']+1:
            break
        sid = request['logical_session_id']
        command = 'resume' if current['dispatch']['policies'][sid]['paused'] else 'pause'
        old = current['revision']
        current = owner_setup_input(product, command=command, deadline=time.monotonic()+30,
            complete=lambda observed, source: {'revision': source['revision']}
                if source['revision'] > old and source['dispatch']['policies'][sid]['paused'] == (command == 'pause')
                else None,
            unchanged=lambda previous, source: previous['dispatch']['policies'][sid] == source['dispatch']['policies'][sid])
        catches.append(current['revision'])
    else:
        raise AssertionError('bounded unrelated revision catch-up did not reach original current revision')
    result['catch_up_revisions'] = catches
    # Replay the exact captured old boundary only. No request, grant, admission,
    # executor identity or expected revision is rewritten to make it succeed.
    loss.deliver_original_once(held)
    if original_claim:
        loss.deliver_original_once(original_claim)
    observations = []
    for _ in range(6):
        current = orch_action(product, request)
        if phase == 'before-issue':
            assert current is None, 'old absent issued action was recreated'
        elif phase == 'before-claim':
            assert current and current['phase'] == 'held_ready', 'restored unissued draft regained effect authority'
            original = snapshot['dispatch']['actions'][request['action_id']]
            assert current['request'] == original['request'] and not current.get('claim')
        else:
            assert current and current['phase'] == 'uncertain', 'restored claimed potential effect became executable'
            assert current['request_bytes'] == request_bytes
            assert current['request']['admission_seq'] == request['admission_seq']
        peer = spawn_request(product, request)
        assert not peer or peer['body']['status'] not in ('resolved', 'claimed', 'launching'), 'reclaimed old effect regained an executable peer phase'
        assert len(native_launches(product, record)) == 1
        assert process_identity(launched['pid']) == identity
        observations.append({'orch_action': current, 'peer': peer, 'native_context': product.ui('context')})
        product.lib.idle(.3)
    result['after_restore'] = observations
    product.capture('reverse-'+phase+'-no-second-effect')
    result['checks'].append('reclaimed real peer result stays non-executable after ORCH-only restore, unrelated revision catch-up and exact captured old delivery; original process remains once')


def _guide(product, result):
    initialize(product)
    _assign(product)
    worker = _accepted(product)
    launch = native_launches(product)[0]
    identity = process_identity(launch['pid'])
    old_route = copy.deepcopy(worker['origin_binding'])
    old_pane = copy.deepcopy(worker['pane_binding'])
    result['before_reload'] = {'worker': worker, 'process': identity, 'context': product.ui('context')}
    _reload(product, 'spawn')
    _reload(product, 'orchplus')
    _continue_controller(product)
    show_advanced(product)
    product.ui.command(product.controller, 'recovery_guide')
    _pick_fragment(product, 'Reload recovery:', 'Recover the previous SPAWN owner (')
    def runtime_page():
        for pane in product.ui('panes'):
            if pane.get('block') != 'spawn.spawner':
                continue
            prefs = product.ui('preferences', pane=pane['pane'])['properties']
            if prefs.get('page') == 'runtime' and any(row['id'] == 'bridge-owner-'+worker['logical_session_id']
                  for section in prefs['sections'] for row in section['rows']):
                return pane['pane'], prefs
        return None
    pane, prefs = product.lib.wait_for(runtime_page, 'clicked guide opens exact SPAWN Config runtime owner controls', 40)
    product.spawn_pane = pane
    result['clicked_runtime'] = {'pane': pane, 'preferences': prefs, 'context': product.ui('context')}
    row = 'bridge-recover-'+worker['logical_session_id']
    product.ui.preference(pane, row=row)
    def fenced():
        props = product.ui('preferences', pane=pane)['properties']
        return props if 'I verified previous controller and pending launch executors stopped or retired' in json.dumps(props) else None
    result['fenced_owner'] = product.lib.wait_for(fenced, 'visible independent SPAWN owner fence', 30)
    assert process_identity(launch['pid']) == identity, 'owner fencing broadly killed the worker'
    # The existing reattachment budget includes confirmation settlement and the
    # newly explicit ownership/admission steps. Every mutation is submitted once.
    assert getattr(product.ui, 'operation_deadline', None) is None
    product.ui.operation_deadline = time.monotonic()+120
    try:
        sid = worker['logical_session_id']
        old_controller = copy.deepcopy(registry(product.runtime)['sessions'][sid]['controller'])
        admission_seq = registry(product.runtime)['sessions'][sid]['admission_seq']
        product.ui.preference(pane, row=row)
        def confirmed():
            peer = spawn_dispatch(product)['sessions'][sid]['control']
            return peer if (peer.get('binding') is None and peer.get('recovery', {}).get('phase') == 'confirmed'
                            and peer['generation_floor'] >= old_controller['generation']) else None
        result['confirmed_spawn_recovery'] = product.lib.wait_for(
            confirmed, 'actual SPAWN confirmation retires only the previous controller', product.ui.remaining(30))
        product.ui.command(product.controller, 'recovery_guide')
        _pick_fragment(product, 'Reload recovery:', 'Retire this fenced controller generation')
        product.ui.choose('Retire this SPAWN-fenced controller generation?',
                          'Retire this controller generation; preserve workers and pending evidence')
        product.lib.wait_for(lambda: registry(product.runtime)['sessions'][sid].get('controller') is None,
                             'explicit guarded retirement of the fenced ORCH controller', product.ui.remaining(30))
        assert process_identity(launch['pid']) == identity and len(native_launches(product)) == 1
        show_advanced(product)
        product.ui.click(product.controller, 'Recover this view for review only')
        def claimed():
            session = registry(product.runtime)['sessions'][sid]
            owner = session.get('controller')
            return session if (owner and owner['owner_id'] != old_controller['owner_id']
                               and owner['generation'] > session['generation_floor']
                               and owner['generation'] > result['confirmed_spawn_recovery']['generation_floor']) else None
        reclaimed = product.lib.wait_for(claimed, 'separate native claim of a fresh controller generation',
                                        product.ui.remaining(30))
        assert not reclaimed.get('admitted') and reclaimed['admission_seq'] == admission_seq
        result['controller_replacement'] = {'previous': old_controller, 'current': reclaimed['controller'],
                                            'retained_admission_seq': admission_seq}
        product.ui.command(product.controller, 'recovery_guide')
        _pick_fragment(product, 'Reload recovery:', 'Reconcile the retained SPAWN admission')
        def admitted():
            session = registry(product.runtime)['sessions'][sid]
            peer = spawn_dispatch(product)['sessions'][sid]['control']
            binding = peer.get('binding') or {}
            return session if (session.get('admitted') and not session.get('bridge_control')
                               and binding.get('owner_id') == session['controller']['owner_id']
                               and binding.get('owner_generation') == session['controller']['generation']) else None
        current_admission = product.lib.wait_for(admitted, 'explicit reconciliation of the same retained admission',
                                                product.ui.remaining(40))
        assert current_admission['admission_seq'] == admission_seq
        result['reconciled_admission'] = current_admission
        product.ui.command(product.controller, 'recovery_guide')
        _pick_fragment(product, 'Reload recovery:', 'Reattach '+worker['work_id']+' / '+worker['worker_id'])
        product.ui.choose('Select the exact existing worker for ', 'Inspect and select existing pane '+old_pane['pane_id'])
        product.ui.choose('Attach '+worker['worker_id'], 'I verified this exact worker and old executors stopped or retired')
        def attached():
            current = _workers(product).get(worker['worker_id'])
            if current and not current.get('continuation_required') and current.get('pane_binding'):
                return current
            return None
        current = product.lib.wait_for(attached, 'exact generation native reattachment and automatic read-only reconciliation',
                                       product.ui.remaining(120))
        assert current['worker_generation'] == worker['worker_generation']
        assert current['mailbox_handle'] == worker['mailbox_handle']
        assert current['pane_binding']['pane_id'] == old_pane['pane_id']
        assert current.get('launch_origin_binding', current['origin_binding']) == old_route
        assert current['control_origin'] != old_route, 'reattachment did not establish a fresh native origin'
        assert current['control_pane_binding']['pane_id'] == old_pane['pane_id']
        assert len(native_launches(product)) == 1 and process_identity(launch['pid']) == identity
        result['after_reattach'] = current
    finally:
        product.ui.operation_deadline = None
    # The idle driver must do actual mailbox observations without a manual poll.
    before = trace(product.runtime, 'spawn')['metrics']['helper_processes']
    product.lib.wait_for(lambda: trace(product.runtime, 'spawn')['metrics']['helper_processes'] > before,
                         'automatic idle wake/read-only helper observation after reattach', 45)
    product.capture('clicked-recovery-guide-exact-worker')
    result['checks'].append('actual guide navigation, separate controller/Config attestations, exact same worker process reattached with fresh origin, no relaunch, automatic idle read-only reconciliation')


def _rollover(product, predecessor):
    return next((entry for entry in (registry(product.runtime) or {}).get('dispatch', {}).get('rollovers', {}).values()
                 if entry['predecessor_worker_id'] == predecessor and entry['phase'] not in ('complete', 'cancelled')), None)


def _coordinator(product, worker):
    state = registry(product.runtime)
    owner = state['sessions'][worker['logical_session_id']].get('orchestrator')
    return owner if owner and owner.get('managed_worker_id') == worker['worker_id'] else None


def _running_coordinator(product, record, exclude=None):
    def ready():
        for worker in _workers(product).values():
            if worker['record_id'] != record or worker['worker_id'] == exclude:
                continue
            owner = _coordinator(product, worker)
            if (worker.get('phase') == 'accepted' and owner and owner.get('phase') == 'running'
                    and worker.get('activation', {}).get('acknowledged')):
                return worker
        return None
    return product.lib.wait_for(ready, 'actual accepted and activation-ACKed coordinator '+record, 240)


def _provider_identity(product, worker):
    """Two fresh OMP sessions share a configured directory, never a conversation."""
    matches = []
    for path in (product.runtime.root/'provider-sessions'/worker['record_id']).glob('*.jsonl'):
        payload = path.read_bytes()
        lines = payload.splitlines(keepends=True)
        rows = [json.loads(line) for line in lines if line.endswith(b'\n')]
        messages = [row['message'] for row in rows if row.get('type') == 'message']
        first = next((message for message in messages if message.get('role') == 'user'), None)
        if not first:
            continue
        parts = [{'text': first['content']}] if isinstance(first['content'], str) else first['content']
        transports = [json.loads(line.removeprefix('report-files-v1: '))
                      for part in parts if isinstance(part, dict)
                      for line in part.get('text', '').splitlines() if line.startswith('report-files-v1: ')]
        if len(transports) != 1 or transports[0]['binding']['worker_id'] != worker['worker_id']:
            continue
        binding = {key: worker[key] for key in ('logical_session_id', 'worker_id', 'worker_generation',
                                               'work_id', 'launch_request_id', 'enrolment_token')}
        assert transports[0]['binding'] == binding
        assert transports[0]['assignment_sha256'] == worker['assignment_sha256']
        if worker.get('handover_id'):
            assert transports[0]['handover_id'] == worker['handover_id']
            assert transports[0]['handover_token'] == worker['handover_token']
        responses = [message for message in messages if message.get('role') == 'assistant']
        if not responses:
            continue
        assert all(message.get('provider') == 'openai-codex' and message.get('model') == 'gpt-6-astra'
                   for message in responses), 'actual provider/model differs from approved native route'
        matches.append({'file': str(path), 'sha256': hashlib.sha256(payload).hexdigest(),
                        'worker_id': worker['worker_id'], 'assistant_responses': len(responses),
                        'first_user_binding_exact': True})
    if not matches:
        return None
    assert len(matches) == 1, 'ambiguous fresh provider conversation for exact worker'
    return matches[0]


def _handover(product, result, mode):
    provider = product.provider
    loss = None if provider else EventLoss(product)
    product.start()
    product.open_spawn()
    product.create_record('c2-builder', 'OMP' if provider else 'Codex')
    product.create_record('c2-release', 'OMP')
    record = 'c2-builder' if provider else 'c3-coordinator'
    if not provider:
        product.create_record(record, 'OMP', coordinator=True)
    product.initialize_orch()
    product.configure_orch('review_disabled')
    product.claim()
    show_advanced(product)
    prompt = (
        'Bounded C3 native coordinator handover qualification; do not modify any repository file or ref, '
        'make proposals, launch workers or use Tern yourself. Preserve fixture.txt. This is a genuine '
        'post-activation user turn: retain your already initialized helper, ACCEPTED receipt and '
        'consumed activation; never initialize or report ACCEPTED again. End the turn idle. '
        'On a typed CHECKPOINT report_request only, claim it, run a real read-only check that fixture.txt is exactly good followed by newline '
        'and git status is clean, read git rev-parse HEAD, report CHECKPOINT echoing the request_id with completed/remaining work '
        'and a passed check for that exact revision with actual check evidence. Resolve that control and drain receipts, then end idle. '
        'On typed coordinator_retirement claim it, quiesce, report COORDINATOR_RELEASE with its exact owner/generation/token and action '
        'correlation, resolve the control and drain receipts, then end idle. Never self-release before retirement. '
        'Do not poll or hold a native-ask turn open; only act on the exact delivered typed control. '
        'In the genuine CHECKPOINT remaining work, explicitly instruct the fresh successor to preserve '
        'fixture.txt and all refs, acknowledge its own exact handover and activation, then wait idle '
        'for explicit owner work. No retry of uncertain effects; no predecessor transcript is transferred.'
    )
    if mode == 'terminal':
        prompt += (' On coordinator_retirement, consume and claim the genuine control, then end idle '
                   'WITHOUT reporting release or resolving it. Only the later explicit conversation turn '
                   'RELEASE HELD RETIREMENT authorizes the already requested retirement to finish.')
    _assign(product, record, coordinator=True, prompt=prompt)
    predecessor = _running_coordinator(product, record)
    before_turn = result['hybrid_coordinator_identity'][predecessor['worker_id']]['provider_identity']['assistant_responses']
    def handover_instruction_consumed():
        proof = provider_coordinator_identity(product, predecessor)
        return proof if (proof['native_agent']['state'] == 'idle'
                         and proof['provider_identity']['assistant_responses'] > before_turn) else None
    result['handover_instruction_response'] = product.lib.wait_for(
        handover_instruction_consumed, 'actual provider response to bounded handover instructions', 180)
    predecessor_owner = _coordinator(product, predecessor)
    result['predecessor'] = {'worker': predecessor, 'owner': predecessor_owner}
    result['predecessor_provider'] = provider_coordinator_identity(product, predecessor)
    predecessor_identity = result['predecessor_provider']
    if mode == 'uncertain':
        loss.set([_boundary(loss, 'successor-begin', request={'op': 'launch', 'record_id': record})])
    product.ui.command(product.controller, 'rollover', worker_id=predecessor['worker_id'])
    product.ui.choose('Roll over coordinator ', 'Roll over coordinator')
    if mode == 'terminal':
        def retirement_waiting():
            r = _rollover(product, predecessor['worker_id'])
            current = _workers(product).get(predecessor['worker_id'], {})
            retirement = current.get('retirement') or {}
            return r if (r and r['phase'] == 'retirement_requested'
                         and retirement.get('acknowledged')) else None
        result['prepared_before_retirement'] = product.lib.wait_for(
            retirement_waiting, 'real prepared successor and typed retirement receipt', 180)
        assert result['prepared_before_retirement'].get('prepared')
        product.ui.command(product.controller, 'pause')
        product.lib.wait_for(lambda: registry(product.runtime)['dispatch']['policies'][predecessor['logical_session_id']]['paused'],
                             'native pause before releasing actual predecessor', 30)
        provider_coordinator_prompt(product, predecessor,
            'RELEASE HELD RETIREMENT. Complete only the already claimed genuine coordinator_retirement: '
            'quiesce, report COORDINATOR_RELEASE with its exact payload/correlation, resolve it and drain receipts.',
            deadline=time.monotonic()+180)
        def retired_held():
            r = _rollover(product, predecessor['worker_id'])
            return r if r and r['phase'] == 'owner_retired' and r.get('hold', {}).get('code') == 'session_paused' else None
        result['post_retirement_hold'] = product.lib.wait_for(retired_held, 'actual stopped and retired predecessor with paused unreserved successor', 180)
        state = registry(product.runtime)
        assert state['sessions'][predecessor['logical_session_id']].get('orchestrator') is None
        assert not any(w.get('handover_id') for w in _workers(product).values()
                       if w['record_id'] == record), 'paused retirement launched a successor'
        product.ui.command(product.controller, 'close_handover', worker_id=predecessor['worker_id'])
        product.ui.choose('Close retired handover without a successor?', 'Leave no coordinator; require an explicit new start')
        product.lib.wait_for(lambda: _rollover(product, predecessor['worker_id']) is None,
                             'actual explicit terminal handover close', 60)
        assert registry(product.runtime)['sessions'][predecessor['logical_session_id']].get('orchestrator') is None
        assert not any(w.get('handover_id') for w in _workers(product).values()
                       if w['record_id'] == record), 'terminal close launched a successor'
        result['checks'].append('real checkpoint/retirement/stop/owner release, post-retirement transient pause without reservation, clicked safe terminal close, no successor effect')
    elif mode == 'uncertain':
        held = loss.wait('spawn', 'successor-begin')
        request, request_bytes = _request(held)
        assert request['enrolment']['handover_id']
        snapshot = spawn_dispatch(product)
        retained = spawn_request(product, request)
        assert retained['body']['status'] == 'claimed' and retained.get('claim')
        result['successor_claim'] = {'request_sha256': hashlib.sha256(request_bytes.encode()).hexdigest(),
                                     'request': request, 'claim': retained['claim']}
        loss.set([_result_hold(request, orch_action(product, request), 'successor-result')])
        loss.deliver_original_once(held)
        successor = next(w for w in _workers(product).values()
                         if w['record_id'] == record and w['worker_id'] != predecessor['worker_id'])
        def successor_effect():
            directory = product.runtime.root/'provider-sessions'/record
            return any(str(directory) in agent.get('command', '')
                       for agent in product.ui('agents'))
        product.lib.wait_for(successor_effect, 'actual successor Native OMP process', 90)
        result['successor_provider'] = product.lib.wait_for(
            lambda: _provider_identity(product, successor), 'actual successor provider response', 180)
        successor_agents = [agent for agent in product.ui('agents')
                            if str(product.runtime.root/'provider-sessions'/record) in agent.get('command', '')]
        assert len(successor_agents) == 1, 'expected exactly one live successor Native OMP process'
        argv = shlex.split(successor_agents[0]['command'])
        assert argv.count('--model') == 1 and argv[argv.index('--model')+1] == 'openai-codex/gpt-6-astra'
        assert argv.count('--session-dir') == 1
        assert Path(argv[argv.index('--session-dir')+1]) == product.runtime.root/'provider-sessions'/record
        result['successor_native_effect'] = successor_agents[0]
        loss.wait('orchplus', 'successor-result')
        result['fault'] = restore_spawn_snapshot(product, snapshot)
        _reload(product, 'spawn')
        product.lib.wait_for(lambda: (spawn_request(product, request) or {}).get('body', {}).get('status') == 'uncertain',
                             'potential successor effect retained uncertain after native reload', 60)
        result['uncertain_successor'] = spawn_request(product, request)
        for _ in range(6):
            current_successors = [w for w in _workers(product).values()
                                  if w['record_id'] == record and w['worker_id'] != predecessor['worker_id']]
            assert len(current_successors) == 1 and current_successors[0]['worker_id'] == successor['worker_id'], 'uncertain successor was re-enrolled'
            assert current_successors[0]['phase'] != 'accepted', 'held launch result permitted successor acceptance'
            observed_agents = [agent for agent in product.ui('agents')
                               if str(product.runtime.root/'provider-sessions'/record) in agent.get('command', '')]
            assert len(observed_agents) == 1 and observed_agents[0]['pane'] == successor_agents[0]['pane'], 'uncertain successor was relaunched'
            state = registry(product.runtime)
            owners = [session['orchestrator'] for session in state['sessions'].values() if session.get('orchestrator')]
            assert len(owners) == 1 and owners[0]['owner_id'] != predecessor_owner['owner_id']
            controls = product.ui('surface', pane=product.controller)
            assert not any(node.get('p', {}).get('attrs', {}).get('data-orchplus-command') == 'close_handover'
                           and not node.get('p', {}).get('disabled') for node in surface_nodes((controls or {}).get('main'))), 'unsafe post-effect cancel remains available'
            product.lib.idle(.3)
        r = _rollover(product, predecessor['worker_id'])
        assert r and r.get('prepare_count', 0) <= registry(product.runtime)['dispatch']['policies'][predecessor['logical_session_id']]['loop_cap']
        result['retained_handover'] = r
        result['checks'].append('actual predecessor closure and one potential successor native effect; captured claimed-state rollback stays uncertain, one owner, bounded preparation, no cancel/relaunch')
    else:
        successor = _running_coordinator(product, record, exclude=predecessor['worker_id'])
        owner = _coordinator(product, successor)
        assert owner['owner_id'] != predecessor_owner['owner_id']
        assert owner['generation'] > predecessor_owner['generation']
        assert successor['worker_generation'] > predecessor['worker_generation']
        assert successor.get('handover_id') and successor['pane_binding'] != predecessor['pane_binding']
        product.lib.wait_for(lambda: _rollover(product, predecessor['worker_id']) is None,
                             'accepted successor activation and terminal rollover reclamation', 120)
        result['successor'] = {'worker': successor, 'owner': owner}
        result['successor_provider'] = provider_coordinator_identity(product, successor)
        assert result['successor_provider']['provider_identity']['session_file'] != predecessor_identity['provider_identity']['session_file']
        def predecessor_absent():
            return not any(str(pane['pane']) == predecessor['pane_binding']['pane_id']
                           for pane in product.ui('panes'))
        product.lib.wait_for(predecessor_absent, 'actual original coordinator pane ended', 30)
        state = registry(product.runtime)
        assert sum(bool(session.get('orchestrator')) for session in state['sessions'].values()) == 1
        old = state['dispatch']['workers'].get(predecessor['worker_id'])
        assert old is None or old.get('stopped', {}).get('observation') in ('absent', 'exited')
        result['checks'].append('native successor actually launched, accepted exact handover, ACKed activation after predecessor stop/retirement; one current coordinator and no terminal rollover history')
    product.capture('native-handover-'+mode)
    result['limits'].append('Full preflight placement/capability/manifest/input/capacity/provision/add and every-phase reload grid belongs to native owner suites, not this representative runtime cell.')


def _inventory(product):
    inventory = json.loads(product.runtime.command('inspect', '--json'))
    assert isinstance(inventory.get('clients'), list)
    assert inventory.get('complete') is not False and inventory.get('truncated') is not True
    return inventory


def _incarnation(product, ui):
    key = ui('context')['window']
    inventory = _inventory(product)
    clients = [client for client in inventory['clients'] if client.get('kind') == 'window' and client.get('window') == key]
    assert len(clients) == 1 and all(isinstance(clients[0].get(name), int) for name in ('conn', 'since'))
    return {'window_key': key, 'conn': clients[0]['conn'], 'since': clients[0]['since']}


def _component(value):
    encoded = value.encode().hex()
    return Path(*('x'+encoded[offset:offset+120] for offset in range(0, len(encoded), 120))) if encoded else Path('x')


def _journal(product, incarnation):
    directory = product.runtime.config/'plugin-data/spawn'
    namespace = read_json(directory/'window-observer/namespace.json')
    assert isinstance(namespace, str) and namespace
    root = directory/'window-observer'/_component(namespace)
    expected = {'version': 1, 'namespace': namespace, **incarnation,
                'observer_id': 'window-'+namespace+'-'+str(incarnation['conn'])+'-'+str(incarnation['since'])+'-'+incarnation['window_key']}
    matches = [path.parent for path in (root/'windows').glob('*/identity.json')
               if read_json(path) == expected]
    assert len(matches) <= 1, 'multiple journal leaves claim the same native incarnation'
    return namespace, root, matches[0] if matches else None


def _files(product, incarnation):
    def read_all():
        namespace, root, path = _journal(product, incarnation)
        if path is None:
            return None
        values = {name: read_json(path/name) for name in
                  ('identity.json', 'observer.json', 'spawn.records-seen.v1.json', 'spawn.intents.v1.json')}
        if not all(value is not None for value in values.values()):
            return None
        return {'namespace': namespace, 'root': str(root), 'directory': str(path), 'files': values}
    result = product.lib.wait_for(read_all, 'native incarnation identity, journal and both caches persisted', 40)
    assert result['files']['observer.json']['version'] == 2
    assert result['files']['observer.json']['id'] == result['files']['identity.json']['observer_id']
    return result


def _close_window(product, ui, incarnation):
    assert ui.window_key == incarnation['window_key']
    def matching(inventory):
        return [client for client in inventory['clients'] if client.get('kind') == 'window'
                and client.get('window') == incarnation['window_key'] and client.get('conn') == incarnation['conn']
                and client.get('since') == incarnation['since']]
    assert len(matching(_inventory(product))) == 1
    def offered():
        tree = ui.runtime.ctl('tree')
        choices = [node for node in native_nodes(tree.get('tree', []))
                   if node.get('tag') == 'button' and 'csd-close' in node.get('class', '').split()]
        return choices[0] if len(choices) == 1 else None
    node = ui.lib.wait_for(offered, 'actual native window-chrome close control', 40)
    x, y, width, height = node['rect']
    ui.record_input({'op': 'native_window_close', 'window_key': ui.window_key, 'control': node})
    ui.runtime.ctl('click', str(x+width/2), str(y+height/2))
    confirmation = None
    def ended():
        nonlocal confirmation
        inventory = _inventory(product)
        current = matching(inventory)
        if not current:
            return inventory
        assert len(current) == 1
        tree = ui.runtime.ctl('tree')
        dialogs = [node for node in native_nodes(tree.get('tree', [])) if node.get('role') == 'dialog']
        if dialogs and confirmation is None:
            assert len(dialogs) == 1
            assert any(node.get('tag') == 'h2' and node.get('text') == 'Close window?'
                       for node in native_nodes(dialogs[0]))
            buttons = [node for node in native_nodes(dialogs[0]) if node.get('tag') == 'button'
                       and node.get('text') == 'Close' and 'mdl-go' in node.get('class', '').split()]
            assert len(buttons) == 1
            # This is the explicitly owned disposable window, not a user window.
            # Record before clicking and never resubmit an uncertain confirmation.
            confirmation = dialogs[0]
            ui.record_input({'op': 'native_window_close_confirmation', 'window_key': ui.window_key,
                             'incarnation': incarnation, 'dialog': confirmation, 'control': buttons[0]})
            x, y, width, height = buttons[0]['rect']
            ui.runtime.ctl('click', str(x+width/2), str(y+height/2))
        return None
    observed = product.lib.wait_for(ended, 'complete native inventory proves selected incarnation gone', 40)
    return {'incarnation': incarnation, 'confirmation': confirmation, 'clients_after': observed['clients']}


def _restart_owned_gui(product, expected, worker_pid, worker_identity):
    """Exercise native key reuse without stopping the private session daemon."""
    runtime, lib = product.runtime, product.lib
    assert _incarnation(product, product.ui) == expected
    context = product.ui('context')
    inventory = _inventory(product)
    assert len([client for client in inventory['clients'] if client.get('kind') == 'window']) == 1
    gui = [entry for entry in runtime.own if entry['process'].args[0] == 'xvfb-run']
    daemon = [entry for entry in runtime.own if entry['process'].args[:2] == [lib.TERN, 'daemon']]
    assert len(gui) == len(daemon) == 1 and gui[0]['pgid'] != daemon[0]['pgid']
    gui = gui[0]
    assert process_identity(worker_pid) == worker_identity and os.getpgid(worker_pid) != gui['pgid']
    argv = list(gui['process'].args)
    result = product.result.setdefault('owned_gui_restart', {})
    result['before'] = {'incarnation': expected, 'context': context, 'clients': inventory,
                        'gui_pid': gui['process'].pid, 'gui_pgid': gui['pgid'], 'gui_argv': argv,
                        'daemon_pid': daemon[0]['process'].pid, 'worker': worker_identity}
    lib.WAKERS.remove(runtime.poke)
    lib.stop_entry(gui)
    def ended():
        inventory = _inventory(product)
        if any(client.get('kind') == 'window' for client in inventory['clients']):
            return None
        try:
            os.killpg(gui['pgid'], 0)
        except ProcessLookupError:
            return inventory
        return None
    result['ended_frontend'] = lib.wait_for(ended, 'owned GUI group and native window incarnation ended', 40)
    assert gui['process'].poll() is not None and daemon[0]['process'].poll() is None
    assert process_identity(worker_pid) == worker_identity
    # Keep the stopped entry in the global ledger; only the live-runtime list
    # changes. The old native journals and authority are never edited.
    runtime.own.remove(gui)
    result['ended_frontend_exit'] = gui['process'].returncode
    if runtime.control.exists():
        assert stat.S_ISSOCK(runtime.control.lstat().st_mode)
        runtime.control.unlink()
    runtime.spawn(argv, cwd=runtime.root)
    lib.wait_for(runtime.control.exists, 'same private native GUI control endpoint reopened', 40)
    lib.WAKERS.append(runtime.poke)
    runtime.checked_state()
    after = _incarnation(product, product.ui)
    after_context = product.ui('context')
    assert after['window_key'] == expected['window_key'] and after != expected
    assert after_context['session']['id'] == context['session']['id']
    assert any(str(pane['pane']) == str(product.spawn_pane) and pane.get('block') == 'spawn.spawner'
               for pane in product.ui('panes'))
    assert process_identity(worker_pid) == worker_identity
    result['after'] = {'incarnation': after, 'context': after_context, 'clients': _inventory(product),
                       'worker': process_identity(worker_pid)}
    return result


def _native_spawn_snapshot(ui, pane):
    surface = ui('surface', pane=pane)
    for node in surface_nodes((surface or {}).get('main')):
        props = node.get('p', {})
        if props.get('key') == 'spawn-state':
            text = props.get('text', ''.join(span if isinstance(span, str) else span.get('t', '')
                                            for span in props.get('spans', [])))
            assert text.startswith('SPAWN_STATE_V2 ')
            value = json.loads(text.removeprefix('SPAWN_STATE_V2 '))
            return value if value.get('ready') else None
    return None


def _empty_intent_queue(ui, pane, queue_id=None):
    current = ui.machine(pane, 'spawn.launch.intent', 'spawn-launch-intent')
    # A missing projection is unknown. Only the durable explicit empty queue is
    # positive ACK evidence; an expected queue identity must still match.
    if (current and current.get('schema') == 1 and isinstance(current.get('queue_id'), str)
            and current['queue_id'] and 'intents' in current and not current['intents']
            and (queue_id is None or current['queue_id'] == queue_id)):
        return current
    return None


def _window_persistence(product, result):
    loss = EventLoss(product)
    product.start()
    product.open_spawn()
    product.create_record('c2-builder', 'Codex')
    import_terminal_record(product, 'c3-window-held')
    import_terminal_record(product, 'c3-ordinary')
    second = additional_window(product)
    first_id, second_id = _incarnation(product, product.ui), _incarnation(product, second)
    assert first_id != second_id
    result['native_clients_before'] = _inventory(product)
    # Each real window owns a native Config; neither is assumed to mirror the
    # other's pane. Establish the second required ordinary effect here, so both
    # incarnation caches have genuine native traffic before the reload proof.
    second_pane = second('open', kind='spawn.spawner')
    def shared_authority():
        first = _native_spawn_snapshot(product.ui, product.spawn_pane)
        other = _native_spawn_snapshot(second, second_pane)
        if not first or not other:
            return None
        authority = spawn_authority(product.runtime)
        for snapshot in (first, other):
            assert snapshot['namespace'] == authority['namespace']
            assert snapshot['host_key'] == authority['host_key']
            assert snapshot['authority_id'] == authority['sessions'][snapshot['session_key']]['authority_id']
            assert snapshot['config_revision'] == authority['config_revision']
            assert snapshot['records'] == authority['config']['hosts'][authority['host_key']]['agents']
        assert first['session_key'] != other['session_key']
        return {'first': first, 'second': other, 'namespace': authority['namespace']}
    result['shared_host_authority'] = product.lib.wait_for(
        shared_authority, 'both native Configs independently observe the shared host authority', 40)
    second.preference(second_pane, page='spawn')
    props = second('preferences', pane=second_pane)['properties']
    row = next(row for section in props['sections'] for row in section['rows']
               if row['id'].startswith('spawn-launch:') and row['id'].endswith(':c3-window-held'))
    second.preference(second_pane, row=row['id'])
    held_launch = product.lib.wait_for(lambda: next(iter(native_launches(product, 'c3-window-held')), None),
                                      'actual unresolved effect owned by second incarnation', 60)
    second_process = process_identity(held_launch['pid'])
    result['second_queue_ack'] = product.lib.wait_for(
        lambda: _empty_intent_queue(second, second_pane), 'second Config durable native intent ACK', 40)
    second_files = _files(product, second_id)
    # Suppress only the first incarnation's genuine ACK, not the negative
    # wrong-incarnation envelope exercised below.
    loss.set([{'id': 'ordinary-intent-ack', 'block': 'spawner', 'act': 'spawn.launch-intent-ack',
               'match': {'window_key': first_id['window_key']}}])
    product.ui.preference(product.spawn_pane, page='spawn')
    props = product.ui('preferences', pane=product.spawn_pane)['properties']
    rows = [row for section in props['sections'] for row in section['rows']
            if row['id'].startswith('spawn-launch:') and row['id'].endswith(':c3-ordinary')]
    assert len(rows) == 1
    product.ui.preference(product.spawn_pane, row=rows[0]['id'])
    held = loss.wait('spawn', 'ordinary-intent-ack')
    recipient = json.loads(held['input']['value'])
    launch = product.lib.wait_for(lambda: next(iter(native_launches(product, 'c3-ordinary')), None),
                                 'one actual ordinary native invocation with two windows', 60)
    identity = process_identity(launch['pid'])
    assert len(native_launches(product, 'c3-ordinary')) == 1
    intent = product.ui.machine(product.spawn_pane, 'spawn.launch.intent', 'spawn-launch-intent')
    assert intent and len(intent['intents']) == 1
    assert intent['intents'][0]['recipient'] == {key: recipient[key] for key in ('observer_id', 'window_key', 'conn', 'since')}
    foreign = dict(recipient)
    foreign.update({key: second_files['files']['identity.json'][key]
                    for key in ('observer_id', 'window_key', 'conn', 'since')})
    foreign_event = copy.deepcopy(held['input'])
    foreign_event['value'] = json.dumps(foreign)
    before_lead = product.ui('preferences', pane=product.spawn_pane)['properties']['lead']
    product.ui('event', pane=held['pane'], event=foreign_event)
    refusal = product.lib.wait_for(
        lambda: (value if (value := product.ui('preferences', pane=product.spawn_pane)['properties'])['lead']
                 != before_lead else None), 'native handler presents foreign-incarnation ACK refusal', 40)
    assert product.ui.machine(product.spawn_pane, 'spawn.launch.intent', 'spawn-launch-intent') == intent
    assert len(native_launches(product, 'c3-ordinary')) == 1
    assert process_identity(launch['pid']) == identity
    assert process_identity(held_launch['pid']) == second_process
    result['cross_window_intent'] = {
        'recipient': recipient, 'first_surface': intent, 'second_config': second_pane,
        'foreign_ack': foreign, 'native_refusal': refusal,
        'injection': 'Negative envelope naming the real second incarnation, submitted once through the original Config native handler; no foreign success authority invented.',
        'native_process': identity, 'second_native_process': second_process}
    before = [_files(product, incarnation) for incarnation in (first_id, second_id)]
    authority = spawn_authority(product.runtime)
    attempts = [copy.deepcopy(attempt) for scope in authority['sessions'].values() for attempt in scope['launch']['attempts']]
    result['before_reload'] = {'journals': before, 'authority_sha256': _digest(authority), 'attempts': attempts}
    _reload(product, 'spawn')
    assert _incarnation(product, product.ui) == first_id
    assert _incarnation(product, second) == second_id
    after = [_files(product, incarnation) for incarnation in (first_id, second_id)]
    for old, current in zip(before, after):
        assert old['directory'] == current['directory']
        assert old['files']['observer.json']['id'] == current['files']['observer.json']['id']
        assert current['files']['observer.json']['next_run'] >= old['files']['observer.json']['next_run']
        for cache in ('spawn.records-seen.v1.json', 'spawn.intents.v1.json'):
            prior, saved = old['files'][cache], current['files'][cache]
            if isinstance(prior, dict):
                assert all(saved.get(key) == value for key, value in prior.items())
            else:
                assert isinstance(prior, list) and all(value in saved for value in prior)
    current_authority = spawn_authority(product.runtime)
    assert current_authority['config'] == authority['config']
    # Compare actual attempt identity, not volatile native liveness timestamps.
    old_attempt_ids = {attempt['id'] for attempt in attempts}
    current_attempt_ids = {attempt['id'] for scope in current_authority['sessions'].values() for attempt in scope['launch']['attempts']}
    assert old_attempt_ids <= current_attempt_ids
    assert len(native_launches(product, 'c3-ordinary')) == 1 and process_identity(launch['pid']) == identity
    result['after_reload'] = after
    loss.set([])
    loss.deliver_original_once(held)
    result['first_queue_ack'] = product.lib.wait_for(
        lambda: _empty_intent_queue(product.ui, product.spawn_pane, intent['queue_id']),
        'exact original recipient ACK publishes the durable empty host queue', 40)
    # The second incarnation's earlier real unresolved attempt must survive;
    # positional key reuse is never permission to erase its journal.
    second_files = _files(product, second_id)
    old_tracks = second_files['files']['observer.json']['tracked']
    assert any(track.get('attempt', {}).get('record_id') == 'c3-window-held'
               and track['attempt'].get('unresolved') for track in old_tracks.values())
    result['gone_incarnation_obligation'] = {'launch': held_launch, 'journal': second_files}
    # End only the second native window. New window may allocate another key;
    # actual same-key reuse is exercised through the owned GUI lifetime below.
    # The old wake references a deliberately closed window.
    for wake in getattr(product, 'extra_wakers', []):
        if wake in product.lib.WAKERS:
            product.lib.WAKERS.remove(wake)
    product.extra_wakers = []
    result['window_close'] = _close_window(product, second, second_id)
    # Ready files are private driver observations, not product journals. Remove
    # this stale announcement so additional_window cannot select an ended peer.
    for path in product.ui.data.glob('ready-window-*.json'):
        ready = read_json(path)
        if ready and ready['window_key'] == second_id['window_key']:
            path.unlink()
    replacement = additional_window(product)
    replacement_id = _incarnation(product, replacement)
    assert replacement_id != second_id
    replacement_files = _files(product, replacement_id)
    assert replacement_files['directory'] != before[1]['directory']
    retained = read_json(Path(second_files['directory'])/'observer.json')
    assert retained and retained['id'] == second_files['files']['observer.json']['id']
    assert any(track.get('attempt', {}).get('record_id') == 'c3-window-held'
               and track['attempt'].get('unresolved') for track in retained['tracked'].values()), 'gone incarnation with unresolved attempt was pruned'
    assert replacement_files['files']['observer.json']['id'] != retained['id']
    assert len(native_launches(product, 'c3-window-held')) == 1, 'new incarnation retried an old unresolved launch'
    assert len(native_launches(product, 'c3-ordinary')) == 1
    assert process_identity(launch['pid']) == identity
    result['replacement_window'] = {'ended': second_id, 'replacement': replacement_id,
                                 'new_journal': replacement_files, 'clients': _inventory(product)}
    for wake in getattr(product, 'extra_wakers', []):
        if wake in product.lib.WAKERS:
            product.lib.WAKERS.remove(wake)
    product.extra_wakers = []
    result['replacement_close'] = _close_window(product, replacement, replacement_id)
    first_files = _files(product, first_id)
    assert any(track.get('attempt', {}).get('record_id') == 'c3-ordinary'
               and track['attempt'].get('unresolved')
               for track in first_files['files']['observer.json']['tracked'].values())
    result['owned_gui_restart'] = _restart_owned_gui(product, first_id, launch['pid'], identity)
    reused_id = result['owned_gui_restart']['after']['incarnation']
    reused_files = _files(product, reused_id)
    assert reused_files['directory'] != first_files['directory']
    retained_journals = []
    for previous, record in ((first_files, 'c3-ordinary'), (second_files, 'c3-window-held')):
        old = read_json(Path(previous['directory'])/'observer.json')
        assert old and old['id'] == previous['files']['observer.json']['id']
        assert any(track.get('attempt', {}).get('record_id') == record and track['attempt'].get('unresolved')
                   for track in old['tracked'].values()), 'native GUI lifetime change pruned unresolved history'
        assert reused_files['files']['observer.json']['id'] != old['id']
        retained_journals.append({'directory': previous['directory'], 'observer': old})
    old_cache = before[0]['files']['spawn.intents.v1.json']
    assert any(entry.get('intent_id') == recipient['intent_id'] and entry.get('queue_id') == recipient['queue_id']
               for entry in old_cache), 'the original real held intent was not captured'
    new_cache = reused_files['files']['spawn.intents.v1.json']
    assert not any(entry.get('intent_id') == recipient['intent_id'] and entry.get('queue_id') == recipient['queue_id']
                   for entry in new_cache), 'new incarnation inherited the original intent'
    assert len(native_launches(product, 'c3-window-held')) == len(native_launches(product, 'c3-ordinary')) == 1
    assert process_identity(launch['pid']) == identity
    result['reused_position'] = {'ended': first_id, 'replacement': reused_id, 'new_journal': reused_files,
                                 'retained_journals': retained_journals, 'clients': _inventory(product)}
    kv = read_json(product.runtime.config/'plugin-data/spawn/kv.json')
    assert not any(key in ('window-observer-namespace', 'spawn.records-seen.v1', 'spawn.intents.v1')
                   or key.startswith(('window-observer:', 'window-observer-index:')) for key in kv)
    result['checks'].append('two native Configs independently observe shared host authority; foreign-incarnation ACK cannot consume the original intent or duplicate its effect; authority and distinct journals/cache survive reload; actual same-key/new-incarnation reuse retains unresolved history and the original worker without replay; no shared seen-ID KV writer')
    product.capture('two-native-window-incarnations-one-ordinary-effect')


def _legacy_journals(product, result, incomplete=False):
    """Negative restore of captured V2 journals, never invented old identities."""
    product.start()
    product.open_spawn()
    product.create_record('c2-builder', 'Codex')
    product.ui.preference(product.spawn_pane, page='spawn')
    props = product.ui('preferences', pane=product.spawn_pane)['properties']
    row = next(row for section in props['sections'] for row in section['rows']
               if row['id'].startswith('spawn-launch:') and row['id'].endswith(':c2-builder'))
    product.ui.preference(product.spawn_pane, row=row['id'])
    launch = product.lib.wait_for(lambda: next(iter(native_launches(product)), None),
                                 'actual unresolved ordinary attempt before legacy-layout restore', 60)
    launch_identity = process_identity(launch['pid'])
    second = additional_window(product)
    identities = [_incarnation(product, ui) for ui in (product.ui, second)]
    captures = [_files(product, identity) for identity in identities]
    namespace = captures[0]['namespace']
    assert all(item['namespace'] == namespace for item in captures)
    # Captured equal-value legacy caches are shared old-format data. Use the
    # actual first window value; they are migration inputs, not authority/effects.
    caches = {name.removesuffix('.json'): captures[0]['files'][name]
              for name in ('spawn.records-seen.v1.json', 'spawn.intents.v1.json')}
    path = product.runtime.config/'plugin-data/spawn/kv.json'
    before = read_json(path)
    replacement = copy.deepcopy(before)
    index = {}
    for identity, item in zip(identities, captures):
        observer = item['files']['observer.json']
        key = 'window-observer:'+observer['id']
        replacement[key] = observer
        index[key] = {'window': identity['window_key']}
    replacement.update(caches)
    replacement['window-observer-namespace'] = namespace
    replacement['window-observer-index:'+namespace] = index
    missing = next(iter(index)) if incomplete else None
    if missing:
        del replacement[missing]
    result['legacy_restore'] = {'captured_journals': captures, 'index': index,
                                'kv_before_sha256': _digest(before), 'kv_fault_sha256': _digest(replacement)}
    fault_trace_index = len(trace(product.runtime, 'spawn')['events'])
    # Restore only the exact captured leaves to KV-only storage. Nonrecursive
    # removal refuses unknown files instead of disguising an unsupported layout.
    for item in captures:
        directory = Path(item['directory'])
        for name in item['files']:
            (directory/name).unlink()
        directory.rmdir()
    (Path(captures[0]['root'])/'windows').rmdir()
    (Path(captures[0]['root'])/'migration.json').unlink()
    write_json(path, replacement)
    assert read_json(path) == replacement
    legacy_keys = {*index, *caches, 'window-observer-namespace', 'window-observer-index:'+namespace}
    _reload(product, 'spawn')
    if incomplete:
        def held():
            props = product.ui('preferences', pane=product.spawn_pane)['properties']
            return props if 'Window journal migration incomplete' in json.dumps(props) else None
        result['visible_incomplete_migration'] = product.lib.wait_for(held, 'visible missing indexed source migration hold', 40)
        after = read_json(path)
        assert after['window-observer-index:'+namespace] == index
        assert after['window-observer-namespace'] == namespace
        assert all(after.get(key) == replacement[key] for key in (*caches, *index) if key != missing)
        assert not any(event['kind'] == 'legacy_kv_delete' and event['data']['key'] in legacy_keys
                       for event in trace(product.runtime, 'spawn')['events'][fault_trace_index:])
        assert after['authority']['config'] == before['authority']['config']
        assert len(native_launches(product)) == 1 and process_identity(launch['pid']) == launch_identity
        result['checks'].append('captured indexed legacy source loss visibly blocks migration before any KV deletion; real unresolved native attempt and unrelated authority remain, no relaunch')
        return
    migrated = [_files(product, identity) for identity in identities]
    after = read_json(path)
    assert all(key not in after for key in index)
    assert all(key not in after for key in (*caches, 'window-observer-namespace', 'window-observer-index:'+namespace))
    assert after['authority']['config'] == before['authority']['config']
    assert read_json(Path(captures[0]['root'])/'migration.json') == {'phase': 'ready', 'layout': 'flat-v1'}
    result['migrated'] = migrated
    result['migration_trace'] = trace(product.runtime, 'spawn')
    # Completion requires ordered actual native I/O evidence, not merely the
    # final absence of legacy KV. The opt-in probe never substitutes I/O.
    events = result['migration_trace']['events'][fault_trace_index:]
    def native_path(event):
        path = Path(event['data']['path'])
        return str(path if path.is_absolute() else product.runtime.config/'plugin-data/spawn'/path)
    deletes = [ordinal for ordinal, event in enumerate(events)
               if event['kind'] == 'legacy_kv_delete' and event['data']['key'] in legacy_keys]
    assert deletes, 'missing actual host-only legacy deletion receipts'
    first_delete = min(deletes)
    for item in captures:
        wanted = {'observer.json': item['files']['observer.json'],
                  **{name+'.json': value for name, value in caches.items()}}
        for name, value in wanted.items():
            target = str(Path(item['directory'])/name)
            writes = [index for index, event in enumerate(events[:first_delete])
                      if event['kind'] == 'journal_write' and native_path(event) == target
                      and json.loads(event['data']['bytes']) == value]
            assert writes, 'missing equal-value native legacy journal copy: '+target
            assert any(event['kind'] == 'journal_read' and native_path(event) == target
                       and json.loads(event['data']['bytes']) == value
                       for event in events[max(writes)+1:first_delete]), 'legacy KV deleted before equal native read-back'
    assert len(native_launches(product)) == 1 and process_identity(launch['pid']) == launch_identity
    assert any(track.get('attempt', {}).get('unresolved') for item in migrated
               for track in item['files']['observer.json'].get('tracked', {}).values()), 'migration lost the real unresolved attempt'
    result['checks'].append('captured V2 native identities restored to legacy layout; actual equal-value copy and read-back precede first host-only KV deletion; current authority configuration preserved')
    result['limits'].append('Captured current V2 content in legacy storage layout is negative migration-fault proof, not a frozen old-release-created fixture. Full interrupted/incomplete/orphan legacy grid remains in native owner suites.')


def recovery(base, root, evidence, processes, lib, args):
    phases = ('resolved', 'claimed', 'launching')
    cases = [
        ('reverse-before-issue', lambda p, r: _reverse(p, r, 'before-issue'), False),
        ('reverse-before-claim', lambda p, r: _reverse(p, r, 'before-claim'), False),
        ('reverse-claimed-completed-hole', lambda p, r: _reverse(p, r, 'claimed-hole'), False),
        ('clicked-recovery-guide', _guide, False),
        ('handover-component-positive', lambda p, r: _handover(p, r, 'positive'), False),
        ('handover-held-terminal', lambda p, r: _handover(p, r, 'terminal'), False),
        ('handover-uncertain', lambda p, r: _handover(p, r, 'uncertain'), False),
        ('handover-native-provider-positive', lambda p, r: _handover(p, r, 'positive'), True),
        ('two-window-persistence', _window_persistence, False),
        ('window-legacy-copy-readback', _legacy_journals, False),
        ('window-incomplete-migration', lambda p, r: _legacy_journals(p, r, incomplete=True), False),
    ]
    selected, selection = select_runtime_cases(args, 'recovery',
        ['spawn-rollback-'+phase for phase in phases]+[name for name, _, _ in cases])
    result = {'status': 'not_run', 'mode': 'recovery', 'cases': {}, 'selection': selection,
              'qualification_complete': False, 'limits': [
                  'Owned Linux native desktop only; no Odin scripts-disabled or Thor locked session is launched.',
                  'Private receipts contain capabilities and original events; never publish raw evidence.',
                  'Deterministic native effects and actual provider responses are separate evidence classes.',
                  'Native owner suites remain required for full preflight/every-persisted-phase reload and migration grids.']}
    evidence['recovery'] = result
    if not selected:
        return result
    unavailable = prerequisites()
    if unavailable:
        result.update(unavailable)
        return result
    for phase in phases:
        name = 'spawn-rollback-'+phase
        if name in selected:
            result['cases'][name] = native_rollback_case(base, root, evidence, processes, lib, args, phase)
    for name, body, provider in cases:
        if name in selected:
            result['cases'][name] = _case(base, root, evidence, processes, lib, args, 'recovery-'+name, body, provider)
    result['executed_cases'] = len(result['cases'])
    result['passed_cases'] = sum(case['status'] == 'passed' for case in result['cases'].values())
    result['status'] = 'passed' if result['passed_cases'] == len(result['cases']) else 'failed'
    result['qualification_complete'] = result['status'] == 'passed' and not selection['unrun']
    result['status_scope'] = 'actual selected runtime effects only; never substitutes for full owner-suite transition acceptance'
    return result

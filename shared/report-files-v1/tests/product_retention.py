"""Mandatory C3 retention qualification through ordinary, owned native controls.

The long case uses byte-identical packages, not the bounded instrumentation trace.
Its append-only receipts are PRIVATE TEST EVIDENCE, never product replay authority.
Counts are successful issued results and observed owner/session removals, not loop
iterations. Named conversations create and connect ownership automatically; their
initial agent picker is dismissed with Back, so retention never starts a synthetic worker.
Small instrumented cases exercise exact automatic-admission/catalog input loss
and held close phases/reload. No provider, reducer seeding, deadline extension,
or alternate product runner.
"""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import time
import traceback

from product_c2 import Product, RECORDS, additional_window, owner_setup_input, prerequisites, provider_coordinator_identity, spawn_authority, surface_nodes
from product_c3 import EventLoss, initialize, native_launches, select_runtime_cases, spawn_dispatch, write_json
from product_recovery import _accepted, _assign, _reload
from product_scenario import TESTS, read_json, registry


REQUEST_TARGET = 4098
RETIREMENT_TARGET = 2049
SESSION_TARGET = 65
KEYED_TABLES = ('catalogs', 'sweeps', 'policies', 'command_cursors', 'capacity')
SCOPED_TABLES = ('actions', 'workers', 'gates', 'rollovers', 'reviews', 'deploys',
                 'plans', 'intakes', 'chains', 'commands', 'projects')
OLD_HISTORY_KEYS = ('request_outcomes', 'retired', 'request_fences', 'tombstones',
                    'retired_generations', 'reconcile_outcomes')
CLOSE_TITLE = 'Close this logical session after all current obligations settle?'
CLOSE_CHOICE = 'Close session; preserve documents, sources and Git'


def _sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     separators=(',', ':')).encode()).hexdigest()


def _items(value):
    return value.items() if isinstance(value, dict) else enumerate(value or [])


def _references(value, session_id):
    if isinstance(value, dict):
        return (session_id in value
                or value.get('logical_session_id') == session_id
                or value.get('orch_session_id') == session_id
                or any(_references(child, session_id) for child in value.values()))
    return isinstance(value, list) and any(_references(child, session_id) for child in value)


def _scoped(dispatch, session_id):
    result = {name: dispatch.get(name, {}).get(session_id) for name in KEYED_TABLES}
    result.update({name: {key: row for key, row in _items(dispatch.get(name, {}))
                          if _references(row, session_id)} for name in SCOPED_TABLES})
    result['landing'] = {name: {key: row for key, row in _items(dispatch.get('landing', {}).get(name, {}))
                                if _references(row, session_id)} for name in ('items', 'queues')}
    return result


def _closed(state, peer, session_id):
    assert session_id not in state['sessions'], 'ORCH session remains after close'
    scoped = _scoped(state.get('dispatch', {}), session_id)
    assert not any(scoped[name] for name in KEYED_TABLES + SCOPED_TABLES), scoped
    assert not any(scoped['landing'].values()), scoped['landing']
    assert not _references(state.get('dispatch', {}), session_id), 'orphan ORCH session reference'
    assert session_id not in peer['sessions'], 'SPAWN admission remains after close'
    for name in ('requests', 'workers', 'mailboxes', 'gates', 'controls'):
        assert not _references(peer.get(name, {}), session_id), 'orphan SPAWN '+name
    return scoped


def _atomic_close(before, after, session_id, peer):
    session = before['sessions'][session_id]
    assert session['phase'] == 'closing' and session['close']['peer_closed']
    assert not session.get('controller') and not session.get('orchestrator')
    expected = json.loads(json.dumps(before))
    expected['revision'] += 1
    del expected['sessions'][session_id]
    dispatch = expected['dispatch']
    for name in KEYED_TABLES:
        if name in dispatch:
            dispatch[name].pop(session_id, None)
    # Conversation-first creation owns one empty project. Closing preserves only
    # its bounded presentation summary, never its managed session identity.
    projects = [row for row in dispatch.get('projects', {}).values()
                if row['logical_session_id'] == session_id and not row.get('finished')]
    prior_summaries = dispatch.get('finished_projects', [])
    summaries = after['dispatch'].get('finished_projects', [])
    assert len(projects) == 1 and len(prior_summaries) < 100
    assert len(summaries) == len(prior_summaries)+1 and summaries[:-1] == prior_summaries
    project, summary = projects[0], summaries[-1]
    assert not project.get('sources') and not project.get('associations')
    assert isinstance(summary.get('finished_at_ms'), (int, float)) and summary['finished_at_ms'] > 0
    assert summary == {'name': project['name'],
                       'result': 'Orchestration closed after its managed obligations settled.',
                       'links': [], 'finished_at_ms': summary['finished_at_ms']}
    dispatch['finished_projects'] = summaries
    for name in SCOPED_TABLES:
        if name in dispatch:
            dispatch[name] = {key: row for key, row in dispatch[name].items()
                              if not _references(row, session_id)}
    for name, table in dispatch.get('landing', {}).items():
        dispatch['landing'][name] = {key: row for key, row in table.items()
                                     if not _references(row, session_id)}
    assert after == expected, 'close was not one exact scoped-removal commit preserving all unrelated state'
    _closed(after, peer, session_id)


def _no_histories(value, path=''):
    if isinstance(value, dict):
        for key, child in value.items():
            where = path+'/'+str(key)
            assert key not in OLD_HISTORY_KEYS, 'obsolete managed history field '+where
            if key == 'commands':
                assert not child, 'completed command history '+where
            _no_histories(child, where)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _no_histories(child, path+'/'+str(index))


def _projection_values(surface):
    prefixes = {'orchplus.spawn-response': 'SPAWN_DISPATCH v2 ',
                'orchplus.spawn-catalog': 'SPAWN_DISPATCH v2 ',
                'orchplus.spawn-execution': 'SPAWN_EXECUTION v2 '}
    for node in surface_nodes((surface or {}).get('main')):
        props = node.get('p', {})
        role = props.get('role', '')
        if not role.startswith(('orchplus.', 'spawn.')) or role == 'orchplus.alias':
            continue
        text = props.get('text', ''.join(span if isinstance(span, str) else span.get('t', '')
                                       for span in props.get('spans', [])))
        prefix = prefixes.get(role)
        if prefix and text.startswith(prefix):
            value = json.loads(text[len(prefix):])
            if role in ('orchplus.spawn-response', 'orchplus.spawn-catalog'):
                body = value['body_json'].encode('utf-8')
                assert value['complete'] is True and len(body) == value['body_bytes']
                assert hashlib.sha256(body).hexdigest() == value['body_sha256']
                yield role+'.envelope', value
                value = json.loads(body)
        elif text.startswith(('{', '[')):
            value = json.loads(text)
        else:
            continue
        yield role, value


def _remaining_native_scope(product, session_id):
    remaining = []
    for pane in product.ui('panes'):
        assert pane.get('block') != 'spawn.dispatch', 'pane-free channel opened a retired dispatch pane'
        if pane.get('block') not in ('orchplus.orchestrator', 'spawn.spawner'):
            continue
        surface = product.ui('surface', pane=pane['pane'])
        if not surface or not surface.get('main'):
            remaining.append({'pane': str(pane['pane']), 'role': 'unavailable-native-surface'})
            continue
        seen = set()
        for role, value in _projection_values(surface):
            seen.add(role)
            if _references(value, session_id):
                remaining.append({'pane': str(pane['pane']), 'role': role})
    return remaining




def _snapshot(product):
    return {'orch': registry(product.runtime), 'spawn': spawn_dispatch(product)}


def _save(product, label, value):
    directory = product.runtime.root/'retention-evidence'
    directory.mkdir(mode=0o700, exist_ok=True)
    path = directory/(label+'.json')
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, separators=(',', ':'))
    return {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def _append(product, name, value):
    directory = product.runtime.root/'retention-evidence'
    directory.mkdir(mode=0o700, exist_ok=True)
    path = directory/(name+'.jsonl')
    with path.open('a', encoding='utf-8') as stream:
        stream.write(json.dumps(value, ensure_ascii=False, separators=(',', ':'))+'\n')
    return str(path)


def _flush_inputs(product, *uis):
    # NativeUI already durably appends each actual input to its own action log.
    # Preserve our bounded chunks separately before releasing in-memory copies.
    for index, ui in enumerate(uis):
        if ui.inputs:
            _append(product, 'native-input-chunks', {'window': ui.window_key,
                    'chunk_ui': index, 'inputs': ui.inputs})
            ui.inputs.clear()


def _scope(product):
    data = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
    return data if data and data.get('controller_phase') == 'active' else None


def _admit(product, session_id):
    def admitted():
        state, peer = registry(product.runtime), spawn_dispatch(product)
        session = state['sessions'][session_id]
        other = peer['sessions'].get(session_id)
        return session if (session.get('admitted') is True and other
                           and session['admission_seq'] == other['admission_seq']
                           and session['spawn_namespace'] == peer['namespace']) else None
    return product.lib.wait_for(admitted, 'actual paired session admission', 30, .05)


def _register(product, loss=None, delayed=None):
    """Create in the owned panel; optionally hold its exact automatic admission."""
    before = registry(product.runtime)
    name = 'Retention orchestration '+str(before['next_owner_id'])
    deadline = time.monotonic()+40
    outer = getattr(product.ui, 'operation_deadline', None)
    product.ui.operation_deadline = min(outer, deadline) if outer else deadline
    try:
        # One visible creation and one name submission, never a replayed intent.
        product.ui.mouse_click(product.controller, 'New orchestration…')
        form = product.ui.form_pane('Name your orchestration')
        product.ui.edit_field(form, 'Name your orchestration', name)
        product.ui.mouse_click(form, 'Create orchestration')
    finally:
        product.ui.operation_deadline = outer
    deadline = time.monotonic()+30
    def newly_owned():
        state = registry(product.runtime)
        added = set(state['sessions'])-set(before['sessions'])
        assert len(added) <= 1, 'one name submission created multiple logical sessions'
        scope = _scope(product)
        if not scope or scope['orch_session_id'] not in added:
            return None
        session = state['sessions'][scope['orch_session_id']]
        assert session['name'] == name
        assert session['controller']['owner_id'] == scope['owner_id']
        assert state['next_owner_id'] == before['next_owner_id']+1, 'owner allocation did not advance once'
        return scope
    scope = product.lib.wait_for(newly_owned, 'one named native orchestration and controller',
                                max(0, deadline-time.monotonic()), .05)
    session_id = scope['orch_session_id']
    if loss:
        original = loss.wait('orchplus', 'late-admission')
        payload = json.loads(original['input']['value'])
        assert payload['orch_session_id'] == session_id and payload['command'] == 'bridge_control'
        assert payload['operation'] == 'admit_session'
        delayed.append(original)
        loss.set([])
        loss.deliver_original_once(original)
        # Automatic project creation may immediately replace command_result.
        # Positive paired admission below proves this exact delivered input.
    _admit(product, session_id)
    # Back out of the real native picker; choosing an agent would launch a worker.
    product.ui.mouse_click(product.ui.agent_picker('Choose your orchestrator'), 'Back')
    _advanced(product)
    return session_id


def _advanced(product):
    """Expose the shipped diagnostic/recovery controls, never hidden commands."""
    surface = product.ui('surface', pane=product.controller)
    labels = [node.get('p', {}).get('text') for node in surface_nodes((surface or {}).get('main'))]
    if 'Hide Advanced' not in labels:
        product.ui.click(product.controller, 'Advanced')


def _idle(product, session_id, *, close_will_ack=False):
    quiet = {}
    def settled():
        state, peer = registry(product.runtime), spawn_dispatch(product)
        session = state['sessions'][session_id]
        actions = [row for row in state['dispatch']['actions'].values()
                   if _references(row, session_id)]
        pending = [row for row in peer['requests'].values() if _references(row, session_id)]
        if actions or session.get('bridge_control') or (pending and not close_will_ack):
            quiet.clear()
            return None
        if close_will_ack:
            # Observe settlement before the FIRST click, never refresh or
            # replay the authority captured by the close confirmation.
            source_key = (state['authority_namespace'], state['revision'])
            if quiet.get('source') != source_key:
                quiet.update(source=source_key, since=time.monotonic())
                return None
            if time.monotonic()-quiet['since'] < 1:
                return None
            rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
            if (not rendered or rendered.get('orch_session_id') != session_id
                    or rendered.get('authority_namespace') != state['authority_namespace']
                    or rendered.get('authority_revision') != state['revision']
                    or registry(product.runtime)['revision'] != state['revision']):
                return None
            return {'orch': state, 'spawn': peer, 'owner_input': {
                'authority_namespace': state['authority_namespace'], 'source_revision': state['revision'],
                'rendered_revision': rendered['authority_revision'],
                'prior_command_result': rendered.get('command_result')}}
        return {'orch': state, 'spawn': peer}
    description = ('locally consumed results before authenticated close' if close_will_ack
                   else 'current result consumption and authenticated peer ACK')
    return product.lib.wait_for(settled, description, 30, .05)


def _catalog(product, session_id, ordinal):
    before = registry(product.runtime)
    serial = before['sessions'][session_id]['next_request_serial']
    observed = {}
    def completed():
        state, peer = registry(product.runtime), spawn_dispatch(product)
        session = state['sessions'][session_id]
        for row in peer['requests'].values():
            request = row.get('request', {})
            if request.get('logical_session_id') == session_id and request.get('request_serial') == serial:
                assert request['op'] == 'catalog', 'unexpected issued operation occupies catalog serial'
                if row.get('body', {}).get('category') == 'current_result':
                    observed.update(request=request, body=row['body'])
        assert session['next_request_serial'] <= serial+1, 'single catalog click issued additional requests'
        if not observed or session['next_request_serial'] != serial+1:
            return None
        if observed['body']['status'] == 'pending':
            return None
        assert observed['body']['status'] == 'catalog', 'catalog result was not successful'
        if observed['request']['action_id'] in state['dispatch']['actions']:
            return None
        catalog = state['dispatch']['catalogs'].get(session_id)
        assert catalog == observed['body']['payload'], 'consumed catalog consequence differs from peer result'
        return {'ordinal': ordinal, 'native_input': product.ui.inputs[-1] if product.ui.inputs else None,
                'request': observed['request'], 'result': observed['body'],
                'consumed_registry_revision': state['revision'],
                'next_request_serial': session['next_request_serial'],
                'catalog_sha256': _sha(catalog)}
    receipt = owner_setup_input(product, command='catalog', deadline=time.monotonic()+30,
        complete=lambda observed, source: completed(),
        unchanged=lambda old, new: old['sessions'][session_id]['next_request_serial']
                                   == new['sessions'][session_id]['next_request_serial']
                                   and old['dispatch']['actions'] == new['dispatch']['actions'])
    product.result['request_ledger'] = _append(product, 'issued-results', receipt)
    product.result['counts']['completed_requests'] += 1
    return receipt


def _close_input(product):
    _advanced(product)
    deadline = time.monotonic()+40
    owner_setup_input(product, command='close_session', deadline=deadline,
        complete=lambda observed, source: CLOSE_TITLE in json.dumps(product.runtime.ctl('tree'), ensure_ascii=False),
        unchanged=lambda old, new: old['sessions'] == new['sessions'])
    product.ui.choose(CLOSE_TITLE, CLOSE_CHOICE, deadline=deadline)


def _close(product, session_id, ordinal, preserve=None):
    # Close carries ack_progress and SPAWN validates/consumes it before testing
    # for unresolved effects. Waiting for peer deletion first can deadlock on
    # the final consumed catalog result. Never replace the real close checks.
    before = _idle(product, session_id, close_will_ack=True)
    session = before['orch']['sessions'][session_id]
    owner = session['controller']
    assert owner and session['admitted']
    scope = _scoped(before['orch']['dispatch'], session_id)
    phases = {}
    product.result['pending_close'] = {'ordinal': ordinal, 'session_id': session_id,
                                       'owner_input': before['owner_input'], 'before_state': before['orch']}
    _close_input(product)
    def removed():
        snapshot = _snapshot(product)
        state, peer = snapshot['orch'], snapshot['spawn']
        current = state['sessions'].get(session_id)
        if preserve:
            preserve(state, peer)
        if current:
            if current.get('phase') == 'open':
                rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
                response = (rendered or {}).get('command_result') or {}
                if response != before['owner_input']['prior_command_result'] and response.get('ok') is False:
                    product.result['pending_close']['refusal'] = response
                    raise AssertionError('native close refused without replay: '+str(response))
            if current.get('phase') == 'closing':
                phase = ('owner-held' if current.get('controller') else
                         'peer-closed' if current.get('close', {}).get('peer_closed') else 'owner-released')
                if phase not in phases:
                    phases[phase] = {'revision': state['revision'], 'session': current}
                current_scope = _scoped(state['dispatch'], session_id)
                for name in KEYED_TABLES:
                    if scope[name] is not None:
                        assert current_scope[name] is not None, 'scoped '+name+' removed before session close'
                for name in ('catalogs', 'policies'):
                    assert current_scope[name] == scope[name], 'close changed retained '+name
                if not current.get('controller'):
                    assert current['generation_floor'] > owner['generation']
            return None
        _closed(state, peer, session_id)
        remaining = _remaining_native_scope(product, session_id)
        if remaining:
            product.result['closing_native_views'] = remaining
            return None
        product.result.pop('closing_native_views', None)
        return snapshot
    after = product.lib.wait_for(removed, 'positive peer closure, scoped removal and consumed native views', 30, .05)
    # The initial owner was real and confirm_close cannot commit with either owner
    # present. Removal is positive release evidence, not an absent-pane heuristic.
    receipt = {'ordinal': ordinal, 'session_id': session_id,
               'owner': owner, 'admission_seq': session['admission_seq'],
               'issued_count': session['next_request_serial']-1,
               'peer_results_before_close': [
                   {'request_id': row['request']['request_id'], 'request_serial': row['request']['request_serial'],
                    'category': row.get('body', {}).get('category'), 'status': row.get('body', {}).get('status')}
                   for row in before['spawn']['requests'].values() if _references(row, session_id)],
               'before_revision': before['orch']['revision'], 'after_revision': after['orch']['revision'],
               'before_scope': scope, 'after_scope': _scoped(after['orch']['dispatch'], session_id),
               'observed_phases': phases, 'peer_admission_cursor': after['spawn']['admission_cursor']}
    product.result['close_ledger'] = _append(product, 'closed-sessions', receipt)
    product.result.pop('pending_close', None)
    product.result['counts']['retired_owners'] += 1
    product.result['counts']['closed_sessions'] += 1
    return receipt


def _live_signature(state, peer, session_id):
    session = state['sessions'][session_id]
    owner = session['controller']
    other = peer['sessions'][session_id]
    return {'session_id': session_id, 'phase': session['phase'],
            'admitted': session.get('admitted'), 'controller_phase': owner['phase'],
            'owner_id': owner['owner_id'], 'generation': owner['generation'],
            'pane_binding': owner['pane_binding'], 'admission_seq': session['admission_seq'],
            'spawn_binding': other['control'].get('binding'),
            'spawn_control_phase': other['control']['phase'],
            'policy': state['dispatch']['policies'][session_id],
            'catalog': state['dispatch']['catalogs'][session_id],
            'projects': {key: row for key, row in state['dispatch']['projects'].items()
                         if row['logical_session_id'] == session_id}}


def _store_sweep(product, label, closed_session=None):
    snapshot = _snapshot(product)
    _no_histories(snapshot['orch'])
    _no_histories(snapshot['spawn'])
    summaries = snapshot['orch']['dispatch'].get('finished_projects', [])
    assert len(summaries) <= 100, 'finished presentation history exceeded its count bound'
    assert len(json.dumps(summaries, ensure_ascii=False, separators=(',', ':')).encode()) <= 512*1024, 'finished presentation history exceeded its byte bound'
    for action in snapshot['orch']['dispatch']['actions'].values():
        assert action['phase'] not in ('complete', 'resolved'), 'completed ORCH action retained'
    files, observers, projections = {}, {}, {}
    checked_projection_roles = []
    for plugin in ('orchplus', 'spawn'):
        directory = product.runtime.config/'plugin-data'/plugin
        for path in sorted(directory.rglob('*')):
            if not path.is_file():
                continue
            relative = str(path.relative_to(directory))
            if relative.startswith('product-'):
                # Private bounded diagnostic wrapper output is not shipping state.
                continue
            raw = path.read_bytes()
            files[plugin+'/'+relative] = {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
            if path.name == 'kv.json':
                kv = json.loads(raw)
                for key in kv:
                    assert not (key == 'window-observer-namespace' or key.startswith('window-observer:')
                                or key.startswith('window-observer-index:')
                                or key in ('spawn.records-seen.v1', 'spawn.intents.v1')), 'legacy window KV remains: '+key
            if relative.startswith('window-observer/') and path.suffix == '.json':
                value = json.loads(raw)
                observers[plugin+'/'+relative] = value
                if closed_session:
                    assert not _references(value, closed_session), 'closed session retained in window journal '+relative
                if path.name == 'migration.json':
                    assert value.get('phase') == 'ready', 'incomplete observer migration'
        if plugin == 'spawn':
            assert (directory/'window-observer/namespace.json').is_file(), 'native observer namespace not persisted'
    for pane in product.ui('panes'):
        assert pane.get('block') != 'spawn.dispatch', 'pane-free channel opened a retired dispatch pane'
        if pane.get('block') not in ('orchplus.orchestrator', 'spawn.spawner'):
            continue
        surface = product.ui('surface', pane=pane['pane'])
        assert surface and surface.get('main'), 'native surface unavailable: '+str(pane['pane'])
        seen = set()
        projections[str(pane['pane'])] = surface
        for role, value in _projection_values(surface):
            seen.add(role)
            _no_histories(value)
            if closed_session:
                assert not _references(value, closed_session), 'closed session retained in native '+role
            checked_projection_roles.append({'pane': str(pane['pane']), 'role': role})
        if pane['block'] == 'orchplus.orchestrator':
            assert 'orchplus.spawn-relay' in seen, 'missing real host channel projection: '+str(pane['pane'])
    if closed_session:
        _closed(snapshot['orch'], snapshot['spawn'], closed_session)
    return _save(product, label, {'snapshot': snapshot, 'shipping_file_inventory': files,
                 'window_observers': observers, 'native_projections': projections,
                 'checked_projection_roles': checked_projection_roles,
                 'excluded_observation_files': 'product-* private instrumentation only; no shipping stores excluded'})


def _repository_identity(product):
    # No Git process is needed: immutable objects, refs, index and source bytes
    # are inventoried directly. Merely closing sessions must change none of them.
    return {str(path.relative_to(product.repository)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(product.repository.rglob('*')) if path.is_file()}


def _soak(product, result, *, rehearsal=False):
    cycles = SESSION_TARGET if rehearsal else RETIREMENT_TARGET
    result['purpose'] = 'non-qualifying rehearsal' if rehearsal else 'mandatory retention soak'
    result['qualification_complete'] = False
    initialize(product)
    first_ui, first_pane = product.ui, product.controller
    live_id = _scope(product)['orch_session_id']
    _idle(product, live_id)
    before = _snapshot(product)
    signature = _live_signature(before['orch'], before['spawn'], live_id)
    result['live_other_session'] = _save(product, 'live-other-session', {'native': first_ui('context'),
                  'pane': first_pane, 'signature': signature, 'snapshot': before})
    repository = _repository_identity(product)
    second = additional_window(product)
    result['independent_native_contexts'] = [first_ui('context'), second('context')]
    assert result['independent_native_contexts'][0]['session'] != result['independent_native_contexts'][1]['session'], 'second window did not create an independent native session'
    product.ui = second
    # Native windows have separate pane/session scopes. Open this window's
    # ordinary Config and reuse its empty orchestration panel for each named run.
    product.spawn_pane = second('open', kind='spawn.spawner')
    product.controller = second('open', kind='orchplus.orchestrator')
    result['second_window_panes'] = {'config': product.spawn_pane, 'controller': product.controller}
    def preserve(state, peer):
        assert _live_signature(state, peer, live_id) == signature, 'other live session state changed during reclamation'
    result['milestones'] = []
    for cycle in range(1, cycles+1):
        started = time.monotonic_ns()
        try:
            session_id = _register(product)
            for _ in range(2):
                _catalog(product, session_id, result['counts']['completed_requests']+1)
            closed = _close(product, session_id, cycle, preserve)
        finally:
            result['cycle_timing_ledger'] = _append(product, 'cycle-timings', {
                'ordinal': cycle, 'started_monotonic_ns': started,
                'elapsed_ns': time.monotonic_ns()-started,
                'completed': result['counts']['closed_sessions'] == cycle,
                'purpose': result['purpose']})
        if cycle in (1, 64, 65, 2048, 2049) or cycle % 128 == 0:
            result['milestones'].append({'counts': dict(result['counts']),
                'evidence': _store_sweep(product, 'milestone-'+str(cycle), session_id),
                'last_close': closed})
            product.capture('retention-'+str(cycle))
        _flush_inputs(product, first_ui, second)
    if rehearsal:
        assert result['counts'] == {'completed_requests': 2*SESSION_TARGET,
                                   'retired_owners': SESSION_TARGET, 'closed_sessions': SESSION_TARGET}
    else:
        assert result['counts']['completed_requests'] >= REQUEST_TARGET
        assert result['counts']['retired_owners'] >= RETIREMENT_TARGET
        assert result['counts']['closed_sessions'] >= SESSION_TARGET
    assert _repository_identity(product) == repository, 'close altered source/Git/archive files'
    final = _snapshot(product)
    preserve(final['orch'], final['spawn'])
    assert set(final['orch']['sessions']) == {live_id}, 'unexpected active ORCH session remains'
    assert set(final['spawn']['sessions']) == {live_id}, 'unexpected active SPAWN session remains'
    assert not final['orch']['dispatch']['actions'] and not final['spawn']['requests'], 'settled managed requests remain'
    result['final_bounds'] = {'orch_sessions': len(final['orch']['sessions']),
                            'spawn_sessions': len(final['spawn']['sessions']),
                            'orch_actions': len(final['orch']['dispatch']['actions']),
                            'spawn_requests': len(final['spawn']['requests'])}
    if rehearsal:
        result['checks'].append('65 complete native named-creation/automatic-admission/two-catalog/close cycles; rehearsal only, not the mandatory 4098-request/2049-owner soak')
    else:
        result['checks'].extend(['observed >4096 successful issued catalog results consumed by ORCH',
            'observed >2048 real controller retirements through admitted native close',
            'observed >64 lifetime logical sessions with every named scoped table absent on removal'])
        result['qualification_complete'] = True
    result['checks'].extend([
        'independent live native session, actual policy/catalog/binding and source/Git files preserved',
        'all plugin-data files inventoried; managed stores, window journals, projections and legacy KV swept'])


def _ordinary_attempts(product):
    authority = spawn_authority(product.runtime)
    return {scope_id+'/'+attempt['id']: attempt
            for scope_id, scope in authority['sessions'].items()
            for attempt in scope['launch']['attempts']
            if attempt.get('purpose') != 'managed'}


def _ordinary_history(product):
    before = _ordinary_attempts(product)
    product.ui.preference(product.spawn_pane, page='spawn')
    props = product.ui('preferences', pane=product.spawn_pane)['properties']
    rows = [row for section in props['sections'] for row in section['rows']
            if row['id'].startswith('spawn-launch:') and row['id'].endswith(':c2-release')]
    assert len(rows) == 1, 'ordinary native release-fixture launch is not uniquely offered'
    product.ui.preference(product.spawn_pane, row=rows[0]['id'])
    def running():
        candidates = [(key, row) for key, row in _ordinary_attempts(product).items()
                      if key not in before and row['record_id'] == 'c2-release' and row.get('pane')
                      and row['phase'] in ('Running', 'Waiting for input')]
        return candidates[0] if len(candidates) == 1 and native_launches(product, 'c2-release') else None
    key, attempt = product.lib.wait_for(running, 'actual ordinary non-provider terminal launch', 60)
    product.ui('close', pane=attempt['pane'])
    def exited():
        current = _ordinary_attempts(product).get(key)
        return current if current and current['phase'] == 'Exited' else None
    finished = product.lib.wait_for(exited, 'positively observed ordinary native exit', 60)
    assert len(native_launches(product, 'c2-release')) == 1
    return key, finished


def _helper_files(product, worker):
    launched = read_json(product.control/worker['mailbox_handle']/'launched.json')
    assert launched and launched['transport']['mailbox_handle'] == worker['mailbox_handle']
    root = Path(launched['transport']['root'])
    assert root.resolve().is_relative_to(product.runtime.root.resolve()), 'helper root escaped owned runtime'
    box = root/worker['mailbox_handle']
    files = {}
    for path in sorted(box.rglob('*')):
        if path.is_file():
            assert not path.is_symlink(), 'unexpected helper-state symlink'
            raw = path.read_bytes()
            files[str(path.relative_to(box))] = {'sha256': hashlib.sha256(raw).hexdigest(),
                                                'content_b64': base64.b64encode(raw).decode()}
    return {'root': str(root), 'mailbox': str(box), 'files': files}


def _obligations(product, result):
    worker_path = product.worker.with_name('recovery_worker.py')
    shutil.copy2(TESTS/'recovery_worker.py', worker_path)
    product.worker = worker_path
    result['fixture_sources']['recovery_worker.py'] = hashlib.sha256(worker_path.read_bytes()).hexdigest()
    initialize(product)
    session_id = _scope(product)['orch_session_id']
    ordinary_key, ordinary = _ordinary_history(product)
    result['ordinary_exited_before'] = _save(product, 'ordinary-exited', ordinary)
    _assign(product)
    worker = _accepted(product)
    before = _snapshot(product)
    coordinators = [row for row in before['orch']['dispatch']['workers'].values()
                    if row['logical_session_id'] == session_id and row.get('coordinator_owner_id')]
    assert len(coordinators) == 1, 'expected the actual proposal coordinator'
    coordinator = coordinators[0]
    coordinator_identity = provider_coordinator_identity(product, coordinator)
    result['coordinator_provider_before_retirement'] = coordinator_identity
    assert str(coordinator_identity['native_agent']['pane']) == coordinator['pane_binding']['pane_id']
    helper_before = _helper_files(product, worker)
    result['before_close_refusal'] = _save(product, 'before-close-refusal',
                                         {'state': before, 'helper': helper_before})
    _close_input(product)
    def refused():
        data = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state') or {}
        response = data.get('command_result') or {}
        return response if response.get('ok') is False and response.get('code') == 'session_busy' else None
    result['close_refusal'] = product.lib.wait_for(refused, 'native close refusal for actual managed obligations', 30)
    after = _snapshot(product)
    current = after['orch']['dispatch']['workers'][worker['worker_id']]
    assert after['orch']['sessions'][session_id]['phase'] == 'open'
    for key in ('worker_id', 'logical_session_id', 'work_id', 'mailbox_handle', 'launch_request_id', 'enrolment_token'):
        assert current.get(key) == worker.get(key), 'close refusal changed real worker identity: '+key
    assert current['mailbox_handle'] in after['spawn']['mailboxes']['generations']
    launches = native_launches(product)
    assert len(launches) == 1, 'expected one actual native helper participant'
    result['preserved_obligations'] = _save(product, 'after-close-refusal', {'state': after,
                'native_launches': launches, 'native_panes': product.ui('panes'),
                'helper': _helper_files(product, worker),
                'helper_files': {str(path.relative_to(product.control)): hashlib.sha256(path.read_bytes()).hexdigest()
                                 for path in product.control.rglob('*') if path.is_file()}})
    finish_deadline = time.monotonic()+30
    finish_setup = {}
    result['finish_setup'] = finish_setup
    _advanced(product)
    product.ui.click_match(product.controller, worker['work_id']+' · ')
    def ready_to_finish():
        source = registry(product.runtime)
        dispatch = source['dispatch']
        current = dispatch['workers'][worker['worker_id']]
        workflow = current.get('workflow', {})
        native = workflow.get('native', {})
        finish_setup['last_observed'] = source
        # Match ordinary Finish eligibility, not the document writer's empty-
        # read proof. Finish itself owns positive stop and mailbox retirement.
        if (dispatch['actions'] or source['sessions'][session_id].get('bridge_control')
                or current['phase'] != 'accepted' or current.get('coordinator_owner_id')
                or current.get('continuation_required') or current.get('accept_pending')
                or current.get('compaction_pending') or current.get('assembly') or current.get('rejected_report')
                or current.get('replies') or current.get('wakes') or workflow.get('report_request')
                or native.get('state') != 'idle' or native.get('delivery_error')):
            finish_setup.pop('quiet_source', None)
            return None
        quiet = finish_setup.get('quiet_source')
        now = time.monotonic()
        if not quiet or quiet['source_revision'] != source['revision']:
            finish_setup['quiet_source'] = {'source_revision': source['revision'],
                                            'first_seen_monotonic': now,
                                            'due_poll': workflow.get('due_poll')}
            return None
        if now-quiet['first_seen_monotonic'] < 1:
            return None
        rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
        if (rendered and rendered.get('authority_namespace') == source['authority_namespace']
                and rendered.get('authority_revision') == source['revision']
                and registry(product.runtime)['revision'] == source['revision']):
            finish_setup['source_revision'] = source['revision']
            finish_setup['prior_command_result'] = rendered.get('command_result')
            return source
        return None
    product.lib.wait_for(ready_to_finish, 'eligible ordinary worker and current owner authority before Finish',
                         max(0, finish_deadline-time.monotonic()))
    product.ui.command(product.controller, 'finish', worker_id=worker['worker_id'])
    product.ui.choose('Finish '+worker['work_id']+'?', 'Finish this ordinary worker')
    def retired():
        source = registry(product.runtime)
        current = source['dispatch']['workers'].get(worker['worker_id'])
        stopped = (current or {}).get('stopped')
        if current and not current.get('finish'):
            rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
            response = (rendered or {}).get('command_result') or {}
            if response.get('command') == 'finish' and response != finish_setup['prior_command_result']:
                finish_setup['response'] = response
                assert response.get('ok') is True, 'native Finish refused without replay: '+str(response)
        if not stopped or not current.get('mailbox_retired'):
            return None
        assert stopped['observation'] in ('absent', 'exited')
        assert stopped['pane_binding'] == worker['pane_binding'], 'stop proof belongs to another worker'
        return {'source_revision': source['revision'], 'worker': current}
    # A completed worker can remain in the open session until allocation-time
    # reclamation or close. Prove actual stop/retirement here; the subsequent
    # close and full store sweep must remove every scoped record.
    retirement_deadline = time.monotonic()+180
    result['native_retirement'] = product.lib.wait_for(
        retired, 'positive exact native stop and real helper mailbox retirement',
        max(0, retirement_deadline-time.monotonic()))
    assert len(native_launches(product)) == 1, 'finish or close relaunched a worker'
    product.ui.command(product.controller, 'retire', worker_id=coordinator['worker_id'])
    def coordinator_retired():
        state = registry(product.runtime)
        current = state['dispatch']['workers'].get(coordinator['worker_id'])
        if not current or not current.get('owner_released') or not current.get('mailbox_retired'):
            return None
        assert (current.get('stopped') or {}).get('observation') in ('absent', 'exited')
        assert current['stopped']['pane_binding'] == coordinator['pane_binding']
        assert state['sessions'][session_id].get('orchestrator') is None
        return {'source_revision': state['revision'], 'worker': current}
    result['coordinator_retirement'] = product.lib.wait_for(
        coordinator_retired, 'typed coordinator release, exact native stop and mailbox retirement',
        max(0, retirement_deadline-time.monotonic()))
    assert not any(str(agent['pane']) == coordinator['pane_binding']['pane_id']
                   for agent in product.ui('agents')), 'retired coordinator still has a live native process'
    assert not any(w['record_id'] == coordinator['record_id'] and w['worker_id'] != coordinator['worker_id']
                   for w in registry(product.runtime)['dispatch']['workers'].values()), 'retirement re-enrolled coordinator'
    _close(product, session_id, 1)
    result['final_sweep'] = _store_sweep(product, 'finished-worker-close', session_id)
    mailbox = Path(helper_before['mailbox'])
    assert not mailbox.exists() and not mailbox.is_symlink(), 'retired physical mailbox remains'
    helper_root = Path(helper_before['root'])
    inventory = {}
    for path in sorted(helper_root.rglob('*')):
        if path.is_file():
            assert not path.is_symlink(), 'unexpected mailbox-root state symlink'
            raw = path.read_bytes()
            assert session_id.encode() not in raw, 'closed managed identity archived outside mailbox registry: '+str(path)
            inventory[str(path.relative_to(helper_root))] = {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
    result['physical_mailbox_sweep'] = _save(product, 'physical-mailbox-sweep',
                                            {'root': str(helper_root), 'retired_mailbox': str(mailbox), 'files': inventory})
    retained = _ordinary_attempts(product).get(ordinary_key)
    assert retained is not None, 'managed close erased independent ordinary exit history'
    for key in ('id', 'record_id', 'scope', 'purpose', 'phase', 'pane'):
        assert retained.get(key) == ordinary.get(key), 'managed cleanup changed ordinary '+key
    result['ordinary_exited_after'] = _save(product, 'ordinary-exited-retained', retained)
    result['checks'].extend(['real helper ACCEPTED/receipt/mailbox obligations prevent close without deletion',
                            'native finish stops exact worker; retired physical mailbox and closed identities are absent across the full helper root on session removal',
                            'actual ordinary unmanaged Exited history survives managed reclamation unchanged'])


def _phase(product, result, phase):
    loss = EventLoss(product)
    product.authority_capture_control = product.runtime.root/'retention-authority-capture.json'
    write_json(product.authority_capture_control, {'enabled': False})
    probe_path = product.orch/'product-probe.json'
    probe = read_json(probe_path)
    probe['authority_capture_path'] = str(product.authority_capture_control)
    write_json(probe_path, probe)
    product.start()
    product.open_spawn()
    for record in RECORDS:
        if record[0] in ('c2-builder', 'c2-release'):
            product.create_record(*record)
    # Hold the actual automatic-admission event emitted after a visible name
    # submission. There is no separate registration/claim/admit wizard anymore.
    product.initialize_orch()
    product.configure_orch('review_disabled')
    initial_id = _scope(product)['orch_session_id']
    _close(product, initial_id, 0)
    delayed = []
    loss.set([{'id': 'late-admission', 'block': 'orchestrator', 'act': 'dispatch-operator-command',
               'match': {'command': 'bridge_control', 'operation': 'admit_session'}}])
    session_id = _register(product, loss=loss, delayed=delayed)
    product.qualify_native_pair()
    before = _idle(product, session_id)
    capture_id = 'retention-'+phase
    capture_index = product.runtime.config/'plugin-data/orchplus'/('product-authority-'+capture_id+'-index.json')
    result['authority_capture_index'] = str(capture_index)
    write_json(product.authority_capture_control,
               {'enabled': True, 'id': capture_id, 'logical_session_id': session_id})
    owner = before['orch']['sessions'][session_id]['controller']
    repository = _repository_identity(product)
    for name, button, command in (('late-enqueue', 'catalog', 'catalog'),):
        loss.set([{'id': name, 'block': 'orchestrator', 'act': 'dispatch-operator-command',
                   'match': {'command': command}}])
        product.ui.command(product.controller, button)
        original = loss.wait('orchplus', name)
        payload = json.loads(original['input']['value'])
        assert payload['orch_session_id'] == session_id and payload['command'] == command
        delayed.append(original)
        loss.set([])
        loss.deliver_original_once(original)
        def accepted():
            data = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state') or {}
            response = data.get('command_result') or {}
            return response if response.get('request_id') == payload['request_id'] else None
        response = product.lib.wait_for(accepted, 'original native intent accepted before delayed duplicate', 30)
        assert response.get('ok') is True, 'original intent did not establish a successful pre-close operation'
        _idle(product, session_id)
    def authority_hold(name):
        kinds = {'begin': 'begin_close', 'release': 'release_controller', 'confirm': 'confirm_close'}
        return {'id': name, 'block': 'orchestrator', 'act': 'authority-command',
                'authority_event': {'kind': kinds[name]}}
    loss.set([authority_hold('begin')])
    _close_input(product)
    begin = loss.wait('orchplus', 'begin')
    assert json.loads(begin['input']['value'])['event']['kind'] == 'begin_close'
    loss.set([authority_hold('release')])
    loss.deliver_original_once(begin)
    held = loss.wait('orchplus', 'release')
    assert json.loads(held['input']['value'])['event']['kind'] == 'release_controller'
    if phase != 'owner-held':
        loss.set([{'id': 'peer', 'block': 'orchestrator', 'act': 'dispatch-command',
                   'match': {'command': 'bridge_control', 'operation': 'close_session'}}])
        loss.deliver_original_once(held)
        held = loss.wait('orchplus', 'peer')
    if phase == 'peer-closed':
        loss.set([authority_hold('confirm')])
        loss.deliver_original_once(held)
        held = loss.wait('orchplus', 'confirm')
        assert json.loads(held['input']['value'])['event']['kind'] == 'confirm_close'
    snapshot = _snapshot(product)
    session = snapshot['orch']['sessions'][session_id]
    assert session['phase'] == 'closing'
    assert bool(session.get('controller')) == (phase == 'owner-held')
    assert session['close']['peer_closed'] == (phase == 'peer-closed')
    if phase != 'owner-held':
        assert session['generation_floor'] > owner['generation']
    result['phase_before_reload'] = _save(product, 'close-'+phase,
                                         {'state': snapshot, 'held': held, 'delayed_intents': delayed})
    # Reload reads the actual persisted phase. No state is invented or rewound,
    # and the already-issued immutable close request is never reconstructed.
    _reload(product, 'orchplus')
    _advanced(product)
    current = registry(product.runtime)
    closing = current['sessions'].get(session_id)
    if closing:
        assert closing['phase'] == 'closing' and closing['close']['close_id'] == session['close']['close_id']
        assert closing['next_request_serial'] == session['next_request_serial']
        for name in ('catalogs', 'policies'):
            assert current['dispatch'][name].get(session_id) == snapshot['orch']['dispatch'][name].get(session_id)
        surface = product.ui('surface', pane=product.controller)
        enabled = [node.get('p', {}).get('attrs', {}).get('data-orchplus-command')
                   for node in surface_nodes((surface or {}).get('main'))
                   if node.get('p', {}).get('actions', {}).get('click')
                   and not node.get('p', {}).get('disabled')]
        # Native visibility is recorded separately from the durable close fence.
        # A visible stale control never constitutes permission to enqueue.
        result['closing_visible_commands'] = enabled
        result['phase_after_reload'] = _save(product, 'reloaded-'+phase,
                    {'state': _snapshot(product), 'surface': surface})
        assert not current['dispatch']['actions'], 'reload queued work into a closing session'
        assert closing.get('admitted') is not True, 'reload retained executable admission without fresh reconciliation'
        result['delayed_refusals'] = []
        for original in delayed:
            payload = json.loads(original['input']['value'])
            loss.deliver_original_once(original)
            def refused():
                data = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state') or {}
                response = data.get('command_result') or {}
                return response if response.get('request_id') == payload['request_id'] else None
            response = product.lib.wait_for(refused, 'exact old native intent refused while closing after reload', 30)
            assert response.get('ok') is False, 'old intent succeeded in closing session'
            now = registry(product.runtime)
            assert not now['dispatch']['actions'], 'old enqueue created an action during close'
            retained = now['sessions'][session_id]
            assert retained['phase'] == 'closing' and retained['next_request_serial'] == session['next_request_serial']
            assert retained.get('admission_seq') == session.get('admission_seq')
            result['delayed_refusals'].append({'original': original, 'response': response,
                                              'state': _save(product, payload['command']+'-refused-'+phase, _snapshot(product))})
    else:
        _closed(current, spawn_dispatch(product), session_id)
        result['phase_after_reload'] = _save(product, 'reloaded-'+phase, _snapshot(product))
        raise AssertionError('closure completed before the mandatory delayed enqueue/admission fence observations')
    if phase == 'peer-closed':
        loss.set([])
        _close_input(product)
        def finished():
            state, peer = registry(product.runtime), spawn_dispatch(product)
            if session_id in state['sessions']:
                return None
            _closed(state, peer, session_id)
            remaining = _remaining_native_scope(product, session_id)
            if remaining:
                result['closing_native_views'] = remaining
                return None
            result.pop('closing_native_views', None)
            return {'orch': state, 'spawn': peer}
        final = product.lib.wait_for(finished, 'explicit native completion of reloaded proven peer closure', 30)
        result['atomic_final'] = _save(product, 'atomic-final', final)
        result['final_sweep'] = _store_sweep(product, 'closed-native-views-after-reload', session_id)
    write_json(product.authority_capture_control, {'enabled': False})
    index = read_json(capture_index)
    assert index and index['entries'] and not index['truncated'], 'missing or truncated full native commit capture'
    assert index['logical_session_id'] == session_id and index['limit'] == 64
    commits = []
    for entry in index['entries']:
        path = Path(entry['path'])
        assert path.resolve().is_relative_to((product.runtime.config/'plugin-data/orchplus').resolve())
        value = read_json(path)
        assert value and value['revision'] == entry['revision']
        assert value['authority_namespace'] == before['orch']['authority_namespace']
        _no_histories(value)
        commits.append(value)
    transitions = [(previous, current) for previous, current in zip(commits, commits[1:])
                   if session_id in previous['sessions'] and session_id not in current['sessions']]
    if phase == 'peer-closed':
        assert len(transitions) == 1, 'mandatory single atomic-removal commit was not observed'
        _atomic_close(*transitions[0], session_id, spawn_dispatch(product))
        result['checks'].append('bounded full native commit capture proves exact one-commit removal of all scoped records, one presentation-only project summary and no unrelated state change')
    else:
        assert not transitions, 'unproved peer closure removed a session'
    result['authority_commit_capture'] = _save(product, 'commit-index', index)
    assert _repository_identity(product) == repository, 'phase reload altered source/Git files'
    result['checks'].append('actual '+phase+' persisted phase reload retains close fence and rejects exact previously accepted enqueue/admission duplicates without new work')
    result['limits'].append('This private exact-event-loss case observes safe reload state; it does not claim an uncertain old closing origin can perform fresh effects or blindly resume.')


def _case(base, root, evidence, processes, lib, args, name, body, instrumented):
    result = {'status': 'failed', 'case': name, 'checks': [], 'counts': {
              'completed_requests': 0, 'retired_owners': 0, 'closed_sessions': 0},
              'limits': []}
    evidence.setdefault('c3_cases', {})[name] = result
    product = None
    try:
        product = Product(base, root, evidence, processes, lib, name, args, instrumented=instrumented)
        result.update(product.result)
        product.result = result
        result['fixture_sources']['product_retention.py'] = hashlib.sha256((TESTS/'product_retention.py').read_bytes()).hexdigest()
        result['fixture_sources']['product_recovery.py'] = hashlib.sha256((TESTS/'product_recovery.py').read_bytes()).hexdigest()
        result['fixture_sources']['product_c3.py'] = hashlib.sha256((TESTS/'product_c3.py').read_bytes()).hexdigest()
        result['started_epoch_ns'] = time.time_ns()
        body(product, result)
        assert result['checks'], 'no observed retention acceptance'
        result['status'] = 'passed'
    except Exception as error:
        result['error'] = f'{type(error).__name__}: {error}'
        result['failure_traceback'] = traceback.format_exc()
        if product:
            try:
                result['failure_state'] = _save(product, 'failure', _snapshot(product))
                product.capture(name+'-failure')
            except Exception as capture_error:
                result['failure_capture_error'] = str(capture_error)
    finally:
        result['finished_epoch_ns'] = time.time_ns()
        if product:
            try:
                if hasattr(product, 'authority_capture_control'):
                    write_json(product.authority_capture_control, {'enabled': False})
                product.close()
            except Exception as error:
                result['status'] = 'failed'
                result['cleanup_error'] = f'{type(error).__name__}: {error}'
                try:
                    product.runtime.stop()
                except Exception as stop_error:
                    result['supervisor_cleanup_error'] = str(stop_error)
        if result['status'] != 'passed' and 'qualification_complete' in result:
            result['qualification_complete'] = False
    return result


def retention(base, root, evidence, processes, lib, args):
    """Run selected native cells; every unrun mandatory cell remains unqualified."""
    specifications = [('retention-native-soak', _soak, False),
                      ('retention-live-obligations', _obligations, False)]
    for phase in ('owner-held', 'owner-released', 'peer-closed'):
        specifications.append(('retention-close-'+phase,
                               lambda product, result, phase=phase: _phase(product, result, phase), True))
    rehearsal = getattr(args, 'retention_rehearsal', False)
    if rehearsal:
        specifications = [('retention-native-rehearsal',
                           lambda product, result: _soak(product, result, rehearsal=True), False)]
    selected, selection = select_runtime_cases(args, 'lifecycle/retention',
                                               [name for name, _, _ in specifications])
    result = {'status': 'not_run', 'checks': [], 'cases': [], 'counts': None,
              'selection': selection, 'qualification_complete': False,
              'limits': ['Actual Linux native GUI; hybrid Native OMP coordinator plus deterministic workers, not provider-worker or remote-platform qualification',
                         'Long-soak packages are exact source; close-phase fault packages are explicitly instrumented and separately identified',
                         'Exact soak samples durable close observations; separate bounded full native commit captures prove atomic removal. Combinatorial populated-table/dependency grids remain state-owner-suite evidence, not claimed GUI populations',
                         'All evidence is private: request bodies and state may contain capabilities; no public media promotion',
                         'Finite supervisor ownership is selected by the main runner before execution; per-operation deadlines are not widened']}
    if rehearsal:
        result['purpose'] = 'non-qualifying rehearsal; mandatory retention coverage remains unqualified'
    if not selected:
        return result
    missing = prerequisites()
    if missing:
        result.update(missing)
        return result
    for name, body, instrumented in specifications:
        if name not in selected:
            continue
        case = _case(base, root, evidence, processes, lib, args, name, body, instrumented)
        result['cases'].append(case)
        result['checks'].extend(case['checks'])
        if name in ('retention-native-soak', 'retention-native-rehearsal'):
            result['counts'] = case['counts']
    result['status'] = 'passed' if all(case['status'] == 'passed' for case in result['cases']) else 'failed'
    result['qualification_complete'] = result['status'] == 'passed' and not selection['unrun'] and not rehearsal
    return result

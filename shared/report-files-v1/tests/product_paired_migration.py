"""Actual native paired migration; old stores originate only in frozen native UI.

The explicit legacy_source flag selects frozen C2 controls. The v5 project case
uses the manifest-pinned v4 producer and its historical native setup controls.
One Inspect compatible update action drives both owners; faults intercept its actual immutable
phase inputs. Named orch-first/spawn-first cells retain package installation
order, not obsolete manual mutation ordering. Reducer-order coverage is separate.
Faults remove/corrupt or restore captured owned store values. They never create
an authority, grant, peer proof or successful effect. Evidence is private.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import time
import traceback
from types import ModuleType

from product_c2 import Product, ensure_fixture_coordinator, prerequisites, provider_coordinator_identity, saved_records, surface_nodes
from product_c3 import (EventLoss, assign_idle_worker, initialize, native_launches,
                        process_identity, select_runtime_cases, show_advanced, spawn_dispatch, spawn_request, write_json)
from product_recovery import _reload
from product_scenario import TESTS, instrument, read_json, registry, trace


LEGACY_COMMIT = '97689168b1d12c22407fbb5f8cdd025445eeb682'
# Private reference data is never committed: ORCHPLUS_REFERENCE_DIR points at it. Unset, every source
# below resolves under a path that names the missing variable, so the existing unavailable path reports why.
LEGACY_DIRECTORY = Path(os.environ.get('ORCHPLUS_REFERENCE_DIR') or 'unavailable: ORCHPLUS_REFERENCE_DIR is not set')
FROZEN = LEGACY_DIRECTORY/'build-c2-frozen-9768916'
DEFAULT_ARCHIVE = LEGACY_DIRECTORY/'build-c2-9768916.tar'
V4_FROZEN = LEGACY_DIRECTORY/'platform-completion/cp2-recovery-reference-source-20261109'
V4_RECORD = V4_FROZEN.with_suffix('.json')
V4_RECORD_SHA256 = 'da53224c86faee3fcaf2bfb48900649b2c577c46a57dc825bab7ff2df07e1665'
V4_MANIFEST_SHA256 = '5d7d9f97e5c9449c59d12847fec1059bff7ab5a91fb334317c1f82e1bd70cf3f'


class PrerequisiteUnavailable(RuntimeError):
    pass


def _sha(bytes_):
    return hashlib.sha256(bytes_).hexdigest()


def _digest(value):
    return _sha(json.dumps(value, sort_keys=True, ensure_ascii=False).encode())


def _manifest(directory):
    if not directory.is_dir() or directory.is_symlink():
        raise PrerequisiteUnavailable('Source directory unavailable or linked: '+str(directory))
    result = {}
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():
            raise PrerequisiteUnavailable('Source contains an unverified link: '+str(path))
        if path.is_file():
            result[str(path.relative_to(directory))] = _sha(path.read_bytes())
    if not result:
        raise PrerequisiteUnavailable('Empty source: '+str(directory))
    return result


def _legacy_source(base, args, receipt):
    from native_smoke import baseline_source
    archive = Path(getattr(args, 'legacy_archive', None) or DEFAULT_ARCHIVE).resolve()
    if not archive.is_file():
        raise PrerequisiteUnavailable('Verified C2 archive required: '+str(archive))
    expected = _manifest(FROZEN)
    # baseline_source refuses links/traversal. Also reject duplicate entries:
    # a digest of the final extraction must not hide earlier different bytes.
    with tarfile.open(archive) as stream:
        names = set()
        for member in stream:
            name = str(Path(member.name))
            if name in names:
                raise PrerequisiteUnavailable('Duplicate archive member: '+name)
            names.add(name)
    destination = base/'paired-migration-legacy-source'
    destination.mkdir()
    legacy = baseline_source(archive, destination)
    actual = _manifest(legacy)
    if actual != expected:
        raise PrerequisiteUnavailable('Legacy archive is not byte-identical to the approved frozen C2 source')
    receipt['legacy_provenance'] = {
        'archive': str(archive), 'archive_sha256': _sha(archive.read_bytes()),
        'approved_commit': LEGACY_COMMIT, 'frozen_directory': str(FROZEN),
        'extracted_directory': str(legacy), 'files': actual,
        'manifest_sha256': _digest(actual),
        'verification': 'complete extracted file map equals approved frozen source; commit identity supplied by integration contract, not inferred from archive filename',
    }
    return legacy


def _v4_source(base, receipt):
    if not V4_RECORD.is_file() or V4_RECORD.is_symlink():
        raise PrerequisiteUnavailable('Recorded pre-v5 source manifest required: '+str(V4_RECORD))
    raw = V4_RECORD.read_bytes()
    if _sha(raw) != V4_RECORD_SHA256:
        raise PrerequisiteUnavailable('Pre-v5 provenance record differs from the retained CP2 receipt')
    record = json.loads(raw)
    expected = record['files']
    if record['source'] != str(V4_FROZEN) or _digest(expected) != V4_MANIFEST_SHA256:
        raise PrerequisiteUnavailable('Pre-v5 receipt does not identify the exact approved source')
    if _manifest(V4_FROZEN) != expected:
        raise PrerequisiteUnavailable('Pre-v5 source is not byte-identical to its complete recorded file map')
    destination = base/'paired-migration-v4-source'
    shutil.copytree(V4_FROZEN, destination)
    if _manifest(destination) != expected:
        raise PrerequisiteUnavailable('Private pre-v5 copy differs from the recorded source')
    receipt['v4_provenance'] = {
        'record': str(V4_RECORD), 'record_sha256': V4_RECORD_SHA256,
        'frozen_directory': str(V4_FROZEN), 'extracted_directory': str(destination),
        'manifest_sha256': V4_MANIFEST_SHA256, 'files': expected,
        'verification': 'all 380 files match the retained CP2 recovery-reference receipt; actual source creates v4, no version rewriting or inferred commit',
    }
    return destination


def _rows(product):
    props = product.ui('preferences', pane=product.spawn_pane)['properties']
    return {row['id']: row for section in props.get('sections', []) for row in section.get('rows', [])}


def _orch_view(product):
    return product.ui.machine(product.controller, 'orchplus.migration', 'migration-state')


def _effects(product):
    # Terminal fixture starts and actual Native OMP coordinators are separate
    # evidence. A provider setup diagnostic must never count as a task launch.
    launches = {record: native_launches(product, record)
                for record in ('c2-builder', 'c2-release')}
    coordinators = [worker for worker in (registry(product.runtime) or {}).get('dispatch', {}).get('workers', {}).values()
                    if worker.get('coordinator_owner_id')]
    return {'launches': launches, 'counts': {key: len(value) for key, value in launches.items()},
            'coordinators': coordinators, 'native_agents': product.ui('agents'),
            'panes': product.ui('panes'),
            'native_inventory': json.loads(product.runtime.command('inspect', '--json'))}


def _zero_managed(product):
    observed = _effects(product)
    assert observed['counts']['c2-builder'] == 0, 'unexpected managed native worker effect'
    assert not observed['coordinators'], 'migration/refusal unexpectedly started a coordinator'
    return observed


def _preserve_legacy_worker(product, additional=0):
    baseline = product.result.get('legacy_managed_baseline')
    if baseline is None:
        assert additional == 0
        return _zero_managed(product)
    observed = _effects(product)
    launches = observed['launches']['c2-builder']
    assert launches[:len(baseline['launches'])] == baseline['launches']
    assert len(launches) == len(baseline['launches']) + additional, 'unexpected migration launch delta'
    assert observed['launches']['c2-release'] == baseline['ordinary_launches']
    for launch in baseline['launches']:
        assert process_identity(launch['pid']) == baseline['processes'][str(launch['pid'])]
    current = registry(product.runtime)['dispatch']['workers'][baseline['worker_id']]
    assert {key: current.get(key) for key in baseline['identity']} == baseline['identity']
    pane = next(row for row in observed['panes'] if str(row['pane']) == baseline['pane']['pane'])
    assert {key: str(pane[key]) for key in baseline['pane']} == baseline['pane']
    return observed


def _checkpoint_legacy_observer(product):
    # C2 indexes an observer before persisting its journal. Use a genuine ordinary
    # launch to checkpoint it; never invent the missing journal or erase its index.
    product.ui.preference(product.spawn_pane, page='runtime')
    product.lib.wait_for(lambda: spawn_dispatch(product), 'C2 native runtime initialized', 30)
    _ordinary_spawn(product)
    product.result['legacy_observer_checkpoint_effect'] = product.result.pop('independent_spawn_effect')
    def checkpoint():
        store = read_json(product.runtime.config/'plugin-data/spawn/kv.json')
        namespace = store.get('window-observer-namespace')
        index = store.get('window-observer-index:'+str(namespace))
        if not isinstance(namespace, str) or not isinstance(index, dict) or not index:
            return None
        journals = {}
        for key in index:
            value = store.get(key)
            if not isinstance(value, dict):
                return None
            assert value.get('version') == 2 and value.get('id') == key.removeprefix('window-observer:')
            assert isinstance(value.get('transports'), dict)
            if any(transport.get('pending') is not None for transport in value['transports'].values()):
                return None
            journals[key] = value
        return {'namespace': namespace, 'index': index, 'journals': journals}
    product.result['legacy_observer_checkpoint'] = product.lib.wait_for(
        checkpoint, 'genuine C2 observer journals settled before cutover', 30)


def _live_legacy_worker(product):
    assign_idle_worker(product)
    def accepted():
        workers = registry(product.runtime)['dispatch']['workers']
        return next((worker for worker in workers.values() if worker.get('record_id') == 'c2-builder'
                     and worker.get('phase') == 'accepted' and worker.get('accepted_seq')), None)
    worker = product.lib.wait_for(accepted, 'genuine C2 helper-backed worker ACCEPTED', 90)
    def settled():
        source = registry(product.runtime)
        dispatch = source['dispatch']
        current = dispatch['workers'][worker['worker_id']]
        flow = current.get('workflow', {})
        native, empty = flow.get('native', {}), flow.get('empty_read', {})
        age = time.time()*1000-native.get('at_ms', 0)
        if (all(action['phase'] == 'complete' for action in dispatch['actions'].values())
                and not dispatch.get('gates', {}) and not current.get('accept_pending')
                and not current.get('compaction_pending') and not current.get('receipts')
                and not current.get('replies') and not current.get('wakes')
                and current['compacted_floor'] == current['accepted_seq']
                and not flow.get('report_request')
                and native.get('state') == 'idle' and not native.get('delivery_error')
                and 0 <= age < dispatch['policies'][current['logical_session_id']]['stale_ms']/8
                and empty.get('slot') == current['accepted_seq']+1
                and empty.get('epoch') == native.get('epoch')
                and empty.get('mono_ms', -1) >= native.get('mono_ms', 0)):
            return current
        product.result['legacy_last_unsettled'] = source
        return None
    worker = product.lib.wait_for(settled, 'C2 helper receipts and native obligations settled', 90)
    effects = _effects(product)
    launches = effects['launches']['c2-builder']
    assert len(launches) == 1 and launches[0]['worker_id'] == worker['worker_id']
    assert launches[0]['mailbox_handle'] == worker['mailbox_handle']
    assert worker['logical_session_id'] in spawn_dispatch(product)['owners']
    fields = ('worker_id', 'work_id', 'worker_generation', 'logical_session_id',
              'launch_request_id', 'launch_action_id', 'enrolment_token', 'mailbox_handle',
              'record_id', 'record_revision', 'manifest_sha256', 'assignment_sha256',
              'binding_digest', 'origin_binding', 'controller_pane', 'pane_binding', 'capabilities')
    pane = next(row for row in effects['panes'] if str(row['pane']) == worker['pane_binding']['pane_id'])
    product.result['legacy_managed_baseline'] = {
        'worker_id': worker['worker_id'], 'launches': launches,
        'ordinary_launches': effects['launches']['c2-release'],
        'processes': {str(launch['pid']): process_identity(launch['pid']) for launch in launches},
        'identity': {key: copy.deepcopy(worker.get(key)) for key in fields},
        'pane': {key: str(pane[key]) for key in ('pane', 'kind', 'tab', 'cwd')}}


def _snapshot(product, label):
    directory = product.runtime.root/'migration-evidence'
    directory.mkdir(exist_ok=True)
    stores = {}
    for plugin, key in (('orchplus', 'authority_state'), ('spawn', 'dispatch-v1')):
        path = product.runtime.config/'plugin-data'/plugin/'kv.json'
        raw = path.read_bytes()
        value = json.loads(raw)
        copied = directory/(label+'-'+plugin+'.json')
        copied.write_bytes(raw)
        stores[plugin] = {'path': str(copied), 'kv_sha256': _sha(raw),
                          'source': value.get(key), 'source_json_sha256': _digest(value.get(key)),
                          'other_keys': sorted(name for name in value if name != key)}
    item = {'stores': stores, 'effects': _effects(product), 'context': product.ui('context'),
            'observed_ns': time.time_ns()}
    product.result.setdefault('snapshots', {})[label] = item
    return item


def _update_refused(product):
    """One visible update request; retain its first actual refusal, never retry."""
    prior = ((_orch_view(product) or {}).get('result') or {}).get('request_id')
    prior_events = len(trace(product.runtime, 'orchplus', 'window')['events'])
    show_advanced(product)
    product.ui.mouse_click(product.controller, 'Inspect compatible update')
    def refused():
        view = _orch_view(product)
        response = (view or {}).get('result')
        if response and response.get('request_id') != prior and response.get('ok') is False:
            return view
        events = trace(product.runtime, 'orchplus', 'window')['events'][prior_events:]
        for event in events:
            if event['kind'] == 'native_toast' and event['data']['severity'] == 'error':
                return {'native_refusal': event, 'migration_view': view}
        return None
    observation = product.lib.wait_for(refused, 'one-button update refuses incompatible source', 40)
    product.result.setdefault('migration_controls', []).append(
        {'owner': 'paired', 'operation': 'update', 'view': observation})
    return observation


def _inspect_pair(product, captured):
    """Observe the actual one-button request held before its original handler."""
    request = json.loads(captured['input']['value'])
    assert request['operation'] == 'inspect'
    view = _orch_view(product)
    pair = {'orch': view['qualification']['proof'], 'spawn': request['peer']['proof']}
    assert request['intent']['expected_revision'] == registry(product.runtime)['revision']
    for owner, source in (('orch', registry(product.runtime)), ('spawn', spawn_dispatch(product))):
        proof = pair[owner]
        assert source and proof['source_revision'] == source['revision']
        assert proof['source_schema'] == source['version']
        assert len(proof['source_sha256']) == 64 and len(proof['managed_sha256']) == 64
        if owner == 'spawn':
            assert proof['source_namespace'] == source['namespace'] == proof['candidate_namespace']
        elif source['version'] == 3:
            assert 'source_namespace' not in proof, 'invented historical ORCH namespace'
        else:
            assert proof['source_namespace'] == source['authority_namespace'] == proof['candidate_namespace']
        assert proof['state'] == 'ready' and proof['pending_immutable'] == proof['blockers'] == 0
    assert pair['orch']['managed_sha256'] == pair['spawn']['managed_sha256']
    product.result.setdefault('independent_pairs', []).append(
        {'proofs': copy.deepcopy(pair), 'native_compatibility': copy.deepcopy(view['compatibility'])})
    return pair, view['qualification']['selection']


def _legacy_setup(product, active, live=False):
    product.legacy_source = True
    product.start()
    product.open_spawn()
    product.create_record('c2-builder', 'Codex')
    product.create_record('c2-release', 'OMP')
    product.result['old_helper_bundles'] = {
        str(Path(record['mailbox']['helper_path']).parent): _manifest(Path(record['mailbox']['helper_path']).parent)
        for record in saved_records(product.runtime)}
    product.initialize_orch()
    product.configure_orch('review_disabled')
    assert registry(product.runtime)['version'] == 3, 'fixture is not C2 ORCH format'
    product.result['before_legacy_claim'] = _snapshot(product, 'old-empty')
    if active:
        product.claim(legacy=True)
    _checkpoint_legacy_observer(product)
    if active and live:
        _live_legacy_worker(product)
    peer = spawn_dispatch(product)
    assert peer and peer['version'] == 1, 'fixture is not initialized C2 SPAWN format'
    if active:
        assert registry(product.runtime)['sessions'], 'no genuine old controller registration'
        # C2 catalog/status are read-only and do not reserve a peer owner.
        if live:
            assert peer['owners'], 'the real old worker did not establish its managed peer identity'
    else:
        assert not registry(product.runtime)['sessions'] and not peer['owners']
    _preserve_legacy_worker(product)
    return _snapshot(product, 'old-created')


def _new_packages(product, root, loss):
    directory = product.runtime.root/'paired-new-packages'
    directory.mkdir()
    packages = {}
    for plugin, family in (('spawn', 'SPAWN'), ('orchplus', 'ORCH+')):
        target = directory/family
        configuration = {'held_events_path': str(loss.path)}
        if plugin == 'spawn':
            configuration['orch_kv'] = str(product.runtime.config/'plugin-data/orchplus/kv.json')
            configuration['migration_trace'] = True
        else:
            configuration['toast_trace'] = True
        instrument(root/'plugins/tern'/family, target, configuration)
        packages[plugin] = target
    product.result['new_package_manifests'] = {key: _manifest(path) for key, path in packages.items()}
    return packages


def _switch(product, plugin, packages):
    # Native development links are ID.path markers. Repoint through the native
    # command only; never overwrite the old package/helper directory.
    package = packages[plugin]
    records = copy.deepcopy(saved_records(product.runtime))
    installed = Path(json.loads(product.runtime.command('plugin', 'dir', '--json'))['dir'])/(plugin+'.path')
    old = product.spawn if plugin == 'spawn' else product.orch
    if not installed.is_file() or installed.is_symlink():
        raise PrerequisiteUnavailable('Normal relink requires the existing owned development marker: '+str(installed))
    linked = Path(installed.read_text(encoding='utf-8').strip())
    if not linked.is_absolute() or linked.resolve() != old.resolve():
        raise PrerequisiteUnavailable('Native development marker does not name the exact owned old package: '+str(installed))
    product.runtime.command('plugin', 'link', package)
    _reload(product, plugin)
    if plugin == 'spawn':
        product.spawn = package
    else:
        product.orch = package
        product.legacy_source = False
    assert Path(installed.read_text(encoding='utf-8').strip()).resolve() == package.resolve(), 'native link did not select the new owned path'
    assert saved_records(product.runtime) == records, 'native relink changed saved routes or helper paths'
    product.result.setdefault('package_transitions', []).append(
        {'plugin': plugin, 'old_path': str(old), 'new_path': str(package), 'installed_path': str(installed),
         'route': 'tern plugin link NEW_OWNED_PATH; tern plugin reload ID --json',
         'documented_semantics': 'already-linked ID is repointed; installed-copy ID refuses',
         'documentation': 'https://docs.stencil.so/tern/reference/cli.html'})


def _ordinary_spawn(product):
    before = copy.deepcopy(native_launches(product, 'c2-release'))
    product.ui.preference(product.spawn_pane, page='spawn')
    rows = [row for row in _rows(product).values()
            if row['id'].startswith('spawn-launch:') and row['id'].endswith(':c2-release')]
    assert len(rows) == 1, 'ordinary SPAWN launch prerequisite unavailable'
    product.ui.preference(product.spawn_pane, row=rows[0]['id'])
    def additional_launch():
        launches = native_launches(product, 'c2-release')
        assert launches[:len(before)] == before, 'ordinary launch history changed'
        added = launches[len(before):]
        assert len(added) <= 1, 'more than one ordinary effect from one native press'
        return added[0] if added else None
    launch = product.lib.wait_for(additional_launch, 'one additional independent ordinary native SPAWN effect', 60)
    assert len(native_launches(product, 'c2-release')) == len(before)+1
    product.result['independent_spawn_effect'] = {
        'prior_launch_count': len(before), 'launch': launch, 'process': process_identity(launch['pid'])}
    _zero_managed(product)
    product.ui.preference(product.spawn_pane, page='runtime')


def _mixed(product, first, packages):
    before = _snapshot(product, 'before-mixed')
    previous_boots = {plugin+'/'+realm: trace(product.runtime, plugin, realm)['boot']
                      for plugin in ('orchplus', 'spawn') for realm in ('host', 'window')}
    _switch(product, first, packages)
    if first == 'spawn':
        # Native relink also replaces the legacy controller's executors. Its
        # uncertainty is not permission to pretend the catalog button is active.
        current_boots = {plugin+'/'+realm: trace(product.runtime, plugin, realm)['boot']
                         for plugin in ('orchplus', 'spawn') for realm in ('host', 'window')}
        assert all(current_boots[key] > boot for key, boot in previous_boots.items())
        product.result['mixed_executor_replacement'] = {'before': previous_boots, 'after': current_boots}
        _zero_managed(product)
        product.ui('focus', pane=product.controller)
        product.ui('action', action='plugin.orchplus.continue_controller')
        product.ui.choose('Continue controller ', 'I independently verified previous ORCH+/SPAWN executors stopped or retired')
        product.result['legacy_continuation'] = product.lib.wait_for(
            lambda: (product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state') or {}).get('controller_phase') == 'active',
            'explicit legacy controller continuation', 40)
        # The genuine old catalog input reaches only the retained inert view.
        # This is a visible legacy-route refusal, not a current protocol response.
        prior_events = len(trace(product.runtime, 'spawn', 'host')['events'])
        product.ui.click(product.controller, 'Load configured SPAWN catalog')
        def refused():
            events = trace(product.runtime, 'spawn', 'host')['events'][prior_events:]
            for event in events:
                data = event['data']
                if event['kind'] != 'bridge_event' or data.get('act') != 'catalog':
                    continue
                request = json.loads(data['value'])
                if request.get('schema') != 1 or not request.get('origin_binding'):
                    continue
                assert request['controller_pane'] == str(product.controller)
                surface = product.ui('surface', pane=data['pane'])
                disabled = ('Retained SPAWN dispatch view — execution is disabled. Reconcile existing work through '
                            'ORCH+ or SPAWN Advanced recovery; this pane grants no authority.')
                messages = [props.get('text', ''.join(span if isinstance(span, str) else span.get('t', '')
                                                     for span in props.get('spans', [])))
                            for node in surface_nodes((surface or {}).get('main')) for props in [node.get('p', {})]]
                if disabled in messages:
                    return {'event': event, 'request': request, 'surface': surface,
                            'disposition': 'inert legacy route; no current-protocol request was admitted'}
            return None
        product.result['mixed_managed_refusal'] = product.lib.wait_for(refused, 'visible inert legacy-route refusal', 40)
        refusal = product.result['mixed_managed_refusal']
        product.ui('focus', pane=product.result['mixed_managed_refusal']['event']['data']['pane'])
        product.capture('mixed-native-protocol-refusal')
    else:
        product.lib.wait_for(lambda: (_orch_view(product) or {}).get('phase') == 'legacy', 'new ORCH holds old source', 40)
        # The unchanged old SPAWN has no independent new-protocol qualification.
        # The actual migration control must refuse rather than infer readiness.
        refusal = _update_refused(product)
    product.result['mixed_refusal'] = {'upgraded_first': first, 'observation': refusal,
                                       'effects': _zero_managed(product)}
    assert registry(product.runtime)['version'] == 3
    assert spawn_dispatch(product)['version'] == 1
    assert registry(product.runtime)['sessions'].keys() == before['stores']['orchplus']['source']['sessions'].keys()
    _ordinary_spawn(product)
    product.result['checks'].append('mixed native versions visibly refuse managed pairing; ordinary independent SPAWN performs exactly one additional native effect without replacing legacy history')

def _mixed_case(product, root, loss, first):
    _legacy_setup(product, True)
    _mixed(product, first, _new_packages(product, root, loss))
    _snapshot(product, 'mixed-refused')



def _prepared_reload(product, plugins, label):
    before = _snapshot(product, label+'-before')
    for plugin in plugins:
        _reload(product, plugin)
    after = _snapshot(product, label+'-after')
    for plugin in plugins:
        old = before['stores'][plugin]['source']
        current = after['stores'][plugin]['source']
        assert old.get('migration') and current.get('migration') == old['migration']
        field = 'authority_namespace' if plugin == 'orchplus' else 'namespace'
        assert current[field] == old[field]
        assert not current.get('compatibility'), 'prepared reload admitted current protocol'
    _preserve_legacy_worker(product)
    product.result['checks'].append('native reload retains exact prepared obligation and candidate identity without execution: '+label)


def _finish_and_execute(product, old, pair, selection):
    old_sessions = old['stores']['orchplus']['source']['sessions']
    assert set(selection['logical_session_ids']) == set(old['stores']['spawn']['source']['owners'])
    product.result['matched_complete_selection'] = selection
    show_advanced(product)
    product.ui.mouse_click(product.controller, 'Inspect compatible update')
    def paired_finished():
        authority, peer = registry(product.runtime), spawn_dispatch(product)
        if (authority and peer and authority.get('compatibility', {}).get('kind') == 'current'
                and not authority.get('migration') and not peer.get('migration')
                and peer.get('authority_namespace') == authority.get('authority_namespace')):
            return {'orch': authority, 'spawn': peer}
        return None
    product.result['automatic_paired_finish'] = product.lib.wait_for(
        paired_finished, 'one-button update finishes both owners before admission', 40)
    current, peer = registry(product.runtime), spawn_dispatch(product)
    assert not current.get('migration') and not peer.get('migration')
    assert current['compatibility'] == {'schema': 1, 'kind': 'current', 'protocol': 2,
                                        'authority_namespace': current['authority_namespace'], 'spawn_namespace': peer['namespace']}
    assert peer['namespace'] == old['stores']['spawn']['source']['namespace']
    assert peer['authority_namespace'] == pair['orch']['candidate_namespace']
    assert set(old_sessions) <= set(current['sessions'])
    assert not any(key in current for key in ('request_outcomes', 'retired'))
    assert not any(key in peer for key in ('request_fences', 'tombstones', 'owners'))
    finished = _snapshot(product, 'paired-finished-before-admission')
    _preserve_legacy_worker(product)
    baseline_launches = copy.deepcopy(native_launches(product))
    # Never reinterpret a migrated uncertain owner as a fresh controller. Use a
    # separate explicit native registration; retain every old session untouched.
    preserved = copy.deepcopy(current['sessions'])
    product.create_orchestration('Post-migration qualification')
    product.ui.mouse_click(product.ui.agent_picker('Choose your orchestrator'), 'Back')
    product.claim()
    for logical, session in preserved.items():
        assert registry(product.runtime)['sessions'][logical] == session
    assert any(session.get('admitted') for logical, session in registry(product.runtime)['sessions'].items()
               if logical not in preserved)
    coordinator = ensure_fixture_coordinator(product, deadline=time.monotonic()+240)
    product.result['post_migration_coordinator'] = provider_coordinator_identity(product, coordinator)
    assign_idle_worker(product)
    def new_launch():
        launches = native_launches(product)
        assert launches[:len(baseline_launches)] == baseline_launches
        added = launches[len(baseline_launches):]
        assert len(added) <= 1, 'more than one post-finish native effect'
        return added[0] if added else None
    launch = product.lib.wait_for(new_launch, 'one post-finish admitted actual native launch', 90)
    assert launch['started_ns'] > finished['observed_ns'], 'effect preceded explicit paired finish'
    def accepted():
        workers = registry(product.runtime)['dispatch']['workers']
        current = workers.get(launch['worker_id'])
        if (current and current['record_id'] == 'c2-builder'
                and current['logical_session_id'] not in preserved
                and current['mailbox_handle'] == launch['mailbox_handle']
                and current.get('phase') == 'accepted' and current.get('accepted_seq')):
            return current
        return None
    worker = product.lib.wait_for(accepted, 'real helper ACCEPTED after paired migration', 90)
    assert len(native_launches(product)) == len(baseline_launches)+1
    if product.result.get('legacy_managed_baseline'):
        _preserve_legacy_worker(product, additional=1)
    product.result['post_migration_effect'] = {'launch': launch, 'process': process_identity(launch['pid']), 'worker': worker}
    _snapshot(product, 'after-current-effect')
    product.result['checks'].append('independent complete proofs match; one-button automatic paired finish precedes admission and exactly one real helper-backed worker; old current sessions and SPAWN namespace preserved')


def _positive(product, root, loss, active, first):
    old = _legacy_setup(product, active, live=active)
    packages = _new_packages(product, root, loss)
    for plugin in (first, 'orchplus' if first == 'spawn' else 'spawn'):
        _switch(product, plugin, packages)
    inspect_hold = {'id': 'automatic-inspect', 'block': 'orchestrator',
                    'act': 'migration-command', 'match': {'operation': 'inspect'}}
    prepare_hold = {'id': 'automatic-orch-prepare', 'block': 'orchestrator',
                    'act': 'migration-command', 'match': {'operation': 'prepare'}}
    loss.set([inspect_hold, prepare_hold])
    show_advanced(product)
    product.ui.mouse_click(product.controller, 'Inspect compatible update')
    captured_inspect = loss.wait('orchplus', 'automatic-inspect')
    pair, selection = _inspect_pair(product, captured_inspect)
    assert bool(selection['logical_session_ids']) == active
    product.result['legacy_source_pair'] = pair
    product.result['automatic_inspect_event'] = captured_inspect
    loss.set([prepare_hold])
    loss.deliver_original_once(captured_inspect)
    captured_prepare = loss.wait('orchplus', 'automatic-orch-prepare')
    assert registry(product.runtime)['version'] == 3
    assert spawn_dispatch(product)['version'] == 2 and spawn_dispatch(product).get('migration')
    product.result['automatic_prepare_event'] = captured_prepare
    _preserve_legacy_worker(product)
    _prepared_reload(product, ('spawn',), 'one-sided-prepared')
    loss.set([])
    before_stale = _snapshot(product, 'before-stale-automatic-prepare')
    loss.deliver_original_once(captured_prepare)
    request_id = json.loads(captured_prepare['input']['value'])['intent']['request_id']
    def stale_refused():
        response = (_orch_view(product) or {}).get('result')
        return response if response and response.get('request_id') == request_id and response.get('ok') is False else None
    product.result['stale_prepare_refusal'] = product.lib.wait_for(
        stale_refused, 'original automatic prepare is refused after peer reload', 40)
    assert registry(product.runtime)['version'] == 3
    assert spawn_dispatch(product) == before_stale['stores']['spawn']['source']
    finish_hold = {'id': 'automatic-spawn-finish', 'block': 'carrier',
                   'act': 'migration', 'match': {'operation': 'finish'}}
    loss.set([finish_hold])
    show_advanced(product)
    product.ui.mouse_click(product.controller, 'Inspect compatible update')
    captured_finish = loss.wait('spawn', 'automatic-spawn-finish')
    assert captured_finish['kind'] == 'carrier_receive'
    assert json.loads(captured_finish['body'])['operation'] == 'finish'
    assert registry(product.runtime).get('migration')
    assert spawn_dispatch(product)['version'] == 2 and spawn_dispatch(product).get('migration')
    product.result['automatic_finish_event'] = captured_finish
    _prepared_reload(product, ('orchplus', 'spawn'), 'both-prepared')
    before_stale_finish = _snapshot(product, 'before-stale-automatic-finish')
    # Observe the real refusal before ORCH correctly discards an old source.
    # Retaining literal diagnostics on the new panel is not a product invariant.
    refusal_ids = ('stale-finish-endpoint', 'unbound-finish-endpoint')
    loss.set([{'id': name, 'block': 'carrier', 'act': 'spawn.source',
               'match': {'kind': 'held', 'error': error,
                         'relay_endpoint': captured_finish['carrier']['relay_endpoint'],
                         'lane_id': captured_finish['carrier']['lane_id']}}
              for name, error in zip(refusal_ids, ('stale_endpoint', 'endpoint_unbound'))])
    loss.deliver_original_once(captured_finish)
    def stale_finish_refused():
        for name in refusal_ids:
            observed = loss.observed('orchplus', name)
            if not observed:
                continue
            response = json.loads(observed['body'])
            rejected = response.get('rejected_message', {})
            assert rejected.get('id') == captured_finish['frame']['id']
            assert rejected.get('incarnation') == captured_finish['frame']['incarnation']
            return observed
        return None
    captured_refusal = product.lib.wait_for(
        stale_finish_refused, 'exact old finish carrier rejection after reload', 40)
    product.result['stale_finish_refusal'] = captured_refusal
    for plugin, current in (('orchplus', registry(product.runtime)), ('spawn', spawn_dispatch(product))):
        assert current == before_stale_finish['stores'][plugin]['source'], 'stale finish mutated a prepared source'
    _preserve_legacy_worker(product)
    loss.set([])
    loss.deliver_original_once(captured_refusal)
    _finish_and_execute(product, old, pair, selection)


def _pending(product, root, loss, executed=False):
    _legacy_setup(product, True)
    loss.set([{'id': 'old-native-begin', 'block': 'dispatch', 'act': 'spawn.begin', 'request': {'op': 'launch'}}])
    assign_idle_worker(product)
    captured = loss.wait('spawn', 'old-native-begin')
    envelope = json.loads(captured['input']['value'])
    request_bytes = envelope['request_json']
    request = json.loads(request_bytes)
    assert request['schema'] == 1 and request['op'] == 'launch'
    source = registry(product.runtime)
    action = source['dispatch']['actions'][request['action_id']]
    assert action['request_bytes'] == request_bytes
    product.result['immutable_pending'] = {'held_event': captured, 'request_sha256': _sha(request_bytes.encode()),
                                           'action': copy.deepcopy(action), 'before': _snapshot(product, 'pending-old')}
    _zero_managed(product)
    effect_identity = None
    if executed:
        loss.set([{'id': 'old-effect-result', 'block': 'orchestrator',
                   'act': 'dispatch-result/'+action['claim']['grant_id']+'/'+request['origin_binding']['window_epoch']}])
        loss.deliver_original_once(captured)
        launch = product.lib.wait_for(lambda: next(iter(native_launches(product)), None),
                                     'one genuine legacy native effect before callback loss', 90)
        effect_identity = process_identity(launch['pid'])
        result_event = loss.wait('orchplus', 'old-effect-result')
        product.result['immutable_pending']['held_real_result'] = result_event
        product.result['immutable_pending']['actual_effect'] = {'launch': launch, 'process': effect_identity}
        assert len(native_launches(product)) == 1
        _snapshot(product, 'old-effect-unconsumed')
    packages = _new_packages(product, root, loss)
    for plugin in ('spawn', 'orchplus'):
        _switch(product, plugin, packages)
    proof = _orch_view(product)['qualification']['proof']
    assert proof['pending_immutable'] > 0
    product.result['pending_source_proof'] = copy.deepcopy(proof)
    refusal = _update_refused(product)
    product.result['pending_update_refusal'] = refusal
    assert registry(product.runtime)['version'] == 3 and spawn_dispatch(product)['version'] == 1
    retained = registry(product.runtime)['dispatch']['actions'][request['action_id']]
    assert retained['request_bytes'] == request_bytes
    assert retained.get('claim') == action.get('claim'), 'migration rewrote old immutable grant'
    assert len(native_launches(product)) == (1 if executed else 0), 'migration replayed an old native effect'
    if executed:
        assert process_identity(native_launches(product)[0]['pid']) == effect_identity
    _snapshot(product, 'pending-refused')
    product.result['checks'].append(
        'genuine old immutable '+('executed launch with suppressed actual result' if executed else 'pre-effect launch')+
        ' remains visibly migration-blocking; exact request/grant retained; actual native effect count '+str(1 if executed else 0))


def _restore_key(product, plugin, key, value):
    path = product.runtime.config/'plugin-data'/plugin/'kv.json'
    before = read_json(path)
    assert isinstance(before, dict), 'cannot preserve unrelated KV keys'
    after = dict(before)
    if value is None:
        after.pop(key, None)
    else:
        after[key] = copy.deepcopy(value)
    write_json(path, after)
    assert read_json(path) == after
    return {'key': key, 'before_sha256': _digest(before), 'after_sha256': _digest(after),
            'unrelated_keys_preserved': sorted(name for name in before if name != key)}


def _source_fault(product, root, loss, owner, fault):
    old = _legacy_setup(product, True, live=True)
    packages = _new_packages(product, root, loss)
    for plugin in ('spawn', 'orchplus'):
        _switch(product, plugin, packages)
    plugin, key = ('orchplus', 'authority_state') if owner == 'orch' else ('spawn', 'dispatch-v1')
    if fault == 'mismatch':
        # Real earlier source: ORCH had no session when captured; SPAWN now has
        # the old real controller. Neither half is invented or edited.
        replacement = product.result['before_legacy_claim']['stores'][plugin]['source']
        assert not replacement['sessions'] and spawn_dispatch(product)['owners']
    elif fault == 'missing':
        replacement = None
        if owner == 'spawn':
            kv = read_json(product.runtime.config/'plugin-data/spawn/kv.json')
            assert kv.get('dispatch-v1-initialized') == spawn_dispatch(product)['namespace'], 'missing genuine initialization marker'
    else:
        replacement = 'deliberate owned malformed source; not an authority'
    original = copy.deepcopy(registry(product.runtime) if owner == 'orch' else spawn_dispatch(product))
    assert isinstance(original, dict), 'current source unavailable before owned fault injection'
    product.result['source_fault'] = {'owner': owner, 'kind': fault,
                                     'original_source_json_sha256': _digest(original),
                                     'legacy_created_source_json_sha256': _digest(old['stores'][plugin]['source']),
                                     'mutation': _restore_key(product, plugin, key, replacement)}
    try:
        _reload(product, plugin)
        if owner == 'spawn' or fault == 'mismatch':
            refusal = _update_refused(product)
        else:
            def held():
                surface = product.ui('surface', pane=product.controller)
                has_error = any(isinstance(span, dict) and span.get('s') == 'error'
                                for node in surface_nodes(surface.get('main'))
                                for span in node.get('p', {}).get('spans', []))
                return surface if has_error and not product.ui.machine(
                    product.controller, 'orchplus.dispatch', 'dispatch-state') else None
            refusal = product.lib.wait_for(held, 'native '+owner+' '+fault+' source hold', 40)
            if fault == 'missing':
                for node in surface_nodes((refusal or {}).get('main')):
                    props = node.get('p', {})
                    text = props.get('text', ''.join(span if isinstance(span, str) else span.get('t', '')
                                                   for span in props.get('spans', [])))
                    assert not ('Initialize first-use authority' in text and props.get('actions', {}).get('click')
                                and not props.get('disabled') and not props.get('attrs', {}).get('disabled')), \
                        'known initialized ORCH source loss was exposed as first use'
        observed = read_json(product.runtime.config/'plugin-data'/plugin/'kv.json')
        assert observed.get(key) == replacement, 'missing/corrupt source was reinitialized or overwritten'
        product.result['source_fault']['refusal'] = refusal
        effects = _effects(product)
        baseline = product.result['legacy_managed_baseline']
        assert effects['launches']['c2-builder'] == baseline['launches'], 'source fault caused another managed effect'
        assert effects['launches']['c2-release'] == baseline['ordinary_launches'], 'source fault changed ordinary history'
        for launch in baseline['launches']:
            assert process_identity(launch['pid']) == baseline['processes'][str(launch['pid'])]
        product.result['source_fault']['effects'] = effects
        peer = spawn_dispatch(product) if owner == 'orch' else registry(product.runtime)
        assert peer['version'] == (1 if owner == 'orch' else 3), 'peer migrated despite invalid complete source'
        _snapshot(product, 'source-fault-held')
    finally:
        product.result['source_fault']['restore'] = _restore_key(product, plugin, key, original)
        _reload(product, plugin)
    assert (registry(product.runtime) if owner == 'orch' else spawn_dispatch(product)) == original
    _preserve_legacy_worker(product)
    product.result['checks'].append('actual '+owner+' '+fault+' source is held without reset; exact captured source and worker identity restored, unrelated KV and live processes preserved, no additional native managed effects')


def _project_upgrade_proofs(product, loss, begin_hold, *, legacy):
    """Observe both actual native digests, including a deliberately blocked pair."""
    label = 'v4' if legacy else 'v5'
    inspect_id = label+'-project-inspect'
    inspect_hold = {'id': inspect_id, 'block': 'orchestrator',
                    'act': 'migration-command', 'match': {'operation': 'inspect'}}
    loss.set([begin_hold, inspect_hold])
    if legacy:
        product.ui.click(product.controller, 'Config')
    else:
        show_advanced(product)
    if legacy:
        product.ui.preference(product.spawn_pane, page='runtime')
        product.ui.preference(product.spawn_pane, row='managed-migration-inspect')
        product.lib.wait_for(lambda: _rows(product).get('managed-migration-source'),
                             'v4 native SPAWN source publication', 30)
    first_event = len(trace(product.runtime, 'orchplus', 'window')['events'])
    if legacy:
        product.ui.click(product.controller, 'Read paired migration evidence')
    else:
        product.ui.mouse_click(product.controller, 'Inspect compatible update')
    captured = loss.wait('orchplus', inspect_id)
    request = json.loads(captured['input']['value'])
    assert request['operation'] == 'inspect'
    loss.set([begin_hold])
    loss.deliver_original_once(captured)
    def inspected():
        view = _orch_view(product)
        result = (view or {}).get('result') or {}
        return view if result.get('request_id') == request['intent']['request_id'] else None
    view = product.lib.wait_for(inspected, label+' exact native source inspection', 40)
    assert view['result']['ok'] is True, 'independent inspection itself failed'
    pair = {'orch': view['qualification']['proof'], 'spawn': request['peer']['proof']}
    assert view['qualification']['selection'] == request['peer']['selection']
    for owner, source in (('orch', registry(product.runtime)), ('spawn', spawn_dispatch(product))):
        proof = pair[owner]
        assert proof['source_schema'] == source['version']
        assert proof['source_revision'] == source['revision']
        assert len(proof['source_sha256']) == len(proof['managed_sha256']) == 64
        assert proof['state'] == 'blocked' and proof['pending_immutable'] > 0
    assert pair['orch']['managed_sha256'] == pair['spawn']['managed_sha256']
    observation = {'proofs': copy.deepcopy(pair), 'selection': request['peer']['selection'],
                   'captured_inspect': captured, 'view': view}
    if not legacy:
        def held():
            for event in trace(product.runtime, 'orchplus', 'window')['events'][first_event:]:
                if event['kind'] == 'native_toast' and event['data']['severity'] == 'error':
                    return event
            return None
        observation['one_action_refusal'] = product.lib.wait_for(
            held, 'one-action reconnect retains unresolved pre-upgrade launch', 40)
        assert observation['one_action_refusal']['data']['message'] == (
            'The independent sources do not agree, or unresolved effects still require review.'
            ' Existing work and uncertain outcomes are retained; no step was repeated.')
    product.result.setdefault('project_upgrade_proofs', {})[label] = observation
    return pair


def _v5_project_upgrade(product, root, loss):
    # Only historical UI helpers come from this already manifest-verified copy.
    # Runtime isolation, instrumentation, native inputs and cleanup remain current.
    driver_path = product.root/'shared/report-files-v1/tests/product_c2.py'
    historical = ModuleType('paired_migration_v4_ui')
    historical.__file__ = str(driver_path)
    # Execute the pinned helper definitions without creating __pycache__ in the
    # source copy whose complete manifest must remain unchanged.
    exec(compile(driver_path.read_bytes(), str(driver_path), 'exec'), historical.__dict__)
    product.result['fixture_sources']['frozen-v4-product_c2.py'] = _sha(driver_path.read_bytes())
    product.result['qualification_scope'] = (
        'v4 native owner-created saved work and v5 schema/reconnect preservation; '
        'no provider-coordinator or provider-task outcome is claimed')
    product.result['worker_kind'] = 'historical native UI with deterministic terminal routes; no managed launch is released'
    product.legacy_source = True
    product.start()
    product.open_spawn()
    original_probe, original_pair = product.probe_native_route, product.qualify_native_pair
    try:
        product.probe_native_route = historical.Product.probe_native_route.__get__(product)
        product.qualify_native_pair = historical.Product.qualify_native_pair.__get__(product)
        for record in (('c2-builder', 'Codex'), ('c2-release', 'OMP')):
            historical.Product.create_record(product, *record)
        historical.Product.initialize_orch(product)
        historical.Product.configure_orch(product, 'review_disabled')
        assert registry(product.runtime)['version'] == 4, 'the frozen producer did not create genuine v4 state'
        historical.Product.claim(product)
    finally:
        product.probe_native_route, product.qualify_native_pair = original_probe, original_pair
    assert spawn_dispatch(product)['version'] == 2
    product.result['old_helper_bundles'] = {
        str(Path(record['mailbox']['helper_path']).parent): _manifest(Path(record['mailbox']['helper_path']).parent)
        for record in saved_records(product.runtime)}
    begin_hold = {'id': 'v4-project-launch-begin', 'block': 'dispatch',
                  'act': 'spawn.begin', 'request': {'op': 'launch'}}
    loss.set([begin_hold])

    def import_saved_plan(name):
        # This runs before relinking: retain the pinned v4 source popup and path prompt.
        # Ordinary source documents, not synthetic authority/plan/task records.
        path = product.runtime.root/(name+'.md')
        path.write_text(
            '# Feature: '+name+'\n\n## IMPLEMENTATION PLAN\n\n'
            '### Checkpoint 1 - Retained native task\n\n#### Task 1A - Wait without effects\n'
            '**INDEPENDENT**\n\n### UPDATE fixture.txt\n\n'
            '- **IMPLEMENT**: Do not modify files; wait for the bounded migration fixture.\n\n'
            '### Checkpoint 2 - Saved future task\n\n#### Task 2A - Remain queued\n'
            '**INDEPENDENT**\n\n### UPDATE fixture.txt\n\n'
            '- **IMPLEMENT**: Do not modify files; wait for explicit owner permission.\n',
            encoding='utf-8')
        product.ui.command(product.controller, 'start_work')
        policy = product.ui.machine(product.controller, 'orchplus.workflow', 'workflow-index')['policy']
        assert policy.get('glitch_integration') is not False
        label = 'From a /glitch-plan file'
        if policy.get('default_work_source') != 'board':
            label += ' (Recommended)'
        product.ui.choose('Start work from…', label)
        product.ui.enter('Absolute path of the /glitch-plan file', str(path))
        def imported():
            matches = [plan for plan in registry(product.runtime)['dispatch'].get('plans', {}).values()
                       if plan['path'] == str(path)]
            assert len(matches) <= 1, 'one import duplicated saved work'
            return matches[0] if matches else None
        plan = product.lib.wait_for(imported, 'v4 actual native plan import '+name, 40)
        product.result.setdefault('project_upgrade_documents', {})[str(path)] = _sha(path.read_bytes())
        return plan

    first_plan = import_saved_plan('Pre-v5 active plan')
    captured = loss.wait('spawn', begin_hold['id'])
    request_bytes = json.loads(captured['input']['value'])['request_json']
    request = json.loads(request_bytes)
    assert request['schema'] == 2 and request['op'] == 'launch'
    entry = spawn_request(product, request)
    assert entry and entry['body']['status'] == 'claimed' and entry.get('claim')
    action = registry(product.runtime)['dispatch']['actions'][request['action_id']]
    assert action['phase'] == 'claimed' and action['request_bytes'] == request_bytes
    assert action['claim']['spawn_claim'] == {
        key: entry['claim'][key] for key in ('spawn_namespace', 'claim_nonce')}
    product.result['project_upgrade_pending'] = {
        'held_event': captured, 'request_sha256': _sha(request_bytes.encode()),
        'action': copy.deepcopy(action), 'peer_entry': copy.deepcopy(entry)}
    product.ui.command(product.controller, 'pause')
    sid = request['logical_session_id']
    product.lib.wait_for(lambda: registry(product.runtime)['dispatch']['policies'][sid]['paused'],
                         'v4 native session pause', 40)
    second_plan = import_saved_plan('Pre-v5 paused plan')
    assert first_plan['plan_id'] != second_plan['plan_id']
    old_pair = _project_upgrade_proofs(product, loss, begin_hold, legacy=True)
    old = _snapshot(product, 'v4-project-work-before-upgrade')
    before = old['stores']['orchplus']['source']
    assert before['version'] == 4 and not before['dispatch'].get('projects')
    assert before['dispatch']['policies'][sid]['paused'] is True
    assert len(before['dispatch']['plans']) == 2 and before['dispatch']['workers']
    assert sum(len(checkpoint['tasks']) for plan in before['dispatch']['plans'].values()
               for checkpoint in plan['checkpoints']) == 4
    assert any(task.get('worker_id') == request['enrolment']['worker_id']
               for plan in before['dispatch']['plans'].values()
               for checkpoint in plan['checkpoints'] for task in checkpoint['tasks'])
    assert any(task['state'] == 'queued_plan' for plan in before['dispatch']['plans'].values()
               for checkpoint in plan['checkpoints'] for task in checkpoint['tasks'])
    _zero_managed(product)
    packages = _new_packages(product, root, loss)
    # The actual current host performs local v4→v5 preservation on load. Neither
    # a rewritten version tag nor the paired protocol converter performs it.
    for plugin in ('orchplus', 'spawn'):
        _switch(product, plugin, packages)
    new_pair = _project_upgrade_proofs(product, loss, begin_hold, legacy=False)
    current, peer = registry(product.runtime), spawn_dispatch(product)
    assert current['version'] == 5 and peer['version'] == 2
    for owner in ('orch', 'spawn'):
        assert new_pair[owner]['managed_sha256'] == old_pair[owner]['managed_sha256'], \
            'presentation/project schema conversion changed '+owner+' managed peer identity'
        assert new_pair[owner]['source_namespace'] == old_pair[owner]['source_namespace']
    assert current['authority_namespace'] == before['authority_namespace']
    assert current['compatibility'] == before['compatibility']
    assert peer['namespace'] == old['stores']['spawn']['source']['namespace']
    assert current['sessions'].keys() == before['sessions'].keys()
    for logical, session in before['sessions'].items():
        restored = current['sessions'][logical]
        for field in ('orch_session_id', 'name', 'admission_seq', 'spawn_namespace',
                      'controller_generation', 'generation_floor', 'binding'):
            assert restored.get(field) == session.get(field), 'upgrade reset session '+field
        assert not restored.get('admitted'), 'upgrade silently readmitted an uncertain controller'
        for slot in ('controller', 'orchestrator'):
            owner = session.get(slot)
            retained = restored.get(slot)
            if owner is None:
                assert retained is None
                continue
            assert retained['phase'] == 'uncertain'
            for field in ('owner_id', 'generation', 'pane_binding', 'pending_executors'):
                assert retained.get(field) == owner.get(field), 'upgrade replaced occupied '+slot+' '+field
    dispatch, previous = current['dispatch'], before['dispatch']
    assert dispatch['plans'].keys() == previous['plans'].keys()
    assert dispatch['workers'].keys() == previous['workers'].keys()
    assert dispatch['actions'].keys() == previous['actions'].keys(), 'upgrade issued a new managed action'
    project_ids = set()
    for plan_id, plan in previous['plans'].items():
        converted = dispatch['plans'][plan_id]
        assert {key: value for key, value in converted.items() if key not in ('orch_project_id', 'held')} == plan
        assert converted['held'] is True
        project_id = converted['orch_project_id']
        assert project_id not in project_ids, 'different saved plans were collapsed into one project'
        project_ids.add(project_id)
        project = dispatch['projects'][project_id]
        assert project['orch_project_id'] == project_id and project['logical_session_id'] == plan['logical_session_id']
        assert project['name'] == plan['title'] and project['started'] is False and not project.get('finished')
        assert project['sources'] == [{'kind': 'plan', 'ref': plan['path'], 'revision': plan['plan_revision']}]
        for checkpoint in converted['checkpoints']:
            for task in checkpoint['tasks']:
                if task.get('worker_id'):
                    worker = dispatch['workers'][task['worker_id']]
                    assert worker['work_id'] == task['work_id']
                    assert worker['orch_project_id'] == project_id and worker['logical_session_id'] == plan['logical_session_id']
    assert set(dispatch['projects']) == project_ids, 'upgrade invented or orphaned a project'
    assert not dispatch['finished_projects']
    for worker_id, worker in previous['workers'].items():
        retained = dispatch['workers'][worker_id]
        assert retained['continuation_required'] is True
        for field in ('worker_id', 'work_id', 'logical_session_id', 'worker_generation', 'launch_request_id',
                      'record_id', 'record_revision', 'enrolment_token', 'mailbox_handle', 'binding_digest',
                      'manifest_sha256', 'origin_binding', 'controller_pane', 'pane_binding', 'phase'):
            assert retained.get(field) == worker.get(field), 'upgrade reset worker '+field
    for logical, policy in previous['policies'].items():
        retained = dispatch['policies'][logical]
        assert {key: value for key, value in retained.items() if key != 'auto_start_projects'} == {
            key: value for key, value in policy.items() if key != 'auto_launch_intake'}
        assert retained['auto_start_projects'] is False and retained['paused'] is True
    retained_action = dispatch['actions'][request['action_id']]
    assert retained_action['phase'] == 'uncertain'
    assert retained_action['request_bytes'] == request_bytes and retained_action['claim'] == action['claim']
    retained_peer = spawn_request(product, request)
    assert retained_peer and retained_peer['request_json'] == request_bytes
    assert retained_peer['claim'] == entry['claim'] and retained_peer['body']['status'] == 'uncertain'
    assert retained_peer.get('native_result') is None and retained_peer.get('relay_result') is None, \
        'upgrade fabricated a successful effect'
    def archived_original():
        kv = read_json(product.runtime.config/'plugin-data/orchplus/kv.json')
        files = list((product.runtime.config/'plugin-data/orchplus/upgrade-evidence').glob('v4-*.json'))
        assert len(files) <= 1, 'one upgrade archived different historical originals'
        return files[0] if len(files) == 1 and 'authority_state_v4_original' not in kv else None
    archive = product.lib.wait_for(archived_original, 'native v5 window readback archives exact v4 original', 40)
    raw = archive.read_bytes()
    original = json.loads(raw)
    assert archive.name == 'v4-'+_sha(raw)+'.json' and original['version'] == 4
    assert original['authority_namespace'] == before['authority_namespace']
    assert original['dispatch']['plans'] == previous['plans']
    assert original['dispatch']['actions'][request['action_id']]['request_bytes'] == request_bytes
    assert original['dispatch']['actions'][request['action_id']]['claim'] == action['claim']
    product.result['project_upgrade_original'] = {'path': str(archive), 'sha256': _sha(raw), 'source': original}
    projection = product.ui.machine(product.controller, 'orchplus.projects', 'project-index')
    assert projection and projection['version'] == 5
    assert set(projection['projects']) == project_ids
    assert all(project['orch_project_id'] == key and project['started'] is False
               for key, project in projection['projects'].items())
    product.result['project_upgrade_projection'] = projection
    _zero_managed(product)
    held_begin = loss.observed('spawn', begin_hold['id'])
    assert held_begin and held_begin['kind'] == 'block_event'
    assert held_begin['count'] == captured['count'], 'current code re-sent the held pre-upgrade launch'
    product.result['project_upgrade_final_begin_hold'] = held_begin
    final = _snapshot(product, 'v5-project-work-held')
    assert final['effects']['launches'] == old['effects']['launches'], 'upgrade changed native launch history'
    for path, digest in product.result['project_upgrade_documents'].items():
        assert _sha(Path(path).read_bytes()) == digest, 'upgrade rewrote the original saved plan'
    product.capture('v5-project-upgrade-held')
    product.result['checks'].append(
        'manifest-pinned v4 native UI imports two plans and four tasks; current local v5 upgrade preserves '
        'plan/task/project parents, source documents, session pause, occupied owners and exact uncertain '
        'request/grant/peer claim; both native managed identity digests unchanged; one Update / reconnect '
        'refuses unresolved effects without launch, replay or provider-success claims')


def _fresh(product):
    initialize(product)
    peer, authority = spawn_dispatch(product), registry(product.runtime)
    assert peer['version'] == 2
    assert not peer.get('migration') and not authority.get('migration')
    assert authority['compatibility']['spawn_namespace'] == peer['namespace']
    _zero_managed(product)
    coordinator = ensure_fixture_coordinator(product, deadline=time.monotonic()+240)
    product.result['fresh_coordinator'] = provider_coordinator_identity(product, coordinator)
    assigned = assign_idle_worker(product)
    def assignment_effect():
        proposals = product.result.get('hybrid_coordinator_proposals', [])
        matching = [entry for entry in proposals
                    if entry['requested'].get('kind') == 'new_work'
                    and entry['requested'].get('record_id') == 'c2-builder']
        assert len(matching) == 1, 'one exact native coordinator proposal must admit the task'
        proposal = matching[0]
        assert proposal['accepted_report']['worker_id'] == coordinator['worker_id']
        current = registry(product.runtime)['dispatch']['workers'][assigned['worker_id']]
        assert current['prompt'] == proposal['requested']['prompt']
        assert current['record_id'] == proposal['requested']['record_id']
        assert current['logical_session_id'] == coordinator['logical_session_id']
        assert not current.get('project_held'), 'actual owner START did not release task'
        product.result['assignment_diagnostic'] = {'proposal': proposal, 'worker': current}
        launch = next(iter(native_launches(product)), None)
        if launch:
            assert launch['worker_id'] == current['worker_id']
            assert launch['mailbox_handle'] == current['mailbox_handle']
        return launch
    launch = product.lib.wait_for(assignment_effect, 'fresh paired actual native worker', 90)
    assert len(native_launches(product)) == 1
    product.result['effect'] = {'launch': launch, 'process': process_identity(launch['pid'])}
    _snapshot(product, 'fresh-paired-effect')
    product.result['checks'].append('existing Product fresh native inspect/prepare/finish/admit route precedes one actual managed effect')


def _case(base, source, root, evidence, processes, lib, args, name, body):
    receipt = {'status': 'failed', 'checks': [], 'captures': {}, 'case': name}
    evidence.setdefault('c3_cases', {})['paired-migration-'+name] = receipt
    product, protected = None, {}
    try:
        product = Product(base, source, evidence, processes, lib, 'paired-migration-'+name, args)
        receipt.update(product.result)
        product.result = receipt
        target = product.worker.with_name('recovery_worker.py')
        shutil.copy2(TESTS/'recovery_worker.py', target)
        product.worker = target
        receipt['fixture_sources'].update({name: _sha((TESTS/name).read_bytes()) for name in
                                           ('recovery_worker.py', 'product_paired_migration.py')})
        loss = EventLoss(product)
        for package in (product.spawn, product.orch):
            configuration_path = package/'product-probe.json'
            configuration = json.loads(configuration_path.read_text(encoding='utf-8'))
            configuration['recovery_trace'] = True
            write_json(configuration_path, configuration)
        # EventLoss config is installed BEFORE preserving old linked paths.
        protected = {path: _manifest(path) for path in (product.spawn, product.orch)}
        receipt['old_linked_paths'] = {str(path): {'files': manifest, 'manifest_sha256': _digest(manifest)}
                                     for path, manifest in protected.items()}
        body(product, root, loss)
        assert receipt['checks'], 'no observed migration acceptance'
        receipt['status'] = 'passed'
    except PrerequisiteUnavailable as error:
        receipt['status'], receipt['missing_prerequisite'] = 'unavailable', str(error)
    except Exception as error:
        receipt['error'] = f'{type(error).__name__}: {error}'
        receipt['failure_traceback'] = traceback.format_exc()
        if product and hasattr(product, 'ui'):
            try:
                product.capture('paired-migration-failure')
            except Exception as capture_error:
                receipt['capture_error'] = str(capture_error)
    finally:
        for path, manifest in receipt.get('old_helper_bundles', {}).items():
            try:
                assert _manifest(Path(path)) == manifest, 'old helper bundle changed: '+path
            except Exception as error:
                receipt['status'] = 'failed'
                receipt.setdefault('preservation_errors', []).append(str(error))
        for path, manifest in protected.items():
            try:
                assert _manifest(path) == manifest, 'old linked source/helper bytes changed: '+str(path)
            except Exception as error:
                receipt['status'] = 'failed'
                receipt.setdefault('preservation_errors', []).append(str(error))
        receipt['old_linked_paths_preserved'] = bool(protected) and not receipt.get('preservation_errors')
        if product:
            try:
                product.close()
            except Exception as error:
                receipt['status'], receipt['cleanup_error'] = 'failed', str(error)
                try:
                    product.runtime.stop()
                except Exception as stop_error:
                    receipt['supervisor_cleanup_error'] = str(stop_error)
    return receipt


def paired_migration(base, root, evidence, processes, lib, args):
    scenarios = [
        ('fresh-current-pair', 'current', lambda p, r, loss: _fresh(p)),
        ('v5-project-state-upgrade', 'v4', _v5_project_upgrade),
        ('old-empty-orch-first', 'c2', lambda p, r, loss: _positive(p, r, loss, False, 'orchplus')),
        ('old-active-spawn-first', 'c2', lambda p, r, loss: _positive(p, r, loss, True, 'spawn')),
        ('mixed-new-spawn-old-orch', 'c2', lambda p, r, loss: _mixed_case(p, r, loss, 'spawn')),
        ('mixed-new-orch-old-spawn', 'c2', lambda p, r, loss: _mixed_case(p, r, loss, 'orchplus')),
        ('old-immutable-pending', 'c2', _pending),
        ('old-effect-unconsumed', 'c2', lambda p, r, loss: _pending(p, r, loss, executed=True)),
        ('complete-source-mismatch', 'c2', lambda p, r, loss: _source_fault(p, r, loss, 'orch', 'mismatch')),
    ]
    for owner in ('orch', 'spawn'):
        for fault in ('missing', 'corrupt'):
            scenarios.append((owner+'-initialized-'+fault, 'c2',
                              lambda p, r, loss, owner=owner, fault=fault: _source_fault(p, r, loss, owner, fault)))
    selected, selection = select_runtime_cases(args, 'lifecycle/migration',
                                               [name for name, _, _ in scenarios])
    result = {'status': 'not_run', 'checks': [], 'cases': {}, 'selection': selection,
              'qualification_complete': False, 'limits': [
        'Linux owned native desktop; genuine Native OMP coordinators plus deterministic helper-backed workers, not provider task-quality qualification.',
        'Private observational/event-loss wrappers are not byte-identical shipping media.',
        'All migration controls use native UI; only explicitly labelled source-loss/restore faults alter isolated KV.',
        'Failure/unavailable/unrun cases remain qualification blockers; no component-suite substitute.',
    ]}
    result['coverage_mapping'] = {
        'package_order': ['old-empty-orch-first', 'old-active-spawn-first'],
        'project_schema': {'case': 'v5-project-state-upgrade', 'source_record': str(V4_RECORD),
                           'contract': 'Genuine v4 native saved plans/tasks become held v5 projects; occupied owners, uncertain grants and both managed peer digests survive current one-action reconnect.'},
        'native_replacement': 'One visible Update / reconnect; actual source inspection, SPAWN-first preparation, prepared reload, stale-input refusal and automatic paired finish.',
        'lower_level_order': {
            'source': 'plugins/tern/SPAWN/tests/dispatch_migration.luau',
            'contract': 'Stale candidate source cannot finish; fresh already-stable peer permits second-owner finish.',
            'verification': 'Separate native module execution required; this driver does not mark it passed.'},
        'lower_level_no_replay': {
            'source': 'plugins/tern/SPAWN/tests/window_migration.luau',
            'contract': 'Changed source/window and reload cannot adopt or replay a submitted migration challenge.',
            'verification': 'Separate native module execution required; not substituted for these native cells.'},
    }
    evidence['paired_migration'] = result
    if not selected:
        return result
    result['status'] = 'failed'
    unavailable = prerequisites()
    if unavailable:
        result.update(status='unavailable', missing_prerequisite=unavailable)
        return result
    protected = {}
    try:
        protected = {path: _manifest(path) for path in (root/'plugins/tern/SPAWN', root/'plugins/tern/ORCH+')}
        result['current_source_manifests'] = {str(path): _digest(value) for path, value in protected.items()}
    except Exception as error:
        result['status'], result['missing_prerequisite'] = 'unavailable', f'{type(error).__name__}: {error}'
        return result
    sources, unavailable_sources = {'current': root}, {}
    required_sources = {kind for name, kind, _ in scenarios if name in selected}
    for kind, frozen, load in (('c2', FROZEN, lambda: _legacy_source(base, args, result)),
                               ('v4', V4_FROZEN, lambda: _v4_source(base, result))):
        if kind not in required_sources:
            continue
        try:
            protected[frozen] = _manifest(frozen)
            sources[kind] = load()
            protected[sources[kind]] = _manifest(sources[kind])
        except Exception as error:
            unavailable_sources[kind] = f'{type(error).__name__}: {error}'
    if unavailable_sources:
        result['unavailable_sources'] = unavailable_sources
    for name, kind, body in scenarios:
        if name not in selected:
            continue
        source = sources.get(kind)
        if source is None:
            result['cases'][name] = {'status': 'unavailable', 'checks': [],
                                     'missing_prerequisite': unavailable_sources[kind]}
        else:
            result['cases'][name] = _case(base, source, root, evidence, processes, lib, args, name, body)
            if kind == 'v4':
                result['cases'][name]['source_provenance'] = result['v4_provenance']
    try:
        preserved = all(_manifest(path) == before for path, before in protected.items())
    except Exception as error:
        preserved = False
        result['source_preservation_error'] = str(error)
    result['source_preservation'] = {'verified_paths': [str(path) for path in protected],
                                     'unchanged': preserved, 'legacy_provenance_available': 'c2' in sources,
                                     'v4_provenance_available': 'v4' in sources}
    statuses = [case['status'] for case in result['cases'].values()]
    if preserved and statuses and all(status == 'passed' for status in statuses):
        result['status'] = 'passed'
        result['checks'].append('selected actual-native paired migration cells observed; frozen/current sources and old linked helper paths unchanged; owned Product cleanup used')
    elif 'failed' not in statuses and preserved:
        result['status'] = 'unavailable'
    result['qualification_complete'] = result['status'] == 'passed' and not selection['unrun']
    return result

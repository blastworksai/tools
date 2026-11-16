"""C4 native windows, real Git identities and ordinary owner/grant controls."""
import copy
import hashlib
import shlex
import shutil
import sys
import time
import traceback

from product_c2 import (Product, additional_window, approve_landing, ensure_fixture_coordinator, git, landing_for, owner_assignment,
                        prerequisites, provider_coordinator_identity, worker_command, worker_observations)
from product_c3 import select_runtime_cases, write_json
from product_scenario import TESTS, read_json, registry


CASES = ('worktrees', 'stale-head', 'shared', 'targets', 'repositories', 'repository-queue', 'late-results')


def configure_repository(product, checkout, target, route):
    """Associate this actual project, never mutate a global defaults repository."""
    repository = product.configure_repository(checkout, target, route)
    common = git(product.runtime, checkout, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    assert repository['common_dir'] == common
    assert repository['target_ref'] == target and repository['queue_route'] == route
    return repository


def assign(product, record):
    ui, pane = product.ui, product.controller
    check = 'fixture: '+shlex.join([sys.executable, '-c',
            "from pathlib import Path; raise SystemExit(0 if Path('fixture.txt').read_text().splitlines()[0]=='good' else 7)"])
    deadline = time.monotonic()+90
    queued = owner_assignment(product, record, (
        ('Explicit assignment for '+record,
         'C2_CASE=passed C4 controlled repository qualification; only fixture.txt is declared. Await the scenario command.'),
        ('Declared files', 'fixture.txt'), ('Checks (one per line', check),
        ('Base ref', 'refs/heads/main')), deadline=deadline)
    def accepted():
        scope = ui.machine(pane, 'orchplus.dispatch', 'dispatch-state')
        dispatch = (registry(product.runtime) or {}).get('dispatch', {})
        workers = dispatch.get('workers', {})
        # Intake alone is not settled enrollment: publishing its ACK and
        # consuming the helper receipt still mutate the shared authority.
        # Finish that real obligation before opening the next owner prompt.
        return next((worker for worker in workers.values() if worker['worker_id'] == queued['worker_id']
                     and worker['logical_session_id'] == (scope or {}).get('orch_session_id')
                     and worker['phase'] == 'accepted'
                     and worker['compacted_floor'] == worker['accepted_seq']
                     and not worker.get('receipts') and not worker.get('compaction_pending')
                     and not any(action.get('worker_id') == worker['worker_id']
                                 for action in dispatch.get('actions', {}).values())), None)
    return product.lib.wait_for(accepted, 'actual C4 managed worker enrollment and receipt settlement '+record,
                                max(0, deadline-time.monotonic()))


def answer_sharing(product, worker):
    def pending():
        return next((gate for gate in registry(product.runtime)['dispatch']['gates'].values()
                     if gate['worker_id'] == worker['worker_id'] and gate['kind'] == 'shared_checkout'
                     and gate['phase'] == 'pending'), None)
    gate = product.lib.wait_for(pending, 'actual canonical shared-worktree owner question', 40)
    product.ui.question_click(product.controller, gate['question'])
    choice, = [choice for choice in gate['options'] if choice['id'] == 'acknowledge']
    product.ui.choose(gate['question'], choice['label'])
    # Host-consumed checkout questions intentionally have no free-text prompt.
    def resolved():
        current = registry(product.runtime)['dispatch']['gates'].get(gate['id'])
        return current if current and current.get('answer', {}).get('choice_id') == 'acknowledge' else None
    return product.lib.wait_for(resolved, 'single explicit sharing acknowledgement', 40)


def held_grant(product, item_id):
    def current():
        item = registry(product.runtime)['dispatch']['landing']['items'][item_id]
        if not item.get('grants'):
            return None
        holder = registry(product.runtime)['dispatch']['workers'][item['grants'][-1]['worker_id']]
        events = worker_observations(product, holder['mailbox_handle'])['events']
        return holder if any(event['kind'] == 'grant_held' and event['landing_id'] == item_id
                             and event.get('grant_id') == item['grants'][-1]['grant_id'] for event in events) else None
    return product.lib.wait_for(current, 'exact native release manager has claimed its grant', 90)


def late_results(product, other, first, second, item_a, item_b, manager_a, manager_b):
    """Order genuine Git reads at the owned worker, not synthetic HOST results.

    Two external-route grants expect H0. A lands H1; B reads H1 but holds its
    stale-target report. A then lands H2 before B publishes the unchanged H1
    observation through its enrolled helper. Only the native owner's read-only
    reconciliation and a fresh exact approval can authorize B's replacement.
    """
    runtime, lib, result = product.runtime, product.lib, product.result
    evidence = result['late_results'] = {'original_requests': [item_a, item_b]}

    def item(item_id):
        return registry(runtime)['dispatch']['landing']['items'][item_id]

    def heads():
        return {key: value['head'] for key, value in
                registry(runtime)['dispatch']['landing']['queues'].items()}

    def grants():
        return {key: [{'grant_id': grant['grant_id'], 'bytes': grant['bytes']}
                      for grant in value['grants']]
                for key, value in registry(runtime)['dispatch']['landing']['items'].items()}

    def events(owner, worker, kind):
        return [event for event in worker_observations(owner, worker['mailbox_handle'])['events']
                if event['kind'] == kind]

    def next_request(owner, worker, previous):
        worker_command(owner, worker['mailbox_handle'], 'advance')
        return lib.wait_for(
            lambda: next((value for value in registry(runtime)['dispatch']['landing']['items'].values()
                          if value['worker_id'] == worker['worker_id']
                          and value['request']['source_revision'] != previous['request']['source_revision']
                          and value['status'] not in ('landed', 'failed', 'cancelled')), None),
            'fresh actual Git artifact and native landing request', 40)

    original_head = git(runtime, product.repository, 'rev-parse', 'refs/heads/main')
    assert item_a['request']['target_revision'] == item_b['request']['target_revision'] == original_head
    evidence['original_head'] = original_head
    evidence['original_grants'] = grants()
    worker_command(product, manager_a['mailbox_handle'], 'landed')
    head_one = git(runtime, product.repository, 'rev-parse', 'refs/heads/main')
    assert head_one == item_a['request']['source_revision'] and head_one != original_head
    worker_command(other, manager_b['mailbox_handle'], 'capture-stale')
    delayed, = events(other, manager_b, 'result_delayed')
    assert delayed['observed_head'] == head_one
    assert delayed['result']['observed_target_revision'] == head_one
    assert delayed['result']['target_revision'] == original_head
    assert not item(item_b['id'])['grants'][-1].get('result')
    evidence['delayed_original_observation'] = delayed

    item_c = next_request(product, first, item_a)
    assert item_c['request']['target_revision'] == head_one
    approve_landing(product, first, item_c)
    manager_c = held_grant(product, item_c['id'])
    worker_command(product, manager_c['mailbox_handle'], 'landed')
    head_two = git(runtime, product.repository, 'rev-parse', 'refs/heads/main')
    assert head_two == item_c['request']['source_revision']
    assert len({original_head, head_one, head_two}) == 3
    before_late = grants()
    evidence.update(newer_head=head_two, newer_request=item_c,
                    newer_result=item(item_c['id']), heads_before_late=heads(),
                    issued_grants_before_late=before_late)
    assert all(head['revision'] == head_two for head in heads().values())
    worker_command(other, manager_b['mailbox_handle'], 'deliver-stale')

    def unordered():
        current = item(item_b['id'])
        return current if (current['grants'][-1].get('uncertain') or {}).get('code') == 'repository_head_unordered' else None

    late = lib.wait_for(unordered, 'actual late helper result is retained as unordered', 40)
    delivered, = events(other, manager_b, 'delayed_result_delivered')
    assert delivered['result'] == delayed['result'] and delivered['reply'] == delayed['reply']
    assert late['grants'][-1]['late_result']['outcome'] == 'stale_target'
    assert late['grants'][-1]['late_result']['observed_target_revision'] == head_one
    assert not late['grants'][-1].get('result') and not late['grants'][-1].get('reconciliation')
    assert not late.get('refresh') and not events(other, second, 'refresh_requested'), 'unordered evidence issued an obsolete refresh'
    assert grants() == before_late, 'late observation erased or replayed an issued grant'
    assert all(head['revision'] == head_two for head in heads().values())
    assert git(runtime, product.repository, 'rev-parse', 'refs/heads/main') == head_two
    evidence.update(late_result=late, delivered_original=delivered, heads_after_late=heads())

    item_d = next_request(product, first, item_c)
    assert item_d['request']['target_revision'] == head_two
    approve_landing(product, first, item_d)

    def blocked():
        current = item(item_d['id'])
        return current if (current.get('hold') or {}).get('code') == 'repository_head_unordered' else None

    blocked_item = lib.wait_for(blocked, 'unordered evidence blocks even a fresh approved request', 40)
    assert blocked_item.get('approval') and not blocked_item['grants']
    evidence['blocked_fresh_approved_request'] = blocked_item
    held_before_picker = copy.deepcopy(item(item_b['id'])['grants'])
    picker_title = 'Reconcile uncertain landing '+item_b['id']
    picker_start = len(other.ui.inputs)

    other.ui.command(other.controller, 'reconcile_landing')
    other.ui.choose(picker_title, 'Keep the slot held')
    assert item(item_b['id'])['grants'] == held_before_picker
    assert not item(item_d['id'])['grants']
    # The attestation below is backed by independent read-only inspection of the
    # actual owned ref and reflog, not by the older held report.
    current_head = git(runtime, product.repository, 'rev-parse', 'refs/heads/main')
    reflog = git(runtime, product.repository, 'reflog', 'show', '--format=%H', 'refs/heads/main').splitlines()
    assert current_head == head_two and head_two in reflog and head_one in reflog
    assert item_b['request']['source_revision'] not in reflog
    evidence['read_only_reconciliation_inspection'] = {'current_head': current_head, 'reflog': reflog}
    other.ui.command(other.controller, 'reconcile_landing')
    other.ui.choose(picker_title, 'I observed it NOT landed')
    other.ui.prompt('Observed current target head revision (required to resolve unordered results)', current_head)
    other.ui.prompt('Evidence of your read-only inspection',
                    'Owned Git ref and reflog inspected: current '+current_head+
                    '; delayed read '+head_one+'; this granted source is absent from the target reflog.')

    def reconciled():
        current = item(item_b['id'])
        reconciliation = current['grants'][-1].get('reconciliation') or {}
        return current if reconciliation.get('outcome') == 'not_landed' else None

    settled = lib.wait_for(reconciled, 'native selected reconciliation records the actual current head', 40)
    assert settled['grants'][-1]['reconciliation']['target_revision'] == head_two
    assert len(settled['grants']) == 1 and not settled.get('approval') and settled['refresh_required']
    assert all(head['revision'] == head_two for head in heads().values())
    picker_inputs = [entry for entry in other.ui.inputs[picker_start:]
                     if entry.get('op') == 'native_picker' and entry.get('title') == picker_title]
    assert [(entry['label'], entry['control'].get('aria-selected')) for entry in picker_inputs] == [
        ('Keep the slot held', 'true'), ('I observed it NOT landed', 'true')]
    evidence['native_picker_inputs'] = picker_inputs
    evidence.update(reconciled=settled, heads_after_reconciliation=heads())
    manager_d = held_grant(product, item_d['id'])
    # Settle the independently approved control without moving the current head.
    worker_command(product, manager_d['mailbox_handle'], 'rejected')
    fresh = next_request(other, second, item_b)
    assert fresh['id'] == item_b['id'] and fresh['request']['target_revision'] == head_two
    assert len(fresh['grants']) == 1 and not fresh.get('approval')
    assert fresh['grants'][0]['bytes'] == before_late[item_b['id']][0]['bytes']
    evidence['fresh_request_before_approval'] = fresh
    approve_landing(other, second, fresh)
    final_manager = held_grant(other, fresh['id'])
    approved = item(fresh['id'])
    assert len(approved['grants']) == 2 and approved['approval']['gate_id'] == fresh['gate_id']
    assert approved['grants'][-1]['target_revision'] == head_two
    assert approved['proof']['artifact_revision'] == fresh['request']['source_revision']
    worker_command(other, final_manager['mailbox_handle'], 'landed')
    assert git(runtime, product.repository, 'rev-parse', 'refs/heads/main') == fresh['request']['source_revision']
    final_grants = grants()
    for item_id, issued in before_late.items():
        assert final_grants[item_id][:len(issued)] == issued
    manager_ids = {manager['mailbox_handle'] for manager in (manager_a, manager_b, manager_c, manager_d, final_manager)}
    grant_deliveries = [event['grant_id'] for handle in manager_ids
                        for event in worker_observations(product, handle)['events'] if event['kind'] == 'grant_held']
    expected_ids = [grant['grant_id'] for issued in final_grants.values() for grant in issued]
    assert len(grant_deliveries) == len(set(grant_deliveries)) and set(grant_deliveries) == set(expected_ids)
    evidence.update(final_item=item(fresh['id']), final_grants=final_grants, grant_deliveries=grant_deliveries,
                    helper_observations={handle: worker_observations(product, handle) for handle in manager_ids})
    result['checks'].append('Actual H0/H1/H2 Git reads delivered out of order preserve H2 and every issued grant; unordered evidence blocks new grants, native picker reconciliation preserves H2, and only fresh checks plus a new exact owner approval land the replacement once')
    result['limits'].append('Owned deterministic repository-worker ordering, not real-provider proof or external branch-protection qualification; no product state or successful receipt is injected')


def repository_case(base, root, evidence, processes, lib, args, case):
    product = Product(base, root, evidence, processes, lib, 'repository-'+case, args, assignment_trace=True)
    runtime, result = product.runtime, product.result
    result.update(case=case, qualification_scope='one native authority/data directory; independent real session controllers; genuine Native OMP coordinators with deterministic repository workers, not provider-worker qualification')
    health = None
    other = None
    try:
        original = product.repository
        a, b = runtime.root/'worktree-a', runtime.root/'worktree-b'
        git(runtime, original, 'worktree', 'add', '--detach', str(a), 'main')
        if case == 'repositories':
            # The clone has independent native common-directory identity.
            git(runtime, original, 'clone', '--quiet', str(original), str(b))
            git(runtime, b, 'config', 'user.name', 'C4 fixture')
            git(runtime, b, 'config', 'user.email', 'c4@example.invalid')
        elif case != 'shared':
            git(runtime, original, 'worktree', 'add', '--detach', str(b), 'main')
        alias = runtime.root/'checkout-alias'
        alias.symlink_to(a if case == 'shared' else b, target_is_directory=True)
        if case == 'targets':
            git(runtime, original, 'branch', 'release', 'main')
        scene = {'case': case, 'targets': {'c2-builder': 'refs/heads/main',
                                         'c4-builder': 'refs/heads/release' if case == 'targets' else 'refs/heads/main'}}
        write_json(product.control/'repository-scene.json', scene)
        worker = product.worker.parent/'repository_worker.py'
        shutil.copy2(TESTS/'repository_worker.py', worker)
        product.worker = worker
        result['fixture_sources']['repository_worker.py'] = hashlib.sha256(worker.read_bytes()).hexdigest()
        result['fixture_sources']['product_repository.py'] = hashlib.sha256((TESTS/'product_repository.py').read_bytes()).hexdigest()
        product.start(); product.open_spawn()
        for record, cwd, provider in (('c2-builder', a, 'Codex'), ('c4-builder', alias, 'Codex'), ('c2-release', original, 'OMP')):
            product.repository = cwd
            product.create_record(record, provider)
        product.repository = original
        product.initialize_orch()
        product.configure_orch('review_disabled')
        product.claim()
        route = 'repository_queue' if case in ('repository-queue', 'late-results') else 'orch_queue'
        result['first_project_repository'] = configure_repository(product, original, 'refs/heads/main', route)
        ui2 = additional_window(product)
        other = copy.copy(product)
        other.ui = ui2
        other.initialize_orch()
        other.claim()
        result['second_project_repository'] = configure_repository(
            other, b if case == 'repositories' else original, scene['targets']['c4-builder'], route)
        def worker_health():
            for path in product.control.glob('*/error.json'):
                failure = read_json(path)
                assert not failure, 'actual repository worker failed: '+str(path)
        health = worker_health
        lib.WAKERS.append(health)
        coordinators = [ensure_fixture_coordinator(owner, deadline=time.monotonic()+240)
                        for owner in (product, other)]
        assert coordinators[0]['worker_id'] != coordinators[1]['worker_id']
        assert coordinators[0]['logical_session_id'] != coordinators[1]['logical_session_id']
        result['session_coordinators'] = [provider_coordinator_identity(owner, coordinator)
                                          for owner, coordinator in zip((product, other), coordinators)]
        first, second = assign(product, 'c2-builder'), assign(other, 'c4-builder')
        assert first['logical_session_id'] != second['logical_session_id']
        for worker, coordinator in zip((first, second), coordinators):
            assert worker['logical_session_id'] == coordinator['logical_session_id']
            assert worker['worker_id'] != coordinator['worker_id']
            assert not worker.get('coordinator_owner_id')
        worker_command(product, first['mailbox_handle'], 'prepare')
        worker_command(other, second['mailbox_handle'], 'prepare')
        if case == 'shared':
            result['sharing_decision'] = answer_sharing(other, second)
        state = registry(runtime)
        first_now, second_now = (state['dispatch']['workers'][entry['worker_id']] for entry in (first, second))
        same_repository = case != 'repositories'
        assert (first_now['checkout']['common_dir'] == second_now['checkout']['common_dir']) == same_repository
        assert (first_now['checkout']['worktree_path'] == second_now['checkout']['worktree_path']) == (case == 'shared')
        result['checkout_evidence'] = [{key: row['checkout'].get(key) for key in ('common_dir', 'worktree_path', 'head', 'host_key')}
                                       for row in (first_now, second_now)]
        item_a = lib.wait_for(lambda: landing_for(product, first['worker_id']), 'first native landing request', 30)
        item_b = lib.wait_for(lambda: landing_for(other, second['worker_id']), 'second native landing request', 30)
        approve_landing(product, first, item_a)
        manager_a = held_grant(product, item_a['id'])
        approve_landing(other, second, item_b)
        independent = case in ('targets', 'repositories', 'repository-queue', 'late-results')
        if independent:
            manager_b = held_grant(other, item_b['id'])
            result['checks'].append('Both independent routes receive their own normally approved native release grants')
            if case == 'late-results':
                late_results(product, other, first, second, item_a, item_b, manager_a, manager_b)
            elif case == 'repository-queue':
                state = registry(runtime)
                assert all(queue.get('slot') is None for queue in state['dispatch']['landing']['queues'].values())
                worker_command(product, manager_a['mailbox_handle'], 'uncertain')
                worker_command(other, manager_b['mailbox_handle'], 'rejected')
                state = registry(runtime)
                assert state['dispatch']['landing']['items'][item_a['id']]['grants'][-1].get('uncertain')
                assert state['dispatch']['landing']['items'][item_b['id']]['status'] == 'failed'
                result['limits'].append('repository_queue proves the explicit declaration, no competing local slot and exact result handling; it does not certify any external service branch protection')
            else:
                worker_command(product, manager_a['mailbox_handle'], 'landed')
                worker_command(other, manager_b['mailbox_handle'], 'landed')
                assert git(runtime, original, 'rev-parse', 'refs/heads/main') == item_a['request']['source_revision']
                assert git(runtime, b if case == 'repositories' else original, 'rev-parse', scene['targets']['c4-builder']) == item_b['request']['source_revision']
                result['checks'].append('Both real independent Git targets moved to only their exact granted revisions')
        else:
            def waiting():
                item = landing_for(other, second['worker_id'])
                return item if item and item.get('approval') and (item.get('hold') or {}).get('code') == 'repository_wait' else None
            pending = lib.wait_for(waiting, 'second session waits on the same canonical target', 40)
            assert not pending['grants']
            result['checks'].append('Actual worktrees/aliases and distinct sessions share one local target slot after separate owner approvals')
            worker_command(product, manager_a['mailbox_handle'], 'landed' if case == 'stale-head' else 'rejected')
            if case == 'stale-head':
                def stale():
                    current = landing_for(other, second['worker_id'])
                    return current if (current.get('hold') or {}).get('code') == 'target_moved' else None
                stale_item = lib.wait_for(stale, 'cross-session actual target movement invalidates stale approval', 40)
                assert not stale_item['grants']
                lib.wait_for(lambda: any(event['kind'] == 'refresh_requested' for event in
                             worker_observations(other, second['mailbox_handle'])['events']),
                             'builder receives the exact changed-target refresh obligation', 40)
                worker_command(other, second['mailbox_handle'], 'refresh')
                def refreshed():
                    current = landing_for(other, second['worker_id'])
                    return current if (current and current['request']['source_revision'] != item_b['request']['source_revision']
                                       and (current.get('hold') or {}).get('code') == 'approval_pending') else None
                refreshed_item = lib.wait_for(refreshed, 'refreshed actual artifact waits for new owner approval', 40)
                assert not refreshed_item['grants']
                assert refreshed_item['request']['target_revision'] == git(runtime, original, 'rev-parse', 'refs/heads/main')
                approve_landing(other, second, refreshed_item)
                manager_b = held_grant(other, refreshed_item['id'])
                worker_command(other, manager_b['mailbox_handle'], 'landed')
                assert git(runtime, original, 'rev-parse', 'refs/heads/main') == refreshed_item['request']['source_revision']
                result['checks'].append('Actual target movement refuses the stale grant; refreshed artifact/checks wait for new explicit approval and only that exact revision lands')
            else:
                manager_b = held_grant(other, item_b['id'])
                assert manager_b['logical_session_id'] == second['logical_session_id']
                worker_command(other, manager_b['mailbox_handle'], 'landed')
                assert git(runtime, original, 'rev-parse', 'refs/heads/main') == item_b['request']['source_revision']
                result['checks'].append('First-session settlement advances the second native owner and lands exactly its granted commit')
        result['surfaces'] = {'first': product.ui('surface', pane=product.controller),
                              'second': other.ui('surface', pane=other.controller)}
        product.capture('repository-final')
        result['status'] = 'passed'
    except Exception as error:
        result.update(status='failed', error=f'{type(error).__name__}: {error}', failure_traceback=traceback.format_exc())
        if other is not None:
            result['second_window_inputs'] = getattr(other.ui, 'inputs', [])
            try:
                result['second_window_failure_surface'] = other.ui('surface', pane=other.controller)
            except Exception as capture_error:
                result['second_window_capture_error'] = str(capture_error)
    finally:
        if health in lib.WAKERS:
            lib.WAKERS.remove(health)
        product.close()
    return result


def repository(base, root, evidence, processes, lib, args):
    unavailable = prerequisites()
    if unavailable:
        return {'status': 'unavailable', 'reason': unavailable}
    selected, inventory = select_runtime_cases(args, 'repository', CASES)
    result = {'status': 'not_run', 'cases': {}, 'runtime_cells': inventory, 'qualification_complete': False}
    for case in CASES:
        if case in selected:
            result['cases'][case] = repository_case(base, root, evidence, processes, lib, args, case)
    if result['cases']:
        result['status'] = 'passed' if all(case['status'] == 'passed' for case in result['cases'].values()) else 'failed'
        result['qualification_complete'] = result['status'] == 'passed' and not inventory['unrun']
    return result

"""C3 existing-document rulings through conversation-first native controls.

Source intake, existing-document paths and settings use native form panes;
actual owner decisions and written answers retain their floating prompts.
Worker diagnostics and fenced owner recovery use Advanced, never fabricated requests.
Private receipts retain exact captured negative events, not public media.
Parser combinatorics remain in the canonical native module suites.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import time
import traceback

from product_c2 import (Product, additional_window, ensure_fixture_coordinator, native_nodes, owner_assignment, owner_setup_input, prerequisites,
                        provider_coordinator_identity, provider_coordinator_prompt, saved_records, surface_nodes, worker_command, worker_observations)
from product_c3 import EventLoss, initialize, select_runtime_cases, write_json
from product_scenario import TESTS, registry, read_json, trace

REFERENCE = Path('/opt/glitch/_local/orchplus-adversarial-review-20261106')
OPEN = '<!-- orchplus-operator-rulings v1 -->'
CLOSE = '<!-- /orchplus-operator-rulings v1 -->'
QUESTION = 'Which path should this exact ruling fixture take?'
ANSWER = 'Use <literal> `safe` path only. Do not expand the assigned work.'


PLAN = (b'# Feature: Existing ruling qualification\n\n## IMPLEMENTATION PLAN\n\n'
        b'### Checkpoint 1 - Native ruling\n\n#### Task 1A - Await exact native ruling\n'
        b'**INDEPENDENT**\n\n### UPDATE fixture.txt\n\n'
        b'- **IMPLEMENT**: Do not modify files; wait for the bounded native ruling fixture commands.\n'
        b'\n## Progress\nInitial owner progress\n')


def import_plan(product, path):
    product.ui.click(product.controller, 'More…')
    product.ui.choose('Orchestration', 'Add plan file…')
    form = product.ui.form_pane('Plan file on the execution host')
    product.ui.edit_field(form, 'Plan file on the execution host', str(path))
    product.ui.mouse_click(form, 'Continue')
    existing = active_plan(product, path)
    if existing and existing.get('orch_project_id'):
        project = state(product)['projects'][existing['orch_project_id']]
        label = project['name']
    else:
        label = product.current_project()['name']
    product.ui.choose('Add to which project?', label)


def active_plan(product, path):
    matches = [p for p in state(product).get('plans', {}).values()
               if p['path'] == str(path) and p['status'] != 'superseded']
    assert len(matches) <= 1
    return matches[0] if matches else None


def reimport_plan(product, path, expected_revision, timeout):
    trace_path = product.runtime.config/'plugin-data/orchplus/product-trace.json'
    first_event = len(read_json(trace_path)['events'])
    sid = active_plan(product, path)['logical_session_id']
    import_plan(product, path)

    def acknowledged():
        events = read_json(trace_path)['events'][first_event:]
        requests = [event['data'] for event in events if event['kind'] == 'native_input'
                    and event['data'].get('command') == 'plan_import'
                    and event['data'].get('pane') == product.controller]
        assert len(requests) <= 1, 'plan import submitted more than once'
        if not requests:
            return None
        request = requests[0]
        assert isinstance(request.get('command_seq'), int)
        assert request['expected_revision'] == request['current_revision'], 'native plan import was stale before effect'
        commits = [event['data'] for event in events if event['kind'] == 'orch_commit'
                   and any(session['id'] == sid and session.get('command_seq') == request['command_seq']
                           for session in event['data'].get('sessions', []))]
        if not commits:
            return None
        current = active_plan(product, path)
        assert current and current['plan_revision'] == expected_revision
        return {'request': request, 'commit_revision': commits[0]['revision'], 'plan': current}

    return product.lib.wait_for(acknowledged, 'exact native import consumed with expected plan identity', timeout)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def state(product):
    return registry(product.runtime)['dispatch']


def gate(product, gid):
    return state(product)['gates'].get(gid)


def receipt(product, case, **fields):
    case.update(fields)
    path = product.runtime.root/('rulings-'+case['name']+'.json')
    path.write_text(json.dumps(case, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    case['receipt'] = str(path)


def close_case(product, case):
    try:
        receipt(product, case, final_dispatch=state(product))
    except Exception:
        case['status'] = 'failed'
        case['final_observation_error'] = traceback.format_exc()
    finally:
        try:
            product.close()
        except Exception:
            case['status'] = 'failed'
            case['cleanup_error'] = traceback.format_exc()
            try:
                product.runtime.stop()
            except Exception:
                case['runtime_stop_error'] = traceback.format_exc()
    try:
        receipt(product, case)
    except Exception:
        case['status'] = 'failed'
        case['receipt_error'] = traceback.format_exc()


def open_advanced(product):
    """Expose shipped diagnostic/recovery controls without changing authority."""
    tree = product.ui('surface', pane=product.controller)
    labels = [props.get('text', ''.join(span if isinstance(span, str) else span.get('t', '')
                                      for span in props.get('spans', [])))
              for node in surface_nodes(tree.get('main')) for props in [node.get('p', {})]]
    if 'Hide Advanced' not in labels:
        product.ui.click(product.controller, 'Advanced')


def select_worker(product, worker):
    open_advanced(product)
    product.ui.click_match(product.controller, worker['work_id']+' · ')
    product.lib.wait_for(lambda: product.ui.machine(product.controller, 'orchplus.worker',
                         'workflow-worker-'+worker['worker_id']), 'selected native worker surface', 30)


def settled_owner_read(product, worker, source, setup):
    # request_floor/peer_outstanding are cached control observations, not
    # current obligations. Dispatch.ack_progress reconstructs acknowledgements
    # from live actions; an idle owner input must not wait for a new peer query.
    dispatch = source['dispatch']
    current = dispatch['workers'][worker['worker_id']]
    workflow = current.get('workflow', {})
    native, empty = workflow.get('native', {}), workflow.get('empty_read', {})
    session = source['sessions'][worker['logical_session_id']]
    samples = setup.setdefault('owner_input_samples', [])
    if not samples or samples[-1]['source_revision'] != source['revision']:
        samples.append({'source_revision': source['revision'], 'observed_epoch_ns': time.time_ns(),
                        'native': native, 'empty_read': empty, 'last_poll': workflow.get('last_poll'),
                        'due_poll': workflow.get('due_poll'),
                        'actions': [a['request']['op'] for a in dispatch['actions'].values()],
                        'bridge_control': session.get('bridge_control'),
                        'receipt_count': len(current.get('receipts', {})),
                        'accepted_seq': current['accepted_seq'], 'compacted_floor': current['compacted_floor'],
                        'pending_fields': [key for key in ('replies', 'wakes', 'accept_pending', 'finish',
                            'compaction_pending', 'read_selector', 'restored', 'continuation_required',
                            'assembly', 'rejected_report', 'release', 'retirement', 'stop_action_id',
                            'mailbox_retire_action_id') if current.get(key)]})
        if len(samples) > 32:
            samples.pop(0)
            setup['owner_input_samples_truncated'] = True
    if (dispatch['actions'] or session.get('bridge_control') or current.get('replies')
            or current.get('wakes') or current.get('accept_pending') or current.get('finish')
            or current.get('compaction_pending') or current.get('read_selector')
            or current.get('restored') or current.get('continuation_required')
            or current.get('assembly') or current.get('rejected_report')
            or current.get('release') or current.get('retirement')
            or current.get('stop_action_id') or current.get('mailbox_retire_action_id')
            or workflow.get('report_request') or native.get('state') != 'idle'
            or native.get('delivery_error')):
        setup.pop('quiet_source', None)
        return False
    if 'settlement_read' not in setup:
        # One fresh normal read/settlement input, never a repeated captured
        # command. Record the attempt before invoking the real native control.
        setup['settlement_read'] = {'source_revision': source['revision']}
        setup['settlement_read']['input'] = product.ui.click(product.controller, 'Read / settle '+worker['work_id'])
        return False
    # Match dispatch.poll_idle: a later metadata/compaction poll does not
    # invalidate an empty read made after the unchanged native idle evidence.
    # Requiring empty_read == last_poll incorrectly excludes that real no-op
    # interval. Receipt compaction must be complete before watermark polling
    # also becomes read-only.
    policy = dispatch['policies'][worker['logical_session_id']]
    age_ms = time.time()*1000-native.get('at_ms', 0)
    settled = (workflow.get('due_poll') is True and empty.get('slot') == current['accepted_seq']+1
               and empty.get('epoch') == native.get('epoch')
               and empty.get('mono_ms', -1) >= native.get('mono_ms', 0)
               and not current.get('receipts') and current['compacted_floor'] == current['accepted_seq']
               and current['reply_floor'] == current['reply_seq']
               and not any(g['worker_id'] == worker['worker_id'] and g['phase'] == 'answered'
                           for g in dispatch['gates'].values())
               and 0 <= age_ms < policy['stale_ms']/4-policy['poll_ms'])
    if not settled:
        setup.pop('quiet_source', None)
        return False
    # Observe the scheduled-poll edge before creating any owner intent. A just-
    # completed read can leave only a fraction of its five-second interval;
    # capturing there races the next durable due_poll update. Never suspend the
    # scheduler, extend a deadline or refresh an already captured owner intent.
    quiet = setup.get('quiet_source')
    now = time.monotonic()
    if not quiet or quiet['source_revision'] != source['revision']:
        setup['quiet_source'] = {'source_revision': source['revision'],
                                 'first_seen_monotonic': now,
                                 'empty_read': empty, 'last_poll': workflow.get('last_poll'),
                                 'native': native, 'native_age_ms': age_ms}
        return False
    return now-quiet['first_seen_monotonic'] >= 1


def native_participant(product, worker):
    return next(row for row in saved_records(product.runtime)
                if row['id'] == worker['record_id'])['backend'] == 'native-agent'


def associate(product, worker, path):
    select_worker(product, worker)
    before = registry(product.runtime)
    sid = worker['logical_session_id']
    initially_paused = before['dispatch']['policies'][sid]['paused']
    setup = {'initially_paused': initially_paused, 'before_pause': before}
    product.result.setdefault('association_setup', []).append(setup)
    if not initially_paused:
        pause_deadline = time.monotonic()+30
        def pause_ready():
            source = registry(product.runtime)
            setup['pause_preflight_state'] = source
            current = source['dispatch']['workers'][worker['worker_id']]
            if (source['dispatch']['actions']
                    or source['sessions'][sid].get('bridge_control')
                    or current.get('workflow', {}).get('due_poll') is not True):
                return None
            rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
            if (rendered and rendered.get('orch_session_id') == sid
                    and rendered.get('authority_namespace') == source['authority_namespace']
                    and rendered.get('authority_revision') == source['revision']
                    and registry(product.runtime)['revision'] == source['revision']):
                return source
            return None
        # Observe completed work and the scheduled due_poll edge before FIRST
        # Pause, with the native view still at that exact revision. Do not also
        # demand a one-second quiet interval: normal polling can consume this
        # edge sooner. The existing bounded input helper handles a proved
        # pre-effect stale refusal; the original deadline and effect rules remain.
        setup['before_pause'] = product.lib.wait_for(
            pause_ready, 'settled current native source before first Pause',
            max(0, pause_deadline-time.monotonic()))
        owner_setup_input(product, command='pause', deadline=pause_deadline,
            complete=lambda observed, source: source['dispatch']['policies'][sid]['paused'],
            unchanged=lambda old, new: old['dispatch']['policies'][sid] == new['dispatch']['policies'][sid])
    setup['paused'] = registry(product.runtime)
    deadline = time.monotonic() + 90

    def acceptance_published():
        current = state(product)['workers'][worker['worker_id']]
        accepted = current.get('accepted_event')
        published = current.get('receipts', {}).get(str(accepted['seq'])) if accepted else None
        return published if published and published.get('publish') is False else None

    if not native_participant(product, worker):
        setup['published_acceptance'] = product.lib.wait_for(
            acceptance_published, 'actual ACCEPTED receipt published before helper acknowledgement',
            max(0, deadline-time.monotonic()))
        setup['helper_receipts'] = worker_command(product, worker['mailbox_handle'], 'receipts')

    def settled():
        current = registry(product.runtime)
        dispatch = current['dispatch']
        observed = dispatch['workers'][worker['worker_id']]
        workflow = observed.get('workflow', {})
        native = workflow.get('native', {})
        session = current['sessions'][sid]
        # Pause is not an authority lock. Observe current native idle state and
        # settled actions before the FIRST click, without refreshing any intent.
        # The real settlement read prevents an immediately due mailbox effect
        # from racing the prompt; its historical command-result slot is not proof.
        # Poll timers and the product's native freshness bound remain unchanged.
        age_ms = time.time()*1000 - native.get('at_ms', 0)
        if not settled_owner_read(product, worker, current, setup):
            setup['last_unsettled'] = current
            return None
        if (dispatch['policies'][sid]['paused'] and not dispatch['actions']
                and set(dispatch['workers']) == {
                    worker['worker_id'], (session.get('orchestrator') or {}).get('managed_worker_id', worker['worker_id'])}
                and (not dispatch['gates'] or native_participant(product, worker) and all(
                    g['worker_id'] == worker['worker_id'] and g['phase'] == 'pending' and not g.get('answer')
                    for g in dispatch['gates'].values()))
                and not session.get('bridge_control')
                and observed['phase'] == 'accepted' and not observed.get('accept_pending')
                and not observed.get('replies') and not observed.get('wakes')
                and not observed.get('receipts')
                and observed['compacted_floor'] == observed['accepted_seq']
                and observed['reply_floor'] == observed['reply_seq']
                and not workflow.get('report_request')
                and native.get('state') == 'idle' and not native.get('delivery_error')
                and 0 <= age_ms < dispatch['policies'][sid]['stale_ms']/4):
            rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
            poll = (rendered or {}).get('poll_result') or {}
            setup.setdefault('rendered_settlement_checks', []).append({
                'source_revision': current['revision'],
                'rendered_revision': rendered.get('authority_revision') if rendered else None,
                'poll_result': poll,
                'namespace_matches': bool(rendered and
                                          rendered.get('authority_namespace') == current['authority_namespace'])})
            if (rendered and rendered.get('authority_namespace') == current['authority_namespace']
                    and rendered.get('authority_revision') == current['revision']
                    and registry(product.runtime)['revision'] == current['revision']):
                setup['native_idle_observation'] = {'source_revision': current['revision'], 'native': native}
                return current
        setup['last_unsettled'] = current
        return None

    setup['before_picker'] = product.lib.wait_for(
        settled, 'current native idle source and helper/peer obligations before owner input',
        max(0, deadline-time.monotonic()))
    prompt = 'Existing document path on this execution host'
    prompt_deadline = time.monotonic()+40
    owner_setup_input(product, command='associate_document', worker_id=worker['worker_id'],
        deadline=prompt_deadline,
        complete=lambda observed, source: prompt in json.dumps(product.ui.runtime.ctl('tree'), ensure_ascii=False),
        unchanged=lambda old, new: old['dispatch']['workers'][worker['worker_id']].get('ruling_document')
                                   == new['dispatch']['workers'][worker['worker_id']].get('ruling_document'))
    outer_deadline = getattr(product.ui, 'operation_deadline', None)
    product.ui.operation_deadline = min(outer_deadline, prompt_deadline) if outer_deadline else prompt_deadline
    try:
        form = product.ui.form_pane(prompt)
        product.ui.edit_field(form, prompt, str(path))
        product.ui.mouse_click(form, 'Associate document')
    finally:
        product.ui.operation_deadline = outer_deadline
    setup['after_path_input'] = registry(product.runtime)
    product.lib.wait_for(lambda: state(product)['workers'][worker['worker_id']].get('ruling_document', {}).get('path') == str(path),
                         'owner-selected existing association committed', 40)
    setup['associated'] = registry(product.runtime)
    if not initially_paused:
        setup['before_resume'] = product.lib.wait_for(
            settled, 'current rendered authority before the explicit Resume click',
            max(0, deadline-time.monotonic()))
        owner_setup_input(product, command='resume', deadline=time.monotonic()+30,
            complete=lambda observed, source: not source['dispatch']['policies'][sid]['paused'],
            unchanged=lambda old, new: old['dispatch']['policies'][sid] == new['dispatch']['policies'][sid])
    setup['after_association_setup'] = registry(product.runtime)


def assign(product, record='c2-builder', prompt=None):
    deadline = time.monotonic()+180
    queued = owner_assignment(product, record, (
        ('Explicit assignment for '+record, prompt or
         'Bounded native ruling fixture. Do not modify repository content; wait for explicit fixture commands.'),
        ('Declared files', 'fixture.txt'), ('Checks (one per line', ''),
        ('Base ref', 'refs/heads/main')), deadline=deadline)
    def accepted():
        matches = [w for w in state(product)['workers'].values()
                   if w['worker_id'] == queued['worker_id'] and w.get('phase') == 'accepted']
        assert len(matches) <= 1
        return matches[0] if matches else None
    return product.lib.wait_for(accepted, 'actual enrolled ruling worker accepted',
                                max(0, deadline-time.monotonic()))


def pending_gate(product, worker):
    deadline = time.monotonic() + 180
    def observed():
        matches = [g for g in state(product)['gates'].values()
                   if g['worker_id'] == worker['worker_id'] and g['phase'] == 'pending'
                   and g.get('question') == QUESTION]
        assert len(matches) <= 1
        return matches[0] if matches else None
    original = product.lib.wait_for(observed, 'actual typed ASK native gate',
                                    max(0, deadline-time.monotonic()))
    if native_participant(product, worker):
        # The actual model owns its helper; the fixed program's command-file
        # interface must never be used to impersonate its receipt consumption.
        return original
    def published():
        active = state(product)['workers'][worker['worker_id']]
        return all(receipt.get('publish') is False for receipt in active.get('receipts', {}).values())
    product.lib.wait_for(published, 'actual ASK receipt published before helper consumption',
                         max(0, deadline-time.monotonic()))
    helper = worker_command(product, worker['mailbox_handle'], 'receipts')
    def acknowledged():
        active = state(product)['workers'][worker['worker_id']]
        return (not active.get('receipts') and active['compacted_floor'] == active['accepted_seq']
                and active['reply_floor'] == active['reply_seq'])
    product.lib.wait_for(acknowledged, 'actual helper ASK receipt prefix observed by HOST',
                         max(0, deadline-time.monotonic()))
    product.result.setdefault('ask_receipt_settlement', []).append({
        'gate_id': original['id'], 'helper_receipts': helper,
        'compacted_floor': state(product)['workers'][worker['worker_id']]['compacted_floor']})
    assert observed() == original, 'receipt settlement changed the unanswered owner question'
    return original


def answer(product, worker, original):
    select_worker(product, worker)
    setup = {}
    product.result.setdefault('owner_answer_setup', []).append(setup)
    def ready_for_first_input():
        current = registry(product.runtime)
        dispatch = current['dispatch']
        observed = dispatch['gates'].get(original['id'])
        assert observed and all(observed[key] == original[key] for key in
                               ('question', 'revision', 'worker_id', 'worker_generation', 'options'))
        assert observed['phase'] == 'pending' and not observed.get('answer')
        if not settled_owner_read(product, worker, current, setup):
            return None
        session = current['sessions'][worker['logical_session_id']]
        active = dispatch['workers'][worker['worker_id']]
        workflow = active.get('workflow', {})
        native = workflow.get('native', {})
        if (dispatch['actions'] or session.get('bridge_control')
                or native.get('state') != 'idle' or native.get('delivery_error')
                or not 0 <= time.time()*1000-native.get('at_ms', 0)
                       < dispatch['policies'][worker['logical_session_id']]['stale_ms']/4):
            return None
        content = product.ui.machine(product.controller, 'orchplus.gate-content',
                                     'workflow-gate-content-'+original['id'])
        rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
        if (content and rendered and rendered.get('authority_namespace') == current['authority_namespace']
                and rendered.get('authority_revision') == current['revision']
                and registry(product.runtime)['revision'] == current['revision']):
            return {'source_revision': current['revision'], 'gate': observed, 'native': native}
        return None
    # Keep the original content-wait budget. Nothing has been captured or
    # approved yet; after the first click the original intent is never refreshed.
    readiness = product.lib.wait_for(ready_for_first_input, 'current exact gate and native idle before first owner input', 40)
    product.result.setdefault('owner_answer_readiness', []).append(readiness)
    product.ui('click_gate', pane=product.controller, gate_id=original['id'], label='Answer exact question…')
    product.ui.choose(original['question'], 'Use reviewed path')
    product.ui.enter('Explicit owner answer', ANSWER)
    current = product.lib.wait_for(lambda: (gate(product, original['id']) or {}).get('answer'),
                                   'explicit owner decision committed', 40)
    assert current['source']['kind'] == 'owner' and current['answer'] == ANSWER
    assert all(current['source'].get(key) == value for key, value in worker['origin_binding'].items()), 'owner decision provenance differs from the enrolled native control origin'
    observed = gate(product, original['id'])
    assert all(observed[key] == original[key] for key in ('question', 'revision', 'worker_id', 'worker_generation', 'options'))
    return observed


def consume_decision(product, worker, gid):
    deadline = time.monotonic() + 90
    def published():
        current = gate(product, gid)
        return current and current.get('delivery') and current['phase'] == 'delivered'
    product.lib.wait_for(published, 'typed owner decision delivered to actual helper mailbox',
                         max(0, deadline-time.monotonic()))
    reply = worker_command(product, worker['mailbox_handle'], 'consume')['value']
    assert reply and reply['kind'] == 'owner_decision' and reply['gate_id'] == gid
    assert reply['payload']['answer'] == ANSWER
    associated = bool((gate(product, gid) or {}).get('ruling'))
    if associated:
        def ack_published():
            current = gate(product, gid)
            delivery = (current or {}).get('delivery', {})
            if not delivery.get('acknowledged'):
                return None
            active = state(product)['workers'][worker['worker_id']]
            receipt = active.get('receipts', {}).get(str(delivery['ack_seq']))
            if active['compacted_floor'] >= delivery['ack_seq'] or receipt and receipt.get('publish') is False:
                return {'ack_seq': delivery['ack_seq'], 'compacted_floor': active['compacted_floor'],
                        'receipt': receipt}
            return None
        # Consume the actual REPLY_ACK receipt only after HOST publishes it.
        # The fixed helper does not autonomously revisit receipts later.
        proof = product.lib.wait_for(ack_published, 'actual owner-reply ACK receipt published',
                                     max(0, deadline-time.monotonic()))
        product.result.setdefault('owner_reply_receipt_publication', []).append(proof)
    worker_command(product, worker['mailbox_handle'], 'receipts')
    if associated:
        def ack_settled():
            current = state(product)
            active = current['workers'][worker['worker_id']]
            if (active.get('accept_pending') or active.get('compaction_pending') or active.get('receipts')
                    or active['compacted_floor'] != active['accepted_seq']
                    or active['reply_floor'] != active['reply_seq']
                    or any(action.get('worker_id') == worker['worker_id'] for action in current['actions'].values())):
                return None
            return {'accepted_seq': active['accepted_seq'], 'compacted_floor': active['compacted_floor'],
                    'reply_seq': active['reply_seq'], 'reply_floor': active['reply_floor']}
        # The helper's receipt ACK is not settled until HOST consumes and
        # physically compacts that prefix. Keep this inside the ACK deadline,
        # rather than spending the next owner's input budget on stale receipts.
        product.result.setdefault('owner_reply_receipt_settlement', []).append(
            product.lib.wait_for(ack_settled, 'actual owner-reply receipt prefix consumed and physically compacted',
                                 max(0, deadline-time.monotonic())))
    return reply


def finish_writer(product, worker):
    select_worker(product, worker)
    read_setup = {}
    product.result['finish_read_setup'] = read_setup
    deadline = time.monotonic() + 90
    def published_receipts():
        current = state(product)['workers'][worker['worker_id']]
        return (not current.get('accept_pending')
                and all(receipt.get('publish') is False for receipt in current.get('receipts', {}).values()))
    product.lib.wait_for(published_receipts, 'actual report receipts published before helper consumption',
                         max(0, deadline-time.monotonic()))
    read_setup['helper_receipts'] = worker_command(product, worker['mailbox_handle'], 'receipts')
    def settled():
        source = registry(product.runtime)
        if not settled_owner_read(product, worker, source, read_setup):
            return None
        dispatch = source['dispatch']
        current = dispatch['workers'][worker['worker_id']]
        session = source['sessions'][worker['logical_session_id']]
        native = current.get('workflow', {}).get('native', {})
        if (current.get('replies') or current.get('wakes') or current.get('receipts')
                or current['compacted_floor'] != current['accepted_seq']
                or current['reply_floor'] != current['reply_seq'] or dispatch['actions']
                or session.get('bridge_control')
                or native.get('state') != 'idle' or native.get('delivery_error')
                or not 0 <= time.time()*1000-native.get('at_ms', 0)
                       < dispatch['policies'][worker['logical_session_id']]['stale_ms']/4):
            return None
        rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
        if (rendered and rendered.get('authority_namespace') == source['authority_namespace']
                and rendered.get('authority_revision') == source['revision']
                and registry(product.runtime)['revision'] == source['revision']):
            return {'source_revision': source['revision'], 'native': native,
                    'prior_command_result': rendered.get('command_result')}
        return None
    setup = product.lib.wait_for(settled, 'current native idle source and settled owner delivery before Finish',
                                max(0, deadline-time.monotonic()))
    product.result['finish_setup'] = setup
    product.ui.command(product.controller, 'finish', worker_id=worker['worker_id'])
    product.ui.choose('Finish '+worker['work_id']+'?', 'Finish this ordinary worker')
    def stopped():
        source = registry(product.runtime)
        dispatch = source['dispatch']
        current = dispatch['workers'].get(worker['worker_id'])
        proof = current and current.get('stopped')
        if current and not current.get('finish'):
            rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
            response = (rendered or {}).get('command_result') or {}
            if response.get('command') == 'finish' and response != setup['prior_command_result']:
                setup['finish_response'] = response
                assert response.get('ok') is True, 'native Finish refused without replay: '+str(response)
        if (not proof or proof.get('observation') not in ('absent', 'exited')
                or not current.get('mailbox_retired') or dispatch['actions']
                or source['sessions'][worker['logical_session_id']].get('bridge_control')):
            read_setup.pop('finished_source_quiet', None)
            return None
        # Retirement can precede the final native observation/peer update.
        # Observe a quiet current source before returning to the FIRST document
        # write input, inside this same stop deadline; never replay that input.
        quiet = read_setup.get('finished_source_quiet')
        now = time.monotonic()
        if (not quiet or quiet['authority_namespace'] != source['authority_namespace']
                or quiet['source_revision'] != source['revision']):
            read_setup['finished_source_quiet'] = {
                'authority_namespace': source['authority_namespace'],
                'source_revision': source['revision'], 'first_seen_monotonic': now}
            return None
        if now-quiet['first_seen_monotonic'] < 1:
            return None
        rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
        if (rendered and rendered.get('authority_namespace') == source['authority_namespace']
                and rendered.get('authority_revision') == source['revision']
                and registry(product.runtime)['revision'] == source['revision']):
            product.result['finished_writer_source_revision'] = source['revision']
            product.result['finished_writer_source'] = source
            return proof
        return None
    return product.lib.wait_for(stopped, 'positive native writer stop, mailbox retirement and current owner view', 120)


def recover_ended_controller(product, sid, previous, closed_window):
    from product_recovery import _post_reload_epoch, _reload
    # Only positive closure of this explicitly owned native incarnation qualifies.
    incarnation = closed_window['incarnation']
    assert not any(client.get('kind') == 'window'
                   and client.get('window') == incarnation['window_key']
                   and client.get('conn') == incarnation['conn']
                   and client.get('since') == incarnation['since']
                   for client in closed_window['clients_after'])
    before = registry(product.runtime)
    session = before['sessions'][sid]
    assert session['controller'] and all(session['controller'][key] == previous[key]
                                         for key in ('owner_id', 'generation', 'pane_binding'))
    for current in before['dispatch']['workers'].values():
        if current['logical_session_id'] == sid:
            assert current.get('mailbox_retired') and current.get('stopped', {}).get('observation') in ('absent', 'exited')
    intents = {gid: value['ruling']['intent'] for gid, value in before['dispatch']['gates'].items()
               if value.get('ruling', {}).get('intent')}
    setup = {'previous': previous, 'window_close': closed_window,
             'retained_admission_seq': session['admission_seq'], 'retained_ruling_intents': intents}
    product.result['ended_controller_recovery'] = setup
    product.ui.click(product.controller, session['name'])
    deadline = time.monotonic()+40
    assert getattr(product.ui, 'operation_deadline', None) is None
    product.ui.operation_deadline = deadline
    try:
        # Assistance intentionally stays bound to an active owner's exact window.
        # Normal host restore makes that closed owner uncertain, not retired; it
        # preserves the pending document intent and still requires fresh verification.
        _reload(product, 'orchplus', deadline=deadline)
        setup['reload_epoch_settled'] = _post_reload_epoch(product, deadline)
        restored = registry(product.runtime)
        assert restored['sessions'][sid]['controller']['owner_id'] == previous['owner_id']
        assert restored['sessions'][sid]['controller']['phase'] == 'uncertain'
        assert all(restored['dispatch']['gates'][gid]['ruling']['intent'] == intent
                   for gid, intent in intents.items())
        open_advanced(product)
        product.ui.click(product.controller, 'Recheck')
        def unavailable():
            owner = registry(product.runtime)['sessions'][sid]['controller']
            assert owner and owner['owner_id'] == previous['owner_id']
            return owner if (owner.get('owner_active') is not True and owner['pending_executors'] == 0
                             and (owner.get('last_observation') or {}).get('status') == 'unavailable') else None
        setup['native_observation'] = product.lib.wait_for(
            unavailable, 'native observation of the positively closed controller', product.ui.remaining(40))

        product.ui.click(product.controller, 'Independently verify unavailable owner stopped…')
        product.ui.click(product.controller, 'Record my verification (does not clear ownership)')
        product.ui.click(product.controller, 'Begin fenced recovery')
        product.ui.click(product.controller, 'Confirm verified recovery — clear this owner only')
        product.lib.wait_for(lambda: registry(product.runtime)['sessions'][sid].get('controller') is None,
                             'normal fenced controller recovery', product.ui.remaining(40))
        product.ui.click(product.controller, 'Recover this view for review only')
        def claimed():
            current = registry(product.runtime)['sessions'][sid]
            owner = current.get('controller')
            if not owner or owner['owner_id'] == previous['owner_id']:
                return None
            assert owner['generation'] > previous['generation']
            assert owner['pane_binding']['host_pane_id'] == str(product.controller)
            assert not current.get('admitted') and current['admission_seq'] == setup['retained_admission_seq']
            return owner
        setup['new_controller'] = product.lib.wait_for(
            claimed, 'fresh normal controller claim in the surviving window', product.ui.remaining(40))
        after = registry(product.runtime)
        assert not after['sessions'][sid].get('admitted')
        assert all(after['dispatch']['gates'][gid]['ruling']['intent'] == intent for gid, intent in intents.items())
        # Ruling settlement needs the bound active ORCH owner, not execution
        # admission. Keep transport fenced: no worker is resumed or reattached.
        setup['document_only_recovery'] = {'transport_admitted': after['sessions'][sid].get('admitted') is True,
                                          'retained_admission_seq': setup['retained_admission_seq'],
                                          'source_revision': after['revision']}
    finally:
        product.ui.operation_deadline = None


def write_ruling(product, gid):
    emitted = product.ui('click_gate', pane=product.controller, gate_id=gid, label='Record ruling in existing document…')
    product.ui.choose('Use one participating writer for this existing document?',
                      'Document is quiescent; no other writer may edit it during this operation')
    return emitted


def write_ruling_fresh(product, gid, path, *, deadline):
    """One complete new attestation only after exact stale preparation/no-write proof.

    Ordinary document cells only. Fault injection, reissue and negative cases
    retain their single-shot inputs. Silence or any write intent never retries.
    """
    ui = product.ui
    assert getattr(ui, 'operation_deadline', None) is None, 'document inputs must be serial'
    ledger = product.runtime.root/'owner-document-inputs.jsonl'
    product.result['owner_document_input_ledger'] = str(ledger)
    step_id = time.monotonic_ns()

    def record(phase, **fields):
        with ledger.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps({'step_id': step_id, 'phase': phase,
                'monotonic_ns': time.monotonic_ns(), 'original_deadline': deadline,
                'window_key': ui.window_key, 'pane': product.controller,
                'gate_id': gid, **fields}, ensure_ascii=False)+'\n')

    ui.operation_deadline = deadline
    try:
        for attempt in (1, 2):
            before_gate = gate(product, gid)
            assert before_gate and before_gate.get('ruling') and not before_gate['ruling'].get('intent'), 'write intent already exists'
            identity = ui.machine(product.controller, 'orchplus.alias')
            assert identity and all(identity.get(key) for key in
                ('alias_nonce', 'authority_namespace', 'orch_session_id')), 'missing native source identity'
            document = path.read_bytes()
            buffer = ui('doc_read', path=str(path))
            assert isinstance(buffer, str), 'participating buffer is unavailable'
            record('before_input', attempt=attempt, identity=identity,
                   document_sha256=sha(document), buffer_sha256=sha(buffer.encode()))
            emitted = write_ruling(product, gid)
            assert isinstance(emitted, dict) and emitted.get('event', '').startswith('control='), 'no exact native control receipt'
            record('submitted', attempt=attempt, emitted=emitted)
            token = emitted['event'].split('=', 1)[1]

            def outcome():
                current = gate(product, gid)
                if not current or not current.get('ruling') or current['ruling'].get('intent'):
                    return ('started_or_settled', None)
                inputs = [event['data'] for event in trace(product.runtime, 'orchplus')['events']
                          if event['kind'] == 'native_input'
                          and event['data'].get('pane') == product.controller]
                clicks = [item for item in inputs if item.get('act') == 'control'
                          and item.get('control_token') == token]
                if not clicks:
                    return None
                assert len(clicks) == 1, 'ambiguous native document input'
                prepares = [item for item in inputs if item.get('command') == 'ruling_prepare'
                            and item.get('gate_id') == gid
                            and item.get('source_nonce') == identity['alias_nonce']
                            and item['trace_index'] > clicks[0]['trace_index']]
                assert len(prepares) <= 1, 'multiple preparations from one owner input'
                if not prepares:
                    return None
                request = prepares[0]
                replies = [item for item in inputs if item.get('act') == 'ruling-clear'
                           and item.get('source_nonce') == identity['alias_nonce']
                           and item.get('request_id') == request['request_id']
                           and item['trace_index'] > request['trace_index']
                           and (item.get('ruling_response') or {}).get('request_id') == request['request_id']]
                if not replies:
                    return None
                assert len(replies) == 1, 'ambiguous native preparation receipt'
                response = replies[0]['ruling_response']
                if response.get('ok') is True:
                    return ('started_or_settled', response)
                record('refusal', attempt=attempt, preparation=request, response=response)
                assert response.get('ok') is False and response.get('code') == 'stale_revision', 'not an exact stale preparation refusal'
                current_identity = ui.machine(product.controller, 'orchplus.alias') or {}
                assert all(current_identity.get(key) == identity[key] for key in
                    ('alias_nonce', 'authority_namespace', 'orch_session_id')), 'native source identity changed'
                assert gate(product, gid) == before_gate, 'ruling obligation or write intent changed'
                assert path.read_bytes() == document, 'document changed; no fresh input permitted'
                assert ui('doc_read', path=str(path)) == buffer, 'participating buffer changed; no fresh input permitted'
                return ('refused', response)

            kind, response = product.lib.wait_for(outcome, 'native document preparation', ui.remaining(90), .05)
            if kind == 'started_or_settled':
                record(kind, attempt=attempt, response=response)
                return
            assert attempt == 1, 'second document preparation refused; no further input permitted'
            record('fresh_interaction_permitted', response=response, remaining_seconds=ui.remaining(90))
    except Exception as error:
        record('failed', error=f'{type(error).__name__}: {error}')
        raise
    finally:
        ui.operation_deadline = None


def normal_save(product, pane):
    # Exact ordinary palette primitive from build-native-docs-probe.py r5.
    product.ui('focus', pane=pane)
    product.runtime.ctl('palette', 'Save')
    def offered():
        tree = product.runtime.ctl('tree')
        found = []
        for node in native_nodes(tree.get('tree', [])):
            if node.get('role') != 'option':
                continue
            labels = [' '.join(child.get('text', '') for child in native_nodes(part) if child.get('text'))
                      for part in native_nodes(node) if part.get('class') == 'ck-label']
            if ' '.join(labels).casefold() in ('save', 'save file', 'save document', 'save changes'):
                found.append(node)
        return found[0] if len(found) == 1 else None
    node = product.lib.wait_for(offered, 'ordinary native owner Save action', 30)
    x, y, width, height = node['rect']
    product.runtime.ctl('click', str(x+width/2), str(y+height/2))
    product.ui.record_input({'op': 'native_owner_save', 'pane': pane, 'control': node})


def observed_code(product, gid, code):
    return product.lib.wait_for(lambda: (gate(product, gid) or {}).get('ruling', {}).get('state') == code,
                                'durable ruling hold '+code, 45)


def source_receipts(product):
    sources = [TESTS/'product_rulings.py', TESTS/'ruling_worker.py', TESTS/'product_c3.py', TESTS/'product_recovery.py',
               REFERENCE/'build-native-docs-probe.py', REFERENCE/'build-native-docs-probe-r5.json']
    product.result['ruling_sources'] = {str(path): sha(path.read_bytes()) for path in sources}
    reference = json.loads(sources[-1].read_text())
    assert reference['passed'] and 'not integrated' in reference['scope']
    product.result['primitive_reference_scope'] = reference['scope']
    product.result['shipping_source_hashes'] = {
        str(path.relative_to(product.root)): sha(path.read_bytes())
        for package in ('ORCH+', 'SPAWN')
        for path in sorted((product.root/'plugins/tern'/package).rglob('*')) if path.is_file()}


def local_case(base, root, evidence, processes, lib, args, name, initial):
    case = {'name': name, 'status': 'failed', 'scope': 'actual native local Docs and typed helper route'}
    evidence.setdefault('c3_cases', {})['rulings-'+name] = case
    product = None
    readonly_directory = None
    try:
        product = Product(base, root, evidence, processes, lib, 'rulings-'+name, args, assignment_trace=True)
        product.result = {**product.result, **case}
        case = product.result
        evidence['c3_cases']['rulings-'+name] = case
        source_receipts(product)
        shutil.copy2(TESTS/'ruling_worker.py', product.worker.parent/'ruling_worker.py')
        product.worker = product.worker.parent/'ruling_worker.py'
        loss = EventLoss(product)
        docs_hold = product.runtime.root/'ruling-docs-loss.json'
        write_json(docs_hold, {'enabled': False})
        configuration_path = product.orch/'product-probe.json'
        configuration = read_json(configuration_path)
        configuration['docs_edit_hold_path'] = str(docs_hold)
        configuration['recovery_trace'] = True
        write_json(configuration_path, configuration)
        if name in ('ended-absent', 'ended-saved'):
            # The root remains an observer. The disposable second window owns
            # this controller from FIRST claim, so closing it cannot kill the supervisor.
            product.start()
            product.open_spawn()
            product.create_record('c2-builder', 'Codex')
            product.create_record('c2-release', 'OMP')
            product.controller = product.ui('open', kind='orchplus.orchestrator')
            root_ui = product.ui
            root_controller, root_spawn = product.controller, product.spawn_pane
            product.ui = additional_window(product)
            from product_recovery import _incarnation
            original_window = _incarnation(product, product.ui)
            product.spawn_pane = product.ui('open', kind='spawn.spawner')
            product.initialize_orch()
            product.configure_orch('review_disabled')
            receipt(product, case, original_window_panes={'controller': product.controller, 'config': product.spawn_pane})
            product.claim()
        else:
            initialize(product)
        document_directory = product.repository/'owner-documents'
        document_directory.mkdir()
        path = document_directory/'existing-owner-document.md'
        path.write_bytes(initial)
        receipt(product, case, initial_sha256=sha(initial), document=str(path))
        if name == 'plan-progress':
            import_plan(product, path)
            imported = lib.wait_for(lambda: active_plan(product, path), 'native existing plan imported', 60)
            def plan_worker():
                matches = [w for w in state(product)['workers'].values()
                           if w.get('source', {}).get('kind') == 'plan'
                           and w['source'].get('ref', '').startswith(str(path)+'#') and w.get('phase') == 'accepted']
                assert len(matches) <= 1
                return matches[0] if matches else None
            worker = lib.wait_for(plan_worker, 'ordinary imported plan worker accepted', 180)
            receipt(product, case, imported_plan=imported, original_source=worker['source'])
        else:
            worker = assign(product)
        handle = worker['mailbox_handle']
        lib.wait_for(lambda: any(e['kind'] == 'ready' for e in worker_observations(product, handle)['events']), 'native fixture ready', 90)
        if name not in ('unassociated', 'plan-progress'):
            associate(product, worker, path)
        worker_command(product, handle, 'ask')
        original = pending_gate(product, worker)
        answered = answer(product, worker, original)
        receipt(product, case, original_gate=original, answered_gate=answered)
        if name == 'unassociated':
            assert answered.get('ruling') is None
            consume_decision(product, worker, original['id'])
            lib.wait_for(lambda: gate(product, original['id']) is None, 'unassociated completed gate reclaimed', 90)
            assert path.read_bytes() == initial
            assert not list(product.repository.glob('*ruling*'))
            case['checks'].append('Unassociated human answer creates no document obligation or log')
        else:
            obligation = answered['ruling']
            gid, marker, entry = original['id'], obligation['marker'], obligation['entry']
            assert obligation['path'] == str(path) and obligation['gate_revision'] == original['revision']
            assert obligation['work_id'] == worker['work_id'] and obligation['logical_session_id'] == worker['logical_session_id']
            assert marker == 'orchplus-ruling:'+registry(product.runtime)['authority_namespace']+':'+gid
            assert '&lt;literal&gt;' in entry and '&#96;safe&#96;' in entry
            reply = consume_decision(product, worker, gid)
            assert gate(product, gid)['ruling']['entry'] == entry, 'reply ACK falsely completed document'
            receipt(product, case, typed_decision=reply, owner_obligation=obligation)
            # ACK settlement is complete. Use the existing first-write budget
            # to observe current native idle/rendered authority before the
            # first input, then require the live-writer refusal in that budget.
            write_deadline = time.monotonic() + 45
            write_setup = {}
            product.result['first_write_setup'] = write_setup
            def write_ready():
                source = registry(product.runtime)
                current_gate = source['dispatch']['gates'].get(gid)
                assert current_gate and current_gate['ruling']['entry'] == entry
                if not current_gate.get('delivery', {}).get('acknowledged'):
                    return None
                if not settled_owner_read(product, worker, source, write_setup):
                    return None
                active = source['dispatch']['workers'][worker['worker_id']]
                native = active['workflow']['native']
                if (active.get('receipts') or active['compacted_floor'] != active['accepted_seq']
                        or active['reply_floor'] != active['reply_seq']
                        or native.get('delivery_error')
                        or not 0 <= time.time()*1000-native.get('at_ms', 0)
                               < source['dispatch']['policies'][worker['logical_session_id']]['stale_ms']/4):
                    return None
                rendered = product.ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
                if (rendered and rendered.get('authority_namespace') == source['authority_namespace']
                        and rendered.get('authority_revision') == source['revision']
                        and registry(product.runtime)['revision'] == source['revision']):
                    return {'source_revision': source['revision'], 'native': native}
                return None
            write_setup['ready'] = lib.wait_for(write_ready,
                'actual reply ACK and current native settlement before first ruling input',
                max(0, write_deadline-time.monotonic()))
            # This is a real preferred-worker refusal, before positive native stop.
            write_ruling(product, gid)
            lib.wait_for(lambda: (gate(product, gid) or {}).get('ruling', {}).get('state') == 'writer_unproved',
                         'durable ruling hold writer_unproved', max(0, write_deadline-time.monotonic()))
            assert path.read_bytes() == initial
            stopped = finish_writer(product, worker)
            receipt(product, case, original_writer_ended=stopped)
            ruling_deadline = time.monotonic()+90 if name == 'plan-progress' else None
            if name == 'plan-progress':
                product.ui('doc_edit', path=str(path), spec={'line': initial.count(b'\n')+1, 'insert': 'Routine Progress before fresh B0\n'})
                initial = path.read_bytes()
                assert active_plan(product, path)['plan_id'] == imported['plan_id']
                assert sha(initial) != imported['plan_revision']
                receipt(product, case, routine_progress_before_B0={
                    'imported_revision': imported['plan_revision'], 'document_sha256': sha(initial)})
                # This retained ASK crosses its normal report-age threshold near
                # the first positive write. Let that real host transition settle;
                # do not suspend it or refresh an already captured attestation.
                def report_expired():
                    source = registry(product.runtime)
                    current = source['dispatch']['workers'][worker['worker_id']]
                    if current.get('workflow', {}).get('health', {}).get('freshness') != 'stale':
                        return None
                    return {'source_revision': source['revision'],
                            'report_mono_ms': current['workflow']['report']['mono_ms'],
                            'stale_ms': source['dispatch']['policies'][worker['logical_session_id']]['stale_ms']}
                receipt(product, case, report_expiry_before_write=lib.wait_for(
                    report_expired, 'actual report-age transition before first positive ruling input',
                    max(0, ruling_deadline-time.monotonic())))
            pane = None
            if name in ('dirty', 'open-save'):
                pane = product.ui('doc_open', path=str(path))
                lib.wait_for(lambda: product.ui('pane_read', pane=pane).get('kind') == 'file', 'native existing file buffer open', 30)
                if name == 'dirty':
                    product.ui('doc_edit', path=str(path), spec={'line': 1, 'insert': 'Owner unsaved text\n'})
                    write_ruling(product, gid)
                    observed_code(product, gid, 'unsaved_edits')
                    assert path.read_bytes() == initial
                    buffer = product.ui('doc_read', path=str(path))
                    assert 'Owner unsaved text' in buffer and marker not in buffer
                    receipt(product, case, unsaved_buffer=buffer, disk_before_owner_save=path.read_bytes().decode())
                    normal_save(product, pane)
                    lib.wait_for(lambda: path.read_bytes() != initial, 'only normal Save persists owner edits', 30)
                    initial = path.read_bytes()
            if name in ('missing', 'removed-after-read', 'alias', 'readonly'):
                if name in ('missing', 'removed-after-read'):
                    if name == 'removed-after-read':
                        actual_read = product.ui('doc_read', path=str(path))
                        assert actual_read.encode() == initial
                    path.unlink()
                    if name == 'removed-after-read':
                        try:
                            product.ui('doc_edit', path=str(path), spec={'line': 1, 'insert': entry+'\n'})
                        except Exception as error:
                            receipt(product, case, read_before_removal=actual_read, actual_missing_edit_refusal=str(error))
                        else:
                            raise AssertionError('Native Docs edit did not refuse removal after native read')
                        assert not path.exists()
                elif name == 'alias':
                    target = path.with_name('alias-target.md')
                    path.rename(target)
                    path.symlink_to(target)
                else:
                    readonly_directory = path.parent
                    readonly_modes = (readonly_directory.stat().st_mode & 0o777, path.stat().st_mode & 0o777)
                    path.chmod(0o444)
                    readonly_directory.chmod(0o555)
                    denials = {}
                    for label, candidate, flags in (
                            ('inplace', path, os.O_WRONLY | os.O_APPEND),
                            ('atomic_replacement', readonly_directory/'permission-probe', os.O_WRONLY | os.O_CREAT | os.O_EXCL)):
                        try:
                            descriptor = os.open(candidate, flags, 0o600)
                        except PermissionError as error:
                            denials[label] = str(error)
                        else:
                            os.close(descriptor)
                            if label == 'atomic_replacement':
                                candidate.unlink()
                            raise AssertionError('Owned runtime identity did not encounter genuine '+label+' permission denial')
                    receipt(product, case, filesystem_denials=denials, effective_uid=os.geteuid(),
                            owned_environment=product.runtime.owned_environment)
                    try:
                        product.ui('doc_edit', path=str(path), spec={'line': 1, 'insert': 'Must not be written\n'})
                    except Exception as error:
                        receipt(product, case, actual_native_edit_refusal=str(error))
                    else:
                        raise AssertionError('Native Docs did not refuse the genuinely read-only existing file')
                    assert path.read_bytes() == initial
                receipt(product, case, negative_fault={'kind': name, 'at_ns': time.monotonic_ns()})
                if name != 'readonly':
                    loss.set([{'id': 'refusal-observed', 'block': 'orchestrator', 'act': 'ruling-clear'}])
                write_ruling(product, gid)
                if name == 'readonly':
                    lib.wait_for(lambda: (gate(product, gid) or {}).get('ruling', {}).get('intent'),
                                 'read-only native write retains its one-shot intent', 45)
                else:
                    loss.wait('orchplus', 'refusal-observed')
                    response = product.ui.machine(product.controller, 'orchplus.ruling.result', 'ruling-result')
                    assert response and response['code'] == 'document_missing'
                    receipt(product, case, actual_host_refusal=response)
                current = gate(product, gid)
                assert current and current['ruling']['entry'] == entry
                if name != 'readonly':
                    assert not current['ruling'].get('intent')
                if name in ('missing', 'removed-after-read'):
                    assert not path.exists()
                else:
                    assert path.read_bytes() == initial
                receipt(product, case, refusal_surface=product.ui('surface', pane=product.controller), retained_gate=current)
                case['checks'].append('Unwritable/unproved existing path retains exact pending owner entry without creation')
            elif name in ('malformed', 'duplicate-block'):
                write_ruling(product, gid)
                observed_code(product, gid, 'duplicate_entry' if name == 'duplicate-block' else 'needs_review')
                current = gate(product, gid)['ruling']
                assert current['entry'] == entry and not current.get('intent')
                assert path.read_bytes() == initial
                receipt(product, case, parser_refusal=current, unchanged_document_sha256=sha(initial))
            else:
                if name == 'ended-absent':
                    write_json(docs_hold, {'enabled': True, 'id': 'original-docs-edit', 'path': str(path), 'marker': marker})
                elif name == 'ended-saved':
                    loss.set([{'id': 'ended-result', 'block': 'orchestrator', 'act': 'ruling-command',
                               'match': {'command': 'ruling_observe'}}])
                if name in ('lost-result', 'concurrent', 'duplicate', 'two-window'):
                    loss.set([{'id': 'ruling-result', 'block': 'orchestrator', 'act': 'ruling-command', 'match': {'command': 'ruling_observe'}}])
                if name in ('lf', 'crlf', 'no-eof', 'empty', 'fenced', 'later-progress', 'plan-progress'):
                    ruling_deadline = ruling_deadline or time.monotonic()+90
                    write_ruling_fresh(product, gid, path, deadline=ruling_deadline)
                else:
                    write_ruling(product, gid)
                if name in ('ended-absent', 'ended-saved'):
                    from product_recovery import _close_window, _inventory
                    if name == 'ended-absent':
                        held_path = product.runtime.config/'plugin-data/orchplus/product-held-docs-window.json'
                        held = lib.wait_for(lambda: (read_json(held_path) or {}).get('original-docs-edit'),
                                            'original native Docs invocation withheld before effect', 60)
                        assert held['count'] == 1 and not held.get('conflict')
                        assert held['window_key'] == original_window['window_key']
                        assert path.read_bytes() == initial
                        assert marker not in product.ui('doc_read', path=str(path))
                    else:
                        held = loss.wait('orchplus', 'ended-result')
                        assert path.read_bytes().count(marker.encode()) == 1
                    old_intent = gate(product, gid)['ruling']['intent']
                    assert old_intent['writer'] == {'kind': 'window', **original_window}
                    receipt(product, case, original_window=original_window, pre_close_intent=old_intent, withheld_native=held)
                    ended_ui = product.ui
                    previous_controller = registry(product.runtime)['sessions'][worker['logical_session_id']]['controller']
                    assert previous_controller['pane_binding']['host_pane_id'] == str(product.controller)
                    for wake in getattr(product, 'extra_wakers', []):
                        if wake in lib.WAKERS:
                            lib.WAKERS.remove(wake)
                    product.extra_wakers = []
                    receipt(product, case, original_window_inputs=ended_ui.inputs)
                    closed_window = _close_window(product, ended_ui, original_window)
                    inventory = _inventory(product)
                    product.ui = root_ui
                    product.controller, product.spawn_pane = root_controller, root_spawn
                    write_json(docs_hold, {'enabled': False})
                    loss.set([])
                    recover_ended_controller(product, worker['logical_session_id'], previous_controller, closed_window)
                    live = product.ui('doc_read', path=str(path))
                    disk = path.read_bytes()
                    receipt(product, case, ended_inventory=inventory, new_observer_buffer=live, new_observer_disk=disk.decode())
                    if name == 'ended-absent':
                        assert marker not in live and marker.encode() not in disk
                        product.ui('click_gate', pane=product.controller, gate_id=gid, label='Inspect ended writer before enabling a new write')
                    else:
                        product.ui('click_gate', pane=product.controller, gate_id=gid, label='Reconcile ruling buffer and disk')
                    product.ui.choose('Use one participating writer for this existing document?',
                                      'I verified the exact original writer ended and no pending native write can complete')
                    if name == 'ended-absent':
                        lib.wait_for(lambda: not gate(product, gid)['ruling'].get('intent'),
                                     'positive ended-writer and both absence proofs clear only original intent', 45)
                        assert path.read_bytes() == initial
                        write_ruling(product, gid)
                    case['checks'].append('Actual ended native incarnation, independent live-buffer/disk proof, no blind reissue')
                if name in ('open-save', 'dirty'):
                    def pending_native_buffer():
                        ruling = (gate(product, gid) or {}).get('ruling', {})
                        if ruling.get('state') != 'unsaved_edits' or not ruling.get('intent'):
                            return None
                        buffer = product.ui('doc_read', path=str(path))
                        assert buffer.count(marker) <= 1, 'native buffer contains duplicate ruling markers'
                        return buffer if buffer.count(marker) == 1 else None
                    # A dirty document's earlier pre-write refusal has the same
                    # state label. Require this later actual insertion and its
                    # live intent, not the old refusal alone.
                    buffer = lib.wait_for(pending_native_buffer,
                                          'current native ruling insertion awaits normal Save', 45)
                    assert path.read_bytes() == initial
                    receipt(product, case, pending_buffer=buffer, pending_gate=gate(product, gid), disk_before_owner_save=path.read_bytes().decode())
                    intent_before = gate(product, gid)['ruling']['intent']
                    product.ui('click_gate', pane=product.controller, gate_id=gid, label='Inspect ended writer before enabling a new write')
                    assert gate(product, gid)['ruling']['intent'] == intent_before
                    assert product.ui('doc_read', path=str(path)).count(marker) == 1
                    normal_save(product, pane)
                    lib.wait_for(lambda: marker.encode() in path.read_bytes(), 'normal owner save persisted exact ruling', 30)
                if name in ('lost-result', 'concurrent', 'duplicate', 'two-window'):
                    captured = loss.wait('orchplus', 'ruling-result')
                    intent = gate(product, gid)['ruling']['intent']
                    assert intent['expected_document_sha256'] == sha(initial)
                    assert path.read_bytes().count(marker.encode()) == 1
                    receipt(product, case, held_result=captured, original_intent=intent, before_fault=path.read_bytes().decode())
                    if name == 'two-window':
                        second = additional_window(product)
                        from product_recovery import _incarnation, _inventory
                        writer_identity = _incarnation(product, product.ui)
                        second_identity = _incarnation(product, second)
                        assert writer_identity != second_identity
                        assert intent['writer'] == {'kind': 'window', **writer_identity}
                        before = path.read_bytes()
                        assert before.count(marker.encode()) == 1
                        previous_owner = registry(product.runtime)['sessions'][worker['logical_session_id']]['controller']
                        second_config = second('open', kind='spawn.spawner')
                        second_controller = second('open', kind='orchplus.orchestrator')
                        session = registry(product.runtime)['sessions'][worker['logical_session_id']]
                        second.click(second_controller, session['name'])
                        second.click(second_controller, 'Advanced')
                        second.click_match(second_controller, worker['work_id']+' · ')
                        observer_gate = lib.wait_for(
                            lambda: second.machine(second_controller, 'orchplus.gate', 'workflow-gate-'+gid),
                            'same pending ruling in the second window own observer pane', 30)
                        assert observer_gate['ruling']['intent'] == intent
                        observer_surface = second('surface', pane=second_controller)
                        mutation_commands = {'ruling_write', 'ruling_observe', 'ruling_remote', 'ruling_reissue'}
                        assert not any(node.get('p', {}).get('attrs', {}).get('data-orchplus-command') in mutation_commands
                                       for node in surface_nodes(observer_surface.get('main')))
                        inventory = _inventory(product)
                        for incarnation in (writer_identity, second_identity):
                            assert any(client.get('kind') == 'window'
                                       and client.get('window') == incarnation['window_key']
                                       and client.get('conn') == incarnation['conn']
                                       and client.get('since') == incarnation['since'] for client in inventory['clients'])
                        current_owner = registry(product.runtime)['sessions'][worker['logical_session_id']]['controller']
                        assert all(current_owner[key] == previous_owner[key]
                                   for key in ('owner_id', 'generation', 'pane_binding'))
                        assert gate(product, gid)['ruling']['intent'] == intent
                        assert path.read_bytes() == before
                        receipt(product, case, second_window_context=second('context'), second_inputs=second.inputs,
                                second_window_panes={'controller': second_controller, 'config': second_config},
                                second_observer_gate=observer_gate, second_observer_surface=observer_surface,
                                native_clients=inventory, original_controller=current_owner)
                    elif name == 'concurrent':
                        conflict_deadline = time.monotonic()+45
                        product.ui('doc_edit', path=str(path), spec={'line': 1, 'insert': 'Concurrent executable change\n'})
                    elif name == 'duplicate':
                        data = path.read_text()
                        line = data[:data.index(CLOSE)].count('\n')+1
                        product.ui('doc_edit', path=str(path), spec={'line': line, 'insert': entry+'\n'})
                    if name in ('concurrent', 'duplicate'):
                        conflict_bytes = path.read_bytes()
                    if name == 'concurrent':
                        # Advance real authority before delivering the exact held read.
                        # Its correlated refusal must lead to a fresh read, never another
                        # preparation/edit or an overwritten concurrent change.
                        sid = worker['logical_session_id']
                        before_control = registry(product.runtime)
                        paused = before_control['dispatch']['policies'][sid]['paused']
                        owner_setup_input(product, command='resume' if paused else 'pause',
                            deadline=conflict_deadline,
                            complete=lambda observed, source: source['dispatch']['policies'][sid]['paused'] != paused,
                            unchanged=lambda old, new: old['dispatch']['policies'][sid] == new['dispatch']['policies'][sid])
                        captured_request = json.loads(captured['input']['value'])
                        delivery_revision = registry(product.runtime)['revision']
                        assert delivery_revision > captured_request['expected_revision']
                        receipt(product, case, stale_observation={
                            'request_id': captured_request['request_id'],
                            'captured_revision': captured_request['expected_revision'],
                            'delivery_revision': delivery_revision})
                    loss.set([])
                    loss.deliver_original_once(captured)
                    if name in ('lost-result', 'two-window'):
                        loss.deliver_original_once(captured)
                    elif name == 'concurrent':
                        lib.wait_for(lambda: (gate(product, gid) or {}).get('ruling', {}).get('state') == 'needs_review',
                                     'fresh observation retains concurrent change after stale old read',
                                     max(0, conflict_deadline-time.monotonic()))
                    else:
                        observed_code(product, gid, 'duplicate_entry')
                if name in ('concurrent', 'duplicate'):
                    held = gate(product, gid)
                    assert held and held['ruling']['entry'] == entry
                    assert path.read_bytes() == conflict_bytes, 'conflict observation repaired or overwrote document bytes'
                    receipt(product, case, conflict_gate=held, after=path.read_bytes().decode())
                    case['checks'].append('Fresh host B1 detects conflict without repair or rewrite')
                else:
                    lib.wait_for(lambda: gate(product, gid) is None or not gate(product, gid).get('ruling'),
                                 'authoritative durable B1 settles obligation',
                                 max(0, ruling_deadline-time.monotonic()) if ruling_deadline is not None else 90)
                    after = path.read_bytes()
                    eol = b'\r\n' if b'\r\n' in initial else b'\n'
                    expected = initial+eol+OPEN.encode()+eol+entry.replace('\n', eol.decode()).encode()+eol+CLOSE.encode()+eol
                    if name == 'later-progress':
                        # This known fixture has exactly one existing outside-fence block.
                        # No replacement is executed: this is expected-byte comparison only.
                        expected = initial.replace(CLOSE.encode(), entry.encode()+b'\n'+CLOSE.encode(), 1)
                    assert after == expected, 'ruling insertion changed non-rulings bytes or duplicated entry'
                    assert after.count(marker.encode()) == 1
                    receipt(product, case, after=after.decode(), after_sha256=sha(after))
                    case['checks'].append('One exact native insertion; fresh durable B1 preserves all B0 non-rulings bytes')
                    if name in ('ended-absent', 'ended-saved'):
                        assert not registry(product.runtime)['sessions'][worker['logical_session_id']].get('admitted')
                        case['checks'].append('Document-only recovery leaves native execution unadmitted')
                    if name == 'plan-progress':
                        progress_import = reimport_plan(product, path, sha(initial), 40)
                        assert state(product)['plans'][imported['plan_id']]['status'] == 'superseded'
                        same_import = reimport_plan(product, path, sha(initial), 40)
                        assert same_import['plan']['plan_id'] == progress_import['plan']['plan_id']
                        scope_edit = 'Executable scope changed independently\n'
                        product.ui('doc_edit', path=str(path), spec={'line': 2, 'insert': scope_edit})
                        changed = reimport_plan(product, path,
                            sha(initial.replace(b'\n', b'\n'+scope_edit.encode(), 1)), 60)
                        assert changed['plan']['plan_id'] != progress_import['plan']['plan_id']
                        assert state(product)['plans'][progress_import['plan']['plan_id']]['status'] == 'superseded'
                        receipt(product, case, progress_reimport=progress_import, unchanged_ruling_reimport=same_import,
                                independent_executable_reimport=changed)
        case['status'] = 'passed'
    except Exception:
        case['status'] = 'failed'
        case['error'] = traceback.format_exc()
    finally:
        try:
            if readonly_directory is not None:
                readonly_directory.chmod(readonly_modes[0])
                path.chmod(readonly_modes[1])
        except Exception:
            case['status'] = 'failed'
            case['permission_restore_error'] = traceback.format_exc()
        finally:
            if product:
                close_case(product, case)
    return case


def rulings(base, root, evidence, processes, lib, args):
    result = {'status': 'failed', 'cases': [], 'limits': [
        'Deterministic native programs prove component runtime, never real-model behavior.',
        'Canonical LF/CRLF/fence/delimiter/marker parser combinatorics belong to affected native module suites.',
        'B0/B1 is optimistic detection, not filesystem CAS.',
        'Actual Windows helper and locked-host qualifications are tracked separately; this entrypoint grants no unlock or policy override.']}
    result['scope'] = 'Named native runtime cases only; not the complete paired C3 qualification'
    result['required_qualification_dependencies'] = [
        {'suite': 'plugins/tern/ORCH+/tests/rulings.luau',
         'coverage': 'Canonical complete delimiter/fence/entry/EOF combinatorics and pure conflict transitions',
         'status': 'not_executed_by_this_entrypoint'},
        {'suite': 'plugins/tern/SPAWN/tests/mailbox_posix.py',
         'coverage': 'Real POSIX consumer rejects historical descriptors without explicit capability proof',
         'status': 'not_executed_by_this_entrypoint'},
        {'suite': 'plugins/tern/SPAWN/tests/mailbox_helpers.ps1',
         'coverage': 'Actual Windows helper consumes the same canonical corpus and refuses missing capability proof',
         'status': 'requires_actual_windows_qualification'},
    ]
    result['legacy_descriptor_scope'] = (
        'unsupported-helper uses a genuinely newly provisioned capability-limited native worker, NOT an old descriptor. '
        'No old-source native descriptor artifact is manufactured; historical missing-proof refusal remains a required helper-suite qualification.')
    evidence['rulings'] = result
    initial = b'# Existing owner document\n## Progress\nRoutine Progress before fresh B0\n'
    prior_block = ('\n'+OPEN+'\n> orchplus-ruling:authority_1:other_gate\n> Earlier entry\n'+CLOSE+'\n').encode()
    local_cases = [('unassociated', initial), ('lf', initial), ('crlf', initial.replace(b'\n', b'\r\n')),
                   ('no-eof', b'Existing document without final newline'), ('empty', b''),
                   ('dirty', initial), ('open-save', initial), ('lost-result', initial),
                   ('concurrent', initial), ('duplicate', initial), ('two-window', initial),
                   ('missing', initial), ('alias', initial), ('readonly', initial), ('plan-progress', PLAN),
                   ('ended-absent', initial), ('ended-saved', initial),
                   ('removed-after-read', initial),
                   ('fenced', b'# Existing\n```text\n'+prior_block+b'```\n'),
                   ('later-progress', b'Existing'+prior_block+b'## Progress\nLater progress\n'),
                   ('malformed', b'Existing\n'+OPEN.encode()+b'\n> Unclosed unmarked example\n'),
                   ('duplicate-block', b'Existing'+prior_block+prior_block)]
    remote_cases = [('unsupported-helper', False, False), ('authorized-helper', False, True),
                    ('provider-existing-writer', True, True)]
    selected, selection = select_runtime_cases(args, 'rulings',
        [name for name, _ in local_cases]+[name for name, _, _ in remote_cases]+['automatic-associated-decision'])
    result.update(selection=selection, qualification_complete=False)
    if not selected:
        result['status'] = 'not_run'
        return result
    unavailable = prerequisites()
    if unavailable:
        result.update(unavailable)
        return result
    for name, contents in local_cases:
        if name in selected:
            result['cases'].append(local_case(base, root, evidence, processes, lib, args, name, contents))
    for name, provider, capable in remote_cases:
        if name in selected:
            result['cases'].append(remote_case(base, root, evidence, processes, lib, args, provider, capable))
    if 'automatic-associated-decision' in selected:
        result['cases'].append(automatic_case(base, root, evidence, processes, lib, args))
    result['completed_cases'] = sum(case['status'] == 'passed' for case in result['cases'])
    result['status'] = ('failed' if any(case['status'] == 'failed' for case in result['cases'])
                        else 'unavailable' if any(case['status'] == 'unavailable' for case in result['cases']) else 'passed')
    result['qualification_complete'] = result['status'] == 'passed' and not selection['unrun']
    return result


def remote_case(base, root, evidence, processes, lib, args, provider=False, capable=True):
    name = 'provider-existing-writer' if provider else 'authorized-helper' if capable else 'unsupported-helper'
    case = {'name': name, 'status': 'failed', 'scope': 'actual typed helper route and authoritative host B1'}
    evidence.setdefault('c3_cases', {})['rulings-'+name] = case
    product = None
    try:
        product = Product(base, root, evidence, processes, lib, 'rulings-'+name, args, provider=provider, assignment_trace=True)
        product.result = {**product.result, **case}
        case = product.result
        evidence['c3_cases']['rulings-'+name] = case
        source_receipts(product)
        if not provider:
            shutil.copy2(TESTS/'ruling_worker.py', product.worker.parent/'ruling_worker.py')
            product.worker = product.worker.parent/'ruling_worker.py'
        initialize(product)
        record = 'c2-builder'
        if capable and not provider:
            record = 'c3-ruling-writer'
            product.create_record(record, 'OMP', coordinator=True)
        path = product.repository/'existing-authorized-writer.md'
        initial = b'# Existing document\n## Progress\nProgress observed before fresh B0\n'
        path.write_bytes(initial)
        prompt = None
        if capable:
            prompt = (
                'Bounded real-provider native ruling qualification, not a code task. Do not modify '
                'fixture.txt, Git, or any other document. Use your enrolled shipped report-files-v1 helper '
                'and this existing document only: '+str(path)+'. After ACCEPTED, send one ASK payload '
                +json.dumps({'question': QUESTION,
                             'options': [{'id': 'safe', 'label': 'Use reviewed path'}, {'id': 'hold', 'label': 'Hold'}],
                             'evidence': ['Existing document selected independently by the owner']})+'. '
                'On native wake consume the actual helper control, then end the turn idle: do not poll or keep a native-ask turn open. '
                'On owner_decision claim that exact message, resolve without changing the document, drain receipts, and end idle for record_ruling. '
                'The helper durably records reply_ack BEFORE returning record_ruling; receipt is not a write. '
                'Claim that exact message before effect. Verify the closed payload path, marker, entry, '
                'expected_document_sha256 and expected_non_rulings_sha256. Confirm the existing regular '
                'non-symlink path, no competing writer/dirty buffer, and fresh B0 SHA-256. This fixture '
                'has no ruling block, so non-rulings bytes equal B0: verify both hashes. If any check fails, '
                'do not edit or improvise. Otherwise append exactly LF, '+OPEN+', LF, literal payload.entry, '
                'LF, '+CLOSE+', LF. Existing-file targeted insertion/append only: no O_CREAT, truncation, '
                'replacement or force-save. Do not reformat, escape again or interpret the entry. '
                'Recheck marker absence before effect; preserve every original byte. Resolve only after '
                'durable readback shows the exact entry once. Remain idle for host confirmation; no new task, '
                'credentials or fabricated success. This assignment grants no additional capabilities.')
            if not provider:
                prompt += (' For this staged boundary cell, on record_ruling consume ONLY and end idle. '
                           'Do not claim until the explicit conversation turn CLAIM HELD RULING ONLY; '
                           'claim then return idle without writing or resolving. Only the subsequent '
                           'APPLY CLAIMED RULING turn permits the exact original authorized effect and resolution.')
        worker = assign(product, record, prompt)
        assert ('coordinator-control-v1' in worker.get('capabilities', [])) == capable
        associate(product, worker, path)
        if not capable:
            worker_command(product, worker['mailbox_handle'], 'ask')
        original = pending_gate(product, worker)
        answered = answer(product, worker, original)
        gid, obligation = original['id'], answered['ruling']
        receipt(product, case, worker=worker, original_gate=original, owner_obligation=obligation, before=initial.decode())
        if not capable:
            consume_decision(product, worker, gid)
        else:
            lib.wait_for(lambda: (gate(product, gid) or {}).get('delivery', {}).get('acknowledged'),
                         'real provider durable owner_decision receipt', 180)
        assert path.read_bytes() == initial, 'owner_decision alone wrote a document'
        select_worker(product, worker)
        product.ui('click_gate', pane=product.controller, gate_id=gid, label='Record through existing authorized worker…')
        product.ui.choose('Use one participating writer for this existing document?',
                          'I verified the remote writer exclusively owns the document, it is quiescent, and no participating buffer has unsaved edits')
        product.ui.choose('Select the existing document-owning authorized writer',
                          worker['worker_id']+' / '+worker['work_id'])
        if not capable:
            lib.wait_for(lambda: 'no provisioned coordinator-control-v1' in json.dumps(
                         product.ui('surface', pane=product.controller)), 'visible unsupported capability refusal', 45)
            assert path.read_bytes() == initial and gate(product, gid)['ruling']['entry'] == obligation['entry']
            assert not gate(product, gid).get('ruling_delivery')
            receipt(product, case, refusal_surface=product.ui('surface', pane=product.controller), retained_gate=gate(product, gid))
        else:
            if not provider:
                lib.wait_for(lambda: (gate(product, gid) or {}).get('ruling_delivery'), 'typed ruling enqueued', 90)
                box = product.runtime.root/'mailboxes'/worker['mailbox_handle']
                def receive():
                    journal = read_json(box/'producer/journal.json') or {}
                    for fact in journal.get('consumed', []):
                        reply = json.loads(base64.b64decode(fact['bytes']))
                        if reply.get('kind') == 'record_ruling' and reply.get('gate_id') == gid:
                            assert fact['execution'] == 'unclaimed', 'receipt was treated as execution permission'
                            delivery = (gate(product, gid) or {}).get('ruling_delivery') or {}
                            if delivery.get('acknowledged'):
                                return reply
                    return None
                reply = lib.wait_for(receive, 'actual helper durable ruling receive without document effect', 180)
                assert reply['gate_id'] == gid and reply['gate_revision'] == original['revision']
                assert reply['payload']['entry'] == obligation['entry']
                assert reply['payload']['expected_document_sha256'] == sha(initial)
                assert path.read_bytes() == initial and gate(product, gid)['ruling']
                receipt(product, case, durable_receipt_without_effect=reply, gate_after_receipt=gate(product, gid))
                provider_coordinator_prompt(product, worker,
                    'CLAIM HELD RULING ONLY. Claim the already consumed genuine record_ruling, then '
                    'end idle WITHOUT editing or resolving. Only APPLY CLAIMED RULING permits the effect.',
                    deadline=time.monotonic()+180)
                def claimed():
                    journal = read_json(box/'producer/journal.json') or {}
                    return next((fact for fact in journal.get('consumed', [])
                                 if fact['message_id'] == reply['message_id']
                                 and fact['execution'] == 'claimed'), None)
                claim = lib.wait_for(claimed, 'genuine helper claim before authorized document effect', 90)
                assert path.read_bytes() == initial
                receipt(product, case, genuine_claim_without_effect=claim)
                provider_coordinator_prompt(product, worker,
                    'APPLY CLAIMED RULING. Perform only the already claimed record_ruling exact authorized '
                    'append after all original checks, then resolve that message and drain receipts.',
                    deadline=time.monotonic()+180)
            expected = initial+b'\n'+OPEN.encode()+b'\n'+obligation['entry'].encode()+b'\n'+CLOSE.encode()+b'\n'
            lib.wait_for(lambda: path.read_bytes() != initial, 'actual existing authorized writer effect', 180)
            assert path.read_bytes() == expected
            assert gate(product, gid)['ruling'], 'helper receipt/effect alone falsely completed host obligation'
            receipt(product, case, durable_file_before_host_confirmation=path.read_bytes().decode(),
                    gate_before_host_confirmation=gate(product, gid))
            product.ui('click_gate', pane=product.controller, gate_id=gid, label='Reconcile ruling buffer and disk')
            product.ui.choose('Use one participating writer for this existing document?',
                              'I verified the remote writer exclusively owns the document, it is quiescent, and no participating buffer has unsaved edits')
            lib.wait_for(lambda: gate(product, gid) is None or not gate(product, gid).get('ruling'),
                         'authoritative host B1 confirms remote ruling', 90)
            assert path.read_bytes() == expected and path.read_bytes().count(obligation['marker'].encode()) == 1
            box = product.runtime.root/'mailboxes'/worker['mailbox_handle']
            journals = {str(p.relative_to(box)): p.read_text() for p in box.rglob('*.json')
                        if 'journal' in p.name or p.name == 'provision.json'}
            assert journals, 'actual provision/helper journal evidence missing'
            receipt(product, case, actual_helper_journals=journals,
                    after_sha256=sha(path.read_bytes()),
                    actual_provider_identity=provider_coordinator_identity(product, worker),
                    evidence_class='genuine Native OMP authorized writer; deterministic negative workers remain separate')
            if not provider:
                # Resolved, acknowledged entries are reclaimed by the helper.
                # The exact observed claim and advanced consumed floor prove
                # settlement without relying on a fixture event log.
                def resolved():
                    journal = read_json(box/'producer/journal.json') or {}
                    facts = [fact for fact in journal.get('consumed', [])
                             if fact['message_id'] == reply['message_id']]
                    if facts:
                        return journal if len(facts) == 1 and facts[0]['execution'] == 'resolved' else None
                    return journal if journal.get('consumed_reply_floor', 0) >= reply['reply_seq'] else None
                receipt(product, case, genuine_resolved_journal=lib.wait_for(
                    resolved, 'claimed ruling resolved through real producer helper', 90))
        case['checks'].append('Existing provisioned permission only; actual typed reply route, no capability backfill')
        case['status'] = 'passed'
    except Exception:
        case['status'] = 'failed'
        case['error'] = traceback.format_exc()
    finally:
        if product:
            close_case(product, case)
    return case


def automatic_case(base, root, evidence, processes, lib, args):
    """A real in-scope proposal is policy-answered, not relabelled as owner input."""
    case = {'name': 'automatic-associated-decision', 'status': 'failed'}
    evidence.setdefault('c3_cases', {})['rulings-automatic'] = case
    product = None
    try:
        product = Product(base, root, evidence, processes, lib, 'rulings-automatic', args, assignment_trace=True)
        product.result = {**product.result, **case}
        case = product.result
        evidence['c3_cases']['rulings-automatic'] = case
        source_receipts(product)
        shutil.copy2(TESTS/'ruling_worker.py', product.worker.parent/'ruling_worker.py')
        product.worker = product.worker.parent/'ruling_worker.py'
        initialize(product)
        coordinator = ensure_fixture_coordinator(product, deadline=time.monotonic()+240)
        document = product.repository/'existing-coordinator-document.md'
        initial = b'Existing coordinator document; automatic decisions must not append.\n'
        document.write_bytes(initial)
        activation = state(product)['workers'][coordinator['worker_id']]['activation']
        assert activation.get('acknowledged')
        case['coordinator_provider'] = provider_coordinator_identity(product, coordinator)
        associate(product, coordinator, document)
        plan = product.repository/'existing-automatic-plan.md'
        plan.write_bytes(PLAN)
        import_plan(product, plan)
        def target_ready():
            matches = [w for w in state(product)['workers'].values()
                       if w.get('source', {}).get('kind') == 'plan'
                       and w['source'].get('ref', '').startswith(str(plan)+'#') and w.get('phase') == 'accepted']
            assert len(matches) <= 1
            return matches[0] if matches else None
        target = lib.wait_for(target_ready, 'actual in-scope imported plan worker', 180)
        product.ui.click(product.controller, 'More…')
        product.ui.choose('Orchestration', 'Settings')
        before_policy = state(product)['policies'][coordinator['logical_session_id']]
        assert before_policy['auto_approve_kinds'] == []
        form = product.ui.form_pane('Orchestration settings')
        product.ui.mouse_click(form, 'ADVANCED')
        original_choices = product.ui.runtime.ctl('tree')
        product.ui.switch_field(form, 'Report', True)
        def approval_enabled():
            surface = product.ui('surface', pane=form)
            enabled = any(node.get('k') == 'switch' and node.get('p', {}).get('label') == 'Report'
                          and node.get('p', {}).get('on') is True
                          for node in surface_nodes(surface.get('main')))
            return product.ui.runtime.ctl('tree') if enabled else None
        changed_choices = lib.wait_for(approval_enabled, 'actual report approval choice is on', 30)
        receipt(product, case, native_approval_choices_before=original_choices,
                native_approval_choices_after=changed_choices)
        product.ui.mouse_click(form, 'SAVE FOR THIS ORCHESTRATION INSTANCE ONLY')
        lib.wait_for(lambda: state(product)['policies'][coordinator['logical_session_id']]['auto_approve_kinds'] == ['report'],
                     'ordinary grouped settings saved only report auto-approval', 45)
        proposal = {'proposal_id': 'ruling-report-'+str(time.time_ns()), 'kind': 'report',
                    'work_id': target['work_id'], 'project_id': 'rulings-runtime'}
        proposal_receipt = worker_command(product, coordinator['mailbox_handle'], 'propose-task', proposal)
        def policy_gate():
            matches = [g for g in state(product)['gates'].values()
                       if g['worker_id'] == coordinator['worker_id'] and g.get('kind') == 'coordinator_proposal'
                       and g.get('answer', {}).get('source', {}).get('kind') == 'policy']
            assert len(matches) <= 1
            return matches[0] if matches else None
        automatic = lib.wait_for(policy_gate, 'real native policy decision from actual helper proposal', 120)
        assert automatic.get('ruling') is None
        assert automatic['answer']['source']['rule'] == 'auto_approve:report'
        assert state(product)['workers'][coordinator['worker_id']]['ruling_document']['path'] == str(document)
        assert document.read_bytes() == initial and plan.read_bytes() == PLAN
        assert not any(g.get('ruling') for g in state(product)['gates'].values())
        receipt(product, case, activation=activation, in_scope_target=target, automatic_gate=automatic,
                document_sha256=sha(document.read_bytes()), plan_sha256=sha(plan.read_bytes()),
                genuine_coordinator_proposal=proposal_receipt)
        case['checks'].append('Actual associated policy decision creates no owner ruling or document mutation')
        case['status'] = 'passed'
    except Exception:
        case['status'] = 'failed'
        case['error'] = traceback.format_exc()
    finally:
        if product:
            close_case(product, case)
    return case

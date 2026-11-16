#!/usr/bin/env python3
"""Deterministic native qualification worker: real Git, helpers and enrolled launch.

This is not an AI reviewer or provider qualification. Its fixed review checks the
explicit fixture contract only. No test code writes an ORCH/SPAWN authority,
helper journal, grant, receipt or report chunk.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def atomic(path, value):
    pending = path.with_suffix('.pending')
    pending.write_text(json.dumps(value, ensure_ascii=False))
    os.replace(pending, path)


class Worker:
    def __init__(self, control, record, prompt):
        self.control, self.record = control, record
        self.repository = Path.cwd().resolve()
        assert self.repository.is_relative_to(control.parent.resolve()), 'repository is outside owned runtime'
        self.transport = json.loads(next(line.removeprefix('report-files-v1: ') for line in prompt.splitlines()
                                         if line.startswith('report-files-v1: ')))
        self.root = Path(self.transport['root'])
        assert self.root.resolve().is_relative_to(control.parent.resolve()), 'mailbox escaped owned runtime'
        self.handle = self.transport['mailbox_handle']
        self.box = self.root/self.handle
        self.out = control/self.handle
        # Test evidence lives outside product stores and is never a replay fence.
        # Record before mkdir so a duplicate native invocation is observed even
        # when the original worker's evidence directory correctly already exists.
        with (control/'native-launches.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps({'pid': os.getpid(), 'record_id': record,
                                     'mailbox_handle': self.handle,
                                     'worker_id': self.transport['binding']['worker_id'],
                                     'started_ns': time.time_ns()})+'\n')
        self.out.mkdir()
        self.argv = ['sh', self.transport['producer_helper'], str(self.root), self.handle,
                     self.transport['binding']['enrolment_token']]
        self.events, self.calls, self.last_command = [], [], None
        self.activation, self.proposals = None, set()
        self.released = False
        self.control_paused = False
        self.case = next(iter(re.findall(r'C2_CASE=(passed|failed|missing|stale|empty)', prompt)), None)
        self.target = 'refs/heads/main'
        self.branch = 'c2-'+self.handle
        atomic(self.out/'launched.json', {'pid': os.getpid(), 'record_id': record, 'case': self.case,
                                        'transport': self.transport, 'cwd': str(self.repository),
                                        'prompt_sha256': hashlib.sha256(prompt.encode()).hexdigest()})

    def save(self, kind, **data):
        self.events.append({'kind': kind, 'at_ns': time.monotonic_ns(), **data})
        atomic(self.out/'observations.json', {'events': self.events, 'helper_calls': self.calls})

    def git(self, *args):
        result = subprocess.run(['git', '-C', str(self.repository), *args], capture_output=True,
                                text=True, timeout=20, check=True)
        return result.stdout.strip()

    def helper(self, mode, value=None, message=''):
        # Only consume can safely repeat this exact refusal: its POSIX path
        # emits producer_locked before acquiring producer/lock, never after an
        # effect. wait can emit it on re-admission after receipts/consumption;
        # run-checks can already have executed a check before initial admission.
        # Keep checkpoint mutations and uncertain wait outcomes fail-closed.
        deadline = time.monotonic()+10
        while True:
            start = time.monotonic_ns()
            result = subprocess.run(self.argv+[mode, message, '1', '1'],
                                    input=json.dumps(value, ensure_ascii=False).encode() if value is not None else b'',
                                    capture_output=True, timeout=35)
            diagnostic = result.stderr.decode(errors='replace')
            self.calls.append({'mode': mode, 'message': message, 'returncode': result.returncode,
                               'stderr': diagnostic, 'stdout_bytes': len(result.stdout),
                               'started_ns': start, 'finished_ns': time.monotonic_ns()})
            if result.returncode == 0:
                return result.stdout
            # A retained producer lock/workspace is recovery state, not normal
            # target admission. Observe only; never remove or take either lock.
            recovery = (self.box/'producer/lock',
                        self.box/'staging'/('worker-'+self.transport['binding']['enrolment_token']))
            retry = (mode == 'consume' and result.returncode == 1
                     and result.stderr == b'producer_locked\n' and not result.stdout
                     and not any(os.path.lexists(path) for path in recovery)
                     and time.monotonic() < deadline
                     and not (self.control/'stop').exists())
            self.save('helper_admission_refused' if retry else 'helper_failed',
                      operation=mode, diagnostic=diagnostic, retry=retry)
            assert retry, (mode, diagnostic)
            time.sleep(.1)

    def settle(self, sequence):
        deadline = time.monotonic()+120
        path = self.box/'acks'/f'{sequence}.json'
        while not path.exists():
            assert time.monotonic() < deadline, 'native report intake/ACK deadline'
            assert not (self.control/'stop').exists(), 'supervisor stopped worker'
            time.sleep(.1)
        ack = read_json(path)
        assert ack, 'incomplete actual ACK'
        self.helper('receipts')
        return ack

    def report(self, kind, payload, reply=None):
        sequence = read_json(self.box/'producer/journal.json')['next_seq']
        value = {'kind': kind, 'payload': payload}
        if reply:
            value.update(action_id=reply['action_id'], action_revision=reply['action_revision'])
        self.helper('report', value)
        ack = self.settle(sequence)
        self.save('report', report=value, seq=sequence, ack=ack)

    def evidence(self, mode, message=''):
        sequence = read_json(self.box/'producer/journal.json')['next_seq']
        self.helper(mode, message=message)
        ack = self.settle(sequence)
        self.save('helper_evidence', operation=mode, check_id=message, seq=sequence, ack=ack)

    def checkpoint(self):
        head = self.git('rev-parse', 'HEAD')
        self.checkpoint_id = 'cp-'+head[:16]
        self.report('CHECKPOINT', {'checkpoint_id': self.checkpoint_id,
                    'task_ref': self.transport['binding']['work_id'], 'project_id': 'c2-runtime',
                    'worktree_ref': str(self.repository), 'artifact_revision': head,
                    'completed': ['Created the declared deterministic policy fixture'],
                    'remaining': [], 'holds': [], 'checks': []})
        self.report('REVIEW_READY', {'checkpoint_id': self.checkpoint_id, 'artifact_revision': head})
        return head

    def request_landing(self):
        self.report('LANDING_REQUEST', {'checkpoint_id': self.checkpoint_id, 'project_id': 'c2-runtime',
                    'repo_ref': str(self.repository), 'target_ref': self.target,
                    'target_revision': self.git('rev-parse', self.target),
                    'source_ref': 'refs/heads/'+self.branch, 'source_revision': self.git('rev-parse', 'HEAD')})

    def commit(self, contents, message):
        (self.repository/'fixture.txt').write_text(contents)
        self.git('add', 'fixture.txt')
        self.git('commit', '-q', '--allow-empty', '-m', message)

    def prepare(self):
        assert self.case, 'builder assignment lacks explicit deterministic fixture case'
        self.git('checkout', '-q', '-b', self.branch, self.target)
        self.evidence('checkout')
        self.commit('bad\n' if self.case == 'failed' else 'good\n', 'Controlled '+self.case+' fixture')
        if self.case not in ('missing', 'empty'):
            self.evidence('run-checks', 'fixture')
        if self.case == 'stale':
            self.commit('good\nnew revision invalidates earlier evidence\n', 'Create actual stale-check revision')
        self.evidence('checkout')
        head = self.checkpoint()
        self.request_landing()
        self.save('prepared', case=self.case, head=head, checkpoint_id=self.checkpoint_id)

    def repair(self):
        # Check-only rework is observed before this ordinary fixture command is
        # issued. A fresh real commit and helper check repair the failing input.
        self.commit('good\nrepaired by deterministic worker\n', 'Repair controlled fixture')
        self.evidence('run-checks', 'fixture')
        self.evidence('checkout')
        head = self.checkpoint()
        self.request_landing()
        self.save('repaired', head=head)

    def propose(self, payload, kind):
        """Propose fixture work using this process's actual activation only.

        The driver supplies closed new_work or plan_file add_source intent, not an owner identity or an
        authority mutation. Native helper intake, owner approval and project
        START remain independent product operations.
        """
        assert self.activation is not None, 'coordinator activation has not been consumed'
        assert 'coordinator-control-v1' in self.transport['capabilities']
        assert isinstance(payload, dict) and payload.get('kind') == kind
        if kind == 'new_work':
            required = {'proposal_id', 'kind', 'record_id', 'record_revision', 'prompt', 'scope', 'checks'}
            optional = {'orch_project_id', 'new_project_name', 'base_ref', 'repository_id',
                        'target_ref', 'target_revision'}
        else:
            assert kind == 'add_source', 'fixture command only proposes work or a literal owned plan source'
            required, optional = {'proposal_id', 'kind', 'source'}, {'orch_project_id', 'new_project_name'}
            source = payload['source']
            assert isinstance(source, dict) and set(source) == {'kind', 'path', 'revision'}
            assert source['kind'] == 'plan_file'
            path = Path(source['path'])
            assert path.is_absolute() and path.resolve().is_relative_to(self.control.parent.resolve())
            assert hashlib.sha256(path.read_bytes()).hexdigest() == source['revision'], 'source changed before physical proposal'
        assert required <= payload.keys() <= required | optional
        assert ('orch_project_id' in payload) != ('new_project_name' in payload)
        proposal_id = payload['proposal_id']
        assert proposal_id not in self.proposals, 'never allocate another report for an uncertain proposal'
        self.proposals.add(proposal_id)
        self.report('COORDINATOR_PROPOSAL', dict(payload, **self.activation))
        self.save('task_proposed' if kind == 'new_work' else 'source_proposed', proposal_id=proposal_id, payload=payload)

    def consume(self):
        output = self.helper('consume')
        if not output:
            return False
        reply = json.loads(output)
        self.helper('claim', message=reply['message_id'])
        self.save('reply', reply=reply, sha256=hashlib.sha256(output).hexdigest())
        kind, payload = reply['kind'], reply['payload']
        if kind == 'coordinator_activation':
            assert 'coordinator-control-v1' in self.transport['capabilities']
            assert self.activation is None, 'coordinator was activated twice'
            self.activation = {key: payload[key] for key in ('owner_id', 'owner_generation', 'activation_token')}
            self.save('activated', activation=self.activation)
        elif kind == 'project_start':
            assert self.activation is not None, 'project start requires consumed activation'
            assert {'coordinator-control-v1', 'project-start-v1'} <= set(self.transport['capabilities'])
            assert set(payload) == {'owner_id', 'owner_generation', 'activation_token',
                                    'orch_project_id', 'project_revision', 'decision_context'}
            assert {key: payload[key] for key in self.activation} == self.activation
            # The real helper has already consumed/claimed this immutable message.
            # report waits for actual host acceptance before the control is resolved.
            self.report('PROJECT_START_CLAIM', dict(payload), reply)
            self.save('project_started', orch_project_id=payload['orch_project_id'],
                      project_revision=payload['project_revision'], message_id=reply['message_id'])
        elif kind == 'coordinator_retirement':
            assert self.activation is not None
            assert {key: payload[key] for key in self.activation} == self.activation
            self.report('COORDINATOR_RELEASE', dict(self.activation, quiescent=True), reply)
            self.released = True
            self.activation = None
        elif kind == 'review_request':
            # Fixed fixture contract: the deliberately bad check is permitted;
            # review checks that the artifact is committed and fixture-shaped.
            artifact = payload['artifact_revision']
            self.git('cat-file', '-e', artifact+'^{commit}')
            contents = self.git('show', artifact+':fixture.txt')
            assert contents.splitlines()[0] in ('good', 'bad'), 'artifact is not the declared fixture'
            self.report('REVIEW_RESULT', {'review_id': payload['review_id'], 'round': payload['round'],
                        'artifact_revision': artifact, 'outcome': 'approved', 'findings': [],
                        'summary': 'Deterministic fixture-only review: committed fixture shape verified; declared checks independently decide landing.'}, reply)
        elif kind == 'landing_grant':
            assert self.record == 'c2-release', 'grant delivered to non-release fixture'
            assert payload['target_ref'] == self.target
            assert self.git('rev-parse', self.target) == payload['target_revision'], 'target moved before grant execution'
            self.git('merge-base', '--is-ancestor', payload['target_revision'], payload['source_revision'])
            self.git('update-ref', self.target, payload['source_revision'], payload['target_revision'])
            observed = self.git('rev-parse', self.target)
            assert observed == payload['source_revision'], 'real Git landing did not move target'
            self.report('LANDING_RESULT', {key: payload[key] for key in
                        ('landing_id', 'grant_id', 'project_id', 'repo_ref', 'target_ref', 'target_revision', 'source_revision')}
                        | {'outcome': 'landed', 'result_revision': observed,
                           'evidence': ['actual disposable git update-ref with expected old target']}, reply)
            self.save('landed', grant=reply, result_revision=observed)
        elif kind == 'rework':
            self.save('rework_received', payload=payload)
        elif kind == 'report_request':
            self.report('BLOCKED', {'reason': 'Controlled fixture waiting for its next native scenario step', 'evidence': []})
        else:
            self.save('reply_without_effect', reply_kind=kind)
        self.helper('resolve', message=reply['message_id'])
        if kind in ('coordinator_activation', 'coordinator_retirement', 'project_start'):
            self.helper('receipts')
            self.save('resolved', message_id=reply['message_id'], reply_kind=kind)
        return True

    def run(self):
        self.helper('init')
        self.report('ACCEPTED', {'assignment_sha256': self.transport['assignment_sha256']})
        deadline = time.monotonic()+900
        finished = False
        while not (self.control/'stop').exists():
            assert time.monotonic() < deadline, 'bounded deterministic worker expired'
            command = read_json(self.out/'command.json')
            if command and command['id'] != self.last_command:
                self.last_command = command['id']
                operation = command['op']
                if operation == 'prepare':
                    self.prepare()
                elif operation == 'repair':
                    self.repair()
                elif operation == 'repeat-ready':
                    self.report('REVIEW_READY', {'checkpoint_id': self.checkpoint_id, 'artifact_revision': self.git('rev-parse', 'HEAD')})
                elif operation == 'run-current-check':
                    self.evidence('run-checks', 'fixture')
                    # The unchanged, already-approved landing advances when its
                    # missing/stale checks arrive. A second request races that
                    # grant and is correctly refused as landing_in_progress.
                elif operation in ('propose-task', 'propose-source'):
                    self.propose(command['payload'], 'new_work' if operation == 'propose-task' else 'add_source')
                elif operation == 'pause-control':
                    self.control_paused = True
                    self.save('control_paused')
                elif operation == 'resume-control':
                    self.control_paused = False
                    self.save('control_resumed')
                elif operation == 'finish':
                    finished = True
                else:
                    raise AssertionError('unknown deterministic worker operation '+operation)
                atomic(self.out/'command-result.json', {'id': command['id'], 'ok': True})
            if not finished and not self.released and not self.control_paused:
                self.consume()
            time.sleep(.5)


def main():
    worker = Worker(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
    try:
        worker.run()
    except Exception as error:
        atomic(worker.out/'error.json', {'error': f'{type(error).__name__}: {error}'})
        raise


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Fixed native recovery participant, never provider/model qualification.

Only the installed producer helper writes transport state. File gates below delay
this program's own real work; they cannot synthesize a grant, result or identity.
"""
import hashlib
import os
import json
from pathlib import Path
import sys
import time

from policy_worker import Worker, atomic, read_json


class RecoveryWorker(Worker):
    def report(self, kind, payload, reply=None):
        sequence = read_json(self.box/'producer/journal.json')['next_seq']
        value = {'kind': kind, 'payload': payload}
        if reply:
            value.update(action_id=reply['action_id'], action_revision=reply['action_revision'])
        if kind == 'ACCEPTED' and self.transport.get('handover_id'):
            value.update({key: self.transport[key] for key in ('handover_id', 'handover_token')})
        self.helper('report', value)
        ack = self.settle(sequence)
        self.save('report', report=value, seq=sequence, ack=ack)

    def gate(self, name):
        deadline = time.monotonic()+180
        while (self.control/name).exists():
            assert time.monotonic() < deadline, 'bounded recovery gate expired: '+name
            assert not (self.control/'stop').exists(), 'owned supervisor stopped participant'
            time.sleep(.1)

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
            self.activation = {key: payload[key] for key in ('owner_id', 'owner_generation', 'activation_token')}
            self.save('activated', activation=self.activation)
        elif kind == 'coordinator_retirement':
            assert {key: payload[key] for key in self.activation} == self.activation
            self.save('retirement_received', reply=reply)
            self.gate('hold-retirement')
            self.report('COORDINATOR_RELEASE', self.activation | {'quiescent': True}, reply)
            self.released = True
        elif kind == 'report_request' and payload['requested_kind'] == 'CHECKPOINT':
            assert not self.released, 'retired coordinator must not start work'
            self.gate('hold-checkpoint')
            revision = self.git('rev-parse', 'HEAD')
            # A real, read-only bounded check; its complete output is evidence,
            # rather than a scripted declaration that an unrun check passed.
            checked = (self.repository/'fixture.txt').read_bytes()
            assert checked == b'good\n', 'disposable fixture contract failed'
            digest = hashlib.sha256(checked).hexdigest()
            atomic(self.out/'checkpoint-check.json', {'artifact_revision': revision,
                   'file': 'fixture.txt', 'sha256': digest, 'bytes': len(checked),
                   'outcome': 'passed', 'checked_ns': time.time_ns()})
            self.report('CHECKPOINT', {'checkpoint_id': 'recovery-'+payload['request_id'],
                        'request_id': payload['request_id'],
                        'task_ref': self.transport['binding']['work_id'],
                        'project_id': 'c3-recovery', 'worktree_ref': str(self.repository),
                        'artifact_revision': revision,
                        'completed': ['Read and verified the unchanged disposable fixture'],
                        'remaining': ['Wait for the owner-controlled handover'], 'holds': [],
                        'checks': [{'check_id': 'fixture', 'artifact_revision': revision,
                                    'outcome': 'passed', 'evidence_ref': str(self.out/'checkpoint-check.json')}]}, reply)
        elif kind == 'report_request':
            self.report('HEARTBEAT', {'state': 'idle', 'request_id': payload['request_id']})
        else:
            raise AssertionError('unexpected recovery participant control: '+kind)
        self.helper('resolve', message=reply['message_id'])
        self.helper('receipts')
        self.save('resolved', message_id=reply['message_id'], reply_kind=kind)
        return True

    def run(self):
        self.activation, self.released = None, False
        self.helper('init')
        if self.transport.get('handover_id'):
            self.gate('hold-successor-accept')
        self.report('ACCEPTED', {'assignment_sha256': self.transport['assignment_sha256']})
        deadline = time.monotonic()+900
        while not (self.control/'stop').exists():
            assert time.monotonic() < deadline, 'bounded recovery worker expired'
            # Retirement resolution drains the final receipts before returning.
            # Stay quiescent afterward: another consume can own mailbox locks
            # when ORCH performs the already-authorized native stop.
            if not self.released:
                self.consume()
            time.sleep(.2)


def main():
    if len(sys.argv) == 3:
        control, record = Path(sys.argv[1]), sys.argv[2]
        with (control/'native-launches.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps({'pid': os.getpid(), 'record_id': record,
                                     'started_ns': time.time_ns(), 'kind': 'ordinary-terminal'})+'\n')
        deadline = time.monotonic()+300
        while not (control/'stop').exists():
            assert time.monotonic() < deadline, 'bounded ordinary participant expired'
            time.sleep(.2)
        return
    worker = RecoveryWorker(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
    try:
        worker.run()
    except Exception as error:
        atomic(worker.out/'error.json', {'error': f'{type(error).__name__}: {error}'})
        raise


if __name__ == '__main__':
    main()

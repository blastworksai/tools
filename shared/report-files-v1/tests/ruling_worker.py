#!/usr/bin/env python3
"""Bounded ordinary enrolled worker; helper journals and authorities are never edited.

This fixed program is component-runtime evidence, not model/provider evidence.
Commands only request genuine ASK reports and the shipped consume/claim/resolve path.
"""
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import traceback

from policy_worker import Worker, atomic, read_json


class RulingWorker(Worker):
    def consume_ruling(self, execute=False):
        raw = self.helper('consume')
        if not raw:
            return None
        reply = json.loads(raw)
        self.save('received', reply=reply, sha256=hashlib.sha256(raw).hexdigest())
        # consume durably records reply_ack; it does NOT imply an effect.
        if reply['kind'] == 'record_ruling' and not execute:
            return reply
        self.helper('claim', message=reply['message_id'])
        self.save('claimed', message_id=reply['message_id'])
        if reply['kind'] == 'record_ruling':
            assert 'coordinator-control-v1' in self.transport['capabilities']
            payload = reply['payload']
            assert set(payload) == {'path', 'marker', 'entry', 'expected_document_sha256',
                                    'expected_non_rulings_sha256'}
            path = Path(payload['path'])
            assert path.is_absolute() and path.is_relative_to(self.control.parent)
            assert not path.is_symlink() and path.is_file()
            # This deterministic existing writer accepts only its simple fixture.
            # General canonical parsing remains the product's native module suite.
            before = path.read_bytes()
            assert b'orchplus-operator-rulings' not in before
            digest = hashlib.sha256(before).hexdigest()
            assert digest == payload['expected_document_sha256']
            assert digest == payload['expected_non_rulings_sha256']
            assert payload['marker'].encode() not in before
            eol = '\r\n' if b'\r\n' in before else '\n'
            addition = (eol + '<!-- orchplus-operator-rulings v1 -->' + eol
                        + payload['entry'].replace('\n', eol) + eol
                        + '<!-- /orchplus-operator-rulings v1 -->' + eol).encode()
            # No O_CREAT, truncate, whole-file replacement or forced buffer save.
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
            try:
                assert path.read_bytes() == before
                assert os.write(fd, addition) == len(addition)
                os.fsync(fd)
            finally:
                os.close(fd)
            self.save('document_effect', message_id=reply['message_id'], path=str(path),
                      before_sha256=digest, after_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        else:
            assert reply['kind'] in ('owner_decision', 'report_request', 'coordinator_activation'), reply
            if reply['kind'] == 'coordinator_activation':
                self.activation = reply['payload']
            if reply['kind'] == 'report_request':
                self.report('BLOCKED', {'reason': 'Bounded ruling qualification is waiting for an owner step', 'evidence': []})
        self.helper('resolve', message=reply['message_id'])
        self.save('resolved', message_id=reply['message_id'])
        return reply

    def run(self):
        self.activation = None
        self.helper('init')
        self.report('ACCEPTED', {'assignment_sha256': self.transport['assignment_sha256']})
        self.save('ready')
        deadline = time.monotonic() + 1800
        while not (self.control/'stop').exists():
            assert time.monotonic() < deadline, 'bounded ruling worker expired'
            command = read_json(self.out/'command.json')
            if command and command['id'] != self.last_command:
                self.last_command = command['id']
                op = command['op']
                value = None
                if op == 'ask':
                    self.report('ASK', {'question': 'Which path should this exact ruling fixture take?',
                                'options': [{'id': 'safe', 'label': 'Use reviewed path'},
                                            {'id': 'hold', 'label': 'Hold'}],
                                'evidence': ['Existing document selected independently by the owner']})
                elif op in ('consume', 'execute'):
                    value = self.consume_ruling(execute=op == 'execute')
                elif op == 'receipts':
                    self.helper('receipts')
                elif op == 'propose_report':
                    assert self.activation is not None, 'actual typed activation must precede proposal'
                    payload = {key: self.activation[key] for key in ('owner_id', 'owner_generation', 'activation_token')}
                    payload.update(proposal_id='ruling-report-'+str(command['id']), kind='report',
                                   work_id=command['work_id'], project_id='rulings-runtime')
                    self.report('COORDINATOR_PROPOSAL', payload)
                else:
                    raise AssertionError('unknown ruling fixture operation: '+op)
                self.save('command', operation=op, result=value)
                atomic(self.out/'command-result.json', {'id': command['id'], 'op': op, 'value': value})
            time.sleep(.1)


if __name__ == '__main__':
    worker = None
    try:
        control, record, prompt = sys.argv[1:4]
        worker = RulingWorker(Path(control), record, prompt)
        worker.run()
    except Exception:
        if worker is not None:
            atomic(worker.out/'error.json', {'traceback': traceback.format_exc()})
        raise

#!/usr/bin/env python3
"""C4 disposable Git worker; real enrollment, helper reports and native grants."""
import hashlib
import json
from pathlib import Path
import sys
import time

from policy_worker import Worker, atomic, read_json


class RepositoryWorker(Worker):
    def __init__(self, control, record, prompt):
        super().__init__(control, record, prompt)
        self.scene = read_json(control/'repository-scene.json')
        assert self.scene, 'missing explicit repository scenario'
        self.target = self.scene['targets'].get(record, 'refs/heads/main')
        self.pending_grant = None
        self.delayed_result = None

    def prepare(self):
        assert self.record in ('c2-builder', 'c4-builder')
        if self.scene['case'] == 'shared' and self.record == 'c4-builder':
            # The second shared-tree worker only observes the first artifact.
            # There are never concurrent fixture writes to the shared worktree.
            self.branch = self.git('symbolic-ref', '--short', 'HEAD')
        else:
            self.git('checkout', '-q', '-b', self.branch, self.target)
            self.commit('good\n'+self.record+'\n', 'C4 artifact '+self.record)
        self.evidence('run-checks', 'fixture')
        self.evidence('checkout')
        head = self.checkpoint()
        self.request_landing()
        self.save('prepared', head=head, checkpoint_id=self.checkpoint_id,
                  common_dir=self.git('rev-parse', '--path-format=absolute', '--git-common-dir'))

    def refresh(self):
        assert self.record == 'c4-builder' and self.scene['case'] == 'stale-head'
        payload = self.refresh_request
        assert payload and self.git('rev-parse', self.target) == payload['current_revision']
        self.branch += '-refreshed'
        self.git('checkout', '-q', '-b', self.branch, payload['current_revision'])
        self.commit('good\n'+self.record+'\nrefreshed\n', 'C4 refreshed artifact')
        self.evidence('run-checks', 'fixture')
        self.evidence('checkout')
        head = self.checkpoint()
        self.request_landing()
        self.save('refreshed', head=head, target_revision=payload['current_revision'])

    def advance(self):
        """Create fresh checked work on the actual current target, never land it."""
        assert self.scene['case'] == 'late-results'
        assert self.record in ('c2-builder', 'c4-builder')
        target = self.git('rev-parse', self.target)
        self.branch += '-next-' + target[:12]
        self.git('checkout', '-q', '-b', self.branch, target)
        self.commit('good\n'+self.record+'\n'+self.branch+'\n', 'C4 next actual artifact')
        self.evidence('run-checks', 'fixture')
        self.evidence('checkout')
        head = self.checkpoint()
        self.request_landing()
        self.save('advanced', head=head, target_revision=target, checkpoint_id=self.checkpoint_id)

    def capture_stale(self):
        """Hold this real read in worker memory; no mailbox/store bytes are edited."""
        assert self.scene['case'] == 'late-results' and self.record == 'c2-release'
        assert self.pending_grant is not None and self.delayed_result is None
        payload = self.pending_grant['payload']
        repository = Path(payload['repo_ref']).resolve()
        assert repository.is_relative_to(self.control.parent.resolve())
        self.repository = repository
        observed = self.git('rev-parse', payload['target_ref'])
        assert observed != payload['target_revision'], 'capture requires actual target movement'
        self.delayed_result = {key: payload[key] for key in
                               ('landing_id', 'grant_id', 'project_id', 'repo_ref', 'target_ref',
                                'target_revision', 'source_revision')}
        self.delayed_result.update(outcome='stale_target', observed_target_revision=observed,
                                   evidence=['actual disposable Git rev-parse '+payload['target_ref']+' = '+observed])
        self.save('result_delayed', result=self.delayed_result, reply=self.pending_grant,
                  observed_head=observed)

    def deliver_stale(self):
        assert self.delayed_result is not None and self.pending_grant is not None
        result, reply = self.delayed_result, self.pending_grant
        self.report('LANDING_RESULT', result, reply)
        self.helper('resolve', message=reply['message_id'])
        self.save('delayed_result_delivered', result=result, reply=reply)
        self.delayed_result, self.pending_grant = None, None

    def consume(self):
        if self.pending_grant is not None:
            return False
        output = self.helper('consume')
        if not output:
            return False
        reply = json.loads(output)
        self.helper('claim', message=reply['message_id'])
        self.save('reply', reply=reply, sha256=hashlib.sha256(output).hexdigest())
        if reply['kind'] == 'landing_grant':
            assert self.record == 'c2-release', 'grant delivered to a builder'
            self.pending_grant = reply
            self.save('grant_held', landing_id=reply['payload']['landing_id'],
                      grant_id=reply['payload']['grant_id'])
            return True  # Keep the producer's exact unresolved command until instructed.
        if reply['kind'] == 'landing_refresh':
            assert ((self.record == 'c4-builder' and self.scene['case'] == 'stale-head')
                    or (self.scene['case'] == 'late-results' and self.record in ('c2-builder', 'c4-builder')))
            self.refresh_request = reply['payload']
            self.save('refresh_requested', payload=self.refresh_request)
        elif reply['kind'] == 'deploy_grant':
            payload = reply['payload']
            self.report('DEPLOY_RESULT', {key: payload[key] for key in
                        ('deploy_id', 'attempt_id', 'landing_id', 'revision')}
                        | {'outcome': 'not_applicable', 'reason': 'Disposable Git fixture defines no service deployment.',
                           'evidence': ['owned repository only']}, reply)
        elif reply['kind'] == 'report_request':
            self.report('HEARTBEAT', {'state': 'working'})
        else:
            self.save('reply_without_effect', reply_kind=reply['kind'])
        self.helper('resolve', message=reply['message_id'])
        return True

    def release(self, outcome):
        reply = self.pending_grant
        assert reply and outcome in ('landed', 'rejected', 'uncertain')
        payload = reply['payload']
        repository = Path(payload['repo_ref']).resolve()
        assert repository.is_relative_to(self.control.parent.resolve()), 'grant repository escaped the owned fixture'
        self.repository = repository
        observed = self.git('rev-parse', payload['target_ref'])
        result = {key: payload[key] for key in
                  ('landing_id', 'grant_id', 'project_id', 'repo_ref', 'target_ref', 'target_revision', 'source_revision')}
        if outcome == 'landed':
            assert observed == payload['target_revision'], 'actual target moved before release'
            self.git('merge-base', '--is-ancestor', observed, payload['source_revision'])
            self.git('update-ref', payload['target_ref'], payload['source_revision'], observed)
            observed = self.git('rev-parse', payload['target_ref'])
            assert observed == payload['source_revision']
            result.update(outcome='landed', result_revision=observed,
                          evidence=['actual disposable Git compare-and-swap update-ref'])
        else:
            result.update(outcome=outcome, reason='Controlled worker outcome; no target mutation was attempted.',
                          evidence=['observed target '+observed])
        self.report('LANDING_RESULT', result, reply)
        self.helper('resolve', message=reply['message_id'])
        self.pending_grant = None
        self.save('release_result', outcome=outcome, landing_id=payload['landing_id'], observed_head=observed)

    def run(self):
        self.helper('init')
        self.report('ACCEPTED', {'assignment_sha256': self.transport['assignment_sha256']})
        deadline = time.monotonic()+900
        while not (self.control/'stop').exists():
            assert time.monotonic() < deadline, 'bounded repository worker expired'
            command = read_json(self.out/'command.json')
            if command and command['id'] != self.last_command:
                self.last_command = command['id']
                operation = command['op']
                if operation == 'prepare':
                    self.prepare()
                elif operation == 'refresh':
                    self.refresh()
                elif operation == 'advance':
                    self.advance()
                elif operation == 'capture-stale':
                    self.capture_stale()
                elif operation == 'deliver-stale':
                    self.deliver_stale()
                elif operation in ('landed', 'rejected', 'uncertain'):
                    self.release(operation)
                else:
                    raise AssertionError('unknown repository fixture operation '+operation)
                atomic(self.out/'command-result.json', {'id': command['id'], 'ok': True})
            self.consume()
            time.sleep(.5)


def main():
    worker = RepositoryWorker(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
    try:
        worker.run()
    except Exception as error:
        atomic(worker.out/'error.json', {'error': f'{type(error).__name__}: {error}'})
        raise


if __name__ == '__main__':
    main()

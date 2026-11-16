#!/usr/bin/env python3
"""Deterministic terminal worker launched only by the real SPAWN managed route."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def main():
    control = Path(sys.argv[1])
    prompt = sys.argv[2]
    line = next(line for line in prompt.splitlines() if line.startswith('report-files-v1: '))
    transport = json.loads(line.removeprefix('report-files-v1: '))
    root, handle = Path(transport['root']), transport['mailbox_handle']
    assert root.resolve().is_relative_to(control.parent.resolve()), 'mailbox escaped isolated runtime'
    binding = transport['binding']
    argv = ['sh', transport['producer_helper'], str(root), handle, binding['enrolment_token']]
    invocations = []
    def call(mode, value=None):
        started_ns = time.monotonic_ns()
        started_epoch_ns = time.time_ns()
        result = subprocess.run(argv+[mode, '', '1', '2'], input=json.dumps(value, ensure_ascii=False).encode() if value else b'', capture_output=True, timeout=30)
        invocations.append({'mode': mode, 'started_monotonic_ns': started_ns,
                            'started_epoch_ns': started_epoch_ns, 'finished_monotonic_ns': time.monotonic_ns(),
                            'returncode': result.returncode})
        assert result.returncode == 0, (mode, result.stderr.decode(errors='replace'))
        return result
    def wait_for(predicate):
        deadline = time.monotonic()+300
        while not predicate():
            assert time.monotonic() < deadline, 'worker boundary timed out'
            time.sleep(.05)
    def receipt(seq):
        return root/handle/'acks'/f'{seq}.json'
    def publish(name, value):
        (control/(name+'.json')).write_text(json.dumps(value))
    # Invocation itself proves exact argv forwarding to a new managed terminal.
    publish('launched', {'pid': os.getpid(), 'transport': transport, 'prompt_sha256': hashlib.sha256(prompt.encode()).hexdigest()})
    call('init')
    call('report', {'kind': 'ACCEPTED', 'payload': {'assignment_sha256': transport['assignment_sha256']}})
    wait_for(lambda: receipt(1).exists())
    call('receipts')
    publish('accepted', {'ack': json.loads(receipt(1).read_text()), 'helper_invocations': invocations})
    wait_for(lambda: (control/'publish').exists())
    # A multi-chunk real report, with non-ASCII data crossing chunk boundaries.
    refs = [f'evidence-{i}:'+('x'*450)+'é' for i in range(24)]
    report_start_ns, report_start_epoch_ns = time.monotonic_ns(), time.time_ns()
    call('report', {'kind': 'BLOCKED', 'payload': {'reason': 'Native report qualification', 'evidence': refs}})
    publication_return_ns, publication_return_epoch_ns = time.monotonic_ns(), time.time_ns()
    publish('reported', {'seq': 2, 'journal': json.loads((root/handle/'producer/journal.json').read_text()),
                         'report_started_monotonic_ns': report_start_ns, 'report_started_epoch_ns': report_start_epoch_ns,
                         'publication_return_monotonic_ns': publication_return_ns, 'publication_return_epoch_ns': publication_return_epoch_ns,
                         'helper_invocations': invocations})
    wait_for(lambda: receipt(2).exists())
    ack_observed_ns, ack_observed_epoch_ns = time.monotonic_ns(), time.time_ns()
    publish('ack-published', {'ack': json.loads(receipt(2).read_text()), 'ack_sha256': hashlib.sha256(receipt(2).read_bytes()).hexdigest(),
                              'ack_observed_monotonic_ns': ack_observed_ns, 'ack_observed_epoch_ns': ack_observed_epoch_ns,
                              'ack_file_mtime_epoch_ns': receipt(2).stat().st_mtime_ns,
                              'report_to_ack_ms': (ack_observed_ns-report_start_ns)/1_000_000,
                              'publication_return_to_ack_ms': (ack_observed_ns-publication_return_ns)/1_000_000})
    # Supervisor reloads real plugins while delivery remains outstanding. No fake
    # process callback or successful result is injected into either product.
    wait_for(lambda: (control/'consume').exists())
    call('receipts')
    journal = json.loads((root/handle/'producer/journal.json').read_text())
    assert journal['pending'] == [], 'helper did not consume durable ACK'
    publish('settled', {'journal': journal, 'ack_sha256': hashlib.sha256(receipt(2).read_bytes()).hexdigest(),
                        'helper_invocations': invocations})
    # Preserve the enrolled terminal's native identity until the supervisor ends it.
    wait_for(lambda: (control/'stop').exists())


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        if len(sys.argv) > 1:
            (Path(sys.argv[1])/'worker-error.json').write_text(json.dumps({'error': str(error)}))
        raise

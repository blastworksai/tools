#!/usr/bin/env python3
"""Vendor the shared report codec and mailbox helpers into their package consumers.

    python3 shared/report-files-v1/sync.py [--check]

--check writes nothing and exits 1 for missing, differing or extra wire files.
Only the two wire codecs and explicitly named SPAWN helpers are generated.
"""
import argparse
from pathlib import Path
import sys

CANON = Path(__file__).resolve().parent
ROOT = CANON.parents[1]
TARGETS = (ROOT / 'plugins/tern/ORCH+/wire', ROOT / 'plugins/tern/SPAWN/wire')
HEADER = b'-- Vendored from shared/report-files-v1 by sync.py; edit there, then run sync.py.\n'
HELPERS = ('mailbox_reply.jq', 'mailbox_worker.ps1')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='report stale copies; write nothing')
    args = parser.parse_args(argv)
    outputs = [(target / 'codec.luau', HEADER + (CANON / 'codec.luau').read_bytes()) for target in TARGETS]
    outputs.extend((ROOT / 'plugins/tern/SPAWN' / name,
                    b'# Generated from shared/report-files-v1 by sync.py; edit the canonical source.\n' + (CANON / name).read_bytes())
                   for name in HELPERS)
    problems = []
    for path, data in outputs:
        if not path.is_file():
            problems.append(f'missing {path}')
        elif path.read_bytes() != data:
            problems.append(f'differs {path}')
    for target in TARGETS:
        if target.is_dir():
            problems.extend(f'extra {p}' for p in sorted(target.iterdir()) if p.name != 'codec.luau')
    if args.check:
        for problem in problems:
            print(problem)
        return 1 if problems else 0
    # Fail rather than remove an unexpected file: these folders have one explicit owner.
    extras = [p for p in problems if p.startswith('extra ')]
    if extras:
        for problem in extras:
            print(problem, file=sys.stderr)
        return 1
    for path, data in outputs:
        path.parent.mkdir(exist_ok=True)
        if not path.is_file() or path.read_bytes() != data:
            path.write_bytes(data)
            print(f'wrote {path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

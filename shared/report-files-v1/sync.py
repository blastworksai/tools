#!/usr/bin/env python3
"""Vendor the shared wire codec into exactly ORCH+ and SPAWN.

    python3 shared/report-files-v1/sync.py [--check]

--check writes nothing and exits 1 for missing, differing or extra wire files.
No runtime modules outside these two package-local wire directories are touched.
"""
import argparse
from pathlib import Path
import sys

CANON = Path(__file__).resolve().parent
ROOT = CANON.parents[1]
TARGETS = (ROOT / 'plugins/tern/ORCH+/wire', ROOT / 'plugins/tern/SPAWN/wire')
HEADER = b'-- Vendored from shared/report-files-v1 by sync.py; edit there, then run sync.py.\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='report stale copies; write nothing')
    args = parser.parse_args(argv)
    data = HEADER + (CANON / 'codec.luau').read_bytes()
    problems = []
    for target in TARGETS:
        path = target / 'codec.luau'
        if not path.is_file():
            problems.append(f'missing {path}')
        elif path.read_bytes() != data:
            problems.append(f'differs {path}')
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
    for target in TARGETS:
        target.mkdir(exist_ok=True)
        path = target / 'codec.luau'
        if not path.is_file() or path.read_bytes() != data:
            path.write_bytes(data)
            print(f'wrote {path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

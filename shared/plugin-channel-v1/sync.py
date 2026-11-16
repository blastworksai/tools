#!/usr/bin/env python3
"""Vendor the canonical host-local carrier into ORCH+, SPAWN and USAGE only.

    python3 shared/plugin-channel-v1/sync.py [--check]

--check never writes. Unexpected files or symlink targets are refused rather than
removed or followed. This does not touch adapters, wire modules or runner setup.
"""
import argparse
from pathlib import Path
import sys

CANON = Path(__file__).resolve().parent
ROOT = CANON.parents[1]
TARGETS = tuple(ROOT / 'plugins' / 'tern' / name / 'channel' for name in ('ORCH+', 'SPAWN', 'USAGE'))
HEADER = b'-- Vendored from shared/plugin-channel-v1 by sync.py; edit there, then run sync.py.\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='report stale copies without writing')
    args = parser.parse_args(argv)
    data = HEADER + (CANON / 'channel.luau').read_bytes()
    problems = []
    unsafe = []
    for target in TARGETS:
        path = target / 'channel.luau'
        if target.is_symlink() or path.is_symlink():
            unsafe.append(f'refusing symlink {path}')
            continue
        if target.exists() and not target.is_dir():
            unsafe.append(f'not a directory {target}')
            continue
        if target.is_dir():
            unsafe.extend(f'unexpected {entry}' for entry in sorted(target.iterdir()) if entry.name != 'channel.luau')
        if path.exists() and not path.is_file():
            unsafe.append(f'not a regular file {path}')
        elif not path.is_file():
            problems.append(f'missing {path}')
        elif path.read_bytes() != data:
            problems.append(f'differs {path}')
    if unsafe or args.check:
        for problem in unsafe + problems:
            print(problem, file=sys.stderr if unsafe else sys.stdout)
        return 1 if unsafe or problems else 0
    for target in TARGETS:
        target.mkdir(exist_ok=True)
        path = target / 'channel.luau'
        if not path.is_file() or path.read_bytes() != data:
            path.write_bytes(data)
            print(f'wrote {path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())

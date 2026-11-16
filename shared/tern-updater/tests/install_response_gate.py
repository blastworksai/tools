#!/usr/bin/env python3
"""Delay a real native install response after recording its actual completion.

The caller's unchanged native timeout must terminate this owned supervisor before
its 240-second safety limit. No replacement bytes or installer result are faked.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def identity(pid):
    stat = Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()
    return {'pid': pid, 'start_ticks': int(stat[19])}


def main():
    directory = Path(sys.argv[1])
    argv = sys.argv[2:]
    if not directory.is_dir() or len(argv) < 4 or argv[1:3] != ['plugin', 'install']:
        raise ValueError('requires an existing owned evidence directory and real plugin install argv')
    started = time.monotonic()
    own = identity(os.getpid())
    (directory / 'response-supervisor.json').write_text(json.dumps({
        'identity': own, 'argv': argv, 'started_monotonic': started, 'safety_limit_seconds': 240,
    }) + '\n')
    result = subprocess.run(argv, capture_output=True, timeout=150)
    (directory / 'real-install.stdout').write_bytes(result.stdout)
    (directory / 'real-install.stderr').write_bytes(result.stderr)
    (directory / 'real-install-result.json').write_text(json.dumps({
        'status': result.returncode, 'finished_monotonic': time.monotonic(),
    }) + '\n')
    if result.returncode == 0:
        while time.monotonic() - started < 240:
            time.sleep(0.1)
        (directory / 'response-safety-limit-reached').write_text('Native caller did not end its operation within 240 seconds\n')
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


if __name__ == '__main__':
    sys.exit(main())

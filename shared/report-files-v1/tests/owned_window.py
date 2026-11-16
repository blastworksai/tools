#!/usr/bin/env python3
"""Passively record this xvfb-run child's endpoints, then exec its Tern window.

Only the Xauthority *path* is recorded. Never read or export authentication bytes.
"""
import json
import os
from pathlib import Path
import sys
import time

metadata = Path(sys.argv[1])
executable, arguments = sys.argv[2], sys.argv[2:]
metadata.write_text(json.dumps({
    'schema': 1, 'pid': os.getpid(), 'process_group': os.getpgrp(),
    'started_epoch_ns': time.time_ns(), 'started_monotonic_ns': time.monotonic_ns(),
    'DISPLAY': os.environ.get('DISPLAY'), 'XAUTHORITY': os.environ.get('XAUTHORITY'),
    'argv': arguments, 'capture_framebuffer': {'width': 1920, 'height': 1080, 'depth': 24},
}, indent=2)+'\n')
os.execv(executable, arguments)

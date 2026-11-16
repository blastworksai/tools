#!/usr/bin/env python3
"""Run status_prompt_test.luau inside a real, isolated headless Tern host VM.

    systemd-run --user --scope --collect --property=KillMode=control-group --property=RuntimeMaxSec=600s \
        python3 shared/plugin-status-v1/tests/run_tests.py

Needs `tern` on PATH (or TERN=/path/to/tern) and xvfb-run. Uses a private config/daemon like the other plugin
native suites (shared/report-files-v1/tests/owned_runtime.py); touches no live Tern state.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

HERE = Path(__file__).resolve().parent
CANON = HERE.parent
ROOT = CANON.parents[1]
REPORT_TESTS = ROOT / 'shared' / 'report-files-v1' / 'tests'

RUNNER = '''--!nonstrict
local native = tern
local function persist(value) native.fs.write(native.plugin.data .. "/status-result.json", native.json.encode(value)) end
pcall(native.fs.mkdir, native.plugin.data)
persist({ done = false })
native.timer(1, function()
	local ok, value = pcall(function()
		local path = native.plugin.dir .. "/status_prompt_test.luau"
		return assert(loadstring(native.fs.read(path), path))(native.plugin.dir)
	end)
	persist({ done = true, ok = ok, summary = tostring(value) })
end)
'''


def main():
    tern = os.environ.get('TERN') or shutil.which('tern')
    if not tern:
        print('tern not found: put it on PATH or set TERN=/path/to/tern', file=sys.stderr)
        return 2
    sys.path.insert(0, str(REPORT_TESTS))
    spec = importlib.util.spec_from_file_location('updater_isolation', ROOT / 'shared/tern-updater/tests/updater_smoke.py')
    lib = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lib)
    lib.TERN = tern
    lib.FIXTURE_ID = 'status-prompt-tests'
    from owned_runtime import owned_runtime
    base = Path(tempfile.mkdtemp(prefix='status-prompt-'))
    processes, evidence = [], {}
    runtime = None
    try:
        package = base / 'package'
        package.mkdir()
        shutil.copy2(CANON / 'status_prompt.luau', package / 'status_prompt.luau')
        shutil.copy2(HERE / 'status_prompt_test.luau', package / 'status_prompt_test.luau')
        (package / 'runner.luau').write_text(RUNNER)
        (package / 'plugin.toml').write_text('schema = 1\nid = "status-prompt-tests"\nname = "Status prompt tests"\nversion = "0.1.0"\nhost = "runner.luau"\n')
        runtime = owned_runtime(lib, base, 'runtime', evidence, processes)
        runtime.start()
        runtime.command('plugin', 'link', package)
        result_path = runtime.config / 'plugin-data/status-prompt-tests/status-result.json'

        def completed():
            runtime.assert_running()
            try:
                value = json.loads(result_path.read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                return None
            return value if value.get('done') else None

        result = lib.wait_for(completed, 'status prompt suite', 240, .2)
        print(result.get('summary'))
        return 0 if result.get('ok') and str(result.get('summary', '')).startswith('PASS ') else 1
    finally:
        if runtime is not None:
            runtime.stop()
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())

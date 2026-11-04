#!/usr/bin/env python3
"""Real native Tern publication boundaries. CodexBWAI; MIT. No AI or live config.

Launch as an owned native Tern program, with a new private --work-dir.
Adjacent flat helpers support a portable qualification bundle; normal package
execution imports ../bin. All generated data stays in the private work folder.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

here = Path(__file__).resolve().parent
helpers = here if (here/'todo.py').exists() else here.parent/'bin'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--work-dir', required=True, type=Path)
parser.add_argument('--case', choices=['all', 'namespace', 'atomic', 'rename'], default='all')
args = parser.parse_args()
root = args.work_dir.resolve()
root.mkdir(mode=0o700, parents=True, exist_ok=True)
os.environ['TODO_PUBLICATION_ROOT'] = str(root/'private-publications')
sys.path.insert(0, str(helpers))
import publication
from process_identity import ancestors, process


def run(*parts, ok=True):
    if parts[0] in {'publish', 'clear'}:
        parts = (*parts, '--agent-pid', str(os.getpid()))
    child = subprocess.run([sys.executable, '-I', str(helpers/'todo.py'), *parts],
                           capture_output=True, text=True, timeout=10)
    value = json.loads(child.stdout)
    if ok and (child.returncode or not value.get('ok')):
        raise RuntimeError(value)
    return child.returncode, value


receipt = {'author': 'CodexBWAI', 'platform': sys.platform, 'python': sys.version,
           'checks': [], 'case': args.case, 'scope': 'Owned native program; private fixture metadata only'}
owns_binding = False
slow = None
release = root/'release-reader'
try:
    chain = ancestors(os.getpid())
    native = chain[-2]
    receipt['probe_process_chain'] = chain
    assert publication.discover(native['pid'])['state'] == 'none', 'not an empty owned native session'
    owns_binding = True
    first, second = root/'plan-one.md', root/'plan-two.md'
    for path, identifier in [(first, 'plan-111111111111'), (second, 'plan-222222222222')]:
        value = {'schema': 1, 'plan_id': identifier, 'title': 'Publication probe', 'current': 'cp1',
                 'checkpoints': [{'id': 'cp1', 'text': 'Verify publication', 'state': 'active'}]}
        path.write_text('<!-- TERN-SESSION:START -->\n```json\n'+json.dumps(value)+'\n```\n<!-- TERN-SESSION:END -->\n', encoding='utf-8')
    original = first.read_bytes()
    _, published = run('publish', '--plan', str(first))
    _, found = run('discover', '--parent-pid', str(native['pid']))
    binding = {key: found['source'][key] for key in ['path', 'plan_id', 'publication']}
    _, read = run('published', '--binding', json.dumps(binding))
    assert read['plan']['plan_id'] == 'plan-111111111111' and first.read_bytes() == original
    receipt['checks'].append('native publication/discovery/read preserves canonical bytes')

    if os.name != 'nt' and args.case in {'all', 'namespace'}:
        folder = publication.directory(publication.owner())
        mode = folder.stat().st_mode & 0o777
        try:
            folder.chmod(0o777)
            status, unsafe = run('discover', '--parent-pid', str(native['pid']), ok=False)
            assert status == 1 and not unsafe.get('ok') and 'unsafe' in unsafe.get('error', '')
        finally:
            folder.chmod(mode)
        receipt['checks'].append('matching readable unsafe store is a detection error')
        unrelated = publication.root()/(publication.PREFIX+'999999999')
        unrelated.mkdir(mode=0o000)
        try:
            _, safe = run('discover', '--parent-pid', str(native['pid']))
            assert safe['state'] == 'active' and safe['source']['publication'] == binding['publication']
        finally:
            unrelated.chmod(0o700)
            unrelated.rmdir()
        receipt['checks'].append('untraversable unrelated namespace cannot disable valid discovery')

    if sys.platform.startswith('linux') and args.case in {'all', 'rename'}:
        previous = process(os.getpid())['name']
        if ctypes.CDLL(None).prctl(15, b'TODO-renamed', 0, 0, 0) != 0:
            raise OSError('cannot exercise native process rename')
        try:
            assert process(os.getpid())['name'] != previous
            run('publish', '--plan', str(first))
            run('clear')
            run('publish', '--plan', str(first))
        finally:
            ctypes.CDLL(None).prctl(15, previous.encode(), 0, 0, 0)
        receipt['checks'].append('same process can republish and clear after a native name change')

    if args.case in {'all', 'atomic'}:
        entered = root/'reader-entered'
        # Pause the production reader seam at a deterministic boundary. The real
        # writer and concurrent reader still use the ordinary process/filesystem.
        code = '''import sys,time
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import publication,todo
def slow_reader(path):
 Path(sys.argv[4]).write_text('ready')
 deadline=time.monotonic()+10
 while not Path(sys.argv[5]).exists():
  if time.monotonic()>deadline:raise TimeoutError('reader barrier')
  time.sleep(.02)
 return todo.read_plan(path)
publication.publish(Path(sys.argv[2]),slow_reader,int(sys.argv[3]))
'''
        slow = subprocess.Popen([sys.executable, '-I', '-c', code, str(helpers), str(first),
                                 str(os.getpid()), str(entered), str(release)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic()+8
        while not entered.exists() and time.monotonic() < deadline and slow.poll() is None:
            time.sleep(.02)
        assert entered.exists(), 'writer did not enter the real reader boundary'
        _, during = run('published', '--binding', json.dumps(binding))
        assert during['plan']['plan_id'] == binding['plan_id']
        release.write_text('continue')
        stdout, stderr = slow.communicate(timeout=10)
        assert slow.returncode == 0, stdout+stderr
        _, after = run('published', '--binding', json.dumps(binding))
        assert after['plan']['plan_id'] == binding['plan_id']
        receipt['checks'].append('same-plan republish has no missing-record window during validation')

    run('publish', '--plan', str(second))
    status, changed = run('published', '--binding', json.dumps(binding), ok=False)
    failed, _ = run('publish', '--plan', str(root/'missing.md'), ok=False)
    _, vacant = run('discover', '--parent-pid', str(native['pid']))
    assert status == 1 and 'different plan' in changed.get('error', '') and failed == 1 and vacant['state'] == 'none'
    receipt['checks'].append('changed and failed publication cannot retain stale success')
    run('publish', '--plan', str(second))
    run('clear')
    _, vacant = run('discover', '--parent-pid', str(native['pid']))
    assert vacant['state'] == 'none' and process(os.getpid())['pid'] == os.getpid()
    receipt['checks'].append('clear removes binding while selected program stays alive')
    receipt.update(passed=True, native_parent=native, publication=published['publication'])
except Exception as error:
    receipt.update(passed=False, error=str(error))
finally:
    if slow is not None and slow.poll() is None:
        release.write_text('continue')
        try:
            slow.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            slow.kill()
            slow.communicate(timeout=3)
    if owns_binding:
        try:
            run('clear')
        except Exception:
            pass
    receipt['helper_hashes'] = {name: hashlib.sha256((helpers/name).read_bytes()).hexdigest()
                               for name in ['todo.py', 'publication.py', 'process_identity.py']}
    (root/'result.json').write_text(json.dumps(receipt, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(receipt))
sys.exit(0 if receipt.get('passed') else 1)

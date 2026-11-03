"""Interactive source/CLI/SSH boundaries. CodexBWAI, COMMANDER-993."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
READER = ROOT/'bin/todo.py'


def plan(plan_id='plan-123456abcdef', state='pending'):
    return {'schema': 1, 'plan_id': plan_id, 'title': 'Interactive task',
            'current': 'cp1' if state in ('active', 'blocked') else None,
            'checkpoints': [{'id': 'cp1', 'text': 'Prove the outcome', 'state': state,
                             **({'reason': 'Waiting for owner approval'} if state == 'blocked' else {})}]}


def write_plan(path, value):
    # Estate prose is untouched; only the deliberate explicit block is interpreted.
    path.write_text('# Interactive task\n## Progress\n3 Nov: initial discussion.\n'
                    '## START HERE — next action\nFollow the agreed task.\n'
                    '<!-- TERN-SESSION:START -->\n```json\n'+json.dumps(value)+'\n```\n<!-- TERN-SESSION:END -->\n')


class SourceContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='interactive-plan-', dir='/var/tmp')
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.path = self.base/'PLAN with spaces.md'
        write_plan(self.path, plan())

    def cli(self, *args, env=None):
        return subprocess.run([sys.executable, '-I', str(READER), *map(str, args)],
                              capture_output=True, text=True, timeout=6, env=env)

    def test_explicit_block_reads_without_tern_and_never_writes_the_plan(self):
        before = self.path.read_bytes()
        result = self.cli('source', '--plan', self.path)
        self.assertEqual((result.returncode, json.loads(result.stdout)['plan']), (0, plan()))
        self.assertEqual(self.path.read_bytes(), before)

    def test_schema_failure_and_cli_usage_are_errors_not_stop_continuations(self):
        write_plan(self.path, plan(state='blocked'))
        value = plan(state='blocked')
        del value['checkpoints'][0]['reason']
        write_plan(self.path, value)
        self.assertEqual(self.cli('source', '--plan', self.path).returncode, 1)
        self.assertEqual(self.cli('source', '--mistyped').returncode, 1)
        self.assertEqual(self.cli('unrecognized').returncode, 1)

    def ssh_fixture(self):
        binary = self.base/'ssh'
        record = self.base/'ssh-argv.json'
        binary.write_text('#!'+sys.executable+'\nimport subprocess,sys,shlex,json\n'
                          'from pathlib import Path\n'
                          'Path('+repr(str(record))+').write_text(json.dumps(sys.argv[1:]))\n'
                          'r=subprocess.run(shlex.split(sys.argv[-1]),input=sys.stdin.read(),text=True,capture_output=True)\n'
                          'sys.stdout.write(r.stdout); sys.exit(r.returncode)\n')
        binary.chmod(0o700)
        return record, dict(os.environ, PATH=str(self.base)+os.pathsep+os.environ['PATH'])

    def test_ssh_command_preserves_path_boundaries_and_sends_only_the_reader(self):
        record, env = self.ssh_fixture()
        result = self.cli('source', '--plan', self.path, '--ssh', 'reviewed-test', env=env)
        self.assertEqual((result.returncode, json.loads(result.stdout)['plan']), (0, plan()))
        self.assertEqual(self.cli('source', '--plan', self.path, '--ssh', 'seat-claudebwai').returncode, 1)

    def test_option_destination_is_rejected_before_any_ssh_process(self):
        record, env = self.ssh_fixture()
        result = self.cli('source', '--plan', self.path, '--ssh=-Ex@host', env=env)
        self.assertEqual((result.returncode, record.exists()), (1, False))

    def test_ssh_requires_existing_trust_and_separates_options_from_destination(self):
        record, env = self.ssh_fixture()
        self.cli('source', '--plan', self.path, '--ssh', 'reviewed-test', env=env)
        argv = json.loads(record.read_text())
        self.assertIn('StrictHostKeyChecking=yes', argv)
        self.assertIn('UpdateHostKeys=no', argv)
        self.assertEqual(argv[-3:-1], ['--', 'reviewed-test'])


if __name__ == '__main__':
    unittest.main()

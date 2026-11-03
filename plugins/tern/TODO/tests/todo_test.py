"""Interactive source/CLI/SSH boundaries. CodexBWAI, COMMANDER-993."""
import json
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

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

    def test_crlf_plan_reads_without_changing_identity_or_source_bytes(self):
        before = self.path.read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
        self.path.write_bytes(before)
        result = self.cli('source', '--plan', self.path)
        self.assertEqual((result.returncode, json.loads(result.stdout).get('plan'), self.path.read_bytes()),
                         (0, plan(), before))

    def test_schema_failure_and_cli_usage_are_errors_not_stop_continuations(self):
        write_plan(self.path, plan(state='blocked'))
        value = plan(state='blocked')
        del value['checkpoints'][0]['reason']
        write_plan(self.path, value)
        self.assertEqual(self.cli('source', '--plan', self.path).returncode, 1)
        self.assertEqual(self.cli('source', '--mistyped').returncode, 1)
        self.assertEqual(self.cli('unrecognized').returncode, 1)

    def ssh_fixture(self, legacy=False):
        binary = self.base/'ssh'
        record = self.base/'ssh-argv.json'
        guard = "if any(arg.startswith('ForkAfterAuthentication=') for arg in sys.argv): sys.exit(255)\n" if legacy else ''
        binary.write_text('#!'+sys.executable+'\nimport subprocess,sys,shlex,json\n'+guard+
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

    def test_ssh_disables_forwarding_and_connection_sharing_despite_config(self):
        # Resolve the exact production argv against an adverse, synthetic config;
        # ssh -G performs no connection and reads no personal SSH configuration.
        record, env = self.ssh_fixture()
        self.cli('source', '--plan', self.path, '--ssh', 'reviewed-test', env=env)
        config = self.base/'ssh.conf'
        config.write_text('Host reviewed-test\n HostName 192.0.2.1\n ForwardAgent yes\n ForwardX11 yes\n ControlMaster auto\n ControlPath /synthetic/shared-socket\n PermitLocalCommand yes\n GSSAPIDelegateCredentials yes\n')
        argv = json.loads(record.read_text())
        result = subprocess.run(['/usr/bin/ssh', '-G', '-F', str(config), *argv],
                                capture_output=True, text=True, check=True, timeout=4)
        effective = dict(line.split(' ', 1) for line in result.stdout.splitlines() if ' ' in line)
        self.assertEqual((effective['forwardagent'], effective['forwardx11'], effective['permitlocalcommand'], effective['gssapidelegatecredentials']), ('no', 'no', 'no', 'no'))
        self.assertEqual(effective['controlmaster'], 'false')
        self.assertNotIn('controlpath', effective)

    def test_remote_plan_failure_preserves_the_actionable_source_error(self):
        record, env = self.ssh_fixture()
        self.path.write_text('# A plan not yet deliberately adopted\n')
        result = self.cli('source', '--plan', self.path, '--ssh', 'reviewed-test', env=env)
        error = json.loads(result.stdout)['error']
        self.assertEqual((result.returncode, 'TERN-SESSION' in error), (1, True))

    def test_ssh_reader_transport_is_independent_of_non_utf8_parent_locale(self):
        record, env = self.ssh_fixture()
        spec = importlib.util.spec_from_file_location('todo_reader_contract', READER)
        reader = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(reader)
        # Model a Windows ANSI parent; the real child consumes UTF-8 source.
        with patch.dict(os.environ, env), patch('locale.getencoding', return_value='cp1252'):
            self.assertEqual(reader.read_ssh('reviewed-test', self.path), plan())

    def test_ssh_does_not_require_the_newer_backgrounding_config_keyword(self):
        record, env = self.ssh_fixture(legacy=True)
        result = self.cli('source', '--plan', self.path, '--ssh', 'reviewed-test', env=env)
        self.assertEqual((result.returncode, json.loads(result.stdout).get('plan')), (0, plan()))


if __name__ == '__main__':
    unittest.main()

"""Interactive source/CLI/SSH boundaries. Blastworks.ai, COMMANDER-993."""
import contextlib
import copy
import ctypes
import io
import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
READER = ROOT/'bin/todo.py'
sys.path.insert(0, str(READER.parent))
import publication
import process_identity


def reader_module():
    spec = importlib.util.spec_from_file_location('todo_reader_contract', READER)
    reader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reader)
    return reader


def plan(plan_id='plan-123456abcdef', state='pending'):
    return {'schema': 1, 'plan_id': plan_id, 'title': 'Interactive task',
            'current': 'cp1' if state in ('active', 'blocked') else None,
            'checkpoints': [{'id': 'cp1', 'text': 'Prove the outcome', 'state': state,
                             **({'reason': 'Waiting for owner approval'} if state == 'blocked' else {})}]}


def bounded_non_ascii_plan():
    checkpoints = []
    for index in range(30):
        stem = f'c{index}'
        identifier = stem + 'x' * (40-len(stem))
        checkpoints.append({'id': identifier, 'text': '\U0001f600'*240,
                            'state': 'blocked', 'reason': '\U0001f600'*400})
    return {'schema': 1, 'plan_id': 'plan-ffffffffffff', 'title': '\U0001f600'*160,
            'current': checkpoints[0]['id'], 'checkpoints': checkpoints}


def write_plan(path, value):
    # Estate prose is untouched; only the deliberate explicit block is interpreted.
    path.write_text('# Interactive task\n## Progress\n3 Nov: initial discussion.\n'
                    '## START HERE — next action\nFollow the agreed task.\n'
                    '<!-- TERN-SESSION:START -->\n```json\n'+json.dumps(value)+'\n```\n<!-- TERN-SESSION:END -->\n')


class SourceContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='interactive-plan-')
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

    def test_discovery_preserves_writable_installed_helper_membership(self):
        installed = self.base/'installed helpers'
        installed.mkdir()
        before = {}
        for name in ('todo.py', 'publication.py', 'process_identity.py'):
            before[name] = (READER.parent/name).read_bytes()
            (installed/name).write_bytes(before[name])
        # Deliberately omit -B: the public entrypoint owns its read-only policy.
        result = subprocess.run(
            [sys.executable, '-I', str(installed/'todo.py'), 'discover',
             '--parent-pid', str(os.getpid())],
            capture_output=True, text=True, timeout=6,
            env=dict(os.environ, TODO_PUBLICATION_ROOT=str(self.base/'publications')))
        self.assertEqual((result.returncode, json.loads(result.stdout)),
                         (0, {'ok': True, 'state': 'none'}))
        after = {str(path.relative_to(installed)): path.read_bytes()
                 for path in installed.rglob('*') if path.is_file()}
        self.assertEqual(after, before)

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
        self.assertEqual(self.cli('source', '--plan', self.path, '--ssh', 'seat-agent').returncode, 1)

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

    @unittest.skipUnless(shutil.which('ssh'), 'OpenSSH-specific: requires ssh -G')
    def test_openssh_disables_forwarding_and_connection_sharing_despite_config(self):
        # Resolve the exact production argv against an adverse, synthetic config;
        # OpenSSH -G performs no connection and reads no personal SSH configuration.
        record, env = self.ssh_fixture()
        self.cli('source', '--plan', self.path, '--ssh', 'reviewed-test', env=env)
        config = self.base/'ssh.conf'
        config.write_text('Host reviewed-test\n HostName 192.0.2.1\n ForwardAgent yes\n ForwardX11 yes\n ControlMaster auto\n ControlPath /synthetic/shared-socket\n PermitLocalCommand yes\n GSSAPIDelegateCredentials yes\n')
        argv = json.loads(record.read_text())
        result = subprocess.run([shutil.which('ssh'), '-G', '-F', str(config), *argv],
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

    def test_ssh_accepts_padded_valid_non_ascii_checkpoint_envelope(self):
        reader = reader_module()
        value = bounded_non_ascii_plan()
        value['title'] = ' ' + value['title']
        value['checkpoints'][0]['text'] += '\t' * 1024
        value['checkpoints'][0]['reason'] = '\n' * 1024 + value['checkpoints'][0]['reason']
        self.assertEqual(reader.validate(value), value)
        write_plan(self.path, value)
        self.assertLessEqual(self.path.stat().st_size, reader.LIMIT)
        record, env = self.ssh_fixture()
        result = self.cli('source', '--plan', self.path, '--ssh', 'reviewed-test', env=env)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual(json.loads(result.stdout)['plan'], value)
        encoded = (reader._source_envelope(value)+'\n').encode('utf-8')
        self.assertLessEqual(len(encoded), reader.SSH_RESPONSE_LIMIT)
        self.assertGreater(len(encoded), 65536)

    def test_ssh_rejects_one_byte_beyond_the_derived_protocol_ceiling(self):
        reader = reader_module()
        encoded = (reader._source_envelope(plan())+'\n').encode('utf-8')
        stdout = encoded + b' ' * (reader.SSH_RESPONSE_LIMIT+1-len(encoded))
        self.assertEqual(len(stdout), reader.SSH_RESPONSE_LIMIT+1)
        completed = subprocess.CompletedProcess(['ssh'], 0, stdout=stdout, stderr=b'')
        with patch.object(reader.subprocess, 'run', return_value=completed):
            with self.assertRaisesRegex(ValueError, 'SSH source unavailable'):
                reader.read_ssh('reviewed-test', self.path)


class ProcessIdentityContract(unittest.TestCase):
    def test_linux_disappearance_is_definitively_ended(self):
        with patch('process_identity.sys.platform', 'linux'), \
                patch('process_identity.Path.read_text', side_effect=FileNotFoundError(2, 'missing')):
            with self.assertRaises(process_identity.ProcessEnded):
                process_identity.process(424242)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'real procfs disappearance envelope')
    def test_initial_process_ended_helper_envelope_is_terminal(self):
        with tempfile.TemporaryDirectory(prefix='todo-ended-envelope-') as scratch:
            env = dict(os.environ, TODO_PUBLICATION_ROOT=str(Path(scratch)/'metadata'))
            result = subprocess.run([sys.executable, '-I', str(READER), 'discover',
                                     '--parent-pid', '999999999'],
                                    capture_output=True, text=True, timeout=6, env=env)
        envelope = json.loads(result.stdout)
        self.assertEqual(result.returncode, 1)
        self.assertIs(envelope.get('ok'), False)
        self.assertIs(envelope.get('terminal'), True)
        self.assertIn('ended', envelope.get('error', ''))

    def test_discover_binds_a_saved_wait_to_the_process_birth_it_saw(self):
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        with tempfile.TemporaryDirectory(prefix='todo-birth-') as scratch:
            env = dict(os.environ, TODO_PUBLICATION_ROOT=str(Path(scratch)/'metadata'))
            def run(*extra):
                result = subprocess.run([sys.executable, '-I', str(READER), 'discover', '--parent-pid', str(child.pid), *extra],
                                        capture_output=True, text=True, timeout=6, env=env)
                return result.returncode, json.loads(result.stdout)
            # Without the flag the answer is byte-for-byte what it was.
            self.assertEqual(run(), (0, {'ok': True, 'state': 'none'}))
            code, first = run('--with-identity')
            birth = first['parent_birth']
            self.assertEqual((code, first['state'], birth), (0, 'none', process_identity.process(child.pid)['birth']))
            # The same process still answers; a PID that now names another process ends the wait.
            self.assertEqual(run('--with-identity', '--parent-birth', birth)[1]['state'], 'none')
            code, reused = run('--with-identity', '--parent-birth', birth+'x')
            self.assertEqual(code, 1)
            self.assertIs(reused.get('ok'), False)
            self.assertIs(reused.get('terminal'), True)
            self.assertIn('ended or changed', reused.get('error', ''))

    def test_linux_permission_failure_remains_an_access_error(self):
        with patch('process_identity.sys.platform', 'linux'), \
                patch('process_identity.Path.read_text', side_effect=PermissionError(13, 'inspection denied')):
            with self.assertRaises(PermissionError):
                process_identity.process(424242)

    def test_identity_validation_is_explicitly_tri_state(self):
        saved = {'pid': 41, 'ppid': 40, 'owner': '17', 'birth': 'boot:1', 'name': 'agent'}
        with patch('publication.process', return_value=dict(saved)):
            self.assertEqual(publication._identity(saved), (publication.LIVE, saved))
        with patch('publication.process', side_effect=PermissionError(13, 'denied')):
            state, error = publication._identity(saved)
            self.assertEqual(state, publication.UNKNOWN)
            self.assertIsInstance(error, PermissionError)
        with patch('publication.process', side_effect=process_identity.ProcessEnded('ended')):
            self.assertEqual(publication._identity(saved), (publication.ENDED, None))

    def test_real_identity_mismatches_are_definitive_not_unknown(self):
        saved = {'pid': 41, 'ppid': 40, 'owner': '17', 'birth': 'boot:1', 'name': 'agent'}
        replacements = {'pid': 42, 'ppid': 39, 'owner': '18', 'birth': 'boot:2'}
        for key, replacement in replacements.items():
            with self.subTest(key=key):
                current = dict(saved, **{key: replacement})
                with patch('publication.process', return_value=current):
                    self.assertEqual(publication._identity(saved), (publication.ENDED, None))

    def snapshot_result(self, first_error, next_error):
        class Entry(ctypes.Structure):
            _fields_ = [('size', ctypes.c_uint32), ('pid', ctypes.c_uint32),
                        ('parent', ctypes.c_uint32)]
        kernel = Mock()
        kernel.CreateToolhelp32Snapshot.return_value = 91
        last_error = [0]
        def first(snapshot, pointer):
            last_error[0] = first_error or 0
            if first_error is not None: return 0
            pointer._obj.pid = 1
            pointer._obj.parent = 2
            return 1
        def next(snapshot, pointer):
            last_error[0] = next_error or 0
            return 0
        kernel.Process32FirstW.side_effect = first
        kernel.Process32NextW.side_effect = next
        with patch('process_identity.ctypes.get_last_error', side_effect=lambda: last_error[0], create=True):
            result = process_identity._windows_snapshot_parent(kernel, Entry, 42)
        kernel.CloseHandle.assert_called_once_with(91)
        return result

    def test_windows_first_and_next_enumeration_errors_are_retained(self):
        self.assertEqual(self.snapshot_result(5, None), (None, False, 5))
        self.assertEqual(self.snapshot_result(None, 5), (None, False, 5))
        self.assertEqual(self.snapshot_result(18, None), (None, True, None))

    def test_windows_omitted_live_process_and_enumeration_failure_are_unknown(self):
        errors = [(None, True, None, None), (None, False, 5, 87), (None, True, None, 5)]
        for arguments in errors:
            with self.subTest(arguments=arguments), patch('process_identity.ctypes.WinError', create=True,
                                                          side_effect=lambda code: OSError(code, 'native access')):
                with self.assertRaises(OSError) as caught:
                    process_identity._windows_open_error(*arguments)
                self.assertNotIsInstance(caught.exception, process_identity.ProcessEnded)

    def test_windows_only_completed_disappearance_is_definitive(self):
        with self.assertRaises(process_identity.ProcessEnded):
            process_identity._windows_open_error(None, True, None, 87)

    @unittest.skipUnless(os.name == 'nt', 'native Windows retained process handle')
    def test_windows_retained_exited_process_is_terminal(self):
        child = subprocess.Popen([sys.executable, '-I', '-S', '-B', '-c', 'pass'],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
        try:
            self.assertEqual(child.wait(timeout=5), 0)
            # Popen still owns the process handle after wait returns.
            with self.assertRaises(process_identity.ProcessEnded):
                process_identity.process(child.pid)
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)

    @unittest.skipUnless(os.name == 'nt', 'native Windows live process handle')
    def test_windows_live_handle_without_parent_stays_unknown(self):
        self.assertEqual(process_identity.process(os.getpid())['pid'], os.getpid())
        with patch('process_identity._windows_snapshot_parent',
                   return_value=(None, True, None)):
            with self.assertRaises(OSError) as caught:
                process_identity.process(os.getpid())
        self.assertNotIsInstance(caught.exception, process_identity.ProcessEnded)


class WindowsReadContract(unittest.TestCase):
    def kernel(self, payload=b'{"schema":1}', read_error=None):
        kernel = Mock()
        kernel.CreateFileW.return_value = 77
        kernel.GetFileType.return_value = 1
        from ctypes import wintypes as w
        class Info(ctypes.Structure):
            _fields_ = [('attributes', w.DWORD), ('created', w.FILETIME),
                        ('accessed', w.FILETIME), ('written', w.FILETIME),
                        ('volume', w.DWORD), ('size_high', w.DWORD), ('size_low', w.DWORD),
                        ('links', w.DWORD), ('index_high', w.DWORD), ('index_low', w.DWORD)]
        def information(handle, pointer):
            ctypes.cast(pointer, ctypes.POINTER(Info)).contents.links = 1
            return 1
        kernel.GetFileInformationByHandle.side_effect = information
        def read(handle, buffer, size, count, overlapped):
            if read_error is not None: return 0
            ctypes.memmove(buffer, payload, len(payload))
            count._obj.value = len(payload)
            return 1
        kernel.ReadFile.side_effect = read
        return kernel

    def test_windows_reader_closes_handle_on_read_failure(self):
        kernel = self.kernel(read_error=5)
        with patch('publication.ctypes.WinDLL', return_value=kernel, create=True), \
                patch('publication._windows_security'), \
                patch('publication.ctypes.get_last_error', return_value=5, create=True), \
                patch('publication.ctypes.WinError', create=True,
                      side_effect=lambda code: OSError(code, 'read failed')):
            with self.assertRaises(OSError):
                publication._windows_read(Path('publication.json'), 'S-1-5-21-42')
        kernel.CloseHandle.assert_called_once_with(77)

    def test_windows_reader_rejects_open_handle_security_before_reading(self):
        kernel = self.kernel()
        with patch('publication.ctypes.WinDLL', return_value=kernel, create=True), \
                patch('publication._windows_security', side_effect=ValueError('unsafe publication owner or permissions')) as security:
            with self.assertRaisesRegex(ValueError, 'unsafe publication'):
                publication._windows_read(Path('publication.json'), 'S-1-5-21-42')
        security.assert_called_once_with(Path('publication.json'), 'S-1-5-21-42', handle=77)
        kernel.ReadFile.assert_not_called()
        kernel.CloseHandle.assert_called_once_with(77)

    def test_handle_security_uses_existing_owner_and_dacl_policy(self):
        identity = 'S-1-5-21-42'
        cases = [
            (identity, identity, 0, False, None),
            ('S-1-5-18', 'S-1-5-32-544', 0, False, None),
            ('S-1-5-21-99', identity, 0, False, 'unsafe publication'),
            (identity, identity, 0, True, 'unsafe publication'),
            (identity, 'S-1-5-21-99', 0, False, 'another account to write'),
            (identity, identity, 5, False, 'unsupported publication'),
        ]
        for owner_sid, writer_sid, ace_kind, null_acl, error in cases:
            with self.subTest(owner=owner_sid, writer=writer_sid, kind=ace_kind, null_acl=null_acl):
                api, kernel = Mock(), Mock()
                acl = ctypes.create_string_buffer(8)
                ace = ctypes.create_string_buffer(16)
                descriptor = ctypes.create_string_buffer(8)
                ctypes.c_ushort.from_buffer(acl, 4).value = 1
                ctypes.c_ubyte.from_buffer(ace).value = ace_kind
                ctypes.c_uint32.from_buffer(ace, 4).value = 0x40000000
                def security(handle, kind, requested, sid, group, dacl, sacl, sd):
                    self.assertEqual((handle, kind, requested), (77, 1, 5))
                    sid._obj.value = 1
                    dacl._obj.value = None if null_acl else ctypes.addressof(acl)
                    sd._obj.value = ctypes.addressof(descriptor)
                    return 0
                def sid_text(sid, text):
                    text._obj.value = owner_sid if sid.value == 1 else writer_sid
                    return 1
                def get_ace(pointer, index, output):
                    output._obj.value = ctypes.addressof(ace)
                    return 1
                api.GetSecurityInfo.side_effect = security
                api.ConvertSidToStringSidW.side_effect = sid_text
                api.GetAce.side_effect = get_ace
                with patch('publication.ctypes.WinDLL', side_effect=lambda name, **kwargs: api if name == 'advapi32' else kernel, create=True):
                    if error:
                        with self.assertRaisesRegex(ValueError, error):
                            publication._windows_security(Path('replaced.json'), identity, handle=77)
                    else:
                        publication._windows_security(Path('replaced.json'), identity, handle=77)
                api.GetSecurityInfo.assert_called_once()
                api.GetNamedSecurityInfoW.assert_not_called()
                self.assertEqual(kernel.LocalFree.call_args.args[0].value, ctypes.addressof(descriptor))

@unittest.skipUnless(os.name == 'nt', 'native Windows publication replacement')
class WindowsPublicationReplacement(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='todo-native-replace-')
        self.addCleanup(self.scratch.cleanup)
        self.folder = Path(self.scratch.name)
        self.identity = publication.owner()
        publication._windows_security(self.folder, self.identity, True)
        self.target = self.folder/'publication.json'
        self.source = self.folder/'.publish-next'
        self.target.write_bytes(b'{"revision":1}\n')
        self.source.write_bytes(b'{"revision":2}\n')
        for path in (self.target, self.source):
            publication._windows_security(path, self.identity, True)

    @contextlib.contextmanager
    def open_reader(self, share):
        from ctypes import wintypes as w
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.c_void_p,
                                      w.DWORD, w.DWORD, w.HANDLE]
        kernel.CreateFileW.restype = w.HANDLE
        kernel.CloseHandle.argtypes = [w.HANDLE]
        kernel.CloseHandle.restype = w.BOOL
        handle = kernel.CreateFileW(str(self.target), 0x80000000, share, None, 3, 0x80, None)
        if handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            yield handle
        finally:
            kernel.CloseHandle(handle)

    def test_open_product_reader_keeps_old_bytes_while_new_readers_see_replacement(self):
        opened, release = threading.Event(), threading.Event()
        results, errors = [], []
        security = publication._windows_security

        def checked(path, identity, *args, **kwargs):
            security(path, identity, *args, **kwargs)
            if Path(path) == self.target and kwargs.get('handle') is not None:
                opened.set()
                if not release.wait(10):
                    raise TimeoutError('publication reader was not released')

        def read():
            try:
                results.append(publication._windows_read(self.target, self.identity))
            except Exception as error:
                errors.append(error)

        with patch('publication._windows_security', side_effect=checked):
            reader = threading.Thread(target=read)
            reader.start()
            try:
                self.assertTrue(opened.wait(5), 'product reader did not open the publication')
                publication._replace_publication(self.source, self.target, self.identity)
            finally:
                release.set()
                reader.join(10)
        self.assertFalse(reader.is_alive(), 'publication reader did not finish')
        self.assertEqual(errors, [])
        self.assertEqual(results, [b'{"revision":1}\n'])
        self.assertEqual(publication._windows_read(self.target, self.identity), b'{"revision":2}\n')
        self.assertFalse(self.source.exists())
        # A leaked replacement/read handle would prevent this exclusive open.
        with self.open_reader(0):
            pass

    def test_readonly_target_preserves_both_files(self):
        from ctypes import wintypes as w
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.GetFileAttributesW.argtypes = [w.LPCWSTR]
        kernel.GetFileAttributesW.restype = w.DWORD
        kernel.SetFileAttributesW.argtypes = [w.LPCWSTR, w.DWORD]
        kernel.SetFileAttributesW.restype = w.BOOL
        attributes = kernel.GetFileAttributesW(str(self.target))
        if attributes == 0xffffffff:
            raise ctypes.WinError(ctypes.get_last_error())
        if not kernel.SetFileAttributesW(str(self.target), attributes | 0x1):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            with self.assertRaises(OSError):
                publication._replace_publication(self.source, self.target, self.identity)
            self.assertEqual(publication._windows_read(self.target, self.identity), b'{"revision":1}\n')
            self.assertEqual(publication._windows_read(self.source, self.identity), b'{"revision":2}\n')
        finally:
            if not kernel.SetFileAttributesW(str(self.target), attributes):
                raise ctypes.WinError(ctypes.get_last_error())



@unittest.skipIf(os.name == 'nt', 'POSIX publication mode assertions')
class PublicationContract(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='todo-publication-')
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.root = self.base/'metadata'
        self.identity = publication.owner()
        self.agent_pid = 410001
        self.native_pid = 410002
        self.tern_pid = 410003
        self.anchors = [
            {'pid': self.agent_pid, 'ppid': self.native_pid, 'owner': self.identity,
             'birth': 'fixture:agent', 'name': 'agent'},
            {'pid': self.native_pid, 'ppid': self.tern_pid, 'owner': self.identity,
             'birth': 'fixture:native', 'name': 'launcher'},
            {'pid': self.tern_pid, 'ppid': 1, 'owner': self.identity,
             'birth': 'fixture:tern', 'name': 'tern'},
        ]
        self.facts = {item['pid']: copy.deepcopy(item) for item in self.anchors}
        self.facts[os.getpid()] = {'owner': self.identity}
        environment = patch.dict(os.environ, {'TODO_PUBLICATION_ROOT': str(self.root)})
        environment.start()
        self.addCleanup(environment.stop)
        session = patch('publication.session_process', return_value=copy.deepcopy(self.anchors))
        session.start()
        self.addCleanup(session.stop)
        native = patch('publication.process', side_effect=self.lookup)
        native.start()
        self.addCleanup(native.stop)
        self.plan = self.base/'canonical-plan.md'
        self.plan.write_text('canonical bytes\n', encoding='utf-8')

    def lookup(self, pid):
        try:
            return copy.deepcopy(self.facts[int(pid)])
        except KeyError:
            raise process_identity.ProcessEnded('process has ended') from None

    def read_plan(self, path):
        return {'plan_id': 'plan-123456abcdef'}

    def publish(self):
        return publication.publish(self.plan, self.read_plan, self.agent_pid)

    def target(self):
        return publication.directory(self.identity)/publication._key(self.anchors[-2])

    def source(self):
        found = publication.discover(self.native_pid)
        self.assertEqual(found['state'], 'active')
        return found['source']

    def test_linux_agents_modes_apply_to_metadata_only(self):
        with patch('publication.sys.platform', 'linux'):
            self.publish()
            folder = publication.directory(self.identity)
            target = self.target()
            lock = target.with_name(target.name+'.lock')
            self.plan.chmod(0o644)
            self.assertEqual(folder.stat().st_mode & 0o777, 0o751)
            self.assertEqual(target.stat().st_mode & 0o777, 0o640)
            self.assertEqual(lock.stat().st_mode & 0o777, 0o640)
            self.assertEqual(self.plan.stat().st_mode & 0o777, 0o644)

    def test_hardlinked_writer_lock_cannot_change_canonical_bytes_or_mode(self):
        with patch('publication.sys.platform', 'linux'):
            folder = publication.directory(self.identity, create=True)
            target = folder/publication._key(self.anchors[-2])
            lock = target.with_name(target.name+'.lock')
            self.plan.chmod(0o644)
            before = self.plan.read_bytes()
            os.link(self.plan, lock)
            with self.assertRaisesRegex(ValueError, 'invalid publication lock file'):
                self.publish()
            self.assertEqual(self.plan.read_bytes(), before)
            self.assertEqual(self.plan.stat().st_mode & 0o777, 0o644)
            self.assertFalse(target.exists())

    def test_macos_modes_and_explicit_legacy_inventory_are_owner_only(self):
        with patch('publication.sys.platform', 'darwin'):
            self.publish()
            folder = publication.directory(self.identity)
            target = self.target()
            lock = target.with_name(target.name+'.lock')
            legacy = folder/'.publish-legacy'
            legacy.write_text('old metadata', encoding='utf-8')
            for path, mode in [(folder, 0o751), (target, 0o640), (lock, 0o640), (legacy, 0o640)]:
                path.chmod(mode)
            self.plan.chmod(0o644)
            inventory = publication.migration_inventory(self.identity)
            self.assertEqual({Path(item['path']) for item in inventory}, {folder, target, lock, legacy})
            self.assertTrue(all(item['target_mode'] == (0o700 if Path(item['path']) == folder else 0o600)
                                for item in inventory))
            self.publish()
            self.assertEqual(publication.migration_inventory(self.identity), [])
            for path in [target, lock, legacy]:
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
            self.assertEqual(self.plan.read_bytes(), b'canonical bytes\n')
            self.assertEqual(self.plan.stat().st_mode & 0o777, 0o644)

    def test_process_access_failure_is_visible_and_nonterminal(self):
        self.publish()
        source = self.source()
        def denied(pid):
            if int(pid) == self.agent_pid:
                raise PermissionError(13, 'inspection denied')
            return self.lookup(pid)
        with patch('publication.process', side_effect=denied):
            with self.assertRaises(publication.PublicationUnavailable) as caught:
                publication.read_binding(source, self.read_plan)
        self.assertFalse(getattr(caught.exception, 'terminal', False))
        self.assertIn('inspection denied', str(caught.exception))

    def test_process_disappearance_and_real_mismatches_are_terminal(self):
        for field in [None, 'pid', 'ppid', 'owner', 'birth']:
            with self.subTest(field=field):
                self.publish()
                source = self.source()
                saved = copy.deepcopy(self.facts[self.agent_pid])
                try:
                    if field is None:
                        del self.facts[self.agent_pid]
                    else:
                        replacement = self.agent_pid+100 if field == 'pid' else (
                            self.native_pid+100 if field == 'ppid' else 'changed')
                        self.facts[self.agent_pid][field] = replacement
                    with self.assertRaises(publication.PublicationEnded) as caught:
                        publication.read_binding(source, self.read_plan)
                    self.assertTrue(caught.exception.terminal)
                finally:
                    self.facts[self.agent_pid] = saved

    def test_birth_and_owner_mismatch_helper_envelopes_are_terminal(self):
        reader = reader_module()
        for field in ['birth', 'owner']:
            with self.subTest(field=field):
                self.publish()
                source = self.source()
                saved = copy.deepcopy(self.facts[self.agent_pid])
                try:
                    self.facts[self.agent_pid][field] = 'definitively-changed'
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):
                        status = reader.main(['published', '--binding', json.dumps(source)])
                    envelope = json.loads(output.getvalue())
                    self.assertEqual(status, 1)
                    self.assertIs(envelope.get('ok'), False)
                    self.assertIs(envelope.get('terminal'), True)
                    self.assertIn('ended or changed', envelope.get('error', ''))
                finally:
                    self.facts[self.agent_pid] = saved

    def test_record_disappearance_is_terminal(self):
        self.publish()
        source = self.source()
        self.target().unlink()
        with self.assertRaises(publication.PublicationEnded) as caught:
            publication.read_binding(source, self.read_plan)
        self.assertTrue(caught.exception.terminal)

    def test_failed_cleanup_preserves_a_newer_record_revision(self):
        self.publish()
        target = self.target()
        identity = self.identity
        newer = publication._read(target, identity)
        newer['published_ns'] += 1
        original = publication._retract_observed
        def replace_before_cleanup(path, owner, expected):
            path.write_text(json.dumps(newer, ensure_ascii=True, separators=(',', ':')), encoding='utf-8')
            return original(path, owner, expected)
        with patch('publication._retract_observed', side_effect=replace_before_cleanup):
            with self.assertRaises(FileNotFoundError):
                publication.publish(self.base/'missing.md', self.read_plan, self.agent_pid)
        self.assertEqual(publication._revision(publication._read(target, identity)),
                         publication._revision(newer))

    def test_precreated_directory_symlink_cannot_change_target_modes(self):
        with patch('publication.sys.platform', 'linux'):
            self.root.mkdir(mode=0o700)
            victim = self.base/'symlink-target'
            victim.mkdir(mode=0o755)
            canonical = victim/'canonical-plan.md'
            canonical.write_text('do not change\n', encoding='utf-8')
            canonical.chmod(0o644)
            link = self.root/(publication.PREFIX+self.identity)
            link.symlink_to(victim, target_is_directory=True)
            with self.assertRaises((OSError, ValueError)):
                publication.directory(self.identity, create=True)
            self.assertEqual(victim.stat().st_mode & 0o777, 0o755)
            self.assertEqual(canonical.stat().st_mode & 0o777, 0o644)
            self.assertEqual(canonical.read_bytes(), b'do not change\n')

    def test_reader_open_replace_failure_preserves_previous_publication(self):
        self.publish()
        target = self.target()
        previous = publication._read(target, self.identity)
        with target.open('rb') as reader:
            with patch('publication._replace_publication', side_effect=OSError(13, 'sharing violation')):
                with self.assertRaises(OSError):
                    self.publish()
            self.assertEqual(publication._read(target, self.identity), previous)
        self.assertTrue(reader.closed)
        self.assertEqual(list(target.parent.glob('.publish-*')), [])

    def test_cooperating_different_record_writer_survives_pruning(self):
        agent_b = self.agent_pid+10
        native_b = self.native_pid+10
        anchors_b = copy.deepcopy(self.anchors)
        anchors_b[0].update(pid=agent_b, ppid=native_b, birth='fixture:agent-b')
        anchors_b[1].update(pid=native_b, birth='fixture:native-b')
        self.facts.update({item['pid']: copy.deepcopy(item) for item in anchors_b})
        def session(pid):
            return copy.deepcopy(self.anchors if pid == self.agent_pid else anchors_b)
        with patch('publication.session_process', side_effect=session):
            self.publish()
            publication.publish(self.plan, self.read_plan, agent_b)
            target_b = publication.directory(self.identity)/publication._key(anchors_b[-2])
            old_revision = publication._read(target_b, self.identity)['published_ns']
            original_valid = publication._valid
            original_lock = publication._writer_lock
            waiting = threading.Event()
            release = threading.Event()
            failures = []
            def valid(record, parent=None):
                if record['anchors'] == anchors_b and record['published_ns'] == old_revision:
                    return False
                return original_valid(record, parent)
            @contextlib.contextmanager
            def interleaved_lock(target, identity):
                if target == target_b and threading.current_thread().name == 'writer-a':
                    waiting.set()
                    if not release.wait(5): raise TimeoutError('writer interleaving')
                with original_lock(target, identity):
                    yield
            def writer_a():
                try:
                    publication.publish(self.plan, self.read_plan, self.agent_pid)
                except Exception as error:
                    failures.append(error)
            with patch('publication._valid', side_effect=valid), \
                    patch('publication._writer_lock', side_effect=interleaved_lock):
                thread = threading.Thread(target=writer_a, name='writer-a')
                thread.start()
                try:
                    self.assertTrue(waiting.wait(5), 'writer A did not reach candidate B lock')
                    publication.publish(self.plan, self.read_plan, agent_b)
                finally:
                    release.set()
                    thread.join(6)
            self.assertFalse(thread.is_alive())
            self.assertEqual(failures, [])
            current = publication._read(target_b, self.identity)
            self.assertGreater(current['published_ns'], old_revision)
            self.assertEqual(current['anchors'], anchors_b)


class WorkflowEntryContract(unittest.TestCase):
    """Boundary: actual skill entry receives adoption; unrelated work is untouched."""
    def hook(self, value):
        path = ROOT/'integrations/glitch-plan-session-view/entry_hook.py'
        return subprocess.run([sys.executable, '-I', str(path)], input=json.dumps(value),
                              text=True, capture_output=True, timeout=3)


    def test_unrelated_prompts_and_tools_never_adopt_or_block(self):
        cases = [
            {'hook_event_name': 'UserPromptSubmit', 'prompt': 'Explain /glitch-execute to me'},
            {'hook_event_name': 'PreToolUse', 'tool_name': 'Read',
             'tool_input': {'file_path': '/work/plans/other-pane.md'}},
        ]
        self.assertEqual([(r.returncode, r.stdout) for r in map(self.hook, cases)], [(0, ''), (0, '')])


def detailed_plan(plan_id='plan-0123456789ab'):
    """Every entity kind and every state, three levels deep."""
    return {'schema': 2, 'plan_id': plan_id, 'title': 'Detailed task', 'current': 'impl',
            'checkpoints': [
                {'id': 'model', 'text': 'Model', 'state': 'done', 'tasks': [
                    {'id': 'parse', 'text': 'Parser', 'state': 'done', 'items': [
                        {'id': 'parse-file', 'kind': 'file', 'path': 'bin/todo.py', 'text': 'Edit validate', 'state': 'done'},
                        {'id': 'parse-step', 'kind': 'step', 'text': 'Nest the ids', 'state': 'done'},
                        {'id': 'parse-check', 'kind': 'validation', 'text': 'Unit tests pass', 'state': 'done'}]}]},
                {'id': 'ui', 'text': 'UI', 'state': 'pending', 'tasks': [
                    {'id': 'impl', 'text': 'Implement', 'state': 'active', 'items': [
                        {'id': 'impl-file', 'kind': 'file', 'path': 'window.luau', 'text': 'Status segment', 'state': 'pending'},
                        {'id': 'impl-wait', 'kind': 'step', 'text': 'Await owner A-or-B', 'state': 'blocked', 'reason': 'Owner choice'}]}]},
                {'id': 'ship', 'text': 'Ship', 'state': 'pending'}]}


def mutated(value, edit):
    value = copy.deepcopy(value)
    edit(value)
    return value


class DetailedSchema(unittest.TestCase):
    """Schema 2 nests checkpoint -> task -> file/step/validation; schema 1 stays readable."""

    def setUp(self):
        self.reader = reader_module()
        self.scratch = tempfile.TemporaryDirectory(prefix='detailed-plan-')
        self.addCleanup(self.scratch.cleanup)
        self.path = Path(self.scratch.name)/'PLAN.md'

    def rejects(self, value, pattern):
        with self.assertRaisesRegex(ValueError, pattern):
            self.reader.validate(value)

    def test_every_entity_kind_and_state_round_trips_through_the_cli(self):
        # The one blocked entity must carry its reason; the active one is named by current.
        value = detailed_plan()
        write_plan(self.path, value)
        result = subprocess.run([sys.executable, '-I', str(READER), 'source', '--plan', str(self.path)], capture_output=True, text=True, timeout=6)
        self.assertEqual((result.returncode, json.loads(result.stdout)['plan']), (0, value))
        kinds = {item['kind'] for cp in value['checkpoints'] for task in cp.get('tasks', []) for item in task['items']}
        states = {e['state'] for cp in value['checkpoints'] for e in [cp, *cp.get('tasks', [])]}
        self.assertEqual(kinds, {'file', 'step', 'validation'})
        self.assertEqual(states, {'done', 'active', 'pending'})  # only the leaf being worked is active

    def test_schema_one_block_published_before_this_change_still_parses(self):
        # A schema-1 block, as published before this change; the committed fixture carries one.
        legacy = {'schema': 1, 'plan_id': 'plan-4d31a4dc1f2e', 'title': 'Old', 'current': None,
                  'checkpoints': [{'id': 'a', 'text': 'A', 'state': 'pending'}, {'id': 'b', 'text': 'B', 'state': 'done'}]}
        self.assertEqual(self.reader.validate(legacy), legacy)
        fixture = Path(__file__).resolve().parent/'fixtures/schema1_plan.md'
        self.assertEqual(self.reader.read_plan(fixture)['schema'], 1)
        self.rejects(mutated(legacy, lambda v: v['checkpoints'][0].update(tasks=[])), 'checkpoint needs')

    def test_template_is_a_valid_schema_two_block(self):
        out = subprocess.run([sys.executable, '-I', str(READER), 'template', '--title', 'T', '--step', 'one', '--step', 'two'], capture_output=True, text=True, timeout=6).stdout
        self.path.write_text(out)
        plan_ = self.reader.read_plan(self.path)
        self.assertEqual((plan_['schema'], len(plan_['checkpoints'])), (2, 2))

    def test_rename_and_reorder_keep_ids_and_validity(self):
        value = detailed_plan()
        renamed = mutated(value, lambda v: v['checkpoints'][1]['tasks'][0].update(text='Implement, renamed'))
        reordered = mutated(value, lambda v: v['checkpoints'][1]['tasks'][0]['items'].reverse())
        for variant in (renamed, reordered):
            self.reader.validate(variant)
        ids = lambda v: sorted(e for cp in v['checkpoints'] for e in [cp['id'], *[t['id'] for t in cp.get('tasks', [])],
                                                                    *[i['id'] for t in cp.get('tasks', []) for i in t['items']]])
        self.assertEqual(ids(renamed), ids(value))
        self.assertEqual(ids(reordered), ids(value))

    def test_duplicate_ids_are_refused_across_kinds(self):
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][2].update(id='parse')), 'unique')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][1]['tasks'][0]['items'][0].update(id='ui')), 'unique')

    def test_unsupported_state_unknown_field_and_bad_kind_are_refused(self):
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'][0].update(state='finished')), 'state')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'][0]['items'][0].update(extra=1)), 'item needs')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'][0]['items'][0].update(kind='note')), 'kind')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'][0]['items'][1].update(path='x')), 'path')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'][0]['items'][0].pop('path')), 'item needs|path')

    def test_malformed_nesting_is_refused(self):
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'][0].update(tasks=[])), 'task needs')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'][0]['items'][0].update(items=[])), 'item needs')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0].update(tasks={})), 'list')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'].append('x')), 'task needs')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'][0].update(items='x')), 'list')

    def test_several_active_entities_are_valid_for_parallel_builders(self):
        def three_active(v):
            v['checkpoints'][1]['tasks'][0]['items'][0].update(state='active')
            v['checkpoints'][2].update(state='active')
        plan = mutated(detailed_plan(), three_active)
        self.assertEqual(self.reader.validate(plan)['plan_id'], plan['plan_id'])
        self.assertIsNone(self.reader.validate(mutated(plan, lambda v: v.update(current=None)))['current'])
        for bad in ('model', 'ghost', 5):
            self.rejects(mutated(plan, lambda v: v.update(current=bad)), 'current')

    def test_blocked_without_reason_and_bad_current_are_refused(self):
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][1]['tasks'][0]['items'][1].pop('reason')), 'blocked')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][1]['tasks'][0]['items'][0].update(reason='why')), 'blocked')
        self.rejects(mutated(detailed_plan(), lambda v: v.update(current='ship')), 'current')
        self.rejects(mutated(detailed_plan(), lambda v: v.update(current='ghost')), 'current')
        self.rejects(mutated(detailed_plan(), lambda v: v.update(current='model')), 'current')

    def test_bounds_are_enforced_at_each_level(self):
        def cp(i, tasks):
            return {'id': f'c{i}', 'text': 'c', 'state': 'pending', 'tasks': tasks}
        base = lambda cps: {'schema': 2, 'plan_id': 'plan-0123456789ab', 'title': 't', 'current': None, 'checkpoints': cps}
        task = lambda i, items=(): {'id': f't{i}', 'text': 't', 'state': 'pending', 'items': list(items)}
        step = lambda i: {'id': f's{i}', 'kind': 'step', 'text': 's', 'state': 'pending'}
        self.reader.validate(base([cp(0, [task(i) for i in range(20)])]))
        self.rejects(base([cp(0, [task(i) for i in range(21)])]), 'at most 20 tasks')
        self.reader.validate(base([cp(0, [task(0, [step(i) for i in range(30)])])]))
        self.rejects(base([cp(0, [task(0, [step(i) for i in range(31)])])]), 'at most 30 items')
        self.rejects(base([cp(i, []) for i in range(31)]), '1.30')
        # 30 checkpoints x 20 tasks = 630 > 500 entities
        self.rejects(base([cp(i, [{'id': f't{i}x{j}', 'text': 't', 'state': 'pending'} for j in range(20)]) for i in range(30)]), 'at most 500')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'][0].update(text='x' * 241)), 'text')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'][0]['items'][0].update(path='x' * 241)), 'path')
        self.rejects(mutated(detailed_plan(), lambda v: v['checkpoints'][0]['tasks'][0]['items'][0].update(id='A' * 3)), 'unique')

    def test_maximal_unicode_plan_fits_the_ssh_ceiling(self):
        emoji = '\U0001f600'
        entities = []
        checkpoints = []
        count = 0
        for c in range(9):
            tasks = []
            for t in range(5):
                items = []
                for i in range(9):
                    count += 1
                    items.append({'id': f'i{count}', 'kind': 'file', 'path': emoji*240, 'text': emoji*240, 'state': 'blocked', 'reason': emoji*400})
                count += 1
                tasks.append({'id': f't{count}', 'text': emoji*240, 'state': 'blocked', 'reason': emoji*400, 'items': items})
            count += 1
            checkpoints.append({'id': f'c{count}', 'text': emoji*240, 'state': 'blocked', 'reason': emoji*400, 'tasks': tasks})
        value = {'schema': 2, 'plan_id': 'plan-ffffffffffff', 'title': emoji*160, 'current': checkpoints[0]['id'], 'checkpoints': checkpoints}
        self.assertLessEqual(count, self.reader.MAX_ENTITIES)
        self.assertEqual(self.reader.validate(value), value)
        write_plan(self.path, value)
        # The file is only bounded by LIMIT; a plan this large is refused there, never truncated.
        if self.path.stat().st_size > self.reader.LIMIT:
            with self.assertRaisesRegex(ValueError, '1 MiB'):
                self.reader.read_plan(self.path)
        else:
            encoded = (self.reader._source_envelope(value)+'\n').encode()
            self.assertLessEqual(len(encoded), self.reader.SSH_RESPONSE_LIMIT)

    def test_entity_text_may_be_one_codepoint_and_non_ascii(self):
        value = mutated(detailed_plan(), lambda v: v['checkpoints'][2].update(text='\u00e9'))
        self.assertEqual(self.reader.validate(value), value)


class WindowContract(unittest.TestCase):
    """Static contracts for window/host sources that no Python helper exercises."""

    def source(self, name):
        return (ROOT/name).read_text()

    def test_files_button_is_gone_and_status_segment_opens_settings(self):
        window = self.source('window.luau')
        self.assertNotIn('files.button', window)
        self.assertIn('icon = "list-checks", text = "TODO"', window)
        self.assertIn('"settings"', window)
        self.assertIn('TODO: Open Settings', window)
        self.assertIn('status_prompt.ensure(cx, tern.plugin.id)', window)
        self.assertEqual(window.count('status_prompt.ensure('), 1)

    def test_host_never_sends_the_client_window_key_to_the_host_resolver(self):
        host = self.source('host.luau')
        self.assertNotIn('selected.window', host.split('selection.resolve(')[1].split('function')[0])
        self.assertIn('selection.resolve(state.panel, ""', host)

    def test_attach_args_carry_no_client_window_key_and_picker_is_gone(self):
        attach = self.source('lib/attach.luau')
        self.assertNotIn('window_key', attach)
        self.assertNotIn('window =', attach)
        self.assertNotIn('chooseSession', attach)
        host = self.source('host.luau')
        self.assertNotIn('source.window', host)
        self.assertNotIn('window: string', host)
        for name in ['window.luau', 'host.luau', 'lib/attach.luau']:
            self.assertNotIn('chooseSession', self.source(name))

    def test_board_writes_go_through_the_host_claim(self):
        window = self.source('window.luau')
        self.assertIn('board_claim.acquire(', window)
        self.assertLess(window.index('board_claim.acquire('), window.index('board_sync.apply('))
        self.assertIn('board_claim.holds(', window)
        self.assertIn('board_claim.host_serve(', self.source('host.luau'))
        self.assertIn('board_sync.MAX_SYNC_ENTITIES', window)
        self.assertNotIn('excess', self.source('lib/board_sync.luau'))

    def test_turning_sync_on_forgets_the_cached_revision(self):
        window = self.source('window.luau')
        self.assertIn('synced.settingsChanged(before, after)', window)
        self.assertNotIn('lastRev', window)
        self.assertIn('boardMemo.succeeded(target.pane, key, entry.rev, gen, count, tern.now(), title, path)', window)
        self.assertIn('gate.passed(key, rev, gen, count, nowMs)', self.source('lib/sync_pane.luau'))

    def test_every_sync_status_change_repaints_an_open_settings_pane(self):
        window = self.source('window.luau')
        self.assertIn('sync_status.new(', window)
        self.assertNotIn('syncStatus = "', window)
        self.assertNotIn('syncStatus = problem', window)
        self.assertNotIn('syncStatus = board_sync', window)
        self.assertNotIn('syncStatus = nil', window)
        self.assertGreaterEqual(window.count('syncStatus.set('), 7)
        self.assertIn('pane = settingsPane', window)

    def test_manifest_keeps_version_and_icon(self):
        manifest = self.source('plugin.toml')
        self.assertIn('version = "0.7.3"', manifest)
        self.assertIn('icon = "list-checks"', manifest)


if __name__ == '__main__':
    unittest.main()

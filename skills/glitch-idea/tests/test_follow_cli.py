"""--follow: the helper runs the events loop itself, right after the open or from a cursor (SKILLS-168).

The reported shape (Kimi on kimibwai, 16 Nov 2026): the agent's next tool call came more than 35 seconds
after browser-open, so the lease had lapsed and the first wait returned agent_unavailable.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import test_agent_client as fixture

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hermetic_cli import idea_script
SCRIPTS = Path(__file__).resolve().parents[1]/'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
import idea


class ScriptedHandler(fixture.FixedHandler):
    """The fixed owner, except that each events call takes the next scripted answer."""
    def handle_fixed(self):
        f = self.server.fixture
        path = urlsplit(self.path)
        if path.path != '/agent/v1/events' or not f.script:
            return super().handle_fixed()
        f.calls.append((self.command, path.path, None, dict(self.headers)))
        f.afters.append(int(parse_qs(path.query)['after'][0]))
        status, result = f.script.pop(0)
        raw = json.dumps(result).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers(); self.wfile.write(raw)


@unittest.skipUnless(os.name == 'posix', 'Runtime native owner ACLs remain unqualified')
class FollowTests(unittest.TestCase):
    def setUp(self):
        fixture.AgentClientTests.setUp(self)
        # Swap in the scripted handler on the same port the owner published.
        self.server.RequestHandlerClass = ScriptedHandler
        self.script = []; self.afters = []
        self.private = Path(self.temp.name)/'loop'; self.private.mkdir(mode=0o700); os.chmod(self.private, 0o700)
        self.follow = self.private/'events.jsonl'

    stop = fixture.AgentClientTests.stop

    def wait(self, sequence, events=(), status='connected', reason=None):
        return 200, dict(ok=True, code='ok', session_id=self.sid, agent_status=status, reason=reason,
                         sequence=sequence, events=list(events))

    def delivery(self, sequence):
        return self.wait(sequence, [dict(self.correlation, sequence=sequence, data={'exploration': 'input'})])

    def refusal(self, code, status=409):
        return status, dict(ok=False, code=code)

    def cli(self, *extra, ok=True):
        argv = [sys.executable, str(idea_script()), '--store', str(self.owner.store_path), 'events',
                '--runtime-root', str(self.owner.runtime_root), '--session', self.sid, *map(str, extra)]
        result = subprocess.run(argv, capture_output=True, timeout=30)
        self.assertEqual(result.stderr, b'')
        self.assertNotIn(self.token.encode(), result.stdout)
        body = json.loads(result.stdout)
        self.assertEqual(body['ok'], ok, body)
        return body

    def lines(self):
        raw = self.follow.read_bytes()
        self.assertNotIn(self.token.encode(), raw)
        return [json.loads(line) for line in raw.decode().splitlines()]

    # --- the loop ---

    def test_empty_waits_advance_the_cursor_until_a_request_arrives(self):
        self.script = [self.wait(3), self.wait(5), self.delivery(6)]
        body = self.cli('--after', 2, '--timeout', 1, '--follow', self.follow)
        self.assertEqual(body['events'][0]['request_id'], 'request-1')
        self.assertEqual(self.afters, [2, 3, 5])
        self.assertEqual([line['sequence'] for line in self.lines()], [3, 5, 6])
        info = os.lstat(self.follow)
        self.assertEqual(info.st_mode & 0o777, 0o600); self.assertEqual(info.st_uid, os.getuid())

    def test_a_pause_or_disconnect_ends_the_loop(self):
        for status, reason in (('paused', 'idle'), ('disconnected', 'closed')):
            with self.subTest(status=status):
                self.follow.unlink(missing_ok=True); self.afters.clear()
                self.script = [self.wait(1), self.wait(1, status=status, reason=reason)]
                body = self.cli('--timeout', 1, '--follow', self.follow)
                self.assertEqual(body['agent_status'], status)
                self.assertEqual(len(self.lines()), 2); self.assertEqual(self.afters, [0, 1])

    def test_a_stop_code_ends_the_loop_at_once(self):
        self.script = [self.refusal('agent_unavailable', 403), self.delivery(1)]
        body = self.cli('--timeout', 1, '--follow', self.follow, ok=False)
        self.assertEqual(body['error']['code'], 'agent_unavailable')
        self.assertEqual(self.afters, [0])
        self.assertEqual(self.lines(), [body])

    def test_busy_is_waited_again_from_the_same_cursor_then_reported(self):
        self.script = [self.wait(4), self.refusal('busy'), self.refusal('busy'), self.delivery(5)]
        body = self.cli('--timeout', 1, '--follow', self.follow)
        self.assertEqual(body['sequence'], 5); self.assertEqual(self.afters, [0, 4, 4, 4])
        self.follow.unlink(); self.afters.clear()
        self.script = [self.refusal('busy')]*3 + [self.delivery(1)]
        body = self.cli('--timeout', 1, '--follow', self.follow, ok=False)
        self.assertEqual(body['error']['code'], 'busy'); self.assertEqual(self.afters, [0, 0, 0])

    def test_the_file_is_appended_never_replaced(self):
        self.follow.write_text('{"earlier":true}\n'); os.chmod(self.follow, 0o600)
        self.script = [self.delivery(1)]
        self.cli('--timeout', 1, '--follow', self.follow)
        self.assertEqual(self.lines()[0], {'earlier': True}); self.assertEqual(len(self.lines()), 2)

    # --- the file's folder, refused before the owner is ever contacted ---

    def assert_refused(self, path, code='follow_not_private'):
        self.script = [self.delivery(1)]
        body = self.cli('--timeout', 1, '--follow', path, ok=False)
        self.assertEqual(body['error']['code'], code)
        self.assertEqual(self.calls, [])

    def test_a_loose_folder_is_refused(self):
        os.chmod(self.private, 0o755)
        self.assert_refused(self.follow)
        self.assertFalse(self.follow.exists())

    def test_a_missing_folder_is_refused_and_never_created(self):
        self.assert_refused(self.private/'absent'/'events.jsonl')
        self.assertFalse((self.private/'absent').exists())

    def test_a_symlinked_file_or_folder_is_refused(self):
        target = self.private/'elsewhere.jsonl'; target.write_text(''); os.chmod(target, 0o600)
        os.symlink(target, self.follow)
        self.assert_refused(self.follow)
        self.assertEqual(target.read_text(), '')
        link = Path(self.temp.name)/'linked'; os.symlink(self.private, link)
        self.assert_refused(link/'events.jsonl')

    def test_a_hard_linked_or_loose_file_is_refused(self):
        other = self.private/'other.jsonl'; other.write_text(''); os.chmod(other, 0o600)
        os.link(other, self.follow)
        self.assert_refused(self.follow)
        os.unlink(self.follow); self.follow.write_text(''); os.chmod(self.follow, 0o644)
        self.assert_refused(self.follow)

    def test_the_runtime_folder_and_a_relative_path_are_usage(self):
        self.assert_refused(Path(self.owner.runtime_root)/'events.jsonl', 'usage')
        below = Path(self.owner.runtime_root)/'loop'; below.mkdir(mode=0o700)
        self.assert_refused(below/'events.jsonl', 'usage')  # a folder inside the runtime folder too
        self.assertFalse((below/'events.jsonl').exists())
        self.assert_refused('events.jsonl', 'usage')

    def test_a_zero_wait_with_follow_is_refused_before_the_owner_is_contacted(self):
        self.script = [self.delivery(1)]
        body = self.cli('--timeout', 0, '--follow', self.follow, ok=False)
        self.assertEqual(body['error']['code'], 'invalid_agent_input')
        self.assertEqual(self.calls, []); self.assertFalse(self.follow.exists())

    def test_without_follow_events_waits_once_as_before(self):
        self.script = [self.wait(3), self.delivery(4)]
        body = self.cli('--timeout', 0)
        self.assertEqual(body['sequence'], 3); self.assertEqual(self.afters, [0])


class FakeClient:
    def __init__(self, answers): self.answers = list(answers); self.afters = []
    def events(self, after, timeout):
        self.afters.append(after); answer = self.answers.pop(0)
        if isinstance(answer, Exception): raise answer
        return answer


@unittest.skipUnless(os.name == 'posix', 'Runtime native owner ACLs remain unqualified')
class FollowLoopUnitTests(unittest.TestCase):
    """The loop's own rules, without a socket: what a slow transport answer or a cut write does."""
    def setUp(self):
        from idea_agent_client import AgentClientError
        self.Error = AgentClientError
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        folder = Path(self.temp.name)/'loop'; folder.mkdir(mode=0o700); os.chmod(folder, 0o700)
        os.chmod(self.temp.name, 0o700)
        self.path = folder/'events.jsonl'
        self.fd = idea._follow_file(str(self.path)); self.addCleanup(os.close, self.fd)

    def wait(self, sequence, events=()):
        return dict(ok=True, code='ok', session_id='session_'+'1'*32, agent_status='connected', reason=None,
                    sequence=sequence, events=list(events))

    def test_a_transport_timeout_is_waited_again_from_the_same_cursor_then_reported(self):
        late = lambda: self.Error('agent_transport_timeout')
        client = FakeClient([self.wait(4), late(), late(), self.wait(5, [{'x': 1}])])
        self.assertEqual(idea._follow(self.fd, client, 0, 1, self.Error)['sequence'], 5)
        self.assertEqual(client.afters, [0, 4, 4, 4])
        client = FakeClient([late(), late(), late(), self.wait(1, [{'x': 1}])])
        self.assertEqual(idea._follow(self.fd, client, 0, 1, self.Error)['error']['code'], 'agent_transport_timeout')
        self.assertEqual(client.afters, [0, 0, 0])

    def test_a_file_owned_by_another_account_is_refused(self):
        self.path.write_text(''); os.chmod(self.path, 0o600)
        real, ino = os.fstat, os.lstat(self.path).st_ino
        def foreign(fd):
            info = real(fd)
            if info.st_ino != ino: return info
            fields = list(info); fields[4] = info.st_uid + 1
            return os.stat_result(fields)
        with patch.object(idea.os, 'fstat', side_effect=foreign):
            with self.assertRaises(idea.IdeaError) as caught: idea._follow_file(str(self.path))
        self.assertEqual(caught.exception.code, 'follow_not_private')

    def test_a_folder_owned_by_another_account_is_refused(self):
        import idea_runtime
        real, ino = os.fstat, os.lstat(self.path.parent).st_ino
        def foreign(fd):
            info = real(fd)
            if info.st_ino != ino: return info
            fields = list(info); fields[4] = info.st_uid + 1
            return os.stat_result(fields)
        target = self.path.parent/'other.jsonl'
        with patch.object(idea_runtime.os, 'fstat', side_effect=foreign):
            with self.assertRaises(idea.IdeaError) as caught: idea._follow_file(str(target))
        self.assertEqual(caught.exception.code, 'follow_not_private'); self.assertFalse(target.exists())

    def test_follow_is_refused_off_posix_before_any_file_is_made(self):
        target = self.path.parent/'other.jsonl'
        with patch.object(idea.os, 'name', 'nt'):
            with self.assertRaises(idea.IdeaError) as caught: idea._follow_file(str(target))
        self.assertEqual(caught.exception.code, 'follow_unsupported'); self.assertFalse(target.exists())

    def test_a_short_write_still_lands_one_whole_line(self):
        real = os.write
        with patch.object(idea.os, 'write', side_effect=lambda fd, data: real(fd, bytes(data[:3]))):
            idea._follow_line(self.fd, {'sequence': 7, 'text': 'a longer value than three bytes'})
        self.assertEqual(json.loads(self.path.read_text()), {'sequence': 7, 'text': 'a longer value than three bytes'})

    def test_a_client_that_cannot_be_built_reports_its_own_code(self):
        from idea_runtime import RuntimeError as OwnerError
        with patch('idea_agent_client.AgentClient', side_effect=OwnerError('owner_unavailable')):
            result = idea._follow_session(self.fd, Path(self.temp.name), Path(self.temp.name), 'session_'+'1'*32, None, 0, 1)
        self.assertEqual(result['error']['code'], 'owner_unavailable')
        self.assertEqual(json.loads(self.path.read_text()), result)


@unittest.skipUnless(os.name == 'posix', 'Runtime native owner ACLs remain unqualified')
class FollowAfterOpenTests(unittest.TestCase):
    """browser-open --follow: the open is the first line and the first wait follows in the same process."""
    setUp = FollowTests.setUp
    stop = FollowTests.stop
    wait = FollowTests.wait
    delivery = FollowTests.delivery
    lines = FollowTests.lines

    def launch(self, *extra, opened=None):
        order = []
        def fake_open(store, runtime, config, **options):
            order.append('open')
            return dict(binding_id=self.bid, session_id=self.sid, opened=True, how='above')
        args = idea.parser().parse_args(['--store', str(self.owner.store_path), 'browser-open',
                                         '--runtime-root', str(self.owner.runtime_root), *map(str, extra)])
        config = dict(store_path=str(self.owner.store_path))
        with patch.object(idea, 'launcher_configuration', return_value=(Path(self.owner.store_path), Path(self.owner.runtime_root), config, sys.executable)), \
             patch('idea_launch.open_browser_session', side_effect=opened or fake_open), \
             patch('idea_tern.open_tern_session', side_effect=opened or fake_open), \
             patch('idea_tern.default_is_tern', return_value=False):
            args.runtime_root_fallback = None
            return idea.run_launcher(args), order

    def test_the_open_is_line_one_and_the_loop_starts_at_cursor_zero(self):
        self.script = [self.wait(2), self.delivery(3)]
        result, order = self.launch('--browser', 'system', '--follow', self.follow)
        self.assertEqual(order, ['open'])
        self.assertTrue(result['ok']); self.assertEqual(result['session_id'], self.sid)
        self.assertEqual(result['follow']['events'][0]['request_id'], 'request-1')
        lines = self.lines()
        self.assertEqual(lines[0]['session_id'], self.sid); self.assertTrue(lines[0]['opened'])
        self.assertEqual([line['sequence'] for line in lines[1:]], [2, 3])
        self.assertEqual(self.afters, [0, 2])

    def test_a_bad_file_is_refused_before_any_session_is_opened(self):
        os.chmod(self.private, 0o755)
        result, order = self.launch('--browser', 'system', '--follow', self.follow)
        self.assertEqual(result['error']['code'], 'follow_not_private')
        self.assertEqual(order, []); self.assertEqual(self.calls, [])

    def test_a_loop_failure_keeps_the_open_result(self):
        self.script = [(403, dict(ok=False, code='agent_unavailable'))]
        result, _ = self.launch('--browser', 'system', '--follow', self.follow)
        self.assertTrue(result['ok']); self.assertEqual(result['follow']['error']['code'], 'agent_unavailable')

    def test_a_launch_needs_a_new_file_and_refuses_before_any_session(self):
        self.follow.write_text('{"earlier":true}\n'); os.chmod(self.follow, 0o600)
        result, order = self.launch('--browser', 'system', '--follow', self.follow)
        self.assertEqual(result['error']['code'], 'follow_exists')
        self.assertEqual(order, []); self.assertEqual(self.calls, [])
        self.assertEqual(self.follow.read_text(), '{"earlier":true}\n')

    def test_a_failed_first_line_keeps_the_open_result(self):
        with patch.object(idea, '_follow_line', side_effect=OSError('disk full')):
            result, order = self.launch('--browser', 'system', '--follow', self.follow)
        self.assertEqual(order, ['open'])
        self.assertTrue(result['ok']); self.assertEqual(result['session_id'], self.sid)
        self.assertEqual(result['follow']['error']['code'], 'follow_write_failed')
        self.assertEqual(self.calls, [])

    def test_reconnect_and_orca_take_no_follow(self):
        for extra in (('--browser', 'orca', '--orca-worktree', 'w', '--orca-terminal', 't'),
                      ('--browser', 'orca', '--orca-worktree', 'w', '--orca-terminal', 't', '--reconnect', self.bid)):
            result, order = self.launch(*extra, '--follow', self.follow)
            self.assertEqual(result['error']['code'], 'usage'); self.assertEqual(order, [])

    def test_without_follow_the_open_returns_at_once(self):
        result, order = self.launch('--browser', 'system')
        self.assertNotIn('follow', result); self.assertEqual(self.calls, [])
        self.assertFalse(self.follow.exists())


if __name__ == '__main__':
    unittest.main()

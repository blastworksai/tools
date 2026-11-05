"""remove-idea is one step: --confirm removes the idea and drops this seat's saved sessions that select it."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
SCRIPTS = Path(__file__).resolve().parents[1]/'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
from test_handoff_store import seed as seed_handoff
from unittest.mock import patch
from idea_runtime import Runtime
import idea
import idea_launch as launch
import idea_store

SCRIPT = SCRIPTS/'idea.py'
OTHER = 'idea_'+'b'*32


def tree(root):
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in sorted(Path(root).rglob('*')) if p.is_file() and p.name != '.lock'}


def binding(number, idea):
    return dict(schema_version=1, binding_id='binding_'+format(number, '032x'), actor='Operator',
                receipt_session_id='session_'+format(number, '032x'), selected_idea_id=idea)


def bid(number):
    return 'binding_'+format(number, '032x')


class RemoveIdeaDropsSessions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.store, self.runtime = base/'store', base/'private'
        self.sid, self.key, self.packets, self.links = seed_handoff(self.store)

    def save(self, *records, root=None):
        owner = Runtime(self.store, root or self.runtime)
        owner.acquire_owner()
        try:
            for record in records: owner.persist_binding(record)
        finally: owner.close()

    def saved(self, root=None):
        return sorted(r['binding_id'] for r in Runtime(self.store, root or self.runtime).list_bindings())

    def raw(self, *args):
        result = subprocess.run([sys.executable, str(SCRIPT), '--store', str(self.store), 'remove-idea', '--idea', self.key,
                                 '--actor', 'operator', '--runtime-root', str(self.runtime), *args], capture_output=True, text=True)
        self.assertNotIn('Traceback', result.stderr)
        return result, json.loads(result.stdout)

    def run_in_process(self, *patches):
        """remove-idea --confirm with NO --runtime-root flag; the root must come from config or the default."""
        buffer = io.BytesIO()
        out = type('S', (), {'buffer': buffer, 'write': lambda *a: None, 'flush': lambda *a: None})()
        argv = ['--store', str(self.store), 'remove-idea', '--idea', self.key, '--actor', 'operator', '--confirm']
        with contextlib.ExitStack() as stack:
            for item in patches: stack.enter_context(item)
            stack.enter_context(patch.object(sys, 'stdout', out))
            code = idea.main(argv)
        return code, json.loads(buffer.getvalue())

    def config_root(self):
        real = idea._configuration_source

        def configured():
            value, base, skill_dir, installed, argv, timeout = real()
            return dict(value, runtime_root=str(self.runtime)), base, skill_dir, installed, argv, timeout
        return patch.object(idea, '_configuration_source', configured)

    # (1)
    def test_preview_lists_the_selecting_sessions_and_writes_nothing(self):
        self.save(binding(1, self.key), binding(2, OTHER), binding(3, self.key))
        before, bindings = tree(self.store), tree(self.runtime)
        result, data = self.raw()
        self.assertEqual(result.returncode, 0, data)
        self.assertTrue(data['ok'] and not data['removed'] and data['dry_run'])
        self.assertEqual(data['sessions_to_drop'], [dict(binding_id=bid(1), in_use=None), dict(binding_id=bid(3), in_use=None)])
        self.assertIn('--confirm', data['sessions_note'])
        text = json.dumps(data)
        for word in ('token', 'owner_token', 'pair', 'credential', 'Operator', 'session_'):
            self.assertNotIn(word, text)
        self.assertEqual(tree(self.store), before)
        self.assertEqual(tree(self.runtime), bindings)

    def test_preview_with_no_session_lists_none(self):
        _, data = self.raw()
        self.assertEqual(data['sessions_to_drop'], [])
        self.assertNotIn('sessions_note', data)
        self.assertFalse(self.runtime.exists(), 'the preview never creates the runtime')

    # (2)
    def test_confirm_with_no_service_removes_the_idea_and_drops_the_selecting_bindings_only(self):
        self.save(binding(1, self.key), binding(2, OTHER), binding(3, self.key), binding(4, None))
        result, data = self.raw('--confirm')
        self.assertEqual(result.returncode, 0, data)
        self.assertTrue(data['ok'] and data['removed'], data)
        self.assertEqual(data['sessions_dropped'], [bid(1), bid(3)])
        self.assertNotIn('sessions_not_dropped', data)
        self.assertEqual(self.saved(), [bid(2), bid(4)])
        self.assertNotIn('idea_in_use', json.dumps(data))

    def test_confirm_with_no_runtime_folder_just_removes(self):
        _, data = self.raw('--confirm')
        self.assertTrue(data['ok'] and data['removed'], data)
        self.assertEqual(data['sessions_dropped'], [])
        self.assertFalse(self.runtime.exists())

    # (3)
    @unittest.skipUnless(os.name == 'posix', 'Native owner ACLs remain unqualified')
    def test_confirm_drops_a_live_session_through_the_running_owner_and_the_service_keeps_running(self):
        children = []
        client = Runtime(self.store, self.runtime)

        def spawn(*a, **k):
            child = subprocess.Popen(*a, **k); children.append(child); return child

        def cleanup():
            end = time.monotonic() + 8
            while any(c.poll() is None for c in children) and time.monotonic() < end:
                try: client.request_owned_stop(timeout=3)
                except Exception: time.sleep(.05)
            for c in children: c.wait(timeout=5)
        self.addCleanup(cleanup)
        opened = launch.open_session(self.store, self.runtime, selected_idea_id=self.key, spawn=spawn)
        live = opened['binding_id']
        self.assertEqual(self.saved(), [live])
        _, preview = self.raw()
        self.assertEqual(preview['sessions_to_drop'], [dict(binding_id=live, in_use=preview['sessions_to_drop'][0]['in_use'])])
        self.assertIsInstance(preview['sessions_to_drop'][0]['in_use'], bool)
        _, data = self.raw('--confirm')
        self.assertTrue(data['ok'] and data['removed'], data)
        self.assertEqual(data['sessions_dropped'], [live])
        self.assertEqual(self.saved(), [])
        self.assertIsNone(children[0].poll(), 'the owner service is still running')
        self.assertEqual(client.list_sessions(timeout=5), [], 'and it answers, with the session gone')

    # (4)
    def test_a_session_saved_between_the_commit_and_the_sweep_is_dropped_too(self):
        self.save(binding(1, self.key))
        real, late = idea_store.Store.remove_idea, binding(9, self.key)

        def racing(store, *args, **kwargs):
            result = real(store, *args, **kwargs)
            if kwargs.get('confirm'): self.save(late)  # the owner saves a session just after the removal committed
            return result
        code, data = self.run_in_process(patch.object(idea_store.Store, 'remove_idea', racing), self.config_root())
        self.assertEqual(code, 0, data)
        self.assertEqual(data['sessions_dropped'], [bid(1), bid(9)])
        self.assertEqual(self.saved(), [])

    # (5)
    def test_a_drop_failure_leaves_the_idea_removed_and_is_reported(self):
        self.save(binding(1, self.key), binding(2, self.key))
        real = idea._drop_session

        def flaky(args, binding_id):
            if binding_id == bid(1): raise RuntimeError('refused')
            return real(args, binding_id)
        code, data = self.run_in_process(patch.object(idea, '_drop_session', flaky), self.config_root())
        self.assertEqual(code, 0, data)
        self.assertTrue(data['ok'] and data['removed'], data)
        self.assertEqual(data['sessions_dropped'], [bid(2)])
        self.assertEqual(data['sessions_not_dropped'], [bid(1)])
        self.assertEqual(self.saved(), [bid(1)])
        _, again = self.raw('--confirm')
        self.assertEqual(again['error']['code'], 'not_found', 'the idea is gone')

    # (6)
    def test_the_runtime_root_comes_from_the_configuration_when_no_flag_is_given(self):
        self.save(binding(1, self.key))
        code, data = self.run_in_process(self.config_root())
        self.assertEqual(code, 0, data)
        self.assertEqual(data['sessions_dropped'], [bid(1)])
        self.assertEqual(self.saved(), [])

    def test_the_default_runtime_root_is_used_when_neither_flag_nor_config_names_one(self):
        home = Path(self.temp.name)/'home'
        home.mkdir(mode=0o700)
        real = idea._configuration_source

        def unconfigured():
            value, base, skill_dir, installed, argv, timeout = real()
            return {k: v for k, v in value.items() if k != 'runtime_root'}, base, skill_dir, installed, argv, timeout
        default = home/'.local/state/glitch-idea'
        self.save(binding(1, self.key), root=default)
        code, data = self.run_in_process(patch.object(idea, '_configuration_source', unconfigured),
                                         patch.object(idea, '_private_home', lambda: home))
        self.assertEqual(code, 0, data)
        self.assertEqual(data['sessions_dropped'], [bid(1)])
        self.assertEqual(self.saved(default), [])


if __name__ == '__main__':
    unittest.main()

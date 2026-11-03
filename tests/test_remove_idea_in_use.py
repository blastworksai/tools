"""remove-idea refuses while one of this seat's saved browser sessions still selects the idea."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
SCRIPTS = Path(__file__).resolve().parents[1]/'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
from test_handoff_store import seed as seed_handoff
from unittest.mock import patch
from idea_runtime import Runtime
import idea
import idea_store

SCRIPT = SCRIPTS/'idea.py'
OTHER = 'idea_'+'b'*32


def tree(root):
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in sorted(Path(root).rglob('*')) if p.is_file() and p.name != '.lock'}


def binding(number, idea):
    return dict(schema_version=1, binding_id='binding_'+format(number, '032x'), actor='Operator',
                receipt_session_id='session_'+format(number, '032x'), selected_idea_id=idea)


class RemoveIdeaInUse(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.store, self.runtime = base/'store', base/'private'
        self.sid, self.key, self.packets, self.links = seed_handoff(self.store)

    def save(self, *records):
        owner = Runtime(self.store, self.runtime)
        owner.acquire_owner()
        try:
            for record in records: owner.persist_binding(record)
        finally: owner.close()

    def discard(self, binding_id):
        owner = Runtime(self.store, self.runtime)
        owner.acquire_owner()
        try: owner.remove_binding(binding_id)
        finally: owner.close()

    def raw(self, *args):
        result = subprocess.run([sys.executable, str(SCRIPT), '--store', str(self.store), 'remove-idea', '--idea', self.key,
                                 '--actor', 'operator', '--runtime-root', str(self.runtime), *args], capture_output=True, text=True)
        self.assertNotIn('Traceback', result.stderr)
        return result, json.loads(result.stdout)

    def test_a_session_selecting_the_idea_refuses_preview_and_confirm_and_touches_nothing(self):
        self.save(binding(1, self.key), binding(2, OTHER), binding(3, self.key))
        before = tree(self.store)
        for extra in ((), ('--confirm',)):
            result, data = self.raw(*extra)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(data['ok'])
            self.assertEqual(data['error']['code'], 'idea_in_use', data)
            self.assertEqual(data['binding_ids'], ['binding_'+format(1, '032x'), 'binding_'+format(3, '032x')])
            self.assertEqual(tree(self.store), before)

    def test_the_refusal_carries_only_typed_ids(self):
        self.save(binding(1, self.key))
        _, data = self.raw('--confirm')
        self.assertEqual(set(data), {'ok', 'error', 'binding_ids'})
        self.assertEqual(set(data['error']), {'code', 'message'})
        text = json.dumps(data)
        for word in ('token', 'owner_token', 'pair', 'credential', 'Operator', 'session_'):
            self.assertNotIn(word, text)

    def test_a_session_on_another_idea_does_not_block(self):
        self.save(binding(1, OTHER), binding(2, None))
        _, data = self.raw('--confirm')
        self.assertTrue(data['ok'], data)
        self.assertTrue(data['removed'])

    def test_no_runtime_folder_means_no_sessions(self):
        self.assertFalse(self.runtime.exists())
        _, data = self.raw()
        self.assertTrue(data['ok'], data)
        self.assertFalse(data['removed'])
        self.assertFalse(self.runtime.exists(), 'the check never creates the runtime')
        _, data = self.raw('--confirm')
        self.assertTrue(data['removed'])

    def test_after_the_session_is_discarded_removal_works(self):
        self.save(binding(1, self.key))
        self.assertEqual(self.raw('--confirm')[1]['error']['code'], 'idea_in_use')
        self.discard('binding_'+format(1, '032x'))
        _, data = self.raw('--confirm')
        self.assertTrue(data['ok'] and data['removed'], data)

    def test_a_session_saved_after_the_early_scan_is_caught_under_the_store_lock(self):
        before = tree(self.store)
        real, late = idea_store.Store.remove_idea, binding(9, self.key)

        def racing(store, *args, **kwargs):
            if kwargs.get('confirm'): self.save(late)  # the owner opens a session between the scan and the lock
            return real(store, *args, **kwargs)
        code, data = self.run_in_process(patch.object(idea_store.Store, 'remove_idea', racing), self.config_root())
        self.assertEqual(code, 1)
        self.assertEqual(data['error']['code'], 'idea_in_use', data)
        self.assertEqual(data['binding_ids'], [late['binding_id']])
        self.assertEqual(tree(self.store), before)

    def run_in_process(self, *patches):
        """remove-idea --confirm with NO --runtime-root flag; the root must come from config or the default."""
        import io, contextlib
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

    def test_the_runtime_root_comes_from_the_configuration_when_no_flag_is_given(self):
        self.save(binding(1, self.key))
        real = idea._configuration_source

        def configured():
            value, base, skill_dir, installed, argv, timeout = real()
            return dict(value, runtime_root=str(self.runtime)), base, skill_dir, installed, argv, timeout
        code, data = self.run_in_process(patch.object(idea, '_configuration_source', configured))
        self.assertEqual(code, 1)
        self.assertEqual(data['error']['code'], 'idea_in_use', data)

    def test_the_default_runtime_root_is_checked_when_neither_flag_nor_config_names_one(self):
        home = Path(self.temp.name)/'home'
        home.mkdir(mode=0o700)
        real = idea._configuration_source

        def unconfigured():
            value, base, skill_dir, installed, argv, timeout = real()
            return {k: v for k, v in value.items() if k != 'runtime_root'}, base, skill_dir, installed, argv, timeout
        default = home/'.local/state/glitch-idea'
        owner = Runtime(self.store, default)
        owner.acquire_owner()
        try: owner.persist_binding(binding(1, self.key))
        finally: owner.close()
        code, data = self.run_in_process(patch.object(idea, '_configuration_source', unconfigured),
                                         patch.object(idea, '_private_home', lambda: home))
        self.assertEqual(code, 1)
        self.assertEqual(data['error']['code'], 'idea_in_use', data)


if __name__ == '__main__':
    unittest.main()

"""A saved session whose idea was removed is set aside on restore; it never stops the owner service from starting."""
import copy
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'glitch-idea' / 'scripts'))
import idea_launch as launch
import idea_service
import idea_store as storage
from idea_domain import IdeaError
from idea_runtime import Runtime
from test_import_idea import plain_idea

GONE = 'idea_' + '3' * 32
LIVE = 'idea_' + '4' * 32


@unittest.skipUnless(os.name == 'posix', 'Native owner ACLs remain unqualified')
class RestoreParksOrphanedSessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.store_path, self.root = base / 'ideas', base / 'private'
        self.store = storage.Store(self.store_path, observer='seed')
        with self.store.transaction(write=True) as state:
            for key in (GONE, LIVE):
                state['ideas'][key] = plain_idea(key); state['order'].append(key)
            state['backlog_revision'] += 1
            self.store.commit(state)

    def save(self, selected):
        """Persist one binding record under the runtime, as an earlier owner would have."""
        record = dict(schema_version=1, binding_id='binding_' + os.urandom(16).hex(), actor=launch._actor(),
                      receipt_session_id=self.store.create_session(), selected_idea_id=selected)
        runtime = Runtime(self.store_path, self.root); runtime.acquire_owner()
        try: runtime.persist_binding(record)
        finally: runtime.close()
        return record

    def bindings_dir(self, runtime):
        return runtime.path / 'bindings'

    def parked_dir(self, runtime):
        return self.root / 'parked-bindings' / runtime.store_sha256

    def remove_gone(self):
        self.store.remove_idea(GONE, actor='seed', confirm=True)

    def build(self):
        runtime = Runtime(self.store_path, self.root); runtime.acquire_owner()
        self.addCleanup(runtime.close)
        log = launch.attach_activity_log(self.root)
        self.addCleanup(lambda: launch.logging.getLogger('idea.activity').removeHandler(log))
        owner = launch.OwnerService(runtime)
        self.addCleanup(owner.shutdown)
        return runtime, owner

    def test_orphan_is_parked_live_one_restored(self):
        orphan, live = self.save(GONE), self.save(LIVE)
        original = (self.bindings_dir(Runtime(self.store_path, self.root)) / (orphan['binding_id'] + '.json')).read_bytes()
        self.remove_gone()
        runtime, owner = self.build()
        parked = self.parked_dir(runtime) / (orphan['binding_id'] + '.json')
        self.assertTrue(parked.is_file())
        self.assertEqual(stat.S_IMODE(parked.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(parked.parent.stat().st_mode), 0o700)
        self.assertEqual(parked.read_bytes(), original)
        self.assertFalse((self.bindings_dir(runtime) / (orphan['binding_id'] + '.json')).exists())
        self.assertNotIn(orphan['binding_id'], owner.members)
        self.assertEqual([r['binding_id'] for r in runtime.list_bindings()], [live['binding_id']])
        self.assertEqual(owner.members, {live['binding_id']})
        text = (self.root / 'activity.log').read_text()
        line = [row for row in text.splitlines() if orphan['binding_id'] in row]
        self.assertEqual(len(line), 1, text)
        for part in (GONE, 'idea_removed'): self.assertIn(part, line[0])
        self.assertNotRegex(text, r'[A-Za-z0-9_-]{43}')

    def test_real_child_starts_and_opens_a_session(self):
        self.save(GONE); self.save(LIVE)
        self.remove_gone()
        children = []
        client = Runtime(self.store_path, self.root)

        def spawn(*a, **k):
            child = subprocess.Popen(*a, **k); children.append(child); return child

        def cleanup():
            end = time.monotonic() + 8
            while any(c.poll() is None for c in children) and time.monotonic() < end:
                try: client.request_owned_stop(timeout=3)
                except Exception: time.sleep(.05)
            for c in children: c.wait(timeout=5)
        self.addCleanup(cleanup)
        opened = launch.open_session(self.store_path, self.root, spawn=spawn)
        self.assertTrue(opened)
        self.assertEqual(len(list(self.parked_dir(client).iterdir())), 1)

    def test_other_restore_error_still_fails_the_start_and_parks_nothing(self):
        orphan = self.save(GONE)
        self.remove_gone()
        runtime = Runtime(self.store_path, self.root); runtime.acquire_owner(); self.addCleanup(runtime.close)

        def broken(self, *args, **kwargs): raise IdeaError('corrupt_store', 'store is corrupt')
        with patch.object(idea_service.Service, 'state', broken):
            with self.assertRaises(IdeaError) as caught:
                launch.OwnerService(runtime)
        self.assertEqual(caught.exception.code, 'corrupt_store')
        self.assertTrue((self.bindings_dir(runtime) / (orphan['binding_id'] + '.json')).exists())
        self.assertFalse(self.parked_dir(runtime).exists())

    def test_not_found_for_an_idea_that_still_exists_is_not_parked(self):
        live = self.save(LIVE)
        runtime = Runtime(self.store_path, self.root); runtime.acquire_owner(); self.addCleanup(runtime.close)

        def odd(self, *args, **kwargs): raise IdeaError('not_found', 'Unknown idea')
        with patch.object(idea_service.Service, 'state', odd):
            with self.assertRaises(IdeaError):
                launch.OwnerService(runtime)
        self.assertTrue((self.bindings_dir(runtime) / (live['binding_id'] + '.json')).exists())
        self.assertFalse(self.parked_dir(runtime).exists())

    def test_binding_without_a_selection_is_untouched(self):
        none = self.save(None)
        runtime, owner = self.build()
        self.assertEqual(owner.members, {none['binding_id']})
        self.assertTrue((self.bindings_dir(runtime) / (none['binding_id'] + '.json')).exists())
        self.assertFalse(self.parked_dir(runtime).exists())

    def test_a_failed_write_or_fsync_leaves_no_temp_file_and_the_binding_stays(self):
        from idea_runtime import RuntimeError as RuntimeFailure
        orphan = self.save(GONE)
        runtime = Runtime(self.store_path, self.root); runtime.acquire_owner(); self.addCleanup(runtime.close)
        original = (self.bindings_dir(runtime) / (orphan['binding_id'] + '.json')).read_bytes()
        real = os.fsync

        def failing(fd):
            if stat.S_ISREG(os.fstat(fd).st_mode): raise OSError(5, 'injected fsync failure')
            return real(fd)
        with patch('idea_runtime.os.fsync', failing):
            with self.assertRaises(RuntimeFailure) as caught:
                runtime.park_binding(orphan['binding_id'], 'idea_removed')
        self.assertEqual(caught.exception.code, 'runtime_persistence_failed')
        self.assertEqual(list(self.parked_dir(runtime).glob('.parking_*.tmp')), [])
        self.assertEqual(list(self.parked_dir(runtime).iterdir()), [])
        self.assertEqual((self.bindings_dir(runtime) / (orphan['binding_id'] + '.json')).read_bytes(), original)
        target = runtime.park_binding(orphan['binding_id'], 'idea_removed')  # restorable: the next try works
        self.assertEqual((self.parked_dir(runtime) / target).read_bytes(), original)


if __name__ == '__main__':
    unittest.main()

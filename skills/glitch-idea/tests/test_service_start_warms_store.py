"""The owner reads the store once during start-up, so the first binding-open is warm."""
from pathlib import Path
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "glitch-idea" / "scripts"))
import idea_launch as launch
import idea_store as storage
from idea_runtime import Runtime
from idea_domain import IdeaError


@unittest.skipUnless(os.name == 'posix', 'Native owner ACLs remain unqualified')
class ServiceStartWarmsStoreTests(unittest.TestCase):
    def test_init_loads_store_and_first_open_does_not_reparse(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        base = Path(temp.name); store = base / 'ideas'; root = base / 'private'
        # Seed a real Markdown store so the load path is the parsing one.
        seed = storage.Store(store, observer='seed')
        seed.create_session()
        runtime = Runtime(store, root); runtime.acquire_owner()
        calls = []
        original = storage.Store._load_markdown

        def counted(self, *args, **kwargs):
            calls.append(1)
            return original(self, *args, **kwargs)

        with patch.object(storage.Store, '_load_markdown', counted):
            owner = launch.OwnerService(runtime)
            self.addCleanup(owner.shutdown)
            self.assertGreaterEqual(len(calls), 1, 'store was not loaded during start-up')
            before = len(calls)
            owner._open(dict(mode='new', binding_id=None, selected_idea_id=None))
            self.assertEqual(len(calls), before, 'first binding-open re-parsed the store')

    def test_store_error_in_warm_read_does_not_stop_the_service_and_first_open_raises_it(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        base = Path(temp.name); store = base / 'ideas'; root = base / 'private'
        storage.Store(store, observer='seed').create_session()
        runtime = Runtime(store, root); runtime.acquire_owner()
        self.addCleanup(runtime.close)

        def broken(self, *args, **kwargs):
            raise IdeaError('corrupt_store', 'store is corrupt')
        with patch.object(storage.Store, '_load_markdown', broken):
            owner = launch.OwnerService(runtime)  # zero saved bindings: only the warm read touches the store
            self.addCleanup(owner.shutdown)
            self.assertIsNotNone(owner.server)
            with self.assertRaises(IdeaError) as caught:
                owner._open(dict(mode='new', binding_id=None, selected_idea_id=None))
        self.assertEqual(caught.exception.code, 'corrupt_store')


if __name__ == '__main__':
    unittest.main()

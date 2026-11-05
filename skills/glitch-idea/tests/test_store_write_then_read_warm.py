"""A commit that changes no authority file (create_session) keeps the remembered load warm; others' changes still miss."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parent))
import test_store_load_cache as base
from test_store_load_cache import md, HIT, Counting, patch
import idea_store as storage
from idea_domain import IdeaError


class WriteThenReadWarm(base.LoadCacheTests):
    # Reuses LoadCacheTests.setUp only; its own tests are deleted from this class.
    def counted(self,store=None):
        counter = Counting()
        with patch.object(md,'parse_document',counter):
            self.read(store)
        return counter.calls

    def test_own_create_session_leaves_next_read_a_hit(self):
        self.read()
        self.store.create_session()
        self.assertEqual(self.counted(),HIT)

    def test_cold_store_create_session_then_read_is_a_hit(self):
        fresh = storage.Store(self.root,observer='observing-session')
        fresh.create_session()
        self.assertEqual(self.counted(fresh),HIT)

    def test_another_store_instance_create_session_keeps_this_one_warm_but_edit_misses(self):
        self.read(); self.store.create_session()
        self.helper.edit(lambda m:m['idea']['ratings'].update(urgency=9))   # another writer, same bytes path
        self.assertGreater(self.counted(),HIT)

    def test_another_store_commit_misses(self):
        self.read(); self.store.create_session()
        other = storage.Store(self.root,observer='other-session')
        other.create_session()
        self.read(other)
        path = self.root/'IDEAS.md'
        path.write_bytes(path.read_bytes()+b'\n')
        with self.assertRaises(IdeaError):   # a hit would have served stale state silently
            self.read(self.store)

    def test_commit_that_changes_files_is_not_served_stale(self):
        from idea_workflow import save_draft
        self.read()
        with self.store.transaction(write=True) as state:
            idea = state['ideas'][base.KEY]
            state['ideas'][base.KEY] = save_draft(idea,'priorities',{'urgency':6,'importance':None},
                expected_revision=idea['revision'],expected_draft_version=idea['workflow']['draft_version'])['idea']
            self.store.commit(state)
        self.assertEqual(self.read()['ideas'][base.KEY]['workflow']['drafts']['priorities']['urgency'],6)

for _name in [n for n in vars(base.LoadCacheTests) if n.startswith('test_')]:
    setattr(WriteThenReadWarm,_name,None)


if __name__ == '__main__':
    unittest.main()

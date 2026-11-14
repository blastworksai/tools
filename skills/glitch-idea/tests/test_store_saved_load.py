"""SKILLS-157: a saved load lets a new service start skip the parse, and never hides a change."""
import copy
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'glitch-idea/scripts'))
import idea_markdown as md
import idea_store as storage
from idea_domain import IdeaError
from test_external_edits import KEY, ExternalEditTests
from test_store_load_cache import HIT, Counting
from test_workflow import original_idea
import test_chain_store
import test_handoff_store

POSIX = os.name == 'posix'


class Loads:
    """Counts full loads (the parsing path) on every Store while active."""
    def __init__(self):
        self.calls = 0
        self.real = storage.Store._load_markdown

    def __enter__(self):
        outer = self

        def counted(store, *args, **kwargs):
            outer.calls += 1
            return outer.real(store, *args, **kwargs)
        self.patch = patch.object(storage.Store, '_load_markdown', counted)
        self.patch.start()
        return self

    def __exit__(self, *_):
        self.patch.stop()


def outcome(root, saved=None, observer='observing-session'):
    """('ok', state) or ('error', code) for one fresh Store, and how many full loads it ran."""
    with Loads() as loads:
        try:
            with storage.Store(root, observer=observer, saved_load=saved).transaction() as state:
                result = ('ok', copy.deepcopy(state))
        except IdeaError as exc:
            result = ('error', exc.code)
    return result, loads.calls


def store_files(root):
    return sorted(p for p in root.rglob('*')
                  if p.is_file() and p.name != '.lock' and '.transactions' not in p.parts)


@unittest.skipUnless(POSIX, 'The saved load is POSIX-only, as the owner service is')
class SavedLoadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base/'ideas'
        helper = ExternalEditTests('test_legacy_null_inputs_import_once_with_observer_not_declared_editor')
        helper.root = self.root
        helper.store = storage.Store(self.root, observer='observing-session')
        helper.seed(second=True)
        self.helper = helper
        self.saved = self.base/'private'/'loads'/'store.json'
        self.saved.parent.parent.mkdir(mode=0o700)

    def start(self, root=None, saved=None, observer='observing-session'):
        return outcome(root or self.root, saved or self.saved, observer)

    def parse_count(self, root=None, saved=None):
        counter = Counting()
        with patch.object(md, 'parse_document', counter):
            result, loads = self.start(root, saved)
        return counter.calls, loads, result

    # Cold-start twin: the first start parses and saves, the next fresh Store reuses it.
    def test_first_start_saves_and_the_next_start_skips_the_parse(self):
        self.assertFalse(self.saved.exists())
        first_parses, first_loads, first = self.parse_count()
        self.assertGreater(first_parses, HIT)
        self.assertEqual(first_loads, 1)
        self.assertTrue(self.saved.is_file())
        self.assertEqual(stat.S_IMODE(self.saved.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.saved.parent.stat().st_mode), 0o700)
        parses, loads, second = self.parse_count()
        self.assertEqual((parses, loads), (HIT, 0))
        self.assertEqual(second, first)
        self.assertEqual(second, outcome(self.root)[0])

    def test_a_store_without_a_saved_path_never_reads_or_writes_one(self):
        def refuse(*_args, **_kwargs):
            raise AssertionError('a saved load was touched')
        with patch.object(storage, 'read_saved_load', refuse), patch.object(storage, 'write_saved_load', refuse):
            for _ in range(2):
                result, loads = outcome(self.root)
                self.assertEqual(result[0], 'ok')
        self.assertFalse(self.saved.parent.exists())

    def test_a_load_that_needed_a_normalising_write_is_not_saved(self):
        self.helper.edit(lambda m: m['idea']['ratings'].update(urgency=9))
        store = storage.Store(self.root, observer='observing-session', saved_load=self.saved)
        with store.transaction():
            pass
        self.assertFalse(self.saved.exists())

    # History independence: ten times the history, the same hit.
    def grown(self, name, edits):
        root = self.base/name
        helper = ExternalEditTests('test_legacy_null_inputs_import_once_with_observer_not_declared_editor')
        helper.root = root
        helper.store = storage.Store(root, observer='observing-session')
        helper.seed(original_idea())
        for n in range(edits):
            def rate(meta, n=n):
                ratings = meta['idea']['ratings'] or dict(importance=8, actor='editor', timestamp='edit-time')
                meta['idea']['ratings'] = dict(ratings, urgency=1+n % 9)
            helper.edit(rate)
            helper.show()
        return root

    def test_ten_times_the_history_starts_with_the_same_hit(self):
        results = {}
        for name, edits in (('small', 3), ('large', 30)):
            root = self.grown(name, edits)
            saved = self.base/'private'/('loads-'+name)/'store.json'
            _, first_loads, first = self.parse_count(root, saved)
            self.assertEqual(first_loads, 1)
            revisions = first[1]['ideas'][KEY]['revision']
            started = time.perf_counter()
            parses, loads, second = self.parse_count(root, saved)
            seconds = time.perf_counter()-started
            self.assertEqual((parses, loads), (HIT, 0))
            self.assertEqual(second, first)
            results[name] = (revisions, seconds)
        self.assertGreaterEqual(results['large'][0], 10*results['small'][0]-10)
        print('\nsaved-load hit: '+'; '.join(name+' '+str(r)+' revisions '+format(s, '.3f')+' s'
                                              for name, (r, s) in results.items()), file=sys.stderr)
        self.assertLess(results['large'][1], 1.0)

    # Invariant sweep: after a save, any one changed byte answers exactly as no saved load does.
    def test_every_changed_file_answers_as_a_store_without_a_saved_load(self):
        source = self.base/'handoff'
        test_handoff_store.seed(source)
        actor = test_handoff_store.ACTOR
        names = [p.relative_to(source) for p in store_files(source)]
        self.assertGreater(len(names), 5)
        for index, relative in enumerate(names):
            with self.subTest(file=str(relative)):
                twin = self.base/('twin-'+str(index))
                shutil.copytree(source, twin)
                saved = self.base/'private'/('sweep-'+str(index))/'store.json'
                saved_result, _ = outcome(twin, saved, actor)
                self.assertEqual(saved_result[0], 'ok')
                self.assertTrue(saved.is_file())
                target = twin/relative
                raw = target.read_bytes()
                target.write_bytes(raw[:-1]+bytes([raw[-1] ^ 1]) if raw else b'x')
                control = self.base/('control-'+str(index))
                shutil.copytree(twin, control)
                expected, _ = outcome(control, None, actor)
                got, loads = outcome(twin, saved, actor)
                self.assertEqual(loads, 1, 'a changed file was served from the saved load')
                if expected[0] == 'error':
                    self.assertEqual(got, expected)
                else:
                    self.assertEqual(got[0], 'ok')
                    self.assertEqual(got[1]['ideas'], expected[1]['ideas'])
                shutil.rmtree(twin); shutil.rmtree(control)

    def test_an_added_or_removed_file_misses_and_is_refused_as_today(self):
        for name, change in (('added', lambda root: (root/('idea_'+'f'*32+'.md')).write_bytes(b'x')),
                             ('removed', lambda root: next((root/'history').rglob('*.md')).unlink())):
            with self.subTest(change=name):
                root = self.base/name
                test_handoff_store.seed(root)
                saved = self.base/'private'/('change-'+name)/'store.json'
                self.assertEqual(outcome(root, saved, test_handoff_store.ACTOR)[0][0], 'ok')
                change(root)
                control = self.base/(name+'-control')
                shutil.copytree(root, control)
                expected, _ = outcome(control, None, test_handoff_store.ACTOR)
                self.assertEqual(expected[0], 'error')
                got, loads = outcome(root, saved, test_handoff_store.ACTOR)
                self.assertEqual((got, loads), (expected, 1))

    # Doubt grid: every doubt about the saved file is a miss, then a correct full load.
    def assert_miss(self, prepare, cleanup=None):
        self.start()
        self.assertTrue(self.saved.exists())
        prepare()
        try:
            result, loads = self.start()
        finally:
            if cleanup:
                cleanup()
        self.assertEqual(loads, 1)
        self.assertEqual(result, outcome(self.root)[0])

    def rewrite(self, change):
        value = json.loads(self.saved.read_bytes())
        change(value)
        self.saved.write_bytes(json.dumps(value).encode())

    def test_garbage_bytes_miss(self):
        self.assert_miss(lambda: self.saved.write_bytes(b'\x00not json'))

    def test_the_wrong_shape_misses(self):
        self.assert_miss(lambda: self.saved.write_bytes(b'{"format": 1}'))

    def test_an_unknown_format_misses(self):
        self.assert_miss(lambda: self.rewrite(lambda v: v.update(format=2)))

    def test_other_code_misses(self):
        self.assert_miss(lambda: self.rewrite(lambda v: v.update(fingerprint='0'*64)))

    def test_changed_code_misses(self):
        def prepare():
            storage._code_fingerprint_value = 'f'*64
        def cleanup():
            storage._code_fingerprint_value = None
        self.assert_miss(prepare, cleanup)

    def test_another_stores_saved_load_misses(self):
        self.assert_miss(lambda: self.rewrite(lambda v: v.update(store=str(self.base/'elsewhere'))))

    def test_a_link_in_place_of_the_file_misses_and_its_target_is_untouched(self):
        target = self.base/'target.json'
        def prepare():
            target.write_bytes(self.saved.read_bytes())
            os.chmod(target, 0o600)  # a private, valid target: only the link itself is in doubt
            self.saved.unlink(); self.saved.symlink_to(target)
        before = []
        def cleanup():
            before.append(target.read_bytes())
        self.assert_miss(prepare, cleanup)
        self.assertEqual(target.read_bytes(), before[0])
        self.assertFalse(self.saved.is_symlink())

    def test_a_file_others_can_read_misses(self):
        self.assert_miss(lambda: os.chmod(self.saved, 0o640))

    def test_a_folder_others_can_enter_misses_and_nothing_is_saved_there(self):
        before = []
        def prepare():
            os.chmod(self.saved.parent, 0o750)
            before.append(self.saved.read_bytes())
            self.saved.write_bytes(b'stale')
        self.assert_miss(prepare)
        self.assertEqual(self.saved.read_bytes(), b'stale')
        self.assertEqual(sorted(p.name for p in self.saved.parent.iterdir()), ['store.json'])

    def test_a_file_above_the_limit_misses(self):
        size = []
        def prepare():
            size.append(self.saved.stat().st_size)
            self.limit = patch.object(storage, 'MAX_SAVED_LOAD', size[0]-1); self.limit.start()
        self.assert_miss(prepare, lambda: self.limit.stop())

    def test_a_codec_slip_saves_nothing(self):
        real = storage.decode_saved_load
        def slipped(raw, store_path):
            loaded, held = real(raw, store_path)
            loaded[0]['backlog_revision'] = -1
            return loaded, held
        with patch.object(storage, 'decode_saved_load', slipped):
            self.start()
        self.assertFalse(self.saved.exists())


@unittest.skipUnless(POSIX, 'The saved load is POSIX-only, as the owner service is')
class SavedHeldIdeaTests(test_chain_store.Base):
    def setUp(self):
        super().setUp()
        self.break_idea(test_chain_store.SHAPE_ONLY)
        self.saved = Path(self.root).parent/'private'/'store.json'
        self.saved.parent.mkdir(mode=0o700)
        store = storage.Store(self.root, saved_load=self.saved)
        for _ in range(2):
            with store.transaction():
                pass
        self.assertTrue(self.saved.exists())

    def test_a_held_idea_survives_a_saved_start(self):
        held = test_chain_store.SHAPE_ONLY
        with Loads() as loads:
            store = storage.Store(self.root, saved_load=self.saved)
            with store.transaction() as state:
                ideas = list(state['ideas'])
        self.assertEqual(loads.calls, 0)
        self.assertEqual(ideas, [test_chain_store.FULL])
        self.assertEqual(list(store.held), [held])
        self.assertEqual(list(store.migration_report.held), [held])
        with self.assertRaises(IdeaError):
            store.refuse_held(held)

    def test_an_edit_to_the_held_idea_misses(self):
        path = self.root/(test_chain_store.SHAPE_ONLY+'.md')
        path.write_bytes(path.read_bytes()+b'\n')
        with Loads() as loads:
            store = storage.Store(self.root, saved_load=self.saved)
            with store.transaction():
                pass
        self.assertEqual(loads.calls, 1)
        self.assertEqual(list(store.held), [test_chain_store.SHAPE_ONLY])


@unittest.skipUnless(POSIX, 'Native owner ACLs remain unqualified')
class SavedServiceStartTests(unittest.TestCase):
    def start_service(self, store, root):
        import idea_launch as launch
        from idea_runtime import Runtime
        runtime = Runtime(store, root); runtime.acquire_owner()
        with Loads() as loads:
            owner = launch.OwnerService(runtime)
            path = launch.saved_load_path(runtime)
            owner.shutdown()
        return loads.calls, path

    def test_the_second_service_start_reuses_the_saved_load(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        base = Path(temp.name); store = base/'ideas'; root = base/'private'
        storage.Store(store, observer='seed').create_session()
        first, path = self.start_service(store, root)
        self.assertGreaterEqual(first, 1)
        self.assertTrue(path.is_file())
        self.assertEqual(path.parent, root/'loads')
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        second, _ = self.start_service(store, root)
        self.assertEqual(second, 0)
        # The runtime's own per-store folder keeps admitting only its own names.
        third, _ = self.start_service(store, root)
        self.assertEqual(third, 0)


if __name__ == '__main__':
    unittest.main()

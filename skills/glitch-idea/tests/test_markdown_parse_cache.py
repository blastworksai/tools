"""SKILLS-168: a store read replays parses of unchanged files instead of parsing every file again.

A live retry (20 Nov 2026) timed out opening a session (owner_unavailable): binding-open has five seconds and
re-reading the shared 272-file store after a write took six to eight. parse_document now keeps each successful
parse by the SHA-256 of the exact bytes and the parse limits, and replays it as a private copy. The parser itself
is unchanged, so every value and every refusal is the same as before.
"""
import copy
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import idea_markdown as md
from idea_domain import IdeaError
from test_markdown import fixture, metadata_fixture

DOC = b'---\na: 1\nnested:\n  list: [1, {b: c}]\n---\nbody\n'


class Counting:
    """Counts real parses (cache misses) by wrapping the uncached parser."""
    def __init__(self):
        self.calls = 0
        self.real = md._parse_document_uncached

    def __call__(self, raw):
        self.calls += 1
        return self.real(raw)


class ParseCacheTests(unittest.TestCase):
    def setUp(self):
        md.clear_parse_cache()
        self.addCleanup(md.clear_parse_cache)
        self.count = Counting()
        patcher = patch.object(md, '_parse_document_uncached', self.count)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_same_bytes_parse_once_and_give_the_same_document(self):
        first = md.parse_document(DOC)
        second = md.parse_document(DOC)
        self.assertEqual(self.count.calls, 1)
        self.assertEqual((first.metadata, first.body, first.has_comments),
                         (second.metadata, second.body, second.has_comments))
        md.parse_document(DOC.replace(b'a: 1', b'a: 2'))
        self.assertEqual(self.count.calls, 2)

    def test_every_caller_gets_a_private_copy(self):
        first = md.parse_document(DOC)
        first.metadata['a'] = 99
        first.metadata['nested']['list'][1]['b'] = 'changed'
        first.metadata['nested']['list'].append('extra')
        again = md.parse_document(DOC)
        self.assertEqual(again.metadata, {'a': 1, 'nested': {'list': [1, {'b': 'c'}]}})
        self.assertIsNot(again.metadata, md.parse_document(DOC).metadata)
        # A replayed Document is private all the way down too.
        again.metadata['nested']['list'][1]['b'] = 'replay changed'
        again.metadata['nested']['list'].append('replay extra')
        self.assertEqual(md.parse_document(DOC).metadata, {'a': 1, 'nested': {'list': [1, {'b': 'c'}]}})
        self.assertEqual(self.count.calls, 1)

    def test_refusals_are_never_kept(self):
        bad = b'---\na: &x [1]\nb: *x\n---\n'
        for _ in range(3):
            with self.assertRaises(IdeaError):
                md.parse_document(bad)
        self.assertEqual(self.count.calls, 3)
        self.assertEqual(len(md._parse_cache), 0)

    def test_a_tighter_limit_is_never_answered_from_the_cache(self):
        raw = b'---\na: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]\n---\n'
        md.parse_document(raw)
        for name, value in (('MAX_NODES', 12), ('MAX_FRONTMATTER', 10), ('MAX_DOCUMENT', 10)):
            with self.subTest(limit=name), patch.object(md, name, value):
                with self.assertRaises(IdeaError) as caught:
                    md.parse_document(raw)
                self.assertEqual(caught.exception.code, 'too_large')
        deep = b'---\na: [[[[1]]]]\n---\n'
        md.parse_document(deep)
        with patch.object(md, 'MAX_DEPTH', 3):
            with self.assertRaises(IdeaError) as caught:
                md.parse_document(deep)
            self.assertEqual(caught.exception.code, 'too_large')

    def test_another_loader_is_never_answered_from_the_cache(self):
        raw = b'---\na: 1\n---\n'
        md.parse_document(raw)

        class Refusing(md.BoundedLoader):
            def construct_mapping(self, node, deep=False):
                md.require(False, 'refused by this loader')
        with patch.object(md, 'BoundedLoader', Refusing):
            with self.assertRaises(IdeaError):
                md.parse_document(raw)
        self.assertEqual(self.count.calls, 2)

    def test_the_cache_stays_bounded(self):
        with patch.object(md, 'PARSE_CACHE_ENTRIES', 2):
            for n in range(3):
                md.parse_document(('---\na: %d\n---\n' % n).encode())
            self.assertEqual(len(md._parse_cache), 2)
            md.parse_document(b'---\na: 0\n---\n')
            self.assertEqual(self.count.calls, 4)  # the oldest was evicted, so it parses again
        md.clear_parse_cache()
        sizes = [len(('---\na: %d\n---\n' % n).encode()) for n in range(3)]
        with patch.object(md, 'PARSE_CACHE_BYTES', sizes[0] + sizes[1]):
            for n in range(3):
                md.parse_document(('---\na: %d\n---\n' % n).encode())
            self.assertEqual(len(md._parse_cache), 2)
            self.assertEqual(md._parse_cache_bytes, sizes[1] + sizes[2])
            big = b'---\ntext: ' + b'x' * 64 + b'\n---\n'
            md.parse_document(big)  # larger than the whole budget: parsed, never kept
            self.assertEqual(md._parse_cache_bytes, sizes[1] + sizes[2])
            self.assertEqual(len(md._parse_cache), 2)

    def test_threads_get_correct_private_documents(self):
        raws = [('---\nn: %d\nlist: [%d]\n---\nbody %d\n' % (n, n, n)).encode() for n in range(8)]
        errors = []

        def work(seed):
            try:
                for i in range(200):
                    n = (seed + i) % 8
                    doc = md.parse_document(raws[n])
                    if doc.metadata != {'n': n, 'list': [n]} or doc.body != 'body %d\n' % n:
                        errors.append((n, doc.metadata))
                    doc.metadata['list'].append('mine')
            except Exception as exc:  # pragma: no cover - reported below
                errors.append(repr(exc))
        threads = [threading.Thread(target=work, args=(s,)) for s in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(errors, [])
        self.assertLessEqual(self.count.calls, 8 * 8)

    def test_an_unchanged_state_parses_nothing_again_and_reads_the_same(self):
        for state in (fixture(), metadata_fixture()):
            with self.subTest(ideas=list(state['ideas'])):
                md.clear_parse_cache()
                files = md.encode_state(copy.deepcopy(state))
                first = md.decode_state(files)
                before = self.count.calls
                second = md.decode_state(files)
                self.assertEqual(self.count.calls, before)
                self.assertEqual(first, second)
                self.assertEqual(second, state)


if __name__ == '__main__':
    unittest.main()

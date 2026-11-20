"""SKILLS-168: the store reads its Markdown with libyaml when PyYAML has it, under the same bounds.

A live retry (20 Nov 2026) timed out opening a session: binding-open has five seconds and the pure-Python
YAML reader took six to eight on a 272-file store. The parser now runs in C; composing, the bounds and
construction stay in Python, so every refusal and every parsed value is the same as before.
"""
import copy
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

import yaml

SCRIPTS = Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import idea_markdown as md
from idea_domain import IdeaError
from test_markdown import fixture, metadata_fixture

HOSTILE = ('a: 1\na: 2', 'a: &x [1]\nb: *x', 'a: {<<: {x: 1}}',
           'a: !!python/object:evil {}', 'a: !!timestamp 2026-10-01',
           'a: !!set {one: null}', '1: text', '? [key]\n: text',
           'a: .nan', 'a: .inf', 'a: -.Inf', 'a: [broken',
           'a: 1\n...\n---\nb: 2', '- not-a-mapping', 'a: &x 1', 'a: !custom 1',
           'a: ' + '[' * 35 + '0' + ']' * 35)
PLAIN = ('a: "# quoted"', "a: '# quoted'", 'a: abc#literal', 'a: |\n  # block content\n  next',
         'a: >\n  words # in block', 'a: value # comment', '# full comment\na: 1',
         'a: | # header comment\n  content', 'a: |\n  content\n# after scalar',
         'date: 2026-10-01\nboolean: "true"\nyes_word: yes\nnum: 0x1F\nnull_word: ~',
         'text: "Caf\\u00e9 \\U0001F4A1\\r\\nline"', 'nested: {a: [1, {b: c}], d: -1.5e3}',
         'empty: {}\nlist: []\nkey: ""')


def outcome(loader, raw):
    """What parse_document makes of raw with loader in charge: the parsed fields, or the refusal's code."""
    with patch.object(md, 'BoundedLoader', loader):
        try:
            doc = md.parse_document(raw)
        except IdeaError as exc:
            return ('refused', exc.code)
        return ('parsed', doc.metadata, doc.body, doc.has_comments)


def corpus():
    raws = [('---\n' + front + '\n---\nbody\n').encode() for front in HOSTILE + PLAIN]
    for state in (fixture(), metadata_fixture()):
        raws.extend(md.encode_state(copy.deepcopy(state)).values())
    return raws


@unittest.skipUnless(yaml.__with_libyaml__, 'PyYAML was built without libyaml')
class FastLoaderTests(unittest.TestCase):
    def test_libyaml_parser_is_used_when_present(self):
        self.assertTrue(issubclass(md.BoundedLoader, yaml.cyaml.CParser))
        self.assertFalse(issubclass(md.BoundedLoader, yaml.parser.Parser))

    def test_both_readers_agree_on_every_value_and_refusal(self):
        raws = corpus()
        self.assertGreater(len(raws), 30)
        for raw in raws:
            with self.subTest(raw=raw[:60]):
                self.assertEqual(outcome(md.BoundedLoader, raw), outcome(md.PureBoundedLoader, raw))

    def test_bounds_hold_on_the_fast_reader(self):
        def refused(front):
            return outcome(md.BoundedLoader, ('---\n' + front + '\n---\n').encode())[0] == 'refused'
        for front in HOSTILE:
            with self.subTest(front=front):
                self.assertTrue(refused(front))
        with patch.object(md, 'MAX_NODES', 12):
            self.assertEqual(outcome(md.BoundedLoader, b'---\na: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]\n---\n'),
                             ('refused', 'too_large'))
        self.assertEqual(outcome(md.BoundedLoader, ('---\na: ' + '[' * 35 + '0' + ']' * 35 + '\n---\n').encode()),
                         ('refused', 'too_large'))

    def test_one_resolver_table_and_no_global_change(self):
        self.assertIs(md.BoundedLoader.yaml_implicit_resolvers, md.PureBoundedLoader.yaml_implicit_resolvers)
        for rules in md.BoundedLoader.yaml_implicit_resolvers.values():
            self.assertNotIn('tag:yaml.org,2002:timestamp', [tag for tag, _ in rules])
        self.assertIn('tag:yaml.org,2002:timestamp',
                      [tag for rules in yaml.SafeLoader.yaml_implicit_resolvers.values() for tag, _ in rules])


class PureFallbackTests(unittest.TestCase):
    def test_without_libyaml_the_pure_reader_keeps_every_bound(self):
        code = ('import sys, yaml\n'
                'yaml.__with_libyaml__ = False\n'
                'sys.path.insert(0, sys.argv[1])\n'
                'import idea_markdown as md\n'
                'from idea_domain import IdeaError\n'
                'assert md.BoundedLoader is md.PureBoundedLoader\n'
                'assert issubclass(md.BoundedLoader, yaml.SafeLoader)\n'
                'for front in sys.argv[2:]:\n'
                '    try: md.parse_document(("---\\n" + front + "\\n---\\n").encode())\n'
                '    except IdeaError: continue\n'
                '    raise SystemExit("accepted: " + front)\n'
                'print(md.parse_document(b"---\\ndate: 2026-10-01\\n---\\n").metadata["date"])\n')
        result = subprocess.run([sys.executable, '-I', '-c', code, str(SCRIPTS), *HOSTILE], capture_output=True,
                                text=True, stdin=subprocess.DEVNULL, timeout=60, env=dict(os.environ))
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.strip(), '2026-10-01')


if __name__ == '__main__':
    unittest.main()

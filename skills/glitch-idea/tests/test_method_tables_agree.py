"""One place that fails when the method tables drift: Python, both workflow versions, and the web files read as text."""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'glitch-idea/scripts'))
import idea_domain as domain
import idea_workflow as v3
import idea_workflow_v2 as v2

SELECTABLE = ('bounded-plan', 'bmad', 'appetite-led', 'experiment-led')
RETIRED = ('adaptive-slices',)
LABELS = {'bounded-plan': 'Full Plan Up Front', 'bmad': 'BMAD (Roles and Stories)',
          'appetite-led': 'Fixed Budget, Build what Fits', 'experiment-led': 'Experiment First',
          'adaptive-slices': 'Vertical Slicing (Agile)'}
WEB = ROOT / 'glitch-idea/web'
METHODS_MD = ROOT / 'glitch-idea/references/methods.md'


def web(name):
    return (WEB / name).read_text(encoding='utf-8')


def block(text, opener, closer):
    """The text between the opener (a regex, ending at its bracket) and the next closer."""
    found = re.search(opener, text)
    assert found, opener
    return text[found.end():text.index(closer, found.end())]


def quoted(text):
    return re.findall(r"""['"]([a-z][a-z-]*)['"]""", text)


class MethodTablesAgree(unittest.TestCase):
    def test_python_tables(self):
        self.assertEqual(tuple(domain.METHOD_LABELS), SELECTABLE + RETIRED)
        self.assertEqual(domain.METHOD_LABELS, LABELS)
        self.assertEqual(domain.SELECTABLE_METHODS, SELECTABLE)
        self.assertEqual(domain.RETIRED_METHODS, RETIRED)
        self.assertEqual(v3.METHODS, SELECTABLE)
        self.assertEqual(v2.METHODS, SELECTABLE)
        self.assertEqual(v3.READABLE_METHODS, SELECTABLE + RETIRED)
        self.assertEqual(v2.READABLE_METHODS, SELECTABLE + RETIRED)

    def test_contracts_are_the_one_source_for_labels_and_the_methods_table(self):
        self.assertEqual(tuple(domain.METHOD_CONTRACTS), SELECTABLE)
        table = METHODS_MD.read_text(encoding='utf-8').split('## Four development methods', 1)[1].split('\n## ', 1)[0]
        rows = {}
        for line in table.splitlines():
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            found = re.fullmatch(r'(.+) \(`([a-z-]+)`\)', cells[0]) if len(cells) == 4 else None
            if found:
                rows[found.group(2)] = (found.group(1), cells[1], cells[2])
        self.assertEqual(rows, {m: (c['label'], c['fixed_now'], c['earns_next'])
                                for m, c in domain.METHOD_CONTRACTS.items()})

    def test_domain_accepts_exactly_the_readable_set(self):
        base = dict(outcome=None, scope=None, scope_reason=None, alternatives=[], method=None, method_reason=None,
                    assumptions=[], next_slice=None, learning=[])
        for method in (None,) + SELECTABLE + RETIRED:
            domain.shape(dict(base, method=method))
        with self.assertRaises(domain.IdeaError):
            domain.shape(dict(base, method='vertical-slicing'))

    def test_web_folds(self):
        text = web('folds.js')
        labels = dict(re.findall(r"""['"]?([a-z][a-z-]*)['"]?\s*:\s*['"]([^'"]+)['"]""",
                                 block(text, r'METHOD_LABELS\s*=\s*(?:Object\.freeze\()?\{', '}')))
        self.assertEqual(labels, LABELS)
        self.assertEqual(list(labels), list(SELECTABLE + RETIRED))
        self.assertEqual(tuple(quoted(block(text, r'SELECTABLE_METHODS\s*=\s*(?:Object\.freeze\()?\[', ']'))), SELECTABLE)
        self.assertEqual(tuple(quoted(block(text, r'RETIRED_METHODS\s*=\s*(?:Object\.freeze\()?\[', ']'))), RETIRED)

    def test_web_api(self):
        ids = quoted(block(web('api.js'), r'const METHODS\s*=\s*new Set\(\[', ']'))
        self.assertEqual(tuple(ids), SELECTABLE + RETIRED)

    def test_web_method_step_has_a_card_text_for_each_selectable_id(self):
        text = web('steps/method.js')
        for method in SELECTABLE:
            self.assertRegex(text, r"""['"]?""" + re.escape(method) + r"""['"]?\s*:""", method)
        self.assertNotRegex(text, r"""['"]?adaptive-slices['"]?\s*:""")


if __name__ == '__main__':
    unittest.main()

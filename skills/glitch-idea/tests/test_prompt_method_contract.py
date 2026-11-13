"""The planning prompt's Method section: one source, exact lines, retired and inner methods, old handoffs."""
import copy
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'))
import idea_domain as domain
import idea_handoff_evidence as codec
import idea_workflow as wf
from test_handoff_evidence import fixture

INSTRUCTION = ('Plan to this contract: what is fixed now comes first in the plan; '
               'nothing later starts before it has earned the next step.')
INVESTMENT = dict(cap=3, unit='days', boundary='Lid only')
EXPERIMENT = dict(question='Does it clean?', evidence='A trial', success_criterion='Clean lid', stop_rule='Two failures')
EXTRA = {'bounded-plan': {}, 'bmad': {}, 'appetite-led': dict(investment=INVESTMENT),
         'experiment-led': dict(experiment=EXPERIMENT)}
LINES = {
    'bounded-plan': ('Full Plan Up Front', 'Clear scope and acceptance criteria', 'Verification of the bounded change'),
    'bmad': ('BMAD (Roles and Stories)', 'A written brief, requirements and architecture before any building',
             'Each story is built and checked against those documents'),
    'appetite-led': ('Fixed Budget, Build what Fits', "Operator's investment cap and outcome boundaries",
                     'Completed bet or explicit stop/reshape'),
    'experiment-led': ('Experiment First', 'A question, evidence criterion and bounded experiment',
                       'Evidence supports proceeding, changing or stopping'),
}


def sketch(*methods):
    return [dict(title='Item '+str(i), why_next='Why', done_when='Done', method=m) for i, m in enumerate(methods)]


def prompt_for(method, items=None):
    exploration = dict(EXTRA.get(method, {}))
    if items is not None:
        exploration['sketch'] = items
    # A retired method can no longer be chosen; it is written as it was stored, with the old list put back.
    with mock.patch.object(wf, 'METHODS', wf.METHODS+domain.RETIRED_METHODS):
        state, idea, design, record = fixture(method=dict(selection=method), exploration=exploration)
    raw = codec.encode_record(record); link = codec.record_link(record, raw)
    root = record['source_files']['detail']['path'].rsplit('/', 1)[0]
    return codec.render_prompt(record, root+'/'+link['path']), (state, idea, design, record)


def method_block(prompt):
    return prompt.split('## Method\n', 1)[1].split('## Planning source\n', 1)[0]


class MethodContractPromptTests(unittest.TestCase):
    def test_constant_covers_exactly_the_selectable_methods(self):
        self.assertEqual(tuple(domain.METHOD_CONTRACTS), domain.SELECTABLE_METHODS)
        for method, contract in domain.METHOD_CONTRACTS.items():
            self.assertEqual(contract['label'], domain.METHOD_LABELS[method])
            self.assertEqual((contract['label'], contract['fixed_now'], contract['earns_next']), LINES[method])

    def test_each_method_prompt_carries_its_three_lines_and_the_instruction_in_order(self):
        for method, (label, fixed, earns) in LINES.items():
            with self.subTest(method=method):
                prompt, _ = prompt_for(method)
                expected = '## Method\n'+label+'\nFixed now: '+fixed+'\nEarns the next step: '+earns+'\n'+INSTRUCTION+'\n\n## Planning source\n'
                self.assertIn(expected, prompt)
                self.assertLess(prompt.index('## Idea trace'), prompt.index('## Method'))
                self.assertEqual(prompt.count('## Method'), 1)

    def test_retired_method_shows_its_old_label_only(self):
        prompt, _ = prompt_for('adaptive-slices')
        self.assertEqual(method_block(prompt), 'Vertical Slicing (Agile)\n\n')
        self.assertNotIn('Fixed now', prompt); self.assertNotIn('Earns the next step', prompt)
        self.assertNotIn(INSTRUCTION, prompt)

    def test_inner_method_blocks_follow_the_instruction_and_items_without_one_add_nothing(self):
        prompt, _ = prompt_for('bounded-plan', sketch('bmad', None, 'experiment-led'))
        block = method_block(prompt)
        bmad, exp = LINES['bmad'], LINES['experiment-led']
        self.assertEqual(block, 'Full Plan Up Front\nFixed now: Clear scope and acceptance criteria\n'
            'Earns the next step: Verification of the bounded change\n'+INSTRUCTION+'\n'
            '\nItem: Item 0\n'+bmad[0]+'\nFixed now: '+bmad[1]+'\nEarns the next step: '+bmad[2]+'\n'
            '\nItem: Item 2\n'+exp[0]+'\nFixed now: '+exp[1]+'\nEarns the next step: '+exp[2]+'\n\n')
        self.assertNotIn('Item: Item 1', prompt)

    def test_retired_inner_method_shows_its_old_label_only(self):
        prompt, _ = prompt_for('bmad', sketch('adaptive-slices'))
        block = method_block(prompt)
        self.assertTrue(block.endswith(INSTRUCTION+'\n\nItem: Item 0\nVertical Slicing (Agile)\n\n'), block)
        self.assertEqual(block.count('Fixed now'), 1)

    def test_prompt_with_no_inner_methods_has_no_item_block(self):
        prompt, _ = prompt_for('bmad', sketch(None))
        self.assertNotIn('Item:', method_block(prompt))

    def test_a_handoff_recorded_before_this_change_still_verifies_and_renders_the_section(self):
        # The prompt is never stored or hashed: RECORD_KEYS has no prompt field and render_prompt reads the record.
        self.assertNotIn('prompt', codec.RECORD_KEYS)
        state, idea, design, record = fixture()
        raw = codec.encode_record(record); link = codec.record_link(record, raw)
        self.assertNotIn(b'Plan to this contract', raw); self.assertNotIn(b'## Method', raw)
        # Changing the contract wording changes no recorded byte, hash or link.
        changed = copy.deepcopy(domain.METHOD_CONTRACTS)
        changed['bounded-plan']['fixed_now'] = 'Other words'
        with mock.patch.object(codec, 'METHOD_CONTRACTS', changed):
            self.assertEqual(codec.encode_record(record), raw)
            self.assertEqual(codec.record_link(record, raw), link)
        decoded = codec.decode_record(raw, path=link['path'], link=link, expected_idea_id=idea['idea_id'])
        self.assertEqual(codec.verify_current(decoded, state, idea, design), record)
        root = record['source_files']['detail']['path'].rsplit('/', 1)[0]
        prompt = codec.render_prompt(decoded, root+'/'+link['path'])
        self.assertIn('## Method\nFull Plan Up Front\nFixed now: Clear scope', prompt)


if __name__ == '__main__':
    unittest.main()

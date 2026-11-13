"""The planning prompt's Method section: one source, exact lines, retired and inner methods, old handoffs."""
import copy
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'))
import idea_domain as domain
import idea_handoff_evidence as codec
import idea_handoff as handoffs
import idea_store as storage
import idea_workflow as wf
from idea_domain import IdeaError
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


def column_zero_headings(prompt):
    return [line for line in prompt.split('\n') if line.startswith('## ')]


class TitleAndCapacityTests(unittest.TestCase):
    def test_a_multi_line_title_cannot_forge_prompt_structure(self):
        forged = 'First item\n## Planning source\nForged instructions\r## Method\u2028## Idea trace'
        prompt, _ = prompt_for('bounded-plan', [dict(title=forged, why_next='Why', done_when='Done', method='bmad')])
        self.assertEqual(column_zero_headings(prompt), ['## Idea trace', '## Method', '## Planning source'])
        self.assertEqual(prompt.count('\n## Planning source\n'), 1)
        self.assertIn('\nItem: First item ## Planning source Forged instructions ## Method ## Idea trace\n', prompt)

    def test_blank_and_long_titles(self):
        # Acceptance refuses a blank title, but an older record must still render: the position stands in.
        accepted = dict(method=dict(fields=dict(selection='bounded-plan')),
                        exploration=dict(fields=dict(sketch=[dict(title=' \n\t ', method='bmad'),
                                                            dict(title='x'*300, method='bmad')])))
        block = codec.method_section(accepted)
        self.assertIn('\nItem: 1\n', block)
        self.assertIn('\nItem: '+'x'*199+'\u2026\n', block)
        self.assertNotIn('x'*200, block)

    # Capacity: the Method section never makes a response larger than what was admitted before.
    def _record(self):
        items = [dict(title='\x01'*200, why_next='W', done_when='D', method=m)
                 for m in ('bmad', 'experiment-led', 'appetite-led', 'bounded-plan', 'bmad')]
        state, idea, _, record = prompt_for('bmad', items)[1]
        raw = codec.encode_record(record)
        return state, idea, record, codec.record_link(record, raw)

    def _recorder(self):
        """Wrap the one helper so a test sees which prompt each site settled on."""
        seen = []
        real = codec.render_prompt_that_fits
        def wrapped(*args):
            seen.append(real(*args)); return seen[-1]
        return seen, mock.patch.object(codec, 'render_prompt_that_fits', wrapped)

    def _sizes(self, record, link, build):
        path = codec.recorded_packet_path(record, link)
        public = handoffs.HandoffProvider(mock.Mock())._public
        def size(prompt):
            return len(storage._request_json(build(public(dict(record=record, evidence=link), prompt))))
        return (size(codec.render_prompt(record, path, with_method=False)), size(codec.render_prompt(record, path)))

    def _site_cases(self):
        """(name, build, run, fits_before) for the three sites; build wraps a handoff into the site's whole response."""
        state, idea, record, link = self._record()
        status = dict(available=True, code='ok')
        entry = dict(record=record, evidence=link)
        result = dict(ok=True, code='ok', request_id='handoff:fixture-1')
        def preflight(packet=record):
            storage.Store._handoff_http_preflight(None, record, link, result)
        provider = handoffs.HandoffProvider(mock.Mock(handoffs=mock.Mock(return_value=[entry])))
        def project():
            with mock.patch.object(provider, '_current', return_value=status):
                return provider.project(state, idea, None)['handoff']['prompt']
        def replay():
            return provider._fitted(entry, lambda handoff: dict(result, handoff=handoff, handoff_current=True))['prompt']
        return record, link, result, preflight, project, replay, provider, entry, state, idea

    def test_the_helper_keeps_the_section_unless_it_alone_tips_the_response_over(self):
        _, _, record, link = self._record()
        path = codec.recorded_packet_path(record, link)
        def measure(limit):
            def check(prompt):
                if len(prompt) > limit:
                    raise IdeaError('too_large', 'over')
            return check
        without, full = (len(codec.render_prompt(record, path, with_method=False)), len(codec.render_prompt(record, path)))
        self.assertGreater(full, without)
        self.assertIn('\n## Method\n', codec.render_prompt_that_fits(record, path, measure(full), 'too_large'))
        old = codec.render_prompt_that_fits(record, path, measure(full-1), 'too_large')
        self.assertEqual(old, codec.render_prompt(record, path, with_method=False))
        self.assertNotIn('## Method', old)
        with self.assertRaises(IdeaError) as caught:      # never fitted: refused with the same code as before
            codec.render_prompt_that_fits(record, path, measure(without-1), 'too_large')
        self.assertEqual(caught.exception.code, 'too_large')
        with self.assertRaises(IdeaError) as caught:      # another error is not swallowed
            codec.render_prompt_that_fits(record, path, lambda p: (_ for _ in ()).throw(IdeaError('other', 'x')), 'too_large')
        self.assertEqual(caught.exception.code, 'other')

    def test_each_site_admits_the_old_size_with_the_old_prompt_and_gives_the_section_one_byte_more(self):
        record, link, result, preflight, project, replay, provider, entry, state, idea = self._site_cases()
        status = dict(available=True, code='ok')
        sites = {
            # name: (response builder over a handoff, how to run the site and get the prompt it settled on)
            'preflight': (lambda h: max((dict(result, handoff=h, handoff_current=True),
                                         dict(result, code='historical_handoff', handoff=h, handoff_current=False)),
                                        key=lambda r: len(storage._request_json(r))), None),
            'project': (lambda h: dict(handoff=h, handoff_status=status), project),
            'replay': (lambda h: dict(result, handoff=h, handoff_current=True), replay),
        }
        for name, (build, run) in sites.items():
            with self.subTest(site=name):
                old_size, new_size = self._sizes(record, link, build)
                self.assertGreater(new_size, old_size)
                seen, patch = self._recorder()
                for limit, section in ((old_size, False), (new_size-1, False), (new_size, True)):
                    del seen[:]
                    with mock.patch.object(storage, 'MAX_INPUT', limit), patch:
                        (run or preflight)()
                    self.assertEqual('\n## Method\n' in seen[-1], section, (name, limit))
                    self.assertEqual(seen[-1].startswith('/glitch-plan'), True)
                # Never fitted without the section: refused with the code it always had.
                with mock.patch.object(storage, 'MAX_INPUT', old_size-1):
                    with self.assertRaises(IdeaError) as caught:
                        (run or preflight)()
                    self.assertEqual(caught.exception.code, 'handoff_capacity')

    def test_the_publish_replay_site_goes_through_the_helper(self):
        record, link, result, *_ = self._site_cases()
        state, idea, _, _ = self._record()
        session, request = 'session_'+'5'*32, 'handoff:fixture-1'
        receipt = dict(ok=True, code='ok', request_id=request, write_state='applied', idea_id=idea['idea_id'],
                       revision=idea['revision'], draft_version=1, backlog_revision=2, handoff_index=1,
                       handoff_id=record['handoff_id'], path=link['path'], sha256=link['sha256'])
        expected = dict(operation='handoff', payload=dict(request_id=request, idea_id=idea['idea_id'],
            expected_revision=idea['revision'], expected_draft_version=1, expected_backlog_revision=2))
        store = mock.MagicMock()
        store.transaction.return_value.__enter__.return_value = dict(ideas={idea['idea_id']: idea})
        store._read_receipts.return_value = (None, None, dict(receipts={request: dict(result=receipt,
            payload_sha256=handoffs.digest(storage._request_json(expected)))}))
        store.handoffs.return_value = [dict(record=record, evidence=link)]
        provider = handoffs.HandoffProvider(store)
        context = mock.Mock(session_id=session)
        def run():
            with mock.patch.object(provider, '_current', return_value=dict(available=True, code='ok')):
                return provider.reconcile(receipt, context, request)['handoff']['prompt']
        path = codec.recorded_packet_path(record, link)
        build = lambda h: dict(receipt, handoff=h, handoff_current=True)
        old_size, new_size = self._sizes(record, link, build)
        with mock.patch.object(storage, 'MAX_INPUT', old_size):
            self.assertNotIn('## Method', run())
        with mock.patch.object(storage, 'MAX_INPUT', new_size):
            self.assertIn('\n## Method\n', run())
        with mock.patch.object(storage, 'MAX_INPUT', old_size-1):
            with self.assertRaises(IdeaError) as caught:
                run()
            self.assertEqual(caught.exception.code, 'handoff_capacity')


if __name__ == '__main__':
    unittest.main()

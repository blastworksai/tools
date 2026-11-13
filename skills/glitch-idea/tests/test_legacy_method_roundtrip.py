"""A saved idea carrying the retired method `adaptive-slices` still opens, shows and saves; it can no longer be chosen."""
import copy
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import idea_markdown as md
import idea_workflow as wf
import idea_workflow_v2 as v2
from idea_domain import METHOD_LABELS, IdeaError, shape
from test_markdown import fixture as empty_state
from test_workflow import accept, captured, fields

OLD = 'adaptive-slices'
OLD_LABEL = 'Vertical Slicing (Agile)'
FOUND = {'status': 'found', 'sources': ['safe-reference'], 'rationale': 'Observed preference', 'preferred_method': OLD}
STEPS = ('priorities', 'method', 'discovery', 'exploration', 'visualize', 'assess')


def legacy_idea(selection=OLD, preferred=False, sketch_method=None):
    """The stored form as it was written before the change: the old method list is put back while it is built."""
    with patch.object(wf, 'METHODS', wf.METHODS + (OLD,)):
        idea = captured()
        for step in STEPS:
            value = fields()[step]
            if step == 'method':
                value['selection'] = selection
                if preferred:
                    value['memory'] = dict(FOUND)
            if step == 'exploration':
                value['sketch'][0]['method'] = sketch_method
            idea = accept(idea, step, value)['idea']
    return idea


def detail(idea):
    state = empty_state()
    state['ideas'] = {idea['idea_id']: idea}
    state['order'] = [idea['idea_id']]
    return md.encode_state(state)[idea['idea_id'] + '.md']


def changed_lines(before, after):
    old, new = before.decode().splitlines(), after.decode().splitlines()
    return [line for line in old if line not in new] + [line for line in new if line not in old]


class LegacyMethodRoundtrip(unittest.TestCase):
    def refused(self, operation):
        with self.assertRaises(IdeaError) as caught:
            operation()
        self.assertEqual(caught.exception.code, 'invalid_input')
        self.assertIn('Invalid', str(caught.exception))

    def draft(self, idea, step, value):
        return wf.save_draft(idea, step, value, expected_revision=idea['revision'],
                             expected_draft_version=idea['workflow']['draft_version'])

    def test_it_opens_and_shows_its_old_label(self):
        idea = legacy_idea()
        state = wf.derive_state(idea)
        self.assertEqual(state['steps']['method']['status'], 'saved')
        self.assertEqual(idea['workflow']['steps']['method']['fields']['selection'], OLD)
        wf.validate_snapshot(idea['revisions'][-1])
        self.assertEqual(METHOD_LABELS[OLD], OLD_LABEL)
        self.assertIn(OLD_LABEL.encode(), detail(idea))
        shape(dict(outcome=None, scope=None, scope_reason=None, alternatives=[], method=OLD, method_reason=None,
                   assumptions=[], next_slice=None, learning=[]))

    def test_saving_another_field_leaves_the_stored_choice_and_the_detail_alone(self):
        idea = legacy_idea()
        before = detail(idea)
        value = copy.deepcopy(idea['workflow']['steps']['method']['fields'])
        value['reason'] = 'A reason typed later'
        after = accept(idea, 'method', value)['idea']
        stored = after['workflow']['steps']['method']['fields']
        self.assertEqual(stored['selection'], OLD)
        self.assertEqual(stored, dict(idea['workflow']['steps']['method']['fields'], reason='A reason typed later'))
        self.assertEqual(wf.derive_state(after)['steps']['method']['status'], 'saved')
        text = [line for line in changed_lines(before, detail(after)) if OLD in line or OLD_LABEL in line]
        self.assertEqual(text, [])
        self.assertIn(OLD_LABEL.encode(), detail(after))

    def test_a_draft_beside_the_stored_choice_is_kept(self):
        idea = legacy_idea()
        before = detail(idea)
        value = dict(copy.deepcopy(idea['workflow']['steps']['method']['fields']), reason='Half typed')
        drafted = self.draft(idea, 'method', value)['idea']
        self.assertEqual(drafted['workflow']['drafts']['method']['selection'], OLD)
        self.assertEqual(drafted['workflow']['steps']['method'], idea['workflow']['steps']['method'])
        self.assertEqual([l for l in detail(drafted).decode().splitlines() if OLD_LABEL in l],
                         [l for l in before.decode().splitlines() if OLD_LABEL in l])

    def test_memory_may_report_a_retired_preference_and_the_choice_is_still_refused(self):
        idea = legacy_idea(selection='bmad', preferred=True)
        value = copy.deepcopy(idea['workflow']['steps']['method']['fields'])
        value['reason'] = 'Reworded'
        after = accept(idea, 'method', value)['idea']
        self.assertEqual(after['workflow']['steps']['method']['fields']['memory']['preferred_method'], OLD)
        # Memory reports what was observed, so a fresh idea may record a retired preference beside a current choice.
        fresh = legacy_idea(selection='bmad')
        changed = copy.deepcopy(fresh['workflow']['steps']['method']['fields'])
        changed['memory'] = dict(FOUND)
        self.draft(fresh, 'method', changed)
        saved = accept(fresh, 'method', changed)['idea']['workflow']['steps']['method']['fields']
        self.assertEqual((saved['selection'], saved['memory']['preferred_method']), ('bmad', OLD))
        # The choice itself is still refused, with or without that memory.
        changed['selection'] = OLD
        self.refused(lambda: self.draft(fresh, 'method', changed))
        self.refused(lambda: accept(fresh, 'method', changed))

    def test_sketch_item_with_the_retired_inner_method(self):
        idea = legacy_idea(sketch_method=OLD)
        self.assertEqual(wf.derive_state(idea)['steps']['exploration']['status'], 'saved')
        self.assertIn(OLD_LABEL.encode(), detail(idea))
        value = copy.deepcopy(idea['workflow']['steps']['exploration']['fields'])
        value['next_slice'] = 'Another slice'
        value['sketch'][0]['title'] = 'Check the lid twice'
        after = accept(idea, 'exploration', value)['idea']
        self.assertEqual(after['workflow']['steps']['exploration']['fields']['sketch'][0]['method'], OLD)
        self.assertIn('1. Check the lid twice (' + OLD_LABEL + ')', detail(after).decode())
        drafted = self.draft(idea, 'exploration', value)['idea']
        self.assertEqual(drafted['workflow']['drafts']['exploration']['sketch'][0]['method'], OLD)

    def test_choosing_the_retired_method_is_refused(self):
        idea = captured()
        idea = accept(idea, 'priorities')['idea']
        value = fields()['method']
        value['selection'] = OLD
        self.refused(lambda: self.draft(idea, 'method', value))
        self.refused(lambda: accept(idea, 'method', value))
        done = legacy_idea(selection='bmad')
        base = copy.deepcopy(done['workflow']['steps']['exploration']['fields'])
        changed = copy.deepcopy(base)
        changed['sketch'][0]['method'] = OLD
        self.refused(lambda: self.draft(done, 'exploration', changed))
        self.refused(lambda: accept(done, 'exploration', changed))
        extra = copy.deepcopy(base)
        extra['sketch'].append({'title': 'A new item', 'why_next': 'Next', 'done_when': 'Done', 'method': OLD})
        self.refused(lambda: self.draft(done, 'exploration', extra))
        self.refused(lambda: accept(done, 'exploration', extra))

    def test_a_new_retired_item_beside_a_stored_one_is_refused(self):
        idea = legacy_idea(sketch_method=OLD)
        extra = copy.deepcopy(idea['workflow']['steps']['exploration']['fields'])
        extra['sketch'].append({'title': 'A new item', 'why_next': 'Next', 'done_when': 'Done', 'method': OLD})
        self.refused(lambda: self.draft(idea, 'exploration', extra))
        self.refused(lambda: accept(idea, 'exploration', extra))

    def test_the_retired_choice_can_be_replaced_by_a_current_one(self):
        idea = legacy_idea()
        value = dict(copy.deepcopy(idea['workflow']['steps']['method']['fields']), selection='bmad')
        after = accept(idea, 'method', value)['idea']
        self.assertEqual(after['workflow']['steps']['method']['fields']['selection'], 'bmad')

    def test_a_fresh_idea_can_choose_bmad_and_it_survives_a_reload(self):
        idea = captured()
        for step in STEPS:
            value = fields()[step]
            if step == 'method':
                value['selection'] = 'bmad'
            idea = accept(idea, step, value)['idea']
        state = empty_state()
        state['ideas'] = {idea['idea_id']: idea}
        state['order'] = [idea['idea_id']]
        files = md.encode_state(state)
        reloaded = md.decode_state(files)['ideas'][idea['idea_id']]
        self.assertEqual(reloaded['workflow']['steps']['method']['fields']['selection'], 'bmad')
        self.assertIn(b'BMAD (Roles and Stories)', files[idea['idea_id'] + '.md'])

    def test_workflow_v2_evidence_still_reads_the_retired_choice(self):
        self.assertNotIn(OLD, v2.METHODS)
        workflow = v2.empty_workflow()
        fields_ = {'selection': OLD, 'reason': 'Learn', 'investment': None, 'experiment': None,
                   'memory': {'status': 'unavailable', 'sources': [], 'rationale': None}}
        receipt = {'accepted_revision': 2, 'evidence_id': 'receipt-fixture', 'source_revision': 1,
                   'source_digest': 'a' * 64, 'dependencies': {'capture': {'revision': 1, 'digest': 'b' * 64}},
                   'actor': 'Operator', 'timestamp': '2026-10-01T12:00:00+00:00'}
        workflow['steps']['method'] = {'fields': fields_, 'acceptance': receipt, 'invalidated_by': []}
        self.assertEqual(v2.validate_workflow(workflow)['steps']['method']['fields']['selection'], OLD)
        self.assertEqual(v2.step_requirements('method', fields_), ())


if __name__ == '__main__':
    unittest.main()

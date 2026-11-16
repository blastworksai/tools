"""SKILLS-171: BMAD is steered to big builds, in the page, the method guide and the agent's Exploration check."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SKILL = (ROOT / 'glitch-idea/SKILL.md').read_text(encoding='utf-8')
METHODS_MD = (ROOT / 'glitch-idea/references/methods.md').read_text(encoding='utf-8')
METHOD_JS = (ROOT / 'glitch-idea/web/steps/method.js').read_text(encoding='utf-8')

# einh's pick B, 16 Nov 2026, added after the card's existing line.
STEER = 'Best for big builds (a project or an epic). Smaller work usually goes faster with Full Plan Up Front.'
CARD_LINE = 'Fix a written brief, requirements and architecture first; then build story by story. ' + STEER
KEEP_LABEL = 'BMAD kept for this size:'


def flat(text):
    return re.sub(r'\s+', ' ', text)


def js_entry(name, key):
    block = re.search(r'const ' + name + r' = \{(.*?)\n\};', METHOD_JS, re.S).group(1)
    found = re.search(r"'" + re.escape(key) + r"': '((?:[^'\\]|\\.)*)'", block)
    return found.group(1).replace("\\'", "'")


def good_fit(method):
    table = METHODS_MD.split('## Four development methods', 1)[1].split('\n## ', 1)[0]
    for line in table.splitlines():
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if len(cells) == 4 and cells[0].endswith('(`%s`)' % method):
            return cells[3]
    raise AssertionError(method)


class BmadSizeSteer(unittest.TestCase):
    def test_card_line_carries_the_steer_after_its_line(self):
        self.assertEqual(js_entry('LINES', 'bmad'), CARD_LINE)

    def test_no_other_card_carries_the_steer(self):
        for key in ('bounded-plan', 'appetite-led', 'experiment-led'):
            self.assertNotIn('big builds', js_entry('LINES', key))

    def test_tell_me_more_agrees(self):
        more = js_entry('MORE', 'bmad')
        self.assertIn('big builds (a project or an epic)', more)
        self.assertIn('smaller work usually goes faster with Full Plan Up Front', more)
        self.assertNotIn('larger work', more)

    def test_methods_guide_good_fit_agrees(self):
        fit = good_fit('bmad')
        self.assertIn('Big builds (a project or an epic)', fit)
        self.assertIn('smaller work usually goes faster with Full Plan Up Front', fit)

    def test_methods_guide_points_smaller_work_to_apiv(self):
        self.assertRegex(flat(METHODS_MD), r'(?i)smaller work \(a small change or a capability\).{0,80}APIV.{0,80}Full Plan Up Front.{0,40}/glitch-plan.{0,60}fits better than BMAD')

    def test_method_rule_names_the_one_exception(self):
        for text in (SKILL, METHODS_MD):
            self.assertRegex(flat(text), r'(?i)the one exception is the BMAD size check in Exploration')

    def test_exploration_check_fires_once_for_small_change_and_capability(self):
        body = flat(SKILL.split('### Exploration', 1)[1].split('\n### ', 1)[0])
        self.assertRegex(body, r'\*\*BMAD size check\.\*\* Once the scope is agreed, if the overall method is BMAD \(`bmad`\) and the scope is `small-change` or `capability`, say once, in one plain line,')
        self.assertRegex(body, r'(?i)never switch or fill the method yourself')
        self.assertRegex(body, r'(?i)never raise it for a `project` or an `epic`')

    def test_keep_is_saved_once_and_never_asked_again(self):
        body = flat(SKILL.split('### Exploration', 1)[1].split('\n### ', 1)[0])
        self.assertIn('add one entry to `assumptions` that begins `%s`' % KEEP_LABEL, body)
        self.assertRegex(body, r'Skip the check when the idea\'s `assumptions` already carry an entry that begins `' + re.escape(KEEP_LABEL) + r'`, also after a resume')

    def test_check_scopes_are_exactly_the_two_small_ones(self):
        sentence = re.search(r'\*\*BMAD size check\.\*\*[^.]*?and the scope is ([^,]+),', flat(SKILL)).group(1)
        self.assertEqual(re.findall(r'`([a-z-]+)`', sentence), ['small-change', 'capability'])


if __name__ == '__main__':
    unittest.main()

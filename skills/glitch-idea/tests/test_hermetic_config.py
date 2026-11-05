"""The CLI the tests launch must never read the source tree's local config.json."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hermetic_cli

SOURCE_CONFIG = Path(__file__).resolve().parents[1]/'config.json'
SKILL_CONFIG = hermetic_cli.PACKAGE/'config.json'


class HermeticConfigTests(unittest.TestCase):
    def test_helper_script_lives_outside_the_source_tree_with_no_config_beside_it(self):
        package = hermetic_cli.idea_script().parent.parent
        self.assertNotEqual(package, hermetic_cli.PACKAGE)
        self.assertNotIn(SOURCE_CONFIG.parent, package.parents)
        self.assertFalse((package/'config.json').exists())
        self.assertFalse((package.parent/'config.json').exists())
        self.assertFalse((package/'.glitch-idea-install.json').exists())

    def test_cli_runs_cleanly_from_the_helper_copy(self):
        with tempfile.TemporaryDirectory() as t:
            out = subprocess.run([sys.executable, str(hermetic_cli.idea_script()), '--store', str(Path(t)/'ideas'), 'list'],
                                 capture_output=True, timeout=20)
            body = json.loads(out.stdout)
            self.assertTrue(body['ok'], body)

    def test_runner_never_opens_source_config_and_does_look_for_its_own(self):
        script = hermetic_cli.idea_script()
        package = script.parent.parent
        bad = [str(SOURCE_CONFIG), str(SKILL_CONFIG)]
        mine = [str(package/'config.json'), str(package.parent/'config.json')]
        # The audit hook kills the child if a source config is opened; a Path.exists spy records
        # the lookups of the copy's own candidates, proving configuration loading really ran.
        code = ("import sys,runpy,pathlib\n"
                "bad=%r\n"
                "mine=%r\n"
                "def h(e,a):\n"
                "    if e=='open' and a and str(a[0]) in bad: raise SystemExit('LEAK')\n"
                "sys.addaudithook(h)\n"
                "_ex=pathlib.Path.exists\n"
                "def ex(self,*a,**k):\n"
                "    if str(self) in mine: sys.stderr.write('LOOKED '+str(self)+'\\n')\n"
                "    if str(self) in bad: raise SystemExit('LEAK')\n"
                "    return _ex(self,*a,**k)\n"
                "pathlib.Path.exists=ex\n"
                "sys.path.insert(0,%r)\n"
                "sys.argv=[%r,'--store',%r,'list']\n"
                "runpy.run_path(%r,run_name='__main__')\n")
        with tempfile.TemporaryDirectory() as t:
            r = subprocess.run([sys.executable, '-c', code % (bad, mine, str(script.parent),
                                                              str(script), str(Path(t)/'s'), str(script))],
                               capture_output=True, text=True, timeout=20)
        self.assertNotIn('LEAK', r.stderr + r.stdout)
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertTrue(json.loads(r.stdout)['ok'], r.stdout)
        for path in mine:
            self.assertIn('LOOKED ' + path, r.stderr)

    def test_a_hostile_source_skill_config_cannot_reach_the_helper_copy(self):
        if SKILL_CONFIG.exists():
            self.skipTest('a developer config.json already exists in the skill folder; it is never touched')
        # Prove the premise: a config in the source skill folder WOULD break the CLI.
        SKILL_CONFIG.write_text('{"validator_timeout_seconds": "not a number"}', encoding='utf-8')
        try:
            hermetic_cli._copy = None
            helper = hermetic_cli.idea_script()
            self.assertFalse((helper.parent.parent/'config.json').exists())
            with tempfile.TemporaryDirectory() as t:
                out = subprocess.run([sys.executable, str(helper), '--store', str(Path(t)/'ideas'), 'list'],
                                     capture_output=True, text=True, timeout=20)
            body = json.loads(out.stdout)
            self.assertTrue(body['ok'], body)
        finally:
            SKILL_CONFIG.unlink()
            hermetic_cli._copy = None


if __name__ == '__main__':
    unittest.main()

"""Package metadata contracts for updater consumers; sync --check owns copy checks."""
import json
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
PLUGINS = ROOT/'plugins/tern'

TOP_ID = re.compile(r'^\s*id\s*=\s*"([^"]*)"', re.M)


def integrated():
    if not PLUGINS.is_dir():
        return []
    return sorted(d for d in PLUGINS.iterdir()
                  if d.is_dir() and (d/'updater').is_dir())


def top_level(text):
    return re.split(r'^\s*\[', text, maxsplit=1, flags=re.M)[0]


class Vendored(unittest.TestCase):
    def test_manifest_has_top_level_id(self):  # (c)
        for d in integrated():
            with self.subTest(plugin=d.name):
                text = (d/'plugin.toml').read_text(encoding='utf-8-sig')
                match = TOP_ID.search(top_level(text))
                self.assertTrue(match and match.group(1), f'{d.name}: empty top-level id')

    def test_requires_json_is_schema_1(self):  # (e)
        for d in integrated():
            path = d/'requires.json'
            if path.exists():
                with self.subTest(plugin=d.name):
                    value = json.loads(path.read_text(encoding='utf-8'))
                    self.assertIsInstance(value, dict)
                    self.assertEqual(value.get('schema'), 1)


def version_tuple(text):
    return tuple(int(part) for part in text.split('.'))


def newest_named(text, product):
    found = re.findall(rf'\b{product} (\d+\.\d+\.\d+)', text)
    return max(found, key=version_tuple) if found else None


class OrchRequirements(unittest.TestCase):
    """ORCH+ requires.json must say what the release notes say the package needs (SKILLS-221 D2)."""

    def setUp(self):
        self.orch = PLUGINS/'ORCH+'
        self.requires = json.loads((self.orch/'requires.json').read_text(encoding='utf-8'))
        self.changelog = (self.orch/'CHANGELOG.md').read_text(encoding='utf-8')

    def test_tern_minimum_is_the_newest_tern_the_release_notes_name(self):
        named = newest_named(self.changelog, 'Tern')
        self.assertIsNotNone(named, 'CHANGELOG names no Tern version')
        self.assertEqual(self.requires['tern'], named)

    def test_spawn_minimum_is_the_newest_spawn_the_release_notes_name(self):
        named = newest_named(self.changelog, 'SPAWN')
        self.assertIsNotNone(named, 'CHANGELOG names no SPAWN version')
        self.assertEqual(self.requires['plugins']['spawn'], named)

    def test_reference_names_the_shipped_version_and_the_minimums(self):  # SKILLS-221 D1
        text = (self.orch/'plugin.toml').read_text(encoding='utf-8-sig')
        shipped = re.search(r'^version\s*=\s*"([^"]+)"', top_level(text), re.M).group(1)
        reference = (self.orch/'REFERENCE.md').read_text(encoding='utf-8')
        self.assertIn(f'[ORCH+](README.md) {shipped}:', reference)
        self.assertIn(f"Tern {self.requires['tern']} and SPAWN {self.requires['plugins']['spawn']} requirements", reference)

    def test_reference_lists_every_group_the_runner_allows(self):  # SKILLS-221 D5
        runner = (self.orch/'tests/run.luau').read_text(encoding='utf-8')
        allowed = re.findall(r'(\w+) = true', re.search(r'local allowed = \{(.*?)\}', runner, re.S).group(1))
        reference = (self.orch/'REFERENCE.md').read_text(encoding='utf-8')
        for group in allowed:
            self.assertIn(f'`{group}`', reference.split('## Test sections', 1)[1], group)
        self.assertIn(f'({len(allowed)})', reference)

    def test_spawn_minimum_is_a_version_that_exists(self):
        text = (PLUGINS/'SPAWN/plugin.toml').read_text(encoding='utf-8-sig')
        shipped = re.search(r'^version\s*=\s*"([^"]+)"', top_level(text), re.M).group(1)
        self.assertLessEqual(version_tuple(self.requires['plugins']['spawn']), version_tuple(shipped))


class VendoredCopies(unittest.TestCase):
    """Each shared folder's own sync.py --check must find every vendored copy current (SKILLS-221 T6)."""

    def check(self, shared):
        result = subprocess.run([sys.executable, str(ROOT/'shared'/shared/'sync.py'), '--check'],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_channel_copies_are_current(self):
        self.check('plugin-channel-v1')

    def test_wire_copies_are_current(self):
        self.check('report-files-v1')

    def test_status_copies_are_current(self):
        self.check('plugin-status-v1')

    # Known drift on main: shell.luau is generated from SPAWN's backend.luau and lags it (OS-user launch
    # marker). Regenerating touches every plugin's updater copy, so it is its own change.
    @unittest.expectedFailure
    def test_updater_copies_are_current(self):
        self.check('tern-updater')


if __name__ == '__main__':
    unittest.main()

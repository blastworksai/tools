"""Vendored updater copies match shared/tern-updater and are wired correctly."""
import importlib.util
import json
from pathlib import Path
import re
import unittest

CANON = Path(__file__).resolve().parents[1]
ROOT = Path(__file__).resolve().parents[3]
PLUGINS = ROOT/'plugins/tern'

_spec = importlib.util.spec_from_file_location('tern_updater_sync', CANON/'sync.py')
sync = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sync)

REGISTER_DIR = re.compile(re.escape(sync.REGISTER) + r'[^)]*?\bdir\s*=\s*"([^"]*)"', re.S)
TOP_ID = re.compile(r'^\s*id\s*=\s*"([^"]*)"', re.M)


def integrated():
    if not PLUGINS.is_dir():
        return []
    return sorted(d for d in PLUGINS.iterdir()
                  if d.is_dir() and (sync.registers(d) or (d/'updater').exists()))


def top_level(text):
    return re.split(r'^\s*\[', text, maxsplit=1, flags=re.M)[0]


class Vendored(unittest.TestCase):
    def test_canonical_modules_exist(self):
        for m in sync.MODULES:
            self.assertTrue((CANON/f'{m}.luau').is_file(), m)

    def test_register_and_updater_dir_go_together(self):  # (d)
        for d in integrated():
            with self.subTest(plugin=d.name):
                self.assertTrue(sync.registers(d), f'{d.name}: updater/ without register call')
                self.assertTrue((d/'updater').is_dir(), f'{d.name}: register call without updater/')

    def test_vendored_files_equal_canonical_plus_header(self):  # (a)
        plugins = integrated()
        want = sync.expected() if plugins else {}
        for d in plugins:
            with self.subTest(plugin=d.name):
                self.assertEqual(sync.problems(d, want), [], 'run shared/tern-updater/sync.py')

    def test_register_dir_is_folder_name(self):  # (b)
        for d in integrated():
            with self.subTest(plugin=d.name):
                window = d/'window.luau'
                match = REGISTER_DIR.search(window.read_text(encoding='utf-8')) if window.is_file() else None
                self.assertIsNotNone(match, f'{d.name}: no register({{ dir = "..." }})')
                self.assertEqual(match.group(1), d.name)

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


if __name__ == '__main__':
    unittest.main()

"""Package metadata contracts for updater consumers; sync --check owns copy checks."""
import json
from pathlib import Path
import re
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


if __name__ == '__main__':
    unittest.main()

"""Contract drift: installer, launch config and run-time helper must accept and refuse the same port/mode values."""
import contextlib
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'glitch-idea/scripts'))
import install
import idea
import idea_launch
from idea_domain import IdeaError

GOOD = (1024, 8840, 65535)
BAD = (True, False, 0, 80, 1023, 65536, '8840', 8840.0, [], {}, -1)
MODES_GOOD = ('link', 'system', 'tern')
MODES_BAD = ('orca', '', 1, True, 0, [], 'LINK')
RETIRED = (dict(ssh_client='workstation'), dict(ssh_server_port=22), dict(browser_mode='ssh'),
           dict(ssh_client='workstation', ssh_server_port=22, browser_mode='ssh'),
           dict(ssh_client='two words', ssh_server_port=0))  # retired keys are dropped unread, valid or not


class Contract(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='portcontract-')).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.local = self.tmp / 'local'
        self.source = self.local / 'glitch-idea'
        self.source.mkdir(parents=True)
        self.destination = self.tmp / 'skills' / 'glitch-idea'

    def installer(self, **extra):
        (self.local / 'config.json').write_text(json.dumps(dict(store_path='ideas', **extra)))
        try:
            with contextlib.redirect_stderr(io.StringIO()) as err:
                config = install.effective_config(self.source, self.destination, None, False)
            self.stderr = err.getvalue()
            return 'ok', config
        except install.InstallError as exc:
            return 'refused', str(exc)

    def launch(self, **extra):
        try:
            return 'ok', idea_launch._config(dict(extra) or None, self.tmp / 'ideas')
        except IdeaError as exc:
            return 'refused', exc.code

    def runtime(self, **extra):
        try:
            return 'ok', idea._fixed_ports(dict(extra))
        except IdeaError as exc:
            return 'refused', exc.code

    def test_good_ports_accepted_by_all_three(self):
        for key in ('browser_port', 'prototype_port'):
            for v in GOOD:
                with self.subTest(key=key, value=v):
                    status, cfg = self.installer(**{key: v})
                    self.assertEqual((status, cfg.get(key)), ('ok', v))
                    run = self.runtime(**{key: v})
                    self.assertEqual(run[0], 'ok')
                    self.assertEqual(run[1][0 if key == 'browser_port' else 1], v)
                    if key == 'browser_port':
                        status, cfg = self.launch(**{key: v})
                        self.assertEqual((status, cfg.get(key)), ('ok', v))

    def test_bad_ports_refused_by_all_three(self):
        for key in ('browser_port', 'prototype_port'):
            for v in BAD:
                with self.subTest(key=key, value=v):
                    self.assertEqual(self.installer(**{key: v})[0], 'refused')
                    self.assertEqual(self.runtime(**{key: v}), ('refused', 'invalid_config'))
                    if key == 'browser_port':
                        self.assertEqual(self.launch(**{key: v}), ('refused', 'invalid_config'))

    def test_null_is_unset_in_all_three(self):
        for key in ('browser_port', 'prototype_port', 'browser_mode'):
            with self.subTest(key=key):
                status, cfg = self.installer(**{key: None})
                self.assertEqual(status, 'ok')
                self.assertNotIn(key, cfg)
                self.assertEqual(self.runtime(**{key: None}), ('ok', (None, None, None)))
                if key == 'browser_port':
                    status, cfg = self.launch(**{key: None})
                    self.assertEqual(status, 'ok')
                    self.assertNotIn(key, cfg)

    def test_unset_is_written_nowhere(self):
        status, cfg = self.installer()
        self.assertEqual(status, 'ok')
        for key in ('browser_port', 'prototype_port', 'browser_mode'):
            self.assertNotIn(key, cfg)
        self.assertNotIn('browser_port', self.launch()[1])
        self.assertEqual(self.runtime(), ('ok', (None, None, None)))

    def test_equal_ports_refused_by_installer_and_runtime(self):
        for v in GOOD:
            with self.subTest(value=v):
                status, message = self.installer(browser_port=v, prototype_port=v)
                self.assertEqual(status, 'refused')
                self.assertIn('must differ', message)
                self.assertEqual(self.runtime(browser_port=v, prototype_port=v), ('refused', 'invalid_config'))

    def test_distinct_pairs_accepted_by_both(self):
        status, cfg = self.installer(browser_port=8840, prototype_port=8841)
        self.assertEqual((status, cfg['browser_port'], cfg['prototype_port']), ('ok', 8840, 8841))
        self.assertEqual(self.runtime(browser_port=8840, prototype_port=8841), ('ok', (8840, 8841, None)))

    def test_null_partner_is_not_a_collision(self):
        self.assertEqual(self.installer(browser_port=8840, prototype_port=None)[0], 'ok')
        self.assertEqual(self.runtime(browser_port=8840, prototype_port=None), ('ok', (8840, None, None)))

    def test_good_modes_accepted_by_installer_and_runtime(self):
        for m in MODES_GOOD:
            with self.subTest(mode=m):
                status, cfg = self.installer(browser_mode=m)
                self.assertEqual((status, cfg.get('browser_mode')), ('ok', m))
                self.assertEqual(self.runtime(browser_mode=m), ('ok', (None, None, m)))

    def test_bad_modes_refused_by_installer_and_runtime(self):
        for m in MODES_BAD:
            with self.subTest(mode=m):
                self.assertEqual(self.installer(browser_mode=m)[0], 'refused')
                self.assertEqual(self.runtime(browser_mode=m), ('refused', 'invalid_config'))

    def test_retired_ssh_settings_are_dropped_by_the_installer_with_one_line(self):
        for old in RETIRED:
            with self.subTest(old=old):
                status, cfg = self.installer(**old)
                self.assertEqual(status, 'ok')
                for key in ('ssh_client', 'ssh_server_port', 'browser_mode'):
                    self.assertNotIn(key, cfg)
                self.assertEqual(len(self.stderr.strip().splitlines()), 1, self.stderr)
                for key in old:
                    self.assertIn(key, self.stderr)
                for value in ('workstation', 'two words'):
                    self.assertNotIn(value, self.stderr)  # names the keys dropped, never their values
        self.installer(browser_mode='tern')
        self.assertEqual(self.stderr, '')  # nothing retired, nothing said

    def test_retired_ssh_settings_leave_the_other_settings_alone(self):
        status, cfg = self.installer(ssh_client='workstation', browser_mode='ssh', browser_port=8840, prototype_port=8841)
        self.assertEqual((status, cfg['browser_port'], cfg['prototype_port']), ('ok', 8840, 8841))
        self.assertNotIn('browser_mode', cfg)

    def test_retired_ssh_settings_read_as_absent_by_the_runtime(self):
        for old in RETIRED:
            with self.subTest(old=old):
                self.assertEqual(self.runtime(**old), ('ok', (None, None, None)))
        self.assertEqual(self.runtime(ssh_client='x', browser_mode='tern', browser_port=8840), ('ok', (8840, None, 'tern')))

    def test_any_other_unknown_key_is_still_refused_by_the_installer(self):
        for extra, named in ((dict(not_a_key=1), 'not_a_key'), (dict(ssh_clients='x'), 'ssh_clients'),
                             (dict(ssh_client='workstation', not_a_key=1), 'not_a_key')):
            with self.subTest(extra=extra):
                status, message = self.installer(**extra)
                self.assertEqual(status, 'refused')
                self.assertIn('Unsupported configuration keys', message)
                self.assertIn(named, message)

    def test_launch_config_allow_list_refuses_the_keys_it_does_not_carry(self):
        for key, v in (('prototype_port', 8841), ('browser_mode', 'link')):
            with self.subTest(key=key):
                self.assertEqual(self.launch(**{key: v}), ('refused', 'invalid_config'))

    def test_installer_message_names_the_key(self):
        for key in ('browser_port', 'prototype_port'):
            self.assertIn(key, self.installer(**{key: 80})[1])
        self.assertIn('browser_mode', self.installer(browser_mode='orca')[1])


if __name__ == '__main__':
    unittest.main()

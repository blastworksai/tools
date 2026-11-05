"""Contract drift: installer, launch config and run-time helper must accept and refuse the same port/mode values."""
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
MODES_GOOD = ('link', 'system', 'ssh')
MODES_BAD = ('orca', '', 1, True, 0, [], 'LINK')
CLIENTS_GOOD = ('workstation', 'a' * 255, 'workstation.tailnet.example.net', 'x-1')
CLIENTS_BAD = ('', 'a' * 256, 'two words', 'tab\there', 'new\nline', 'nul\x00', '-oProxyCommand=x', '-J', 1, True, 0, [], {})


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
            return 'ok', install.effective_config(self.source, self.destination, None, False)
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

    def test_good_ssh_clients_accepted_by_installer_and_runtime(self):
        for c in CLIENTS_GOOD:
            with self.subTest(client=c):
                status, cfg = self.installer(ssh_client=c)
                self.assertEqual((status, cfg.get('ssh_client')), ('ok', c))
                self.assertEqual(self.runtime(ssh_client=c)[0], 'ok')

    def test_bad_ssh_clients_refused_by_installer_and_runtime(self):
        for c in CLIENTS_BAD:
            with self.subTest(client=c):
                self.assertEqual(self.installer(ssh_client=c)[0], 'refused')
                self.assertEqual(self.runtime(ssh_client=c), ('refused', 'invalid_config'))

    def test_null_ssh_client_is_unset(self):
        status, cfg = self.installer(ssh_client=None)
        self.assertEqual(status, 'ok')
        self.assertNotIn('ssh_client', cfg)
        self.assertEqual(self.runtime(ssh_client=None), ('ok', (None, None, None)))

    def test_ssh_server_port_bounds_agree(self):
        for v in (1, 22, 2222, 65535):
            with self.subTest(good=v):
                self.assertEqual(self.installer(ssh_server_port=v)[1].get('ssh_server_port'), v)
                self.assertEqual(self.runtime(ssh_server_port=v)[0], 'ok')
        for v in (True, False, 0, -1, 65536, '22', 22.0, [], {}):
            with self.subTest(bad=v):
                self.assertEqual(self.installer(ssh_server_port=v)[0], 'refused')
                self.assertEqual(self.runtime(ssh_server_port=v), ('refused', 'invalid_config'))
        self.assertNotIn('ssh_server_port', self.installer(ssh_server_port=None)[1])

    def test_launch_config_allow_list_refuses_the_keys_it_does_not_carry(self):
        for key, v in (('prototype_port', 8841), ('browser_mode', 'link'), ('ssh_client', 'workstation'), ('ssh_server_port', 22)):
            with self.subTest(key=key):
                self.assertEqual(self.launch(**{key: v}), ('refused', 'invalid_config'))

    def test_installer_message_names_the_key(self):
        for key in ('browser_port', 'prototype_port'):
            self.assertIn(key, self.installer(**{key: 80})[1])
        self.assertIn('browser_mode', self.installer(browser_mode='orca')[1])
        self.assertIn('ssh_client', self.installer(ssh_client='two words')[1])


if __name__ == '__main__':
    unittest.main()

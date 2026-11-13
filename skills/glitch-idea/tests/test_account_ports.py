"""account_ports_file: each OS account's two ports come from one registry row, as if written in config.json."""
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'glitch-idea/scripts'
sys.path.insert(0, str(SCRIPTS))
import idea
import idea_prototype
import idea_tern
from idea_domain import IdeaError


class Output:
    def __init__(self):
        self.buffer = io.BytesIO()


@unittest.skipUnless(os.name == 'posix', 'account names come from the POSIX account database')
class AccountPortsTests(unittest.TestCase):
    def setUp(self):
        for name, value in (('default_is_tern', False), ('find_terminal', None)):
            patcher = patch.object(idea_tern, name, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.package = self.directory / 'package/glitch-idea'
        (self.package / 'scripts').mkdir(parents=True)
        fake = self.package / 'scripts/idea.py'
        fake.write_text('fixture')
        patcher = patch.object(idea, '__file__', str(fake))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.store = self.directory / 'ideas'
        self.registry = self.directory / 'ports.json'
        self.account = 'alice'
        patcher = patch.object(idea, '_account_name', lambda: self.account)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.write_registry()

    def write_registry(self, **seats):
        rows = seats or {'alice': {'browser_port': 41001, 'prototype_port': 41002},
                         'bob': {'browser_port': 41003, 'prototype_port': 41004}}
        self.registry.write_text(json.dumps({'schema': 1, 'host': 'testhost', 'seats': rows}))

    def config(self, **extra):
        record = dict(store_path=str(self.store), plan_validator_argv=None, validator_timeout_seconds=30,
                      runtime_python=sys.executable, **extra)
        (self.package / 'config.json').write_text(json.dumps(record))

    def use_registry(self, **extra):
        self.config(account_ports_file=str(self.registry), **extra)

    def invoke(self, *args):
        stream = Output()
        with patch.object(idea.sys, 'stdout', stream):
            status = idea.main(list(args))
        return status, json.loads(stream.buffer.getvalue())

    def test_lookup_gives_this_accounts_two_ports(self):
        self.use_registry()
        value = idea._configuration_source()[0]
        self.assertEqual(idea._fixed_ports(value)[:2], (41001, 41002))
        self.account = 'bob'
        self.assertEqual(idea._fixed_ports(idea._configuration_source()[0])[:2], (41003, 41004))

    def test_launch_config_carries_the_looked_up_browser_port(self):
        self.use_registry()
        args = idea.parser().parse_args(['session-open'])
        _, _, config, _ = idea.launcher_configuration(args)
        self.assertEqual(config['browser_port'], 41001)
        self.assertNotIn('prototype_port', config)
        self.assertNotIn('account_ports_file', config)

    def test_prototype_road_gets_the_looked_up_prototype_port(self):
        self.use_registry()
        with patch.object(idea_prototype, 'serve_prototype', return_value={'ok': True}) as serve:
            status, _ = self.invoke('prototype-serve', '--runtime-root', str(self.directory / 'rt'), '--session', 's', '--dir', 'd')
        self.assertEqual(status, 0)
        self.assertEqual(serve.call_args.kwargs, {'port': 41002})

    def test_browser_mode_still_reads_beside_the_lookup(self):
        self.use_registry(browser_mode='system')
        self.assertEqual(idea._fixed_ports(idea._configuration_source()[0]), (41001, 41002, 'system'))

    def test_key_absent_leaves_todays_behaviour(self):
        self.config(browser_port=41500, prototype_port=41501)
        value = idea._configuration_source()[0]
        self.assertNotIn('account_ports_file', value)
        self.assertEqual(idea._fixed_ports(value)[:2], (41500, 41501))
        self.config()
        value = idea._configuration_source()[0]
        self.assertEqual(idea._fixed_ports(value)[:2], (None, None))
        self.assertNotIn('browser_port', value)

    def test_a_null_key_is_absent(self):
        self.config(account_ports_file=None, browser_port=41500)
        self.assertEqual(idea._fixed_ports(idea._configuration_source()[0])[0], 41500)

    def refused(self, *expect):
        status, body = self.invoke('list')
        self.assertEqual(status, 1, body)
        self.assertEqual(body['error']['code'], 'invalid_config')
        for text in expect:
            self.assertIn(text, body['error']['message'])
        return body

    def test_inline_ports_beside_the_key_are_refused(self):
        for inline in ({'browser_port': 41500}, {'prototype_port': 41501}):
            self.use_registry(**inline)
            self.refused('two sources of one fact')

    def test_registry_missing_is_refused_naming_the_path(self):
        self.registry.unlink()
        self.use_registry()
        self.refused(str(self.registry))

    def test_registry_unparseable_is_refused(self):
        self.registry.write_text('{not json')
        self.use_registry()
        self.refused(str(self.registry))

    def test_registry_is_size_bounded(self):
        self.registry.write_text(json.dumps({'schema': 1, 'seats': {}, 'pad': 'x' * 70000}))
        self.use_registry()
        self.refused(str(self.registry), 'too_large')

    def test_registry_symlink_is_not_followed(self):
        real = self.directory / 'real.json'
        real.write_text(self.registry.read_text())
        self.registry.unlink()
        self.registry.symlink_to(real)
        self.use_registry()
        self.refused(str(self.registry))

    def test_registry_not_schema_one_is_refused(self):
        for text in ('{"schema": 2, "seats": {}}', '{"seats": {}}', '{"schema": true, "seats": {}}', '[]'):
            self.registry.write_text(text)
            self.use_registry()
            self.refused(str(self.registry), 'schema 1')

    def test_malformed_rows_are_refused(self):
        for rows in ({'alice': 'x'},
                     {'alice': {'browser_port': 41001}},
                     {'alice': {'browser_port': 41001, 'prototype_port': 41002, 'extra': 1}},
                     {'alice': {'browser_port': '41001', 'prototype_port': 41002}},
                     {'alice': {'browser_port': True, 'prototype_port': 41002}},
                     {'alice': {'browser_port': 80, 'prototype_port': 41002}},
                     {'alice': {'browser_port': 41001, 'prototype_port': 70000}}):
            self.write_registry(**rows)
            self.use_registry()
            self.refused(str(self.registry))

    def test_a_port_used_twice_is_refused_even_for_another_account(self):
        shared_port = {'alice': {'browser_port': 41001, 'prototype_port': 41002},
                       'bob': {'browser_port': 41002, 'prototype_port': 41004}}
        self.write_registry(**shared_port)
        self.use_registry()
        self.refused(str(self.registry), 'used twice')
        self.write_registry(alice={'browser_port': 41001, 'prototype_port': 41001})
        self.refused('used twice')

    def test_no_row_for_this_account_names_registry_and_account(self):
        self.account = 'carol'
        self.use_registry()
        self.refused(str(self.registry), 'carol')

    def test_relative_registry_path_is_refused(self):
        self.config(account_ports_file='ports.json')
        self.refused('absolute')

    def test_key_is_refused_on_windows(self):
        self.use_registry()
        fake_os = SimpleNamespace(name='nt', path=os.path)
        with patch.object(idea, 'os', fake_os):
            with self.assertRaises(IdeaError) as caught:
                idea._configuration_source()
        self.assertEqual(caught.exception.code, 'invalid_config')
        self.assertIn('not supported on Windows', str(caught.exception))

    def test_the_registry_is_read_once_per_invocation(self):
        self.use_registry()
        real = idea.read_bytes
        reads = []

        def counting(path, *args, **kwargs):
            reads.append(str(path))
            return real(path, *args, **kwargs)
        with patch.object(idea, 'read_bytes', counting):
            idea.launcher_configuration(idea.parser().parse_args(['session-open']))
        self.assertEqual(reads.count(str(self.registry)), 1)


if __name__ == '__main__':
    unittest.main()

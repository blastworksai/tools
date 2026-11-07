"""SSH browser mode: client detection, both key directions, the tunnel proof, and opening on the client.

No real ssh runs here: a fake runner answers by the argv it is given and records every call."""
import base64
import re
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'glitch-idea/scripts'))
import idea_ssh
from idea_ssh import Result, SshError
import idea_launch
import idea_runtime

SECRET = 'a1' * 16
URL_CODE = 'f' * 32
ORIGIN = 'http://127.0.0.1:8840/'
USER = 'tester'


def refused():
    return Result(255, '', 'tester@host: Permission denied (publickey).')


class Client:
    def __init__(self, os_name='windows', addresses=('127.0.0.1', '192.0.2.23'), key=True, tunnel='good', tern=True,
                 open_ok=True, curl=True, machine_id=None, printed=None, open_exit=4):
        self.os, self.addresses, self.key, self.tunnel, self.tern = os_name, addresses, key, tunnel, tern
        self.open_ok, self.curl, self.machine_id, self.printed = open_ok, curl, machine_id, printed
        self.open_exit = open_exit
        self.opened = []


class Fake:
    """Answers `ssh -G`, `ss` and the ssh client calls; keeps every (argv, input) pair."""

    def __init__(self, clients, hosts=None):
        self.clients, self.calls = clients, []
        self.hosts = hosts or {a: (a, USER, '22', ('~/.ssh/k_' + a,)) for a in clients}

    def __call__(self, argv, *, input=None, timeout=15):
        self.calls.append((list(argv), input))
        if argv[:2] == ['ssh', '-G']:
            host = self.hosts.get(argv[-1])
            if host is None:
                return Result(1)
            return Result(0, f'hostname {host[0]}\nuser {host[1]}\nport {host[2]}\n'
                          + ''.join(f'identityfile {i}\n' for i in host[3]))
        alias, remote = argv[-2], argv[-1]
        client = self.clients.get(alias)
        if client is None:
            return Result(255, '', 'Could not resolve hostname')
        if not client.key:
            return refused()
        return self.remote(client, remote, input)

    @staticmethod
    def identity(client, remote):
        if client.machine_id is None:
            return Result(1, '', 'unreadable')
        if remote.startswith('reg query'):
            return Result(0, '\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n    MachineGuid    REG_SZ    %s\r\n' % client.machine_id)
        if remote.startswith('ioreg'):
            return Result(0, '    "IOPlatformUUID" = "%s"\n' % client.machine_id)
        return Result(0, client.machine_id + '\n')

    def remote(self, client, remote, input):
        if remote == 'exit':
            return Result(0)
        if remote == 'ver':
            return Result(0, 'Microsoft Windows [Version 10.0]') if client.os == 'windows' else Result(127, '', 'ver: not found')
        if remote == 'uname -s':
            return Result(0, {'macos': 'Darwin', 'linux': 'Linux'}[client.os] + '\n')
        if remote == 'ipconfig' or remote.startswith("sh -c 'ip -o addr"):
            return Result(0, ''.join(f'   IPv4 Address. . . . . . . . . . . : {a}\n' for a in client.addresses))
        if remote.startswith('reg query') or remote == 'cat /etc/machine-id' or remote.startswith('ioreg'):
            return self.identity(client, remote)
        if remote.startswith('curl'):
            if not client.curl:
                return Result(1, '', "'curl' is not recognized as an internal or external command")
            nonce = re.search(r'nonce=([0-9a-f]{32})', remote).group(1)
            if client.tunnel == 'down':
                return Result(7)
            if client.tunnel == 'foreign':
                return Result(0, '{"ok":true,"proof":"%s"}' % ('0' * 64))
            if client.tunnel == 'html':
                return Result(0, '<html>other service</html>')
            return Result(0, '{"ok":true,"proof":"%s"}' % idea_runtime.expected_tunnel_proof(SECRET, nonce))
        if remote.startswith('powershell') or remote.startswith('sh -c'):
            client.opened.append(input)
            if not client.open_ok:
                return Result(client.open_exit)
            if client.os == 'windows' and not client.tern:
                return Result(10)  # no ready plugin: nothing opened, no other road
            return Result(0, client.printed if client.printed is not None else 'OPENED ' + ('tern-plugin' if client.os == 'windows' else 'default') + '\r\n')
        raise AssertionError('unexpected remote command: ' + remote)


def stdin_script(client):
    """The Windows script as the remote bootstrap receives it: line 1 of stdin, base64 of UTF-8."""
    return base64.b64decode(client.opened[0].split('\n', 1)[0]).decode('utf-8')


def detect(fake, config=None, **kw):
    kw.setdefault('env', {'SSH_CONNECTION': '192.0.2.23 50000 192.0.2.9 22'})
    kw.setdefault('utmp', lambda user: [])
    kw.setdefault('proc', lambda port: [])
    kw.setdefault('ssh_config', list(fake.clients))
    kw.setdefault('resolver', lambda *a: [])
    return idea_ssh.detect_client(config or {}, fake, **kw)


def two_machines(tunnel1='good', tunnel2='good'):
    """Two genuinely different computers, both connected to this VM, each with its own interface addresses."""
    return Fake({'workstation': Client(tunnel=tunnel1), 'laptop': Client(addresses=('192.0.2.77',), tunnel=tunnel2)})


BOTH = lambda user: [idea_ssh.ipaddress.ip_address('192.0.2.23'), idea_ssh.ipaddress.ip_address('192.0.2.77')]


def code(call, *a, **kw):
    try:
        call(*a, **kw)
    except SshError as exc:
        return exc.code, exc.details
    raise AssertionError('no SshError')


class Detection(unittest.TestCase):
    def test_from_ssh_connection(self):
        fake = Fake({'workstation': Client()})
        self.assertEqual(detect(fake)[0], 'workstation')

    def test_from_utmp_when_ssh_connection_is_absent(self):
        fake = Fake({'workstation': Client()})
        alias, addresses = detect(fake, env={}, utmp=lambda user: [idea_ssh.ipaddress.ip_address('192.0.2.23')])
        self.assertEqual(alias, 'workstation')

    def test_utmp_is_read_for_all_accounts(self):
        seen = []
        detect(Fake({'workstation': Client()}), env={}, utmp=lambda user: seen.append(user) or [idea_ssh.ipaddress.ip_address('192.0.2.23')])
        self.assertEqual(seen, [None])

    def test_from_proc_with_no_ssh_connection_and_empty_utmp(self):
        seen = []
        proc = lambda port: seen.append(port) or [idea_ssh.ipaddress.ip_address('192.0.2.23')]
        self.assertEqual(detect(Fake({'workstation': Client()}), env={}, utmp=lambda u: [], proc=proc)[0], 'workstation')
        self.assertEqual(seen, [22])

    def test_sshd_port_is_configurable(self):
        seen = []
        proc = lambda port: seen.append(port) or [idea_ssh.ipaddress.ip_address('192.0.2.23')]
        detect(Fake({'workstation': Client()}), dict(ssh_server_port=2222), env={}, proc=proc)
        self.assertEqual(seen, [2222])

    def test_sources_in_order(self):
        a = lambda text: idea_ssh.ipaddress.ip_address(text)
        found = idea_ssh.login_addresses({'SSH_CONNECTION': '198.51.100.1 1 198.51.100.9 22'}, lambda u: [a('198.51.100.3'), a('198.51.100.2')],
                                         lambda port: [a('198.51.100.2')])
        self.assertEqual([str(x) for x in found], ['198.51.100.1', '198.51.100.2', '198.51.100.3'])

    def test_two_candidates_only_one_tunnel_proves(self):
        fake = two_machines(tunnel2='down')
        self.assertEqual(detect(fake, tunnel_check=self.prove(fake), utmp=BOTH)[0], 'workstation')

    def test_two_candidates_both_prove_is_ambiguous(self):
        fake = two_machines()
        found = code(detect, fake, tunnel_check=self.prove(fake), utmp=BOTH)
        self.assertEqual(found[0], 'ssh_client_ambiguous')
        self.assertEqual(sorted(found[1]['client_aliases']), ['laptop', 'workstation'])

    def test_two_candidates_none_prove_is_tunnel_down(self):
        fake = two_machines(tunnel1='down', tunnel2='foreign')
        found = code(detect, fake, tunnel_check=self.prove(fake), utmp=BOTH)
        self.assertEqual(found[0], 'ssh_tunnel_down')
        self.assertEqual(sorted(found[1]['client_aliases']), ['laptop', 'workstation'])

    def test_single_candidate_tunnel_failure_names_the_failure(self):
        fake = Fake({'workstation': Client(tunnel='foreign')})
        self.assertEqual(code(detect, fake, tunnel_check=self.prove(fake))[0], 'ssh_tunnel_foreign')

    def test_configured_client_still_gets_its_tunnel_checked(self):
        fake = Fake({'workstation': Client(tunnel='down')})
        self.assertEqual(code(detect, fake, dict(ssh_client='workstation'), tunnel_check=self.prove(fake))[0], 'ssh_tunnel_down')

    @staticmethod
    def prove(fake):
        return lambda alias: idea_ssh.check_tunnel(fake, alias, 8840, SECRET, idea_runtime.expected_tunnel_proof)

    def test_config_override_skips_the_search(self):
        fake = Fake({'workstation': Client(), 'desktop': Client(addresses=('198.51.100.5',))})
        alias, _ = detect(fake, dict(ssh_client='desktop'), env={})
        self.assertEqual(alias, 'desktop')
        self.assertFalse([c for c in fake.calls if c[0][:2] == ['ssh', '-G']])

    def test_config_override_with_refused_key(self):
        self.assertEqual(code(detect, Fake({'desktop': Client(key=False)}), dict(ssh_client='desktop'), env={})[0], 'ssh_no_key')

    def test_config_override_unreachable(self):
        self.assertEqual(code(detect, Fake({}), dict(ssh_client='ghost'), env={})[0], 'ssh_client_unreachable')

    def test_zero_candidates(self):
        self.assertEqual(code(detect, Fake({'workstation': Client()}), env={})[0], 'ssh_no_client')

    def test_login_address_matches_no_alias(self):
        fake = Fake({'desktop': Client(addresses=('198.51.100.5',))})
        self.assertEqual(code(detect, fake)[0], 'ssh_no_client')

    def test_matching_alias_with_refused_key(self):
        fake = Fake({'workstation': Client(key=False)}, hosts={'workstation': ('192.0.2.23', USER, '22', ('k',))})
        found = code(detect, fake)
        self.assertEqual(found[0], 'ssh_no_key')
        self.assertEqual(found[1], dict(ssh_client='workstation'))

    def test_match_by_literal_hostname_needs_no_address_probe(self):
        fake = Fake({'workstation': Client(addresses=())}, hosts={'workstation': ('192.0.2.23', USER, '22', ('k',))})
        self.assertEqual(detect(fake)[0], 'workstation')

    def test_match_by_resolved_hostname(self):
        fake = Fake({'workstation': Client(addresses=())}, hosts={'workstation': ('workstation.example', USER, '22', ('k',))})
        found = detect(fake, resolver=lambda host, port: [(0, 0, 0, '', ('192.0.2.23', 0))])
        self.assertEqual(found[0], 'workstation')

    def test_two_machines_are_ambiguous(self):
        fake = two_machines()
        found = code(detect, fake, utmp=BOTH)
        self.assertEqual(found[0], 'ssh_client_ambiguous')
        self.assertEqual(sorted(found[1]['client_aliases']), ['laptop', 'workstation'])

    GUID_A, GUID_B = '11111111-2222-3333-4444-555555555555', '66666666-7777-8888-9999-000000000000'

    def pair(self, tunnel1='good', tunnel2='good', id1=None, id2=None, first='192.0.2.23', second='192.0.2.77'):
        fake = Fake({'desktop': Client(addresses=('127.0.0.1', first), tunnel=tunnel1, machine_id=id1),
                     'laptop': Client(addresses=('127.0.0.1', second), tunnel=tunnel2, machine_id=id2)})
        return fake, [['desktop', 'laptop']]  # one Host line configuring two different computers

    def test_one_host_line_two_computers_one_proves(self):
        fake, config = self.pair(tunnel1='down')
        self.assertEqual(detect(fake, ssh_config=config, tunnel_check=self.prove(fake), utmp=BOTH)[0], 'laptop')

    def test_the_second_alias_of_a_host_line_is_verified_even_if_the_first_fails(self):
        fake, config = self.pair(tunnel1='foreign')
        detect(fake, ssh_config=config, tunnel_check=self.prove(fake), utmp=BOTH)
        probed = [c[0][-2] for c in fake.calls if c[0][-1].startswith('curl')]
        self.assertEqual(probed, ['desktop', 'laptop'])

    def test_both_prove_with_different_machine_ids_is_ambiguous(self):
        fake, config = self.pair(id1=self.GUID_A, id2=self.GUID_B)
        found = code(detect, fake, ssh_config=config, tunnel_check=self.prove(fake), utmp=BOTH)
        self.assertEqual(found[0], 'ssh_client_ambiguous')
        self.assertEqual(found[1]['client_aliases'], ['desktop', 'laptop'])

    def test_both_prove_with_the_same_machine_id_is_one_machine(self):
        fake, config = self.pair(id1=self.GUID_A, id2=self.GUID_A.upper())
        self.assertEqual(detect(fake, ssh_config=config, tunnel_check=self.prove(fake), utmp=BOTH)[0], 'desktop')

    def test_same_machine_id_but_only_one_proves_is_that_one(self):
        fake, config = self.pair(tunnel1='down', id1=self.GUID_A, id2=self.GUID_A)
        self.assertEqual(detect(fake, ssh_config=config, tunnel_check=self.prove(fake), utmp=BOTH)[0], 'laptop')

    def test_unreadable_machine_id_never_folds(self):
        for ids in ((None, None), (self.GUID_A, None), (None, self.GUID_A)):
            with self.subTest(ids=ids):
                fake, config = self.pair(id1=ids[0], id2=ids[1])
                self.assertEqual(code(detect, fake, ssh_config=config, tunnel_check=self.prove(fake), utmp=BOTH)[0],
                                 'ssh_client_ambiguous')

    def test_a_shared_private_interface_address_is_not_identity(self):
        fake, config = self.pair(id1=self.GUID_A, id2=self.GUID_B, first='172.17.0.1', second='172.17.0.1')
        both = lambda user: [idea_ssh.ipaddress.ip_address('172.17.0.1')]
        fake2 = Fake({'desktop': Client(addresses=('172.17.0.1',), machine_id=self.GUID_A),
                      'laptop': Client(addresses=('172.17.0.1',), machine_id=self.GUID_B)})
        found = code(detect, fake2, ssh_config=config, tunnel_check=self.prove(fake2), utmp=both)
        self.assertEqual(found[0], 'ssh_client_ambiguous')

    def test_no_tunnel_check_means_no_folding(self):
        fake, config = self.pair(id1=self.GUID_A, id2=self.GUID_A)
        self.assertEqual(code(detect, fake, ssh_config=config, utmp=BOTH)[0], 'ssh_client_ambiguous')
        self.assertFalse([c for c in fake.calls if c[0][-1].startswith(('reg ', 'cat /etc'))])

    def test_strict_identity_parsing_refuses_every_malformed_shape(self):
        a, b = self.GUID_A, self.GUID_B
        reg = lambda *guids: '\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n' + ''.join(
            '    MachineGuid    REG_SZ    %s\r\n' % g for g in guids)
        io = lambda *guids: ''.join('    "IOPlatformUUID" = "%s"\n' % g for g in guids)
        good = 'ab' * 16
        cases = (
            ('linux', good + '\n', ('linux', good)), ('linux', good, ('linux', good)),
            ('linux', good + '\n\n', None), ('linux', good + 'x\n', None), ('linux', good + '\n' + good + '\n', None),
            ('linux', good + ' ' + good, None), ('linux', 'ab' * 15 + '\n', None), ('linux', good.upper() + '\n', None),
            ('linux', 'garbage\n' + good + '\n', None), ('linux', '', None),
            ('windows', reg(a), ('windows', a)), ('windows', reg(a, a), None), ('windows', reg(a, b), None),
            ('windows', reg(a) + 'garbage\r\n', None), ('windows', reg('not-a-guid'), None), ('windows', reg(a + '0'), None),
            ('windows', reg(a).replace('REG_SZ', 'REG_DWORD'), None), ('windows', '', None),
            ('macos', io(a), ('macos', a)), ('macos', io(a, a), None), ('macos', io(a, b), None),
            ('macos', io('bad'), None), ('macos', io(a).replace('"IOPlatformUUID"', '"IOPlatformUUIDX"'), None),
            ('macos', '    "IOPlatformUUID" = "%s" trailing\n' % a, None), ('macos', 'other\n', None),
        )
        for os_name, text, expected in cases:
            with self.subTest(os=os_name, text=text):
                self.assertEqual(idea_ssh._parse_identity(os_name, text), expected[1] if expected else None)

    def test_machine_identity_per_os(self):
        for name, ident in (('windows', self.GUID_A), ('macos', self.GUID_A), ('linux', 'ab' * 16)):
            with self.subTest(os=name):
                got = idea_ssh.machine_identity(Fake({'c': Client(name, machine_id=ident)}), 'c')
                self.assertEqual(got, (name, ident))
        self.assertIsNone(idea_ssh.machine_identity(Fake({'c': Client('linux', machine_id='not-an-id')}), 'c'))
        self.assertIsNone(idea_ssh.machine_identity(Fake({'c': Client()}), 'c'))

    def test_same_machine_identity_on_different_os_never_matches(self):
        fake = Fake({'a': Client('windows', machine_id=self.GUID_A), 'b': Client('macos', machine_id=self.GUID_A)})
        self.assertNotEqual(idea_ssh.machine_identity(fake, 'a'), idea_ssh.machine_identity(fake, 'b'))

    def test_config_stanzas_keep_same_line_aliases_together(self):
        import tempfile
        with tempfile.NamedTemporaryFile('w', suffix='.cfg') as stream:
            stream.write('Host workstation workstation.example.net\n  User x\nHost desktop\n')
            stream.flush()
            self.assertEqual(idea_ssh.ssh_config_stanzas(stream.name), [['workstation', 'workstation.example.net'], ['desktop']])

    def test_unmatched_aliases_never_win(self):
        fake = Fake({'workstation': Client(), 'desktop': Client(addresses=('198.51.100.5',))})
        self.assertEqual(detect(fake)[0], 'workstation')

    def test_every_call_is_an_argv_list_with_batchmode(self):
        fake = Fake({'workstation': Client()})
        detect(fake)
        for argv, _ in fake.calls:
            self.assertIsInstance(argv, list)
            if argv[0] == 'ssh' and argv[1] != '-G':
                self.assertIn('BatchMode=yes', argv)
                self.assertIn('ConnectTimeout=5', argv)
                self.assertEqual(argv[-3], '--')

    def test_alias_validation(self):
        for bad in ('-oProxyCommand=x', 'a b', '', 'x' * 256, 'a\x00b', 5):
            self.assertFalse(idea_ssh.valid_ssh_alias(bad), bad)
        self.assertTrue(idea_ssh.valid_ssh_alias('workstation.tailnet.example.net'))

    def test_config_aliases_skip_wildcards_and_options(self):
        import tempfile
        with tempfile.NamedTemporaryFile('w', suffix='.cfg') as stream:
            stream.write('Host workstation workstation.example.net\n  User x\nHost *\nHost bad* -J ok\n')
            stream.flush()
            self.assertEqual(idea_ssh.ssh_config_aliases(stream.name), ['workstation', 'workstation.example.net', 'ok'])


PROC_HEADER = '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'


def row(local, remote, state='01'):
    return f'   0: {local} {remote} {state} 00000000:00000000 00:00000000 00000000  1000        0 1 1 0 100 0 0 10 0\n'


class ProcTcp(unittest.TestCase):
    V4 = PROC_HEADER + (
        row('226433C6:0016', '176433C6:C019')          # 198.51.100.34:22 <- 198.51.100.23
        + row('226433C6:0016', '0100007F:C019')        # loopback peer: skipped
        + row('00000000:0016', '00000000:0000', '0A')  # LISTEN: ignored
        + row('226433C6:01BB', '176433C6:C01A')        # other local port (443): ignored
    )
    V6 = PROC_HEADER + (
        row('0000000000000000FFFF0000226433C6:0016', '0000000000000000FFFF0000176433C6:C019')  # v4-mapped
        + row('B80D01200000000000000000FA000000:0016', '020000200000000000000000FA000000:C019')  # real v6
        + row('00000000000000000000000001000000:0016', '00000000000000000000000001000000:C019')  # ::1 loopback
    )

    def test_rows(self):
        found = idea_ssh.proc_tcp_peers(22, (self.V4, ''))
        self.assertEqual([str(a) for a in found], ['198.51.100.23'])

    def test_v6_and_mapped_rows(self):
        found = idea_ssh.proc_tcp_peers(22, ('', self.V6))
        self.assertEqual([str(a) for a in found], ['198.51.100.23', '2000:2::fa'])

    def test_other_port(self):
        found = idea_ssh.proc_tcp_peers(443, (self.V4, self.V6))
        self.assertEqual([str(a) for a in found], ['198.51.100.23'])

    def test_both_files_deduplicate(self):
        self.assertEqual(len(idea_ssh.proc_tcp_peers(22, (self.V4, self.V6))), 2)

    def test_unreadable_is_empty(self):
        self.assertEqual(idea_ssh.proc_tcp_peers(22, ('', '')), [])


class ClientOs(unittest.TestCase):
    def test_each_os(self):
        for name in ('windows', 'macos', 'linux'):
            self.assertEqual(idea_ssh.client_os(Fake({'c': Client(name)}), 'c'), name)

    def test_unreachable(self):
        self.assertEqual(code(idea_ssh.client_os, Fake({}), 'c')[0], 'ssh_client_unreachable')


class Tunnel(unittest.TestCase):
    def check(self, **kw):
        return idea_ssh.check_tunnel(Fake({'c': Client(**kw)}), 'c', 8840, SECRET, idea_runtime.expected_tunnel_proof)

    def test_good_proof(self):
        self.check()

    def test_down(self):
        self.assertEqual(code(self.check, tunnel='down')[0], 'ssh_tunnel_down')

    def test_wrong_proof_is_foreign(self):
        self.assertEqual(code(self.check, tunnel='foreign')[0], 'ssh_tunnel_foreign')

    def test_other_service_is_foreign(self):
        self.assertEqual(code(self.check, tunnel='html')[0], 'ssh_tunnel_foreign')

    def test_no_curl(self):
        self.assertEqual(code(self.check, tunnel='down', curl=False)[0], 'ssh_client_no_curl')

    def test_ssh_failure_is_unreachable(self):
        self.assertEqual(code(idea_ssh.check_tunnel, Fake({}), 'c', 8840, SECRET, idea_runtime.expected_tunnel_proof)[0],
                         'ssh_client_unreachable')

    def test_each_probe_uses_a_fresh_nonce(self):
        fake = Fake({'c': Client()})
        for _ in range(2):
            idea_ssh.check_tunnel(fake, 'c', 8840, SECRET, idea_runtime.expected_tunnel_proof)
        nonces = [re.search(r'nonce=([0-9a-f]{32})', c[0][-1]).group(1) for c in fake.calls]
        self.assertEqual(len(set(nonces)), 2)


class Opening(unittest.TestCase):
    def open(self, os_name, **kw):
        client = Client(os_name, **kw)
        fake = Fake({'c': client})
        url = ORIGIN.rstrip('/') + '/#pair=' + URL_CODE
        how, self.failure = idea_ssh.open_on_client(fake, 'c', os_name, url)
        self.assertEqual(how is None, self.failure is not None)
        return how, fake, client, url

    def assert_url_only_on_stdin(self, fake, client, url):
        for argv, _ in fake.calls:
            self.assertFalse([a for a in argv if URL_CODE in a or url in a], argv)
        self.assertEqual(len(client.opened), 1)
        self.assertEqual(client.opened[0].splitlines()[-1], url)
        self.assertEqual(len(client.opened[0].splitlines()), 2 if client.os == 'windows' else 1)

    def test_windows_with_the_plugin(self):
        how, fake, client, url = self.open('windows')
        self.assertEqual(how, 'tern-plugin')
        self.assert_url_only_on_stdin(fake, client, url)
        script = stdin_script(client)
        self.assertIn('Programs\\Tern\\tern.com', script)

    def windows_script(self):
        return idea_ssh.windows_script()

    @staticmethod
    def argv_leaks(script):
        """Lines where the URL variable could reach an argument list: any invocation or Start-Process line naming $u."""
        return [line for line in script.splitlines()
                if '$u' in line and ('Start-Process' in line or line.lstrip().startswith('&') or '& $' in line
                                     or 'ArgumentList' in line or 'plugin list' in line or 'inspect' in line)]

    @staticmethod
    def withdrawal_is_race_safe(script):
        """A failed remove means the plugin holds the request; only a successful remove means it was never claimed."""
        return bool(re.search(r"try \{ Remove-Item -LiteralPath \$req -Force -ErrorAction Stop; \$withdrawn = \$true \} catch \{ \}", script)
                    and re.search(r"if \(\$withdrawn\) \{ exit 6 \}", script)
                    and script.index('$withdrawn = $true') < script.index('exit 6') < script.index('$n -lt 75'))

    def test_the_plugin_is_the_only_road_and_no_url_reaches_an_argv(self):
        script = self.windows_script()
        self.assertEqual(self.argv_leaks(script), [])
        for gone in ('Start-Process', '& $tern browser', 'tern-cli', "'default'", 'ArgumentList'):
            self.assertNotIn(gone, script)
        self.assertIn("$_.id -eq 'glitch-idea'", script)
        self.assertIn("$_.status -eq 'ready'", script)
        # the only places the URL variable is used: read, trimmed, grammar-checked, written into the request body
        uses = [line.strip() for line in script.splitlines() if '$u' in line]
        self.assertEqual(len(uses), 4, uses)
        self.assertIn('url = $u; created =', uses[-1])

    def test_mutation_a_url_in_an_argv_is_caught(self):
        script = self.windows_script()
        for mutated in (script.replace('plugin list --json', 'plugin list --json $u'),
                        script + "\nStart-Process -FilePath $u\n",
                        script + "\n& $tern browser ($u)\n"):
            self.assertNotEqual(mutated, script)
            self.assertTrue(self.argv_leaks(mutated))
        self.assertEqual(self.argv_leaks(script), [])

    def test_the_request_file_is_written_from_the_stdin_variable_never_argv(self):
        script = self.windows_script()
        self.assertIn('url = $u; created =', script)
        self.assertIn('WriteAllText($tmp', script)
        self.assertLess(script.index('Move-Item'), script.index('Test-Path -LiteralPath $res'))
        how, fake, client, url = self.open('windows')
        self.assert_url_only_on_stdin(fake, client, url)

    def test_the_outcomes_in_the_script(self):
        script = self.windows_script()
        self.assertIn("if ($r -ne $null -and $r.ok -eq $true) { Write-Output 'OPENED tern-plugin'; exit 0 }", script)
        self.assertIn('exit 7', script)  # answered not ok: nothing opened
        self.assertIn('exit 6', script)  # withdrawn, never claimed
        self.assertIn("if (-not (Test-Path -LiteralPath $res)) { exit 5 }", script)  # claimed, no answer
        self.assertIn('$n -lt 20 -and (Test-Path -LiteralPath $req)', script)  # up to 4 s for the claim
        self.assertIn('$n -lt 75 -and -not (Test-Path -LiteralPath $res)', script)  # then up to 15 s for the answer
        self.assertLess(script.index('$n -lt 20'), script.index('$n -lt 75'))
        self.assertEqual(script.count('OPENED'), 1)

    def test_the_withdrawal_race(self):
        script = self.windows_script()
        self.assertTrue(self.withdrawal_is_race_safe(script))
        # mutations: a silent or unchecked remove would treat a held request as withdrawn
        for old, new in (('-ErrorAction Stop; $withdrawn', '-ErrorAction SilentlyContinue; $withdrawn'),
                         ('$withdrawn = $true } catch { }', '} catch { $withdrawn = $true }'),
                         ('if ($withdrawn) { exit 6 }', 'exit 6')):
            self.assertNotEqual(script.replace(old, new), script, old)
            self.assertFalse(self.withdrawal_is_race_safe(script.replace(old, new)), old)

    def test_the_folder_is_checked_and_locked_before_any_write(self):
        script = self.windows_script()
        write = script.index('WriteAllText')
        for piece in ('[IO.FileAttributes]::ReparsePoint', 'GetOwner([Security.Principal.SecurityIdentifier])',
                      'SetAccessRuleProtection($true, $false)', 'AreAccessRulesProtected', 'Set-Acl -LiteralPath $d -AclObject $acl',
                      "SecurityIdentifier('S-1-5-18')", "SecurityIdentifier('S-1-5-32-544')",
                      "Join-Path $env:LOCALAPPDATA 'glitch-idea'", 'foreach ($d in @($base, $dir))'):
            self.assertIn(piece, script)
            self.assertLess(script.index(piece), write, piece)
        self.assertEqual(script.count('[IO.FileAttributes]::ReparsePoint'), 1)  # looped over the parent and the folder
        self.assertGreaterEqual(script.count('exit 8'), 3)

    def test_the_folder_owner_is_the_user_or_an_administrators_member_by_sid(self):
        script = self.windows_script()
        self.assertIn('IsInRole($admins)', script)
        self.assertIn('WindowsPrincipal($identity)', script)
        self.assertIn('if (-not ($owner -eq $me.Value -or ($owner -eq $admins.Value -and $isAdmin))) { exit 8 }', script)
        self.assertNotIn('BUILTIN', script)  # SIDs only, never names

    def test_the_acl_is_exactly_the_user_system_and_administrators(self):
        script = self.windows_script()
        self.assertIn('foreach ($sid in @($me, $system, $admins))', script)
        self.assertEqual(script.count('FileSystemAccessRule($sid'), 1)
        self.assertIn("'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'", script)
        verify = script[script.index('$check = Get-Acl'):script.index('$rb = New-Object byte[]')]
        for name in ('$me.Value', '$system.Value', '$admins.Value'):
            self.assertIn("$_.IdentityReference.Value -ne " + name, verify)
        self.assertIn('-not $check.AreAccessRulesProtected', verify)
        self.assertIn('exit 8', verify)
        # the owner attempt is in a try whose failure is ignored, and it comes before the rules are set
        self.assertRegex(script, r'try \{ \$own = New-Object [^\n]*SetOwner\(\$me\); Set-Acl -LiteralPath \$d -AclObject \$own \} catch \{ \}')
        self.assertLess(script.index('SetOwner($me)'), script.index('SetAccessRuleProtection'))
        # mutation: a rule set that skips the verification of foreign (inherited) rules would not name all three SIDs
        mutated = script.replace('$_.IdentityReference.Value -ne $admins.Value', '$true')
        self.assertNotIn('-ne $admins.Value', mutated)

    def test_reads_are_bounded(self):
        script, bootstrap = self.windows_script(), self.bootstrap_text()
        self.assertNotIn('ReadToEnd', script)
        self.assertNotIn('ReadLine', script)
        self.assertIn('$sb.Length -gt 512) { exit 3 }', script)
        self.assertLess(script.index('-gt 512'), script.index('-cnotmatch'))
        self.assertIn('$sb.Length -gt 65536) { exit 3 }', bootstrap)
        self.assertLess(bootstrap.index('-gt 65536'), bootstrap.index('FromBase64String'))
        self.assertNotIn('ReadToEnd', bootstrap)

    def bootstrap_text(self):
        return base64.b64decode(idea_ssh.windows_command().rsplit(' ', 1)[1]).decode('utf-16-le')

    def test_the_windows_command_stays_under_the_cmd_limit(self):
        how, fake, client, url = self.open('windows')
        command = fake.calls[0][0][-1]
        self.assertLess(len(command), 8000)
        # mutation: the whole script inlined back into the command is far past the limit
        inlined = 'powershell -NoLogo -NoProfile -NonInteractive -EncodedCommand ' + base64.b64encode(
            idea_ssh.windows_script().encode('utf-16-le')).decode('ascii')
        self.assertGreaterEqual(len(inlined), 8000)

    def test_the_bootstrap_reads_the_script_line_and_leaves_the_url_line(self):
        how, fake, client, url = self.open('windows')
        bootstrap = self.bootstrap_text()
        self.assertIn('[Console]::In.Read()', bootstrap)
        self.assertIn('[scriptblock]::Create', bootstrap)
        self.assertIn('FromBase64String', bootstrap)
        self.assertIn('exit 3', bootstrap)
        lines = client.opened[0].split('\n')
        self.assertEqual(lines, [lines[0], url, ''])  # exactly two lines, script first, then the URL
        self.assertEqual(stdin_script(client), idea_ssh.windows_script())
        self.assertNotIn(URL_CODE, fake.calls[0][0][-1])

    def test_the_printed_outcome_is_mapped(self):
        for printed, expected in (('OPENED tern-plugin\r\n', 'tern-plugin'), ('OPENED tern-cli\r\n', None),
                                  ('OPENED default\r\n', 'default'), ('OPENED tern\r\n', None), ('', None)):
            how = self.open('windows', printed=printed)[0]
            self.assertEqual(how, expected, printed)

    def test_windows_without_a_ready_plugin_opens_nothing(self):
        how, fake, client, url = self.open('windows', tern=False)
        self.assertIsNone(how)
        self.assertEqual(self.failure, 'plugin_not_ready')
        self.assert_url_only_on_stdin(fake, client, url)

    def test_every_failure_names_its_fixed_reason(self):
        windows = {3: 'invalid_input', 4: 'tern_missing', 5: 'plugin_no_answer', 6: 'plugin_did_not_claim',
                   7: 'plugin_refused', 8: 'request_folder_unsafe', 9: 'no_tern_window', 10: 'plugin_not_ready',
                   124: 'timeout', 255: 'ssh_failed', 1: 'open_failed', 42: 'open_failed'}
        for status, reason in windows.items():
            with self.subTest(os='windows', status=status):
                self.assertIsNone(self.open('windows', open_ok=False, open_exit=status)[0])
                self.assertEqual(self.failure, reason)
        for name in ('macos', 'linux'):
            for status, reason in {3: 'invalid_input', 124: 'timeout', 255: 'ssh_failed', 1: 'open_failed', 9: 'open_failed'}.items():
                with self.subTest(os=name, status=status):
                    self.assertIsNone(self.open(name, open_ok=False, open_exit=status)[0])
                    self.assertEqual(self.failure, reason)
        # exit 0 without the OPENED line is still a failure with a reason, never a silent None
        self.assertIsNone(self.open('windows', printed='')[0])
        self.assertEqual(self.failure, 'open_failed')

    def test_every_windows_exit_in_the_script_has_a_reason(self):
        script = self.windows_script()
        statuses = {int(n) for n in re.findall(r'\bexit (\d+)', script)} - {0}
        self.assertEqual(statuses, set(idea_ssh._WINDOWS_FAILURES))

    @staticmethod
    def daemon_search(script):
        """The daemon search: an inherited TERN_DAEMON_SOCKET, then the default daemon with the variable cleared, then
        each tern-* pipe owned by the user's own SID; it stops only on a daemon with a window AND the ready plugin, and
        both checks run against that same daemon."""
        loop = re.search(r"\$sockets = @\(\)\n(.*?)\nif \(-not \$window\) \{ exit 9 \}\nif \(-not \$ready\) \{ exit 10 \}",
                         script, re.S)
        if not loop:
            return False
        body = loop.group(1)
        pieces = ("if ($env:TERN_DAEMON_SOCKET) { $sockets += $env:TERN_DAEMON_SOCKET }", "$sockets += ''",
                  "[IO.Directory]::GetFiles('\\\\.\\pipe\\')", "-like '\\\\.\\pipe\\tern-*'", 'Select-Object -First 16',
                  "GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $me.Value) { $sockets += $p }",
                  'foreach ($s in $sockets)',
                  'if ($s) { $env:TERN_DAEMON_SOCKET = $s } else { Remove-Item -LiteralPath Env:TERN_DAEMON_SOCKET -ErrorAction SilentlyContinue }',
                  '& $tern inspect --json', "$_.kind -eq 'window'", 'if (-not $here) { continue }', '& $tern plugin list --json',
                  "$_.id -eq 'glitch-idea'", 'if ($ready) { break }')
        if not all(piece in body for piece in pieces):
            return False
        order = [body.index(p) for p in ('$sockets += $env:TERN_DAEMON_SOCKET', "$sockets += ''", '$sockets += $p',
                                          'foreach ($s in $sockets)', '& $tern inspect', 'if (-not $here) { continue }',
                                          '& $tern plugin list', 'if ($ready) { break }')]
        return (order == sorted(order) and 'break' not in body[:body.index('if ($ready) { break }')]
                and script.index('$me = $identity.User') < loop.start()
                and 'TERN_DAEMON_SOCKET' not in script[loop.end():] and 'plugin list' not in script[loop.end():])

    def test_an_elevated_login_finds_the_window_on_the_users_own_daemon(self):
        script = self.windows_script()
        self.assertTrue(self.daemon_search(script))
        self.assertNotIn('BUILTIN', script)
        # mutations: the default daemon only (the bug), any owner's pipe, the variable not set per daemon, an inherited
        # override kept for the "default" candidate (review finding), stopping on a window without the plugin, and the
        # plugin check moved out of the loop
        for old, new in (("foreach ($s in $sockets)", "foreach ($s in @(''))"),
                         ("-eq $me.Value) { $sockets += $p }", ") { $sockets += $p }"),
                         ("if ($s) { $env:TERN_DAEMON_SOCKET = $s }", "if ($s) { }"),
                         (" else { Remove-Item -LiteralPath Env:TERN_DAEMON_SOCKET -ErrorAction SilentlyContinue }", ""),
                         ("if (-not $here) { continue }\n  $window = $true", "if (-not $here) { continue }\n  $window = $true\n  break"),
                         ("if ($ready) { break }", ""),
                         ("if ($env:TERN_DAEMON_SOCKET) { $sockets += $env:TERN_DAEMON_SOCKET }\n", "")):
            with self.subTest(mutation=old):
                mutated = script.replace(old, new)
                self.assertNotEqual(mutated, script)
                self.assertFalse(self.daemon_search(mutated))

    def test_macos(self):
        how, fake, client, url = self.open('macos')
        self.assertEqual(how, 'default')
        self.assertIn('open "$u"', fake.calls[0][0][-1])
        self.assert_url_only_on_stdin(fake, client, url)

    def test_linux(self):
        how, fake, client, url = self.open('linux')
        self.assertEqual(how, 'default')
        self.assertIn('xdg-open "$u"', fake.calls[0][0][-1])
        self.assert_url_only_on_stdin(fake, client, url)

    def test_failure_is_none(self):
        for name in ('windows', 'macos', 'linux'):
            self.assertIsNone(self.open(name, open_ok=False)[0])

    def test_refuses_a_url_that_is_not_the_pairing_shape(self):
        for bad in ('http://evil.example/#pair=' + URL_CODE, 'http://127.0.0.1:8840/#pair=zz', 'http://127.0.0.1:8840/\n'):
            self.assertEqual(code(idea_ssh.open_on_client, Fake({}), 'c', 'linux', bad)[0], 'invalid_input')

    def test_the_whole_grammar_is_enforced_locally(self):
        for bad in ('http://127.0.0.1:8840@evil.example/#pair=' + URL_CODE, 'http://127.0.0.1:8840/x#pair=' + URL_CODE,
                    'http://127.0.0.1:0/#pair=' + URL_CODE, 'http://127.0.0.1:65536/#pair=' + URL_CODE,
                    'http://127.0.0.1:8840/#pair=' + URL_CODE.upper(), 'http://127.0.0.1:8840/#pair=' + URL_CODE[:-1],
                    'http://127.0.0.1:8840/?binding=binding_x#pair=' + URL_CODE, 'http://127.0.0.1:8840#pair=' + URL_CODE,
                    'http://127.0.0.1.evil.example:8840/#pair=' + URL_CODE):
            self.assertFalse(idea_ssh.URL_SHAPE.fullmatch(bad), bad)
        for good in ('http://127.0.0.1:8840/#pair=' + URL_CODE, 'http://127.0.0.1:65535/#pair=' + URL_CODE,
                     'http://127.0.0.1:1/?binding=binding_' + 'a1' * 16 + '#pair=' + URL_CODE):
            self.assertTrue(idea_ssh.URL_SHAPE.fullmatch(good), good)

    def test_every_remote_script_carries_the_full_grammar_before_any_opener(self):
        pattern = idea_ssh.PAIR_URL_PATTERN
        for os_name in ('windows', 'macos', 'linux'):
            with self.subTest(os=os_name):
                how, fake, client, url = self.open(os_name)
                remote = fake.calls[0][0][-1]
                if os_name == 'windows':
                    remote = stdin_script(client)
                    check, openers = remote.index('-cnotmatch'), ('Out-File', 'WriteAllText')
                else:
                    check, openers = remote.index('grep -Eqx'), ('open "$u"', 'xdg-open')
                self.assertIn(pattern, remote)
                self.assertIn(r'\?binding=binding_[0-9a-f]{32}', remote)
                self.assertIn('[0-9a-f]{32}', remote)
                self.assertTrue(all(check < remote.index(o) for o in openers if o in remote))

    def test_a_posix_remote_check_refuses_what_the_local_check_refuses(self):
        import shutil, subprocess
        if not shutil.which('sh') or not shutil.which('grep'):
            self.skipTest('no sh')
        command = idea_ssh._POSIX_OPEN % 'echo ran'
        for url, ok in (('http://127.0.0.1:8840/#pair=' + URL_CODE, True),
                        ('http://127.0.0.1:8840@evil.example/#pair=' + URL_CODE, False),
                        ('http://127.0.0.1:8840/x/#pair=' + URL_CODE, False),
                        ('http://evil.example:8840/#pair=' + URL_CODE, False),
                        ('http://127.0.0.1:8840/#pair=' + URL_CODE.upper(), False)):
            done = subprocess.run(command, shell=True, input=url + '\n', capture_output=True, text=True, timeout=10)
            self.assertEqual(done.returncode == 0, ok, url)
            self.assertEqual('ran' in done.stdout, ok, url)

    def test_a_posix_remote_check_refuses_anything_but_the_one_line(self):
        import shutil, subprocess
        if not shutil.which('sh') or not shutil.which('grep'):
            self.skipTest('no sh')
        command = idea_ssh._POSIX_OPEN % 'echo ran'
        url = 'http://127.0.0.1:8840/#pair=' + URL_CODE
        for payload, ok in ((url, True), (url + '\n', True), (url + '\nextra', False), (url + '\nextra\n', False),
                            (url + '\n\n', False), (url + '\r\n', False), (url + '\n\0', False), (url + '\0', False), ('\0' + url, False), (url + '\r', False), ('x\n' + url, False)):
            done = subprocess.run(command, shell=True, input=payload.encode(), capture_output=True, timeout=10)
            done.stdout = done.stdout.decode()
            self.assertEqual('ran' in done.stdout, ok, repr(payload))
            self.assertEqual(done.returncode == 0, ok, repr(payload))

    def test_the_powershell_check_reads_the_whole_payload_before_any_opener(self):
        script = idea_ssh.windows_script()
        self.assertIn('[Console]::In.Read($buf, 0, 64)', script)
        self.assertNotIn('ReadLine', script)
        self.assertLess(script.index('Console]::In.Read'), script.index('-cnotmatch'))
        self.assertIn('\\z', script)  # the pattern is anchored to the very end of the payload
        self.assertNotIn('$', script[script.index('-cnotmatch'):script.index('exit 3')].replace('$u', ''))


class FakeRuntime:
    def __init__(self, store, root):
        pass

    def tunnel_probe_secret(self, timeout=1):
        return SECRET


class Door(unittest.TestCase):
    def setUp(self):
        self.sessions = []

        def open_session(store, root, config=None, **options):
            self.sessions.append(options)
            return dict(binding_id='binding_' + '1' * 32, session_id='session_' + '2' * 32, selected_idea_id=None,
                        origin=ORIGIN, pairing_code=URL_CODE)
        self.ensure = mock.Mock()
        for target, value in (('ensure_service', self.ensure), ('open_session', open_session)):
            patcher = mock.patch.object(idea_launch, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = mock.patch.object(idea_runtime, 'Runtime', FakeRuntime)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_door(self, client, config=None, **kw):
        fake = Fake({'workstation': client})
        self.fake = fake
        kw.setdefault('env', {'SSH_CONNECTION': '192.0.2.23 50000 192.0.2.9 22'})
        return idea_ssh.open_ssh_session('s', 'r', {'browser_port': 8840} if config is None else config, runner=fake,
                                         utmp=lambda u: [], proc=lambda port: [], ssh_config=['workstation'],
                                         resolver=lambda *a: [], **kw)

    def test_requires_a_fixed_port(self):
        self.assertEqual(code(self.run_door, Client(), {})[0], 'ssh_requires_fixed_port')
        self.assertEqual(self.sessions, [])

    def test_success_shape(self):
        result = self.run_door(Client())
        browser = result['browser']
        self.assertEqual((browser['mode'], browser['client'], browser['opened']), ('ssh', 'workstation', True))
        self.assertEqual(browser['link'], 'http://127.0.0.1:8840/#pair=' + URL_CODE)
        self.assertEqual(result['binding_id'], 'binding_' + '1' * 32)
        self.assertNotIn('warning', result)
        self.assertNotIn('failure', browser)
        self.assertEqual(len(self.sessions), 1)

    def test_no_window_on_any_daemon_is_named(self):
        result = self.run_door(Client(open_ok=False, open_exit=9))
        self.assertEqual((result['warning'], result['browser']['failure'], result['browser']['opened']),
                         ('ssh_open_failed', 'no_tern_window', False))

    def test_open_failure_keeps_the_session_and_warns(self):
        result = self.run_door(Client(open_ok=False))
        self.assertIs(result['browser']['opened'], False)
        self.assertEqual(result['warning'], 'ssh_open_failed')
        self.assertEqual(result['browser']['failure'], 'tern_missing')
        self.assertIn('#pair=', result['browser']['link'])
        self.assertEqual(len(self.sessions), 1)

    def test_failed_checks_allocate_no_session(self):
        cases = (('ssh_no_key', Client(key=False), dict(ssh_client='workstation')), ('ssh_tunnel_down', Client(tunnel='down'), None),
                 ('ssh_tunnel_foreign', Client(tunnel='foreign'), None),
                 ('ssh_no_client', Client(), None))
        for expected, client, extra in cases:
            with self.subTest(expected=expected):
                env = {} if expected == 'ssh_no_client' else {'SSH_CONNECTION': '192.0.2.23 50000 192.0.2.9 22'}
                self.assertEqual(code(self.run_door, client, env=env, **(dict(ssh_client='workstation') if extra else {}))[0], expected)
                self.assertEqual(self.sessions, [])

    def test_messages_name_the_direction(self):
        self.assertIn('VM -> computer', idea_ssh.MESSAGES['ssh_no_key'])
        self.assertIn('computer -> VM', idea_ssh.MESSAGES['ssh_tunnel_down'])

    def test_no_return_key_check_remains(self):
        self.assertFalse(hasattr(idea_ssh, 'check_return_key'))
        self.run_door(Client())
        self.assertFalse([c for c in self.fake.calls if c[0][-1].startswith('ssh ')])

    def test_order_service_then_tunnel_then_session_then_open(self):
        events = []
        self.ensure.side_effect = lambda *a, **k: events.append('ensure')
        real = idea_launch.open_session
        with mock.patch.object(idea_launch, 'open_session', lambda *a, **k: events.append('session') or real(*a, **k)):
            client = Client()
            fake = Fake({'workstation': client})
            wrapped = lambda argv, **k: (events.append('curl' if argv[-1].startswith('curl') else 'open' if argv[-1].startswith('powershell') else 'x'), fake(argv, **k))[1]
            idea_ssh.open_ssh_session('s', 'r', {'browser_port': 8840}, runner=wrapped, env={'SSH_CONNECTION': '192.0.2.23 1 2 22'},
                                      utmp=lambda u: [], proc=lambda p: [], ssh_config=['workstation'], resolver=lambda *a: [])
        order = [e for e in events if e != 'x']
        self.assertEqual(order, ['ensure', 'curl', 'session', 'open'])

    def test_the_url_is_never_in_any_argv(self):
        self.run_door(Client())
        for argv, _ in self.fake.calls:
            self.assertFalse([a for a in argv if URL_CODE in a])


if __name__ == '__main__':
    unittest.main()

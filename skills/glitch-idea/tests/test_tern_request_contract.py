"""Contract drift: the pairing-link and request-title grammars must agree between Python and lib/request.luau.

Three views of each grammar are driven through the same tables:
  1. the Python source of truth (idea_tern.PAIR_URL_PATTERN, and a regex written in this test for titles);
  2. the Luau source read as text, its pattern pieces pulled out and replayed in Python;
  3. the real pure module, when a standalone `luau` binary is on PATH (otherwise that half skips loudly).
"""
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent / 'glitch-idea' / 'tern-plugin'
sys.path.insert(0, str(PLUGIN.parent / 'scripts'))
import idea_tern  # noqa: E402

REQUEST_PATH = PLUGIN / 'lib' / 'request.luau'
SOURCE = REQUEST_PATH.read_text(encoding='utf-8')
CODE = '\n'.join(line for line in SOURCE.splitlines() if not line.lstrip().startswith('--'))

H32 = '0123456789abcdef' * 2
H32B = 'fedcba9876543210' * 2
PAIR = '#pair=' + H32
BIND = '?binding=binding_' + H32B

URLS = [
    # (url, valid)
    ('http://127.0.0.1:8845/' + PAIR, True),
    ('http://127.0.0.1:1/' + PAIR, True),
    ('http://127.0.0.1:65535/' + PAIR, True),
    ('http://127.0.0.1:8845/' + BIND + PAIR, True),
    ('http://127.0.0.1:65536/' + PAIR, False),
    ('http://127.0.0.1:0/' + PAIR, False),
    ('http://127.0.0.1:08845/' + PAIR, False),
    ('http://127.0.0.1:/' + PAIR, False),
    ('http://127.0.0.1:123456/' + PAIR, False),
    ('http://127.0.0.1:8845/' + PAIR.upper().replace('#PAIR=', '#pair='), False),
    ('http://127.0.0.1:8845/#pair=' + H32[:31], False),
    ('http://127.0.0.1:8845/#pair=' + H32 + '0', False),
    ('http://127.0.0.1:8845/#pair=' + 'g' * 32, False),
    ('http://127.0.0.1:8845/?binding=binding_' + H32B[:31] + PAIR, False),
    ('http://127.0.0.1:8845/?binding=bind_' + H32B + PAIR, False),
    ('http://127.0.0.1:8845/?other=1' + PAIR, False),
    ('http://127.0.0.1:8845/x' + PAIR, False),
    ('http://127.0.0.1:8845' + PAIR, False),
    ('https://127.0.0.1:8845/' + PAIR, False),
    ('http://localhost:8845/' + PAIR, False),
    ('http://127.0.0.2:8845/' + PAIR, False),
    ('http://127x0.0.1:8845/' + PAIR, False),
    ('http://user@127.0.0.1:8845/' + PAIR, False),
    ('http://127.0.0.1:8845/' + PAIR + '\n', False),
    ('http://127.0.0.1:8845/' + PAIR + '&x=1', False),
    (' http://127.0.0.1:8845/' + PAIR, False),
    ('', False),
]

TITLES = [
    ('glitch-idea:1:8845:' + H32, True),
    ('glitch-idea:1:1024:' + H32, True),
    ('glitch-idea:1:65535:' + H32, True),
    ('glitch-idea:1:1023:' + H32, False),
    ('glitch-idea:1:65536:' + H32, False),
    ('glitch-idea:1:01024:' + H32, False),
    ('glitch-idea:1:0:' + H32, False),
    ('glitch-idea:1::' + H32, False),
    ('glitch-idea:1:123456:' + H32, False),
    ('glitch-idea:2:8845:' + H32, False),
    ('glitch-idea:8845:' + H32, False),
    ('glitch-idea', False),
    ('glitch-idea:1:8845:' + H32[:31], False),
    ('glitch-idea:1:8845:' + H32 + '0', False),
    ('glitch-idea:1:8845:' + H32.upper(), False),
    ('glitch-idea:1:8845:' + 'g' * 32, False),
    ('Glitch-idea:1:8845:' + H32, False),
    ('glitch-idea:1:88a5:' + H32, False),
    (' glitch-idea:1:8845:' + H32, False),
    ('glitch-idea:1:8845:' + H32 + ' ', False),
    ('glitch-idea:1:8845:' + H32 + '\n', False),
    ('glitch-idea:1:8845:' + H32 + ':x', False),
    ('x glitch-idea:1:8845:' + H32, False),
    ('', False),
]

PORT_OF_URL = [
    ('http://127.0.0.1:8845/' + PAIR, 8845),
    ('http://127.0.0.1:8845/' + BIND + PAIR, 8845),
    ('http://127.0.0.1:08845/' + PAIR, None),
    ('http://127.0.0.1:70000/' + PAIR, None),
    ('https://127.0.0.1:8845/' + PAIR, None),
    ('', None),
]


def python_title(text):
    """The grammar as written in the design note: port 1024..65535, no leading zero, rid 32 lowercase hex."""
    match = re.fullmatch(r'glitch-idea:1:([1-9][0-9]{0,4}):([0-9a-f]{32})', text)
    if not match or '\n' in text:
        return None
    port = int(match.group(1))
    if port < 1024 or port > 65535:
        return None
    return port, match.group(2)


def lua_to_python_pattern(lua):
    """Translate the plain Lua pattern used in the module (no %f, no %b) into a Python regex."""
    out = lua.replace('%-', r'\-').replace('%.', r'\.')
    return out.replace('$', r'\Z') if out.endswith('$') else out


def luau_strings(call, text=CODE):
    return re.findall(re.escape(call) + r'\(([^)]*)\)', text)


class PythonGrammar(unittest.TestCase):
    def test_url_table_through_the_python_pattern(self):
        for url, valid in URLS:
            matched = re.fullmatch(idea_tern.PAIR_URL_PATTERN, url) is not None and '\n' not in url
            self.assertEqual(matched, valid, repr(url))

    def test_title_table_through_the_python_regex(self):
        for title, valid in TITLES:
            self.assertEqual(python_title(title) is not None, valid, repr(title))


class LuauSourcePieces(unittest.TestCase):
    """The Luau grammar, read as text: pieces extracted from lib/request.luau and replayed in Python."""

    def pieces(self):
        urlbody = CODE[CODE.index('function M.valid_url'):CODE.index('function M.parse_title')]
        pat = re.search(r'string\.match\(url, "(\^http://127[^"]*)"\)', urlbody).group(1)
        self.assertEqual(pat, '^http://127%.0%.0%.1:([0-9]+)(/.*)$')
        binding = re.search(r'string\.sub\(rest, 1, (\d+)\) == "(/\?binding=binding_)"', urlbody)
        bind_len = int(binding.group(1))
        self.assertEqual(bind_len, len(binding.group(2)))
        hexpart = re.search(r'hex32\(string\.sub\(rest, (\d+), (\d+)\)\)', urlbody)
        resume = re.search(r'fragment = "/" \.\. string\.sub\(rest, (\d+)\)', urlbody)
        frag = re.search(r'string\.sub\(fragment, 1, (\d+)\) ~= "(/#pair=)"', urlbody)
        tail = re.search(r'return hex32\(string\.sub\(fragment, (\d+)\)\)', urlbody)
        return dict(pattern=pat, bind=binding.group(2), bind_len=bind_len, hex_from=int(hexpart.group(1)),
                    hex_to=int(hexpart.group(2)), resume=int(resume.group(1)), frag=frag.group(2),
                    frag_len=int(frag.group(1)), tail=int(tail.group(1)),
                    max_url=int(re.search(r'MAX_URL = (\d+)', CODE).group(1)),
                    hexlen=int(re.search(r'#text == (\d+)', CODE).group(1)),
                    port_max=int(re.search(r'number > (\d+) then return false', urlbody).group(1)),
                    port_digits=int(re.search(r'#port > (\d+) or', urlbody).group(1)))

    def replay_url(self, url, p):
        if len(url) > p['max_url']:
            return False
        match = re.match(lua_to_python_pattern(p['pattern']).replace('.*', '[\\s\\S]*'), url)
        if not match:
            return False
        port, rest = match.group(1), match.group(2)
        if len(port) > p['port_digits'] or port.startswith('0'):
            return False
        if int(port) < 1 or int(port) > p['port_max']:
            return False

        def hex_ok(text):
            return len(text) == p['hexlen'] and re.fullmatch(r'[0-9a-f]*', text) is not None

        fragment = rest
        if rest[:p['bind_len']] == p['bind']:
            if not hex_ok(rest[p['hex_from'] - 1:p['hex_to']]):
                return False
            fragment = '/' + rest[p['resume'] - 1:]
        if fragment[:p['frag_len']] != p['frag']:
            return False
        return hex_ok(fragment[p['tail'] - 1:])

    def test_url_table_through_the_luau_pieces(self):
        p = self.pieces()
        for url, valid in URLS:
            self.assertEqual(self.replay_url(url, p), valid, repr(url))
        self.assertEqual(p['port_max'], 65535)
        self.assertEqual(p['max_url'], 200)

    def test_literal_pieces_match_the_python_pattern(self):
        pattern = idea_tern.PAIR_URL_PATTERN
        self.assertIn(r'\?binding=binding_[0-9a-f]{32}', pattern)
        self.assertIn(r'#pair=[0-9a-f]{32}', pattern)
        for piece in ('"/?binding=binding_"', '"/#pair="', '"[^0-9a-f]"'):
            self.assertIn(piece, CODE)
        self.assertNotIn('%x', CODE)  # %x would accept A-F

    def test_title_table_through_the_luau_pieces(self):
        body = CODE[CODE.index('function M.parse_title'):CODE.index('function M.url_port')]
        pat = re.search(r'string\.match\(text, "([^"]*)"\)', body).group(1)
        self.assertEqual(pat, '^glitch%-idea:1:([0-9]+):([0-9a-f]+)$')
        floor = int(re.search(r'number < (\d+) then return nil', body).group(1))
        cap = int(re.search(r'#text > (\d+)', body).group(1))
        port_body = CODE[CODE.index('local function port_number'):CODE.index('function M.valid_url')]
        digits = int(re.search(r'#port > (\d+)', port_body).group(1))
        top = int(re.search(r'number > (\d+) then return nil', port_body).group(1))
        hexlen = int(re.search(r'#text == (\d+)', CODE).group(1))
        regex = lua_to_python_pattern(pat)
        for title, valid in TITLES:
            ok = len(title) <= cap and re.match(regex, title) is not None
            if ok:
                port, rid = re.match(regex, title).groups()
                ok = (len(rid) == hexlen and len(port) <= digits and not port.startswith('0')
                      and floor <= int(port) <= top)
            self.assertEqual(ok, valid, repr(title))
        self.assertEqual((floor, top, hexlen), (1024, 65535, 32))

    def test_routes_and_rate_rule_by_text(self):
        self.assertIn('"http://127.0.0.1:" .. tostring(port) .. "/api/v1/tern-claim?rid=" .. rid', CODE)
        self.assertIn('"/api/v1/tern-result?rid=" .. rid .. "&how=" .. how', CODE)
        for how in ('above', 'beside', 'open_failed'):
            self.assertIn('how ~= "%s"' % how, CODE)
        self.assertIn('RATE_MS = 5000', CODE)
        self.assertIn('now_ms - last_ms >= RATE_MS', CODE)
        self.assertIn('value.ok ~= true or type(value.url) ~= "string"', CODE)


def lua_str(text):
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


class PureModuleUnderLuau(unittest.TestCase):
    """The real module, run by a standalone luau binary over the same tables."""

    def run_driver(self):
        binary = shutil.which('luau')
        if binary is None:
            self.skipTest('luau binary not available: pure-module half not run')
        lines = ['local M = loadstring(' + '[==[' + SOURCE + ']==]' + ')()']
        for i, (url, _) in enumerate(URLS):
            lines.append('print("url", %d, tostring(M.valid_url(%s)))' % (i, lua_str(url)))
        for i, (title, _) in enumerate(TITLES):
            lines.append('do local p, r = M.parse_title(%s); print("title", %d, tostring(p), tostring(r)) end'
                         % (lua_str(title), i))
        for i, (url, _) in enumerate(PORT_OF_URL):
            lines.append('print("port", %d, tostring(M.url_port(%s)), tostring(M.same_port(%s, 8845)))'
                         % (i, lua_str(url), lua_str(url)))
        lines += [
            'print("rate", tostring(M.rate_ok(nil, 1)), tostring(M.rate_ok(1000, 5999)), tostring(M.rate_ok(1000, 6000)))',
            'print("claim", M.claim_url(8845, %s))' % lua_str(H32),
            'for _, how in {"above", "beside", "open_failed", "other"} do '
            'print("result", how, tostring(M.result_url(8845, %s, how))) end' % lua_str(H32),
            'local function dec(body) if body == "bad" then error("x") end; return body end',
            'print("claim_ok", tostring(M.parse_claim({ok=true,url="u"}, function(b) return b end)))',
            'print("claim_str", tostring(M.parse_claim("{}", function(b) return {ok=true,url="u"} end)))',
            'print("claim_notok", tostring(M.parse_claim("{}", function(b) return {ok=false,url="u"} end)))',
            'print("claim_nourl", tostring(M.parse_claim("{}", function(b) return {ok=true} end)))',
            'print("claim_throw", tostring(M.parse_claim("bad", dec)))',
        ]
        with tempfile.TemporaryDirectory() as tmp:
            driver = Path(tmp) / 'driver.luau'
            driver.write_text('\n'.join(lines), encoding='utf-8')
            done = subprocess.run([binary, str(driver)], capture_output=True, text=True, timeout=30,
                                  stdin=subprocess.DEVNULL)
        self.assertEqual(done.returncode, 0, done.stderr)
        return [line.split('\t') for line in done.stdout.splitlines()]

    def test_tables_and_routes_under_luau(self):
        rows = self.run_driver()
        urls = [r for r in rows if r[0] == 'url']
        for (url, valid), row in zip(URLS, urls):
            self.assertEqual(row[2] == 'true', valid, repr(url))
        titles = [r for r in rows if r[0] == 'title']
        for (title, valid), row in zip(TITLES, titles):
            expected = python_title(title)
            self.assertEqual(row[2] != 'nil', valid, repr(title))
            if expected:
                self.assertEqual((int(float(row[2])), row[3]), expected)
        ports = [r for r in rows if r[0] == 'port']
        for (url, port), row in zip(PORT_OF_URL, ports):
            self.assertEqual(row[2], 'nil' if port is None else str(port))
            self.assertEqual(row[3], 'true' if port == 8845 else 'false')
        by = {r[0] if r[0] != 'result' else 'result:' + r[1]: r for r in rows}
        self.assertEqual(by['rate'][1:], ['true', 'false', 'true'])
        self.assertEqual(by['claim'][1], 'http://127.0.0.1:8845/api/v1/tern-claim?rid=' + H32)
        for how in ('above', 'beside', 'open_failed'):
            self.assertEqual(by['result:' + how][2], 'http://127.0.0.1:8845/api/v1/tern-result?rid=%s&how=%s' % (H32, how))
        self.assertEqual(by['result:other'][2], 'nil')
        self.assertEqual(by['claim_ok'][1], 'nil')  # a non-string body is refused before decoding
        self.assertEqual(by['claim_str'][1], 'u')
        self.assertEqual(by['claim_notok'][1], 'nil')
        self.assertEqual(by['claim_nourl'][1], 'nil')
        self.assertEqual(by['claim_throw'][1], 'nil')


if __name__ == '__main__':
    unittest.main()

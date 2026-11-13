"""The Tern plugin that opens the idea page above the asking pane: static checks (Luau cannot run here)."""
import re
import tomllib
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent / 'glitch-idea' / 'tern-plugin'

LUAU = (PLUGIN / 'window.luau').read_text(encoding='utf-8')
REQUEST = (PLUGIN / 'lib' / 'request.luau').read_text(encoding='utf-8')
README = (PLUGIN / 'README.md').read_text(encoding='utf-8')


def strip_comments(text):
    return '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('--'))


CODE = strip_comments(LUAU)
REQUEST_CODE = strip_comments(REQUEST)
DENY_LIST = ('odin', 'cmdr', 'claudekk', 'claudebwai', 'codexkk', 'blastworks', 'dev-blastworks', '/opt/',
             '/home/', 'localappdata')


class TernPlugin(unittest.TestCase):
    def test_manifest(self):
        meta = tomllib.loads((PLUGIN / 'plugin.toml').read_text(encoding='utf-8'))
        self.assertEqual(meta, dict(schema=1, id='glitch-idea', name=meta['name'], version='0.2.0',
                                    description=meta['description'], window='window.luau'))
        self.assertNotIn('host', meta)
        self.assertTrue(meta['name'] and meta['description'])
        self.assertNotIn('focused pane', meta['description'])

    def test_license_is_the_repos_mit_licence(self):
        text = (PLUGIN / 'LICENSE').read_text(encoding='utf-8')
        self.assertEqual(text, (PLUGIN.parent.parent / 'LICENSE').read_text(encoding='utf-8'))
        self.assertIn('MIT License', text)

    def test_window_never_touches_files_programs_input_or_the_environment(self):
        for banned in ('tern.fs', 'tern.process', 'tern.pane.write', ':run(', 'cx.browser', 'getenv', 'os.execute',
                       'io.', 'cx.agents', ':send', 'hosts:', 'session:send', 'LOCALAPPDATA'):
            self.assertNotIn(banned, CODE, banned)
            self.assertNotIn(banned, REQUEST_CODE, banned)

    def test_pure_module_never_reads_tern(self):
        self.assertNotRegex(REQUEST_CODE, r'\btern[.:\[]')

    def test_window_fetches_only_the_two_route_shapes(self):
        calls = re.findall(r'tern\.fetch\((request\.claim_url\([^)]*\)|url),', CODE)
        self.assertEqual(sorted(calls), ['request.claim_url(port, rid)', 'url'])
        self.assertIn('local url = request.result_url(port, rid, how)', CODE)
        self.assertNotIn('http', CODE)  # every URL is built by lib/request
        self.assertIn('/api/v1/tern-claim?rid=', REQUEST_CODE)
        self.assertIn('/api/v1/tern-result?rid=', REQUEST_CODE)
        self.assertEqual(len(re.findall(r'tern-(?:claim|result)', REQUEST_CODE)), 2)

    def test_the_report_never_carries_the_url(self):
        report = CODE[CODE.index('local function report'):CODE.index('local function place')]
        self.assertIn('request.result_url(port, rid, how)', report)
        self.assertNotRegex(report, r'\.\.\s*url|claimed|pairing')
        func = REQUEST_CODE[REQUEST_CODE.index('function M.result_url'):REQUEST_CODE.index('function M.parse_claim')]
        self.assertNotIn('#pair', func)
        self.assertNotRegex(func, r'\burl\b')

    def test_open_only_after_valid_url_and_same_port(self):
        claim = CODE[CODE.index('local function on_claim'):]
        self.assertLess(claim.index('request.valid_url(url)'), claim.index('place('))
        self.assertLess(claim.index('request.same_port(url, port)'), claim.index('place('))
        self.assertEqual(CODE.count('cx:open('), 1)
        self.assertLess(claim.index('request.parse_claim'), claim.index('place('))

    def test_claim_needs_status_200_and_nothing_follows_a_bad_claim(self):
        claim = CODE[CODE.index('local function on_claim'):CODE.index('local function on_title')]
        self.assertIn('res.status ~= 200 then return end', claim)
        self.assertIn('if url == nil or not request.valid_url(url) or not request.same_port(url, port) then return end',
                      claim)
        self.assertEqual(claim.count('report('), 1)  # only after a placed page

    def test_place_and_report_values(self):
        self.assertIn('cx:open(url, "beside", { focus = true })', CODE)
        self.assertIn('cx.layout:move(page, asker, "up")', CODE)
        self.assertIn('page ~= asker', CODE)
        for how in ('"above"', '"beside"', '"open_failed"'):
            self.assertIn('return ' + how, CODE)
        self.assertIn('cx.session:focused()', CODE)

    def test_fresh_cx_in_the_callback_never_retained(self):
        self.assertIn('function(res, fresh)', CODE)
        self.assertIn('pcall(on_claim, res, fresh, port, rid, asker)', CODE)
        title = CODE[CODE.index('local function on_title'):]
        self.assertEqual(title.count('cx:open'), 0)  # the title handler's cx is never used to open

    def test_the_pane_must_be_known_and_requests_are_rate_limited(self):
        title = CODE[CODE.index('local function on_title'):]
        self.assertIn('cx.session:pane(asker)', title)
        self.assertIn('known == nil then return end', title)
        self.assertIn('request.rate_ok(last_asked[asker], now)', title)
        self.assertLess(title.index('cx.session:pane(asker)'), title.index('tern.fetch'))
        self.assertLess(title.index('request.rate_ok'), title.index('tern.fetch'))
        self.assertLess(title.index('request.parse_title'), title.index('cx.session:pane(asker)'))
        self.assertIn('last_asked[asker] = now', title)
        self.assertIn('RATE_MS = 5000', REQUEST_CODE)
        self.assertIn('now_ms - last_ms >= RATE_MS', REQUEST_CODE)

    def test_rate_table_is_bounded_by_pane_closed(self):
        self.assertIn('tern.on("pane_closed"', CODE)
        self.assertIn('last_asked[ev.pane] = nil', CODE)

    def test_requires_the_sibling_module_and_listens_for_title(self):
        self.assertIn('local request = require("./lib/request")', CODE)
        self.assertIn('tern.on("title", on_title)', CODE)

    def test_header_states_the_rule(self):
        header = LUAU.split('\nlocal ', 1)[0].lower()
        self.assertIn('loopback pairing links only', header)
        self.assertIn('never sends input', header)
        self.assertIn('never runs a program', header)

    def test_readme(self):
        self.assertIn('tern plugin install <src>', README)
        self.assertIn('tern plugin uninstall glitch-idea', README)
        self.assertIn('http://127.0.0.1', README)
        self.assertIn('same port number', README)
        self.assertIn('Known limit', README)
        self.assertIn('Anything inside a pane of this Tern may ask.', README)
        self.assertIn('focus', README)

    def test_nothing_estate_specific_in_any_plugin_file(self):
        files = [p for p in PLUGIN.rglob('*') if p.is_file()]
        self.assertGreaterEqual(len(files), 5)
        for path in files:
            low = path.read_text(encoding='utf-8').lower()
            for term in DENY_LIST:
                # the MIT licence text carries the copyright holder's name by law
                if path.name == 'LICENSE' and term == 'blastworks':
                    continue
                self.assertNotIn(term, low, '%s: %s' % (path.name, term))
            stripped = re.sub(r'127\.0\.0\.1|127%\.0%\.0%\.1', '', low)
            self.assertIsNone(re.search(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', stripped), path.name)


if __name__ == '__main__':
    unittest.main()

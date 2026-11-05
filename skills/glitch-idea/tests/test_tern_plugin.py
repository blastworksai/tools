"""The Tern plugin that opens the idea page beside the focused pane: static checks (Luau cannot run here)."""
import re
import sys
import tomllib
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent / 'glitch-idea' / 'tern-plugin'
sys.path.insert(0, str(PLUGIN.parent / 'scripts'))
import idea_ssh  # noqa: E402

LUAU = (PLUGIN / 'window.luau').read_text(encoding='utf-8')
README = (PLUGIN / 'README.md').read_text(encoding='utf-8')
CODE = '\n'.join(line for line in LUAU.splitlines() if not line.lstrip().startswith('--'))


class TernPlugin(unittest.TestCase):
    def test_manifest(self):
        meta = tomllib.loads((PLUGIN / 'plugin.toml').read_text(encoding='utf-8'))
        self.assertEqual(meta, dict(schema=1, id='glitch-idea', name=meta['name'], version='0.1.3',
                                    description=meta['description'], window='window.luau'))
        self.assertTrue(meta['name'] and meta['description'])

    def test_license_is_the_repos_mit_licence(self):
        text = (PLUGIN / 'LICENSE').read_text(encoding='utf-8')
        self.assertEqual(text, (PLUGIN.parent.parent / 'LICENSE').read_text(encoding='utf-8'))
        self.assertIn('MIT License', text)

    def test_grammar_pieces(self):
        for piece in ('"^http://127%.0%.0%.1:([0-9]+)(/.*)$"', '"/?binding=binding_"', '"/#pair="', '[^0-9a-f]',
                      '#text == 32', 'number < 1 or number > 65535', 'string.sub(port, 1, 1) == "0"', '".req"',
                      '"^[A-Za-z]:[\\\\/]"'):
            self.assertIn(piece, LUAU)
        self.assertNotIn('%x', LUAU)  # %x would accept A-F
        self.assertEqual(re.findall(r'\bMAX_BYTES = (\d+)', LUAU), ['1024'])
        for piece in ('MAX_AGE_S = 30', 'SWEEP_MS = 60000', 'POLL_MS = 500', 'count ~= 3 or value.v ~= 1'):
            self.assertIn(piece, LUAU)

    def test_the_opener_grammar_has_the_same_parts(self):
        pattern = idea_ssh.PAIR_URL_PATTERN
        self.assertIn(r'http://127\.0\.0\.1:', pattern)
        self.assertIn(r'\?binding=binding_[0-9a-f]{32}', pattern)
        self.assertIn(r'#pair=[0-9a-f]{32}', pattern)

    def test_claim_before_open_and_the_open_call(self):
        self.assertLess(LUAU.index('tern.fs.remove(path)'), LUAU.rindex('handle(cx, dir, id, request)'))
        self.assertIn('cx.browser:call({ op = "open", owner = agent, url = url, how = "beside" })', LUAU)
        self.assertIn('cx:open(url, "beside", { focus = true })', LUAU)
        self.assertLess(LUAU.index('cx:open(url'), LUAU.index('cx.browser:call'))  # open first, browser is the fallback
        self.assertIn('"beside-browser"', LUAU)
        self.assertIn('"beside-open"', LUAU)
        self.assertIn('"above-open"', LUAU)
        self.assertIn('"above-browser"', LUAU)
        self.assertIn('c.layout:move(page, agent, "up")', LUAU)
        self.assertIn('local agent = focused', LUAU)
        self.assertIn('page ~= agent', LUAU)
        self.assertIn('host.state ~= "connected"', LUAU)
        self.assertIn('cx.session:focused()', LUAU)

    def test_never_runs_programs_sends_input_moves_focus_or_calls_agents(self):
        for banned in (':run(', 'process.run', 'cx.agents', 'agents:', ':send', 'hosts:switch', 'hosts:add',
                       'hosts:terminal', ':focus(', 'session:send', ':command(', 'new_block', 'os.execute', 'io.'):
            self.assertNotIn(banned, CODE, banned)

    def test_startup_never_deletes_a_fresh_request(self):
        # no "everything present at start" sweep: requests expire by their validated `created` when claimed,
        # anything else only after being observed for SWEEP_MS
        self.assertNotIn('first', CODE)
        self.assertIn('math.abs(now - request.created) > MAX_AGE_S', CODE)
        self.assertIn('clock - seen[name] > SWEEP_MS', CODE)
        self.assertIn('if seen[name] == nil then seen[name] = clock end', CODE)
        window_start = CODE[CODE.index('local function start(cx)'):]
        self.assertNotIn('tern.fs.remove', window_start)
        self.assertNotIn('sweep(', window_start)
        self.assertIn('pcall(tick, cx, dir)', window_start)  # a fresh .req is handled normally at once

    def test_the_answer_never_carries_the_url(self):
        answers = re.findall(r'respond\(dir, id, \{[^}]*\}\)', CODE)
        self.assertTrue(answers)
        for answer in answers:
            self.assertNotIn('url', answer)

    def test_readme(self):
        self.assertIn('tern plugin install github.com/blastworksai/tools/skills/glitch-idea/glitch-idea/tern-plugin', README)
        self.assertIn('published path', README)
        self.assertIn('tern plugin uninstall glitch-idea', README)
        self.assertIn('http://127.0.0.1', README)

    def test_no_private_names(self):
        for path in PLUGIN.iterdir():
            low = path.read_text(encoding='utf-8').lower()
            for term in ('/opt/', '/home/', 'c:\\users'):
                self.assertNotIn(term, low, '%s: %s' % (path.name, term))
            stripped = re.sub(r'127\.0\.0\.1|127%\.0%\.0%\.1', '', low)
            self.assertIsNone(re.search(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', stripped), path.name)


if __name__ == '__main__':
    unittest.main()


class FocusStartTests(unittest.TestCase):
    def test_loop_also_starts_on_focus(self):
        # An update installed into a running window never sees window_start; the first focus change must start the loop.
        text = (PLUGIN / 'window.luau').read_text()
        self.assertIn('tern.on("focus"', text)
        self.assertIn('if running then return end', text)


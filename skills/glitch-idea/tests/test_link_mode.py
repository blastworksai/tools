"""Link mode: open_browser_session(mode='link') opens nothing and hands back a ready-paired link.

Real service child, real bridge requests; the runner stub proves no browser or pane is ever driven.
"""
from pathlib import Path
import http.client
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "glitch-idea/scripts"))
import idea_bridge
import idea_launch as launch
from idea_runtime import Runtime

CODE_RE = re.compile(r"[0-9a-f]{32}")


class Runner:
    """Records every call; link mode must make none."""
    def __init__(self):
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, "", "")


@unittest.skipUnless(os.name == "posix", "posix only")
class LinkModeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name) / "ideas"; self.root = Path(self.temp.name) / "private"
        self.client = Runtime(self.store, self.root)
        self.children = []; self.lock = threading.Lock()
        self.runner = Runner()
        self.addCleanup(self.cleanup)

    def spawn(self, *a, **k):
        child = subprocess.Popen(*a, **k)
        with self.lock: self.children.append(child)
        return child

    def cleanup(self):
        end = time.monotonic() + 8
        while any(c.poll() is None for c in self.children) and time.monotonic() < end:
            try: self.client.request_owned_stop(timeout=3)
            except Exception: time.sleep(.05)
        for c in self.children:
            try: c.wait(timeout=5)
            except Exception: c.kill()

    # ---- helpers
    def link(self, **kw):
        return launch.open_browser_session(self.store, self.root, mode="link", runner=self.runner,
                                           spawn=self.spawn, **kw)

    def port(self, opened):
        return int(opened["origin"].rstrip("/").split(":")[-1])

    def wire(self, opened, path, payload=None, headers=None, raw_cookie=None):
        port = self.port(opened)
        h = {"Host": "127.0.0.1:%d" % port}
        h.update(headers or {})
        if payload is not None:
            h.update({"Origin": opened["origin"].rstrip("/"), "Content-Type": "application/json"})
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        try:
            conn.request("POST" if payload is not None else "GET", path,
                         None if payload is None else json.dumps(payload), h)
            resp = conn.getresponse(); raw = resp.read()
            try: body = json.loads(raw)
            except ValueError: body = raw
            return resp.status, body, resp.getheader("Set-Cookie")
        finally:
            conn.close()

    def redeem(self, opened, code=None):
        return self.wire(opened, "/api/v1/pair", {"code": opened["pairing_code"] if code is None else code},
                         {"X-Idea-Binding": opened["binding_id"]})

    def pair(self, opened):
        status, body, cookie = self.redeem(opened)
        self.assertEqual(status, 200, body)
        return dict(binding=opened["binding_id"], cookie=cookie.split(";", 1)[0], tab=body["tab_secret"],
                    csrf=body["csrf_token"], set_cookie=cookie)

    def session(self, opened, creds, cookie=None, tab=None, binding=None):
        return self.wire(opened, "/api/v1/session", None, {
            "X-Idea-Binding": binding or creds["binding"], "Cookie": cookie or creds["cookie"],
            "X-Idea-Tab": tab or creds["tab"]})

    def tree_bytes(self):
        out = {}
        for p in Path(self.temp.name).rglob("*"):
            if p.is_file() and not p.is_symlink():
                try: out[str(p)] = p.read_bytes()
                except OSError: pass
        return out

    # ---- cell 1
    def test_link_result_shape_and_no_pane_driven(self):
        res = self.link()
        browser = res["browser"]
        code = res["pairing_code"]
        self.assertEqual(browser["mode"], "link")
        self.assertRegex(code, "^[0-9a-f]{32}$")
        self.assertEqual(browser["url"], res["origin"])
        self.assertNotIn("#", browser["url"]); self.assertNotIn(code, browser["url"])
        self.assertEqual(browser["link"], browser["url"].rstrip("/") + "/#pair=" + code)
        self.assertIn("fallback_line", res)
        self.assertEqual(res["fallback_line"], f"Only if the tab did not open paired: type {code} within 60 s.")
        self.assertNotIn("browser_page_id", browser)
        self.assertEqual(self.runner.calls, [])
        # The only place the code appears in the result besides the fallback line: the link and pairing_code.
        text = json.dumps({k: v for k, v in res.items() if k not in ("pairing_code", "fallback_line")})
        self.assertEqual(text.count(code), 1)  # in browser.link

    # ---- cell 2
    def test_link_code_pairs_once_and_replay_is_refused(self):
        res = self.link()
        code = re.search(r"#pair=([0-9a-f]{32})$", res["browser"]["link"]).group(1)
        self.assertEqual(code, res["pairing_code"])
        status, body, cookie = self.redeem(res, code)
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"]); self.assertEqual(body["binding_id"], res["binding_id"])
        self.assertTrue(cookie)
        status2, body2, cookie2 = self.redeem(res, code)
        self.assertEqual(status2, 401)
        self.assertEqual(body2["code"], "pairing_replay_session_invalidated")
        self.assertIsNone(cookie2)

    # ---- cell 3
    def test_resume_issues_fresh_code_and_refuses_old_one(self):
        first = self.link()
        second = self.link(binding_id=first["binding_id"])
        self.assertEqual(second["binding_id"], first["binding_id"])
        self.assertRegex(second["pairing_code"], "^[0-9a-f]{32}$")
        self.assertNotEqual(second["pairing_code"], first["pairing_code"])
        self.assertEqual(second["browser"]["link"],
                         second["origin"].rstrip("/") + "/#pair=" + second["pairing_code"])
        self.assertNotEqual(second["browser"]["link"], first["browser"]["link"])
        self.assertEqual(self.runner.calls, [])
        status, body, _ = self.redeem(first)  # the old code
        self.assertEqual(status, 401); self.assertIn("pairing", body["code"])
        status, body, _ = self.redeem(second)
        self.assertEqual(status, 200, body)

    def test_resume_after_pairing_supersedes_the_first_tab(self):
        first = self.link()
        old = self.pair(first)
        self.assertEqual(self.session(first, old)[0], 200)
        second = self.link(binding_id=first["binding_id"])
        self.assertNotEqual(second["pairing_code"], first["pairing_code"])
        status, body, _ = self.session(first, old)
        self.assertEqual((status, body["code"]), (401, "session_superseded"))
        status, body, _ = self.redeem(first)  # the first code is spent and stays refused
        self.assertEqual(status, 401)
        new = self.pair(second)
        self.assertEqual(self.session(second, new)[0], 200)
        self.assertEqual(self.session(second, old)[1]["code"], "session_superseded")
        self.assertEqual(self.runner.calls, [])

    # ---- cell 4
    def test_no_pairing_code_is_written_to_any_file(self):
        first = self.link()
        second = self.link(binding_id=first["binding_id"])
        codes = [first["pairing_code"].encode(), second["pairing_code"].encode()]
        creds = self.pair(second)
        # Drive some traffic so the activity log has content to sweep.
        status, body, _ = self.wire(second, "/api/v1/activity", {}, {
            "X-Idea-Binding": creds["binding"], "Cookie": creds["cookie"], "X-Idea-Tab": creds["tab"],
            "X-CSRF-Token": creds["csrf"]})
        self.assertEqual(status, 200, body)
        files = self.tree_bytes()
        self.assertTrue(files, "no files found to sweep")
        self.assertTrue((self.root / "activity.log").exists(), "activity log missing: sweep would prove less")
        self.assertTrue(any(str(p).startswith(str(self.root)) for p in files))
        for path, data in files.items():
            for code in codes:
                self.assertNotIn(code, data, path)
        # The sweep can see a planted code (guards against a vacuous walk).
        (self.root / "canary.txt").write_bytes(b"x" + codes[0])
        self.assertIn(str(self.root / "canary.txt"),
                      [p for p, d in self.tree_bytes().items() if codes[0] in d])

    # ---- cell 5
    def test_pairing_cookie_is_bounded_and_keeps_its_flags(self):
        res = self.link()
        creds = self.pair(res)
        header = creds["set_cookie"]
        attrs = [a.strip() for a in header.split(";")[1:]]
        for wanted in ("Max-Age=86400", "HttpOnly", "SameSite=Strict", "Path=/"):
            self.assertIn(wanted, attrs, header)
        self.assertNotIn("Secure", attrs)  # plain loopback http

    # ---- cell 6
    def test_documents_todays_cookie_header_limit(self):
        """Documents today's limit: one header line over MAX_HEADER_LINE (8192) is refused with 413.

        A real pairing cookie entry (name + value) is 165 bytes, so 49 fit by one byte and 50 do not.
        """
        res = self.link()
        creds = self.pair(res)
        name, _, value = creds["cookie"].partition("=")
        entry_len = len(creds["cookie"])
        self.assertEqual(entry_len, 165)  # the real shape: gi_<64 hex ns>_<32 hex> = <64 hex>
        self.assertEqual(idea_bridge.MAX_HEADER_LINE, 8192)

        def cookie_header(n):
            parts = []
            for i in range(n):  # same name shape, distinct 32-hex tail, same value length
                parts.append(name[:-32] + format(i, "032x") + "=" + value)
            return "; ".join(parts)

        def send(n):
            return self.wire(res, "/api/v1/session", None, {
                "X-Idea-Binding": creds["binding"], "Cookie": cookie_header(n), "X-Idea-Tab": creds["tab"]})

        def line_len(n):  # "Cookie: " + value + CRLF, as the bridge counts the raw line
            return len("Cookie: ") + len(cookie_header(n)) + 2

        self.assertLessEqual(line_len(49), 8192)
        self.assertGreater(line_len(50), 8192)
        status, body, _ = send(49)
        self.assertNotEqual(status, 413, body)  # fits by 1 byte; refused later as an unauthorised cookie set
        status, body, _ = send(50)
        self.assertEqual((status, body["code"]), (413, "headers_too_large"))
        # And the real, single cookie still authorises afterwards (the service survived).
        self.assertEqual(self.session(res, creds)[0], 200)

    # ---- cell 7
    def test_two_bindings_side_by_side_authorise_only_their_own(self):
        a_open = self.link(); b_open = self.link()
        self.assertNotEqual(a_open["binding_id"], b_open["binding_id"])
        self.assertEqual(self.port(a_open), self.port(b_open))
        a = self.pair(a_open); b = self.pair(b_open)
        self.assertNotEqual(a["cookie"].split("=")[0], b["cookie"].split("=")[0])
        both = a["cookie"] + "; " + b["cookie"]
        status, body, _ = self.session(a_open, a, cookie=both)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["binding_id"], a["binding"])
        # Binding A's selector with B's tab secret: refused.
        status, body, _ = self.session(a_open, a, cookie=both, tab=b["tab"])
        self.assertEqual((status, body["code"]), (401, "browser_unauthorized"))
        # Binding B with B's tab: authorised, and only as B.
        status, body, _ = self.session(b_open, b, cookie=both)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["binding_id"], b["binding"])
        status, body, _ = self.session(b_open, b, cookie=both, tab=a["tab"])
        self.assertEqual((status, body["code"]), (401, "browser_unauthorized"))
        self.assertEqual(self.runner.calls, [])


if __name__ == "__main__":
    unittest.main()

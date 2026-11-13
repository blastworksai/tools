"""Tern pane mode: a real owner service, a fake terminal file, and a fake plugin that claims over loopback HTTP.

Nothing here writes to a real terminal or binds 8845/8860: the service takes its own port and the "terminal" is a temp file.
"""
from functools import partial
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
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "glitch-idea/scripts"))
import idea_launch as launch
import idea_ssh
import idea_tern as tern
from idea_runtime import Runtime, RuntimeError as OwnerError

TITLE = re.compile(r"^glitch-idea:1:([1-9][0-9]{0,4}):([0-9a-f]{32})$")
FAST = dict(claim_wait=0.8, result_wait=0.6, poll=0.02)


def keys(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from keys(item)
    elif isinstance(value, list):
        for item in value:
            yield from keys(item)


class FakeRuntime:
    def __init__(self):
        self.calls = []

    def tern_offer(self, rid, url, timeout=1):
        self.calls.append(("offer", rid))

    def tern_state(self, rid, timeout=1):
        self.calls.append(("state", rid))
        return "pending"


@unittest.skipUnless(os.name == "posix", "posix only")
class TernModeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name) / "ideas"; self.root = Path(self.temp.name) / "private"
        self.terminal = Path(self.temp.name) / "fake-pts"; self.terminal.write_bytes(b"")
        self.client = Runtime(self.store, self.root)
        self.children, self.threads, self.argv = [], [], []
        self.titles, self.claimed, self.plugin_mode = [], [], "above"
        self.lock = threading.Lock()
        self.addCleanup(self.cleanup)

    def spawn(self, *a, **k):
        self.argv.append(list(a[0]) if a else [])
        child = subprocess.Popen(*a, **k)
        with self.lock: self.children.append(child)
        return child

    def cleanup(self):
        for t in self.threads: t.join(timeout=5)
        end = time.monotonic() + 8
        while any(c.poll() is None for c in self.children) and time.monotonic() < end:
            try: self.client.request_owned_stop(timeout=3)
            except Exception: time.sleep(.05)
        for c in self.children:
            try: c.wait(timeout=5)
            except Exception: c.kill()

    # ---- the fake terminal and the fake plugin
    def http(self, port, path):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        try:
            conn.request("GET", path, headers={"Host": "127.0.0.1:%d" % port})
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    def plugin(self, port, rid):
        mode = self.plugin_mode
        if mode == "silent": return
        status, body = self.http(port, "/api/v1/tern-claim?rid=" + rid)
        if status == 200: self.claimed.append(body["url"])
        if mode != "claim_only": self.http(port, "/api/v1/tern-result?rid=%s&how=%s" % (rid, mode))

    def write(self, path, text):
        data = tern.title_escape(text)
        with open(path, "ab") as stream: stream.write(data)
        self.titles.append(text)
        match = TITLE.match(text)
        if match:
            thread = threading.Thread(target=self.plugin, args=(int(match.group(1)), match.group(2)))
            self.threads.append(thread); thread.start()
        return True

    def open(self, terminal="default", write=None, **options):
        sender = partial(tern.send_request, write=write or self.write, **FAST)
        return tern.open_tern_session(self.store, self.root, None, terminal=self.terminal if terminal == "default" else terminal,
                                      sender=sender, spawn=self.spawn, **options)

    def bindings(self):
        return sorted(p.name for p in (self.client.path / "bindings").glob("binding_*.json"))

    def tree_bytes(self):
        out = {}
        for p in Path(self.temp.name).rglob("*"):
            if p.is_file() and not p.is_symlink():
                try: out[str(p)] = p.read_bytes()
                except OSError: pass
        return out

    # ---- success
    def assert_success(self, res, how):
        self.assertEqual(res["browser"], dict(mode="tern", url=res["origin"], opened=True, how=how))
        self.assertEqual(len(self.claimed), 1)
        code = self.claimed[0].rsplit("=", 1)[1]
        self.assertRegex(code, "^[0-9a-f]{32}$")
        text = json.dumps(res)
        self.assertNotIn(code, text)
        self.assertNotIn("#pair=", text)
        for banned in ("link", "pairing_code", "fallback_line", "warning"):
            self.assertNotIn(banned, set(keys(res)))
        self.assertEqual(len(self.bindings()), 1)
        return code

    def test_opened_above(self):
        res = self.open()
        self.assert_success(res, "above")
        self.assertEqual(self.claimed[0], res["origin"].rstrip("/") + "/#pair=" + self.claimed[0].rsplit("=", 1)[1])

    def test_opened_beside(self):
        self.plugin_mode = "beside"
        self.assert_success(self.open(), "beside")

    # ---- every failure returns the live link, once, with exactly one session
    def assert_failure(self, res, failure, terminal_written=True):
        browser = res["browser"]
        self.assertEqual(res["warning"], "tern_open_failed")
        self.assertEqual(browser["mode"], "tern"); self.assertIs(browser["opened"], False)
        self.assertEqual(browser["failure"], failure)
        code = res["pairing_code"]
        self.assertEqual(browser["link"], res["origin"].rstrip("/") + "/#pair=" + code)
        self.assertEqual(browser["url"], res["origin"])
        self.assertEqual(res["fallback_line"], f"Only if the tab did not open paired: type {code} within 60 s.")
        self.assertEqual(len(self.bindings()), 1)
        if terminal_written: self.assertEqual(self.titles[-1], "glitch-idea")

    def test_no_terminal(self):
        res = self.open(terminal=None)
        self.assert_failure(res, "no_terminal", terminal_written=False)
        self.assertEqual(self.titles, [])

    def test_unwritable_terminal_is_no_terminal(self):
        calls = []
        res = self.open(write=lambda path, text: calls.append(text) or False)
        self.assert_failure(res, "no_terminal", terminal_written=False)
        self.assertEqual(len(calls), 2)  # the failed request write, then exactly one reset attempt
        self.assertRegex(calls[0], TITLE)
        self.assertEqual(calls[1], "glitch-idea")

    def test_token_failure_is_offer_failed_with_no_write(self):
        calls = []
        sender = partial(tern.send_request, write=lambda path, text: calls.append(text) or True,
                         token=lambda n: 1 / 0, **FAST)
        res = tern.open_tern_session(self.store, self.root, None, terminal=self.terminal, sender=sender, spawn=self.spawn)
        self.assert_failure(res, "offer_failed", terminal_written=False)
        self.assertEqual(calls, [])

    def test_a_sender_that_raises_keeps_the_session_and_the_link(self):
        def boom(*a, **k): raise RuntimeError("sender broke")
        res = tern.open_tern_session(self.store, self.root, None, terminal=self.terminal, sender=boom, spawn=self.spawn)
        self.assert_failure(res, "no_result", terminal_written=False)
        self.assertEqual(self.titles, [])

    def test_plugin_no_answer(self):
        self.plugin_mode = "silent"
        self.assert_failure(self.open(), "plugin_no_answer")
        self.assertRegex(self.titles[0], TITLE)

    def test_open_failed(self):
        self.plugin_mode = "open_failed"
        self.assert_failure(self.open(), "open_failed")
        self.assertEqual(len(self.claimed), 1)

    def test_no_result(self):
        self.plugin_mode = "claim_only"
        self.assert_failure(self.open(), "no_result")

    def test_offer_failed(self):
        with patch.object(Runtime, "tern_offer", side_effect=OwnerError("tern_offer_refused")):
            res = self.open()
        self.assert_failure(res, "offer_failed", terminal_written=False)
        self.assertEqual(self.titles, [])  # nothing is asked of the pane when the service would not hold the link

    def test_state_failure_is_offer_failed(self):
        with patch.object(Runtime, "tern_state", side_effect=OwnerError("owner_unavailable")):
            res = self.open()
        self.assert_failure(res, "offer_failed")

    def test_failure_never_opens_a_second_session(self):
        self.plugin_mode = "silent"
        with patch.object(launch, "open_session", wraps=launch.open_session) as opened:
            self.open()
        self.assertEqual(opened.call_count, 1)

    # ---- the request
    def test_title_grammar_and_last_write_is_the_fixed_title(self):
        res = self.open()
        port = int(res["origin"].rstrip("/").rsplit(":", 1)[1])
        self.assertEqual(len(self.titles), 2)
        match = TITLE.match(self.titles[0])
        self.assertEqual(int(match.group(1)), port)
        self.assertEqual(self.titles[-1], "glitch-idea")
        self.assertEqual(self.terminal.read_bytes(), tern.title_escape(self.titles[0]) + tern.title_escape("glitch-idea"))

    def test_two_requests_use_two_request_ids(self):
        first = self.open()
        second = self.open(binding_id=first["binding_id"])  # a fresh root first, then a rerun on the same root
        self.assertEqual(second["browser"]["how"], "above")
        rids = [TITLE.match(t).group(2) for t in self.titles if TITLE.match(t)]
        self.assertEqual(len(rids), 2); self.assertNotEqual(*rids)
        self.assertEqual(self.bindings(), [first["binding_id"] + ".json"])

    def test_link_in_no_argv_and_no_file(self):
        self.open()
        code = self.claimed[0].rsplit("=", 1)[1].encode()
        self.assertTrue(self.argv)
        self.assertFalse(any(code in repr(a).encode() for a in self.argv))
        files = self.tree_bytes()
        self.assertTrue(any(str(p).startswith(str(self.root)) for p in files))
        self.assertIn(str(self.terminal), files)
        for path, data in files.items():
            self.assertNotIn(code, data, path)
        (self.root / "canary.txt").write_bytes(b"x" + code)  # the sweep sees a planted code
        self.assertIn(str(self.root / "canary.txt"), [p for p, d in self.tree_bytes().items() if code in d])

    def test_failure_leaves_the_code_only_in_the_returned_result(self):
        self.plugin_mode = "silent"
        res = self.open()
        code = res["pairing_code"].encode()
        for path, data in self.tree_bytes().items():
            self.assertNotIn(code, data, path)

    # ---- send_request refuses a bad link before anything is sent
    def test_bad_links_refuse_before_any_offer_or_write(self):
        port = 8841
        good = "http://127.0.0.1:%d/#pair=%s" % (port, "ab" * 16)
        bad = ("http://10.0.0.1:%d/#pair=%s" % (port, "ab" * 16), "http://localhost:%d/#pair=%s" % (port, "ab" * 16),
               "https://127.0.0.1:%d/#pair=%s" % (port, "ab" * 16), "http://127.0.0.1:%d/#pair=%s" % (port + 1, "ab" * 16),
               "http://127.0.0.1:%d/#pair=nothex" % port, good + "x", "", None, 5)
        for url in bad:
            with self.subTest(url=url):
                runtime, writes = FakeRuntime(), []
                with self.assertRaises(launch.LaunchError) as caught:
                    tern.send_request(runtime, url, port, terminal=str(self.terminal), write=lambda *a: writes.append(a), **FAST)
                self.assertEqual(caught.exception.code, "invalid_pair_url")
                self.assertEqual((runtime.calls, writes), ([], []))
        with self.assertRaises(launch.LaunchError):  # a non-int port
            tern.send_request(FakeRuntime(), good, "8841", terminal=None, **FAST)

    def test_no_terminal_offers_nothing(self):
        runtime = FakeRuntime()
        url = "http://127.0.0.1:8841/#pair=" + "ab" * 16
        self.assertEqual(tern.send_request(runtime, url, 8841, terminal=None, **FAST), (None, "no_terminal"))
        self.assertEqual(runtime.calls, [])

    def test_clock_driven_waits(self):
        ticks = iter(range(0, 1000))
        runtime, writes = FakeRuntime(), []
        url = "http://127.0.0.1:8841/#pair=" + "ab" * 16
        out = tern.send_request(runtime, url, 8841, terminal="t", write=lambda p, t: writes.append(t) or True,
                                clock=lambda: next(ticks), sleep=lambda s: None, claim_wait=4.0, poll=0.25)
        self.assertEqual(out, (None, "plugin_no_answer"))
        self.assertEqual(writes[-1], "glitch-idea")

    # ---- compatibility
    def test_ssh_names_still_import_from_idea_ssh(self):
        for name in ("PAIR_URL_PATTERN", "URL_SHAPE", "Result", "default_runner"):
            self.assertIs(getattr(idea_ssh, name), getattr(tern, name))


class TerminalFinderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.proc = Path(self.temp.name)

    def process(self, pid, parent, name="x", fds=None):
        d = self.proc / str(pid); (d / "fd").mkdir(parents=True)
        (d / "stat").write_text("%d (%s) S %d 1 1 0 -1\n" % (pid, name, parent))
        (d / "comm").write_text(name + "\n")
        for fd, target in (fds or {}).items():
            (d / "fd" / str(fd)).symlink_to(target)

    def find(self, pid, ok=("/dev/pts/7",), **kw):
        return tern.find_terminal(pid, proc=str(self.proc), devcheck=lambda p: p in ok, **kw)

    def test_found_at_the_third_ancestor(self):
        self.process(300, 200, fds={0: "pipe:[1]", 1: "/dev/null", 2: "socket:[9]"})
        self.process(200, 100, fds={0: "/dev/null"})
        self.process(100, 1, fds={1: "pipe:[2]", 2: "/dev/pts/7"})
        self.process(1, 0, fds={0: "/dev/pts/8"})
        self.assertEqual(self.find(300), "/dev/pts/7")

    def test_not_owned_or_not_writable_is_skipped(self):
        self.process(300, 200, fds={0: "/dev/pts/3"})   # a terminal the account may not write
        self.process(200, 100, fds={2: "/dev/pts/7"})
        self.process(100, 1)
        self.assertEqual(self.find(300), "/dev/pts/7")
        self.assertIsNone(self.find(300, ok=()))

    def test_default_check_refuses_non_pty_files(self):
        check = tern._writable_terminal(os.getuid())
        self.assertFalse(check("/dev/null"))      # a character device, but not a terminal
        self.assertFalse(check("/etc/hostname"))  # a regular file
        self.assertFalse(check("pipe:[1]"))

    def test_no_proc_is_none(self):
        self.assertIsNone(tern.find_terminal(1234, proc=str(self.proc / "absent"), devcheck=lambda p: True))
        self.assertIsNone(tern.find_terminal(None, proc=str(self.proc / "absent")))

    def test_a_loop_and_a_long_chain_stop(self):
        self.process(10, 11); self.process(11, 10)
        self.assertIsNone(self.find(10))
        for pid in range(1000, 1075): self.process(pid, pid + 1, fds={})
        self.process(1075, 1, fds={0: "/dev/pts/7"})
        self.assertIsNone(self.find(1000))                   # the terminal is 75 hops up
        self.process(2064, 1, fds={0: "/dev/pts/7"})
        for pid in range(2000, 2064): self.process(pid, pid + 1)
        self.assertIsNone(self.find(2000))                   # the 65th process is one hop too far
        (self.proc / "2063" / "fd" / "0").symlink_to("/dev/pts/7")
        self.assertEqual(self.find(2000), "/dev/pts/7")      # the 64th is reached

    def test_pid_one_is_the_last_stop(self):
        self.process(5, 1); self.process(1, 0, fds={0: "/dev/pts/7"}); self.process(0, 0, fds={0: "/dev/pts/7"})
        self.assertEqual(self.find(5), "/dev/pts/7")
        self.proc.joinpath("1", "fd", "0").unlink()
        self.assertIsNone(self.find(5))

    def test_ancestor_named(self):
        self.process(300, 200, "bash"); self.process(200, 100, "tern"); self.process(100, 1, "init"); self.process(1, 0, "init")
        self.assertTrue(tern.ancestor_named("tern", 300, proc=str(self.proc)))
        self.assertFalse(tern.ancestor_named("kitty", 300, proc=str(self.proc)))
        self.assertFalse(tern.ancestor_named("tern", 300, proc=str(self.proc / "absent")))

    def test_default_truth_table(self):
        for terminal in ("", "/dev/pts/7"):
            for env in ({}, {"TERN_PANE": ""}, {"TERN_PANE": "5"}):
                for named in (False, True):
                    with self.subTest(terminal=terminal, env=env, named=named):
                        expected = bool(terminal) and (bool(env.get("TERN_PANE")) or named)
                        self.assertIs(tern.default_is_tern(env, terminal=terminal, named=named), expected)


class TitleTests(unittest.TestCase):
    def test_title_escape(self):
        self.assertEqual(tern.title_escape("glitch-idea"), b"\x1b]2;glitch-idea\x07")
        self.assertEqual(tern.title_escape("a" * 80), b"\x1b]2;" + b"a" * 80 + b"\x07")
        for bad in ("", "a" * 81, "A", "a b", "a\x07", "a\x1b", "a\n", "é", "a;b", "a/b", None, b"a"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                tern.title_escape(bad)

    def test_write_title_is_one_write_to_a_nocctty_descriptor(self):
        seen = []
        ok = tern.write_title("/x", "glitch-idea", opener=lambda p, f: seen.append((p, f)) or os.open(os.devnull, os.O_WRONLY),
                              writer=lambda fd, d: seen.append(d) or len(d))
        self.assertTrue(ok)
        self.assertEqual(seen[1], b"\x1b]2;glitch-idea\x07")
        self.assertEqual(len(seen), 2)
        self.assertTrue(seen[0][1] & os.O_NOCTTY and seen[0][1] & os.O_WRONLY)
        self.assertTrue(seen[0][1] & os.O_NONBLOCK)

    def test_write_title_short_write_is_false(self):
        calls = []
        ok = tern.write_title("/x", "glitch-idea", opener=lambda p, f: os.open(os.devnull, os.O_WRONLY),
                              writer=lambda fd, d: calls.append(d) or len(d) - 1)
        self.assertFalse(ok)
        self.assertEqual(len(calls), 1)  # one write, never a loop

    def test_write_title_would_block_is_false(self):
        def blocked(fd, data): raise BlockingIOError(11, "again")
        self.assertFalse(tern.write_title("/x", "glitch-idea", opener=lambda p, f: os.open(os.devnull, os.O_WRONLY),
                                          writer=blocked))

    def test_write_title_never_raises(self):
        def boom(*a): raise OSError("no")
        self.assertFalse(tern.write_title("/x", "glitch-idea", opener=boom))
        self.assertFalse(tern.write_title(os.devnull, "glitch-idea", writer=boom))
        self.assertFalse(tern.write_title(os.devnull, "BAD TITLE"))
        self.assertTrue(tern.write_title(os.devnull, "glitch-idea"))


if __name__ == "__main__":
    unittest.main()

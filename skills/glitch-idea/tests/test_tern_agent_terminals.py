"""SKILLS-160: find the pane through the account's own agent front end when the helper runs under a terminal-less daemon.

A fake /proc tree only: nothing here reads another process or writes to a real terminal.
"""
from pathlib import Path
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "glitch-idea/scripts"))
import idea_tern as tern

ME, OTHER = 1045, 1046
CODEX = {"CODEX_THREAD_ID": "019a-thread"}


def tty_nr(n):
    """The kernel's encoding of /dev/pts/<n> (majors 136 to 143)."""
    major, minor = 136 + n // 256, n % 256
    return ((minor & 0xfff00) << 12) | ((major & 0xfff) << 8) | (minor & 0xff)


class AgentTerminalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.proc = Path(self.temp.name)
        self.writable = {"/dev/pts/25", "/dev/pts/30", "/dev/pts/31"} | {"/dev/pts/%d" % n for n in range(40, 52)}

    def process(self, pid, parent, name="x", *, uid=ME, tty=0, environ=None, fds=None):
        d = self.proc / str(pid); (d / "fd").mkdir(parents=True)
        (d / "stat").write_text("%d (%s) S %d %d %d %d -1 4194560\n" % (pid, name, parent, pid, pid, tty))
        (d / "comm").write_text(name + "\n")
        (d / "status").write_text("Name:\t%s\nUmask:\t0022\nState:\tS\nUid:\t%d\t%d\t%d\t%d\nGid:\t1\t1\t1\t1\n" % (name, uid, uid, uid, uid))
        if environ is not None:
            (d / "environ").write_bytes(b"".join(("%s=%s" % kv).encode() + b"\0" for kv in environ.items()))
        for fd, target in (fds or {}).items():
            (d / "fd" / str(fd)).symlink_to(target)

    def kw(self):
        return dict(proc=str(self.proc), uid=ME, devcheck=lambda p: p in self.writable)

    def reported_shape(self):
        """codexbwai, 13 Nov: tern -> bash -> codex TUI on pts/25; the app-server daemon runs the helper with no terminal."""
        self.process(1, 0, "systemd")
        self.process(900, 1, "tern")
        self.process(1300, 900, "bash", tty=tty_nr(25), fds={0: "/dev/pts/25"})
        self.process(1361660, 1300, "codex", tty=tty_nr(25), environ={"TERN_PANE": "3"}, fds={0: "/dev/pts/25"})
        self.process(2000, 1, "codex", environ={})                              # app-server: no terminal
        self.process(2100, 2000, "bash", environ=CODEX, fds={0: "pipe:[1]", 1: "pipe:[2]", 2: "pipe:[3]"})
        self.process(2101, 2100, "python3", environ=CODEX, fds={0: "/dev/null", 1: "pipe:[4]", 2: "pipe:[5]"})

    # ---- the decode
    def test_tty_nr_decode_is_the_kernels(self):
        self.assertEqual(tty_nr(25), 34841)                       # read off the live TUI, 14 Nov
        self.assertEqual(tern._tty_path(34841), "/dev/pts/25")
        for n in (0, 7, 255, 256, 300, 1023, 2047):
            self.assertEqual(tern._tty_path(tty_nr(n)), "/dev/pts/%d" % n)
        for bad in (0, -1, (4 << 8) | 1, (5 << 8) | 0, (144 << 8) | 1, (135 << 8) | 1, None, "34841", 1.5, True):
            with self.subTest(bad=bad):
                self.assertIsNone(tern._tty_path(bad))

    # ---- the road
    def test_reported_shape_finds_the_tui_pane_as_version_two(self):
        self.reported_shape()
        self.assertIsNone(tern.find_terminal(2101, **self.kw()))
        self.assertEqual(tern.pane_terminals(CODEX, pid=2101, **self.kw()), (["/dev/pts/25"], 2))

    def test_claude_shape_keeps_the_ancestor_road_and_never_scans(self):
        self.reported_shape()
        self.process(3000, 900, "claude", tty=tty_nr(30), fds={0: "/dev/pts/30"})
        self.process(3001, 3000, "python3", environ={}, fds={0: "/dev/pts/30"})
        scanned = []
        real = tern._agent_candidates
        def spy(*a, **k):
            scanned.append(1); return real(*a, **k)
        tern._agent_candidates = spy
        self.addCleanup(setattr, tern, "_agent_candidates", real)
        self.assertEqual(tern.pane_terminals(CODEX, pid=3001, **self.kw()), (["/dev/pts/30"], 1))
        self.assertEqual(scanned, [])

    def test_no_marker_is_todays_behaviour(self):
        self.reported_shape()
        self.assertEqual(tern.pane_terminals({}, pid=2101, **self.kw()), ([], 1))
        self.assertEqual(tern.agent_terminals({"TERN_PANE": "3"}, **self.kw()), [])
        self.assertEqual(tern._agent_candidates({}, **self.kw()), [])

    def test_two_tuis_are_both_candidates_sorted(self):
        self.reported_shape()
        self.process(1400, 900, "codex", tty=tty_nr(31), environ={"TERN_PANE": "4"})
        self.assertEqual(tern.pane_terminals(CODEX, pid=2101, **self.kw()), (["/dev/pts/25", "/dev/pts/31"], 2))
        self.assertEqual(tern._agent_candidates(CODEX, **self.kw()), [(1361660, "/dev/pts/25"), (1400, "/dev/pts/31")])

    def test_two_processes_on_one_pane_are_one_terminal(self):
        self.reported_shape()
        self.process(1361700, 1361660, "codex", tty=tty_nr(25), environ={"TERN_PANE": "3"})
        self.assertEqual(tern.agent_terminals(CODEX, **self.kw()), ["/dev/pts/25"])

    def test_another_accounts_tui_is_never_a_candidate(self):
        self.reported_shape()
        self.process(1500, 900, "codex", uid=OTHER, tty=tty_nr(30), environ={"TERN_PANE": "5"})
        self.assertEqual(tern.agent_terminals(CODEX, **self.kw()), ["/dev/pts/25"])

    def test_a_tty_this_account_cannot_write_is_skipped(self):
        self.reported_shape()
        self.process(1500, 900, "codex", tty=tty_nr(33), environ={"TERN_PANE": "5"})   # pts/33 not writable
        self.assertEqual(tern.agent_terminals(CODEX, **self.kw()), ["/dev/pts/25"])

    def test_a_non_pts_tty_is_skipped(self):
        self.reported_shape()
        self.process(1500, 900, "codex", tty=(4 << 8) | 1, environ={"TERN_PANE": "5"})   # /dev/tty1, a console
        self.assertEqual(tern.agent_terminals(CODEX, **self.kw()), ["/dev/pts/25"])

    def test_another_program_on_a_pts_is_not_a_candidate(self):
        self.reported_shape()
        self.process(1500, 900, "claude", tty=tty_nr(30), environ={"TERN_PANE": "5"})
        self.process(1501, 900, "codexx", tty=tty_nr(31), environ={"TERN_PANE": "6"})
        self.assertEqual(tern.agent_terminals(CODEX, **self.kw()), ["/dev/pts/25"])

    def test_missing_proc_is_empty_and_never_raises(self):
        absent = dict(self.kw(), proc=str(self.proc / "absent"))
        self.assertEqual(tern._agent_candidates(CODEX, **absent), [])
        self.assertEqual(tern.agent_terminals(CODEX, **absent), [])
        self.assertEqual(tern.pane_terminals(CODEX, pid=2101, **absent), ([], 1))

    def test_a_process_that_vanishes_or_is_unreadable_mid_scan_is_skipped(self):
        self.reported_shape()
        self.process(1400, 900, "codex", tty=tty_nr(31), environ={"TERN_PANE": "4"})
        self.process(1100, 900, "codex", tty=tty_nr(30), environ={"TERN_PANE": "5"})
        (self.proc / "1100" / "stat").unlink()                          # gone between listdir and read
        self.process(1200, 900, "codex", tty=tty_nr(40), environ={"TERN_PANE": "6"})
        (self.proc / "1200" / "status").write_text("garbage")            # unreadable shape
        (self.proc / "self").mkdir()                                    # a non-pid entry
        self.assertEqual(tern.agent_terminals(CODEX, **self.kw()), ["/dev/pts/25", "/dev/pts/31"])

    def test_a_lone_candidate_not_in_tern_is_never_written(self):
        self.process(1, 0, "systemd")
        self.process(1300, 1, "bash", tty=tty_nr(25))
        self.process(1361660, 1300, "codex", tty=tty_nr(25), environ={"TERM_PROGRAM": "vscode"})
        self.process(2000, 1, "codex", environ={})
        self.process(2101, 2000, "python3", environ=CODEX)
        self.assertEqual([p for _, p in tern._agent_candidates(CODEX, **self.kw())], ["/dev/pts/25"])
        self.assertEqual(tern.agent_terminals(CODEX, **self.kw()), [])
        self.assertEqual(tern.pane_terminals(CODEX, pid=2101, **self.kw()), ([], 1))

    def test_in_tern_by_an_ancestor_named_tern_or_a_set_tern_pane(self):
        self.process(1, 0, "systemd"); self.process(900, 1, "tern")
        self.process(1300, 900, "codex", tty=tty_nr(25), environ={})                 # ancestor tern
        self.process(1400, 1, "codex", tty=tty_nr(30), environ={"TERN_PANE": "9"})   # env only
        self.process(1500, 1, "codex", tty=tty_nr(31), environ={"TERN_PANE": ""})    # empty: not in Tern
        self.assertEqual(tern.agent_terminals(CODEX, **self.kw()), ["/dev/pts/25", "/dev/pts/30"])

    def test_another_accounts_environ_is_never_read(self):
        self.reported_shape()
        self.process(1500, 1, "codex", uid=OTHER, tty=tty_nr(30), environ={"TERN_PANE": "5"})
        opened = []
        real_open = open
        def watch(path, *a, **k):
            opened.append(str(path)); return real_open(path, *a, **k)
        import builtins
        builtins.open = watch
        try:
            tern.agent_terminals(CODEX, **self.kw())
        finally:
            builtins.open = real_open
        self.assertNotIn(str(self.proc / "1500" / "environ"), opened)
        self.assertIn(str(self.proc / "1361660" / "environ"), opened)

    def test_a_lone_codex_exec_in_tern_gets_version_two_not_one(self):
        """The asker may be headless while another session's pane is the only candidate: focus-gated, never placed blind."""
        self.process(1, 0, "systemd"); self.process(900, 1, "tern")
        self.process(1400, 900, "codex", tty=tty_nr(31), environ={"TERN_PANE": "4"})   # `codex exec` in another pane
        self.process(2000, 1, "codex", environ={})
        self.process(2101, 2000, "python3", environ=CODEX)
        self.assertEqual(tern.pane_terminals(CODEX, pid=2101, **self.kw()), (["/dev/pts/31"], 2))

    def test_at_most_eight_terminals(self):
        self.process(1, 0, "systemd"); self.process(900, 1, "tern")
        for n in range(40, 52):
            self.process(5000 + n, 900, "codex", tty=tty_nr(n), environ={"TERN_PANE": str(n)})
        paths = tern.agent_terminals(CODEX, **self.kw())
        self.assertEqual(len(paths), 8)
        self.assertEqual(paths, sorted(paths, key=lambda p: int(p.rsplit("/", 1)[1])))

    def test_default_is_tern_takes_the_lookup(self):
        self.reported_shape()
        self.assertTrue(tern.default_is_tern(CODEX, terminal="", agents=["/dev/pts/25"]))
        self.assertFalse(tern.default_is_tern(CODEX, terminal="", agents=[]))
        self.assertFalse(tern.default_is_tern({}, terminal="", agents=[]))

    def test_the_marker_table_is_closed(self):
        self.assertEqual(tern.AGENT_FRONTS, {"CODEX_THREAD_ID": ("codex",)})


if __name__ == "__main__":
    unittest.main()

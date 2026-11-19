#!/usr/bin/env python3
"""SKILLS-210 / SKILLS-213: structuredquestions.sh prints the exact Guided-setup questions for a fixture host.

Hermetic: fake getent/id/sudo and fake provider CLIs on PATH, twelve neutral seat accounts plus the
operator "you", or the common case of one user. Nothing here touches a real account, provider or login.
Phase 1 asks only about accounts; phase 2 (given the labels) proposes the installs and asks the rest."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest

PACKAGE = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get("SPAWN_SQ_SCRIPT", PACKAGE / "structuredquestions.sh"))  # the override exists to show a test red on the old script
HERE = Path(__file__).parent
GOLDEN = HERE / "structuredquestions.golden.json"                 # phase 1, twelve seats
GOLDEN_P2 = HERE / "structuredquestions.phase2.golden.json"       # phase 2, twelve seats, einh's shape
GOLDEN_SINGLE = HERE / "structuredquestions.single.golden.json"   # both phases, one user, one install each
GOLDEN_TWO = HERE / "structuredquestions.twoinstall.golden.json"  # phase 2, one user, two Claude installs
GOLDEN_SHORT = HERE / "structuredquestions.short.golden.json"     # phase 2, one user, three Claude accounts, one install
PROVIDERS = ["claude", "codex", "kimi", "grok", "agy", "muse", "omp"]
SEATS = ["claudework", "claudehome", "codexone", "codextwo", "kimione", "grokone",
         "agyone", "agytwo", "agythree", "agyfour", "museone", "ompone"]
EINH = ["--accounts", "claude=Work,Home", "--accounts", "codex=One,Two", "--accounts", "agy=Four,Two,One,Three"]
HELP_ALL = "usage: tool [--dangerously-skip-permissions] [--dangerously-bypass-approvals-and-sandbox] [--yolo] [--auto] [--permission-mode default|bypassPermissions] [--approval-mode always-ask|yolo]\n"
LIMIT = "Claude 3: no third install or OS user found. Each Claude account needs its own install with its own login. Type its path, or skip it."
AGY = "Agy keeps its login per OS user; a second install may share the first one's login."


class Fixture:
    def __init__(self, base, seats=SEATS, operator_clis=PROVIDERS, help_text=HELP_ALL, glitch=True, sudo=True, no_cli=(), help_by=None, hang=(), omp_family="openai", fork=(), leak=(), groups="setsid",
                 extra_installs=(), others=()):
        self.base = Path(base)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        # A closed PATH: only these system tools, so a real provider CLI or sudo on the test machine never leaks in.
        self.sys = self.base / "sys"
        self.sys.mkdir()
        # No `timeout` here on purpose (macOS has none): the script must bound calls itself.
        for tool in ("sh", "awk", "grep", "mktemp", "rm", "cat", "env", "test", "true", "tail", "sed", "tr", "head", "od", "sleep", "kill", groups):
            found = shutil.which(tool)
            if found:
                (self.sys / tool).symlink_to(found)
        self.home = self.base / "home"
        self.seats = seats
        for account in ["you", *seats, *others]:
            (self.home / account / ".local/bin").mkdir(parents=True)
        for account in seats:
            provider = next(p for p in PROVIDERS if account.startswith(p))
            if account not in no_cli:
                self.cli(account, provider, (help_by or {}).get(account, help_text), hang=account in hang, mode=("fork" if account in fork else "leak" if account in leak else None), who=account)
        for account in others:  # an OS account not named for a provider that can run Claude
            self.cli(account, "claude", help_text)
        for provider in operator_clis:
            self.cli("you", provider, (help_by or {}).get("you", help_text), hang="you" in hang)
        # Further installs of the operator, in folders after ~/.local/bin on PATH: (folder, cli).
        self.extra_dirs = []
        for folder, provider in extra_installs:
            d = self.home / "you" / folder
            d.mkdir(parents=True, exist_ok=True)
            if d not in self.extra_dirs:
                self.extra_dirs.append(d)
            self.cli("you", provider, (help_by or {}).get(folder, help_text), where=d)
        omp = self.home / "ompone/.omp/agent"
        omp.mkdir(parents=True)
        (omp / "config.yml").write_text("modelRoles:\n  default: anthropic/claude-model\nsetupVersion: 3\n")
        mine = self.home / "you/.omp/agent"
        mine.mkdir(parents=True)
        (mine / "config.yml").write_text(f"modelRoles:\n  default: {omp_family}/some-model\n")
        passwd = "".join(f"{a}:x:{1100 + i}:{1100 + i}::{self.home / a}:/bin/bash\n" for i, a in enumerate([*seats, *others]))
        passwd += f"you:x:1000:1000::{self.home / 'you'}:/bin/bash\n"
        passwd += "nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin\nclaudeservice:x:1200:1200::/nonexistent:/usr/sbin/nologin\n"
        passwd += "root:x:0:0::/root:/bin/bash\nplainuser:x:1300:1300::/home/plainuser:/bin/bash\n"
        (self.base / "passwd").write_text(passwd)
        self.script("getent", '[ "$1" = passwd ] && cat "$FIX/passwd"\n')
        self.script("id", 'echo you\n')
        if sudo:
            self.script("sudo", f'''printf '%s\n' "$*" >> "$FIX/sudo.log"
[ "$1" = -n ] || exit 1
shift
[ "$1" = true ] && exit 1   # this operator may use the per-seat login route but is not allowed root
[ "$1" = -i ] && [ "$2" = -u ] || exit 1
account=$3; shift 3
[ "$1" = -- ] || exit 1
shift
[ -d "$FIX/home/$account" ] || exit 1
cd "$FIX/home/$account" || exit 1
exec env -i FIX="$FIX" HOME="$FIX/home/$account" PATH="$FIX/home/$account/.local/bin:$FIX/sys" "$@"
''')
        self.glitch = self.base / "glitch"
        if glitch:
            self.make_glitch(self.glitch)
        (self.base / "nothing").mkdir()

    @staticmethod
    def make_glitch(root):
        (root / ".claude/scripts").mkdir(parents=True)
        (root / ".claude/scripts/workspaces.py").write_text("x")
        (root / ".claude/scripts/plan_check.py").write_text("x")

    def script(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def cli(self, account, provider, help_text, hang=False, mode=None, who="", where=None):
        path = (where or self.home / account / ".local/bin") / provider
        body = "sleep 300\n" if hang else f"printf '%s' '{help_text}'\n"
        if mode == "fork":    # forks a child, then hangs: the child must not outlive the script
            body = f'sleep 301 &\necho $! > "$FIX/child-{who}.pid"\nsleep 300\n'
        elif mode == "leak":  # answers, exits at once and leaves a child behind
            body = f"sleep 302 &\necho $! > \"$FIX/child-{who}.pid\"\nprintf '%s' '{help_text}'\n"
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run(self, *extra, cwd=None, timeout=120, seconds="20"):
        path = ":".join([str(self.bin), str(self.home / "you/.local/bin"), *map(str, self.extra_dirs), str(self.sys)])
        env = {"SPAWN_QUESTIONS_TIMEOUT": seconds, "PATH": path, "HOME": str(self.home / "you"),
               "FIX": str(self.base), "TMPDIR": str(self.base), "SPAWN_QUESTIONS_SYSTEM_GLITCH": str(self.base / "no-system-glitch")}
        args = ["/bin/sh", str(SCRIPT), "--cwd", str(cwd or self.base / "nothing"), *extra]
        return subprocess.run(args, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return Path(f"/proc/{pid}/stat").read_text().split(")")[-1].split()[0] != "Z"


def decode_login(line):
    """A logged sudo call -> (account, decoded program text), or None when it is not the login wrapper."""
    m = re.match(r"^-n -i -u (\S+) -- /bin/sh -c eval \"\$\(printf \"\$\{1\}\"\)\" spawn-login (.+)$", line)
    if not m:
        return None
    return m.group(1), re.sub(r"\\([0-7]{3})", lambda o: chr(int(o.group(1), 8)), m.group(2))


def questions(data):
    return [q for p in data["prompts"] for q in p["questions"]]


def by_id(data, prompt_id):
    return next(p for p in data["prompts"] if p["id"] == prompt_id)


def q_id(data, qid):
    return next(q for q in questions(data) if q["id"] == qid)


def labels(question):
    return [o["label"] for o in question["options"]]


def lines(data, prompt_id):
    return by_id(data, prompt_id).get("lines", [])


def agents(data):
    return {a["id"]: a for a in data["derived"]["accounts"]}


class StructuredQuestions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="spawn sq ")
        self.addCleanup(self.tmp.cleanup)

    def fixture(self, name=None, **kwargs):
        base = Path(self.tmp.name) / (name or f"fx {len(list(Path(self.tmp.name).iterdir()))}")
        base.mkdir()
        return Fixture(base, **kwargs)

    def output(self, fx, *extra, cwd=None):
        done = fx.run(*extra, cwd=cwd)
        self.assertEqual((done.returncode, done.stderr), (0, ""), done.stdout + done.stderr)
        return json.loads(done.stdout)

    def refused(self, fx, *extra):
        done = fx.run(*extra)
        self.assertEqual(done.returncode, 3, done.stdout + done.stderr)
        data = json.loads(done.stdout)
        self.assertFalse(data["ok"])
        return data["why"]

    def golden(self, path, data, fx):
        text = json.dumps(data, ensure_ascii=False, indent=1, sort_keys=False).replace(str(fx.base), "@FIX@")
        if os.environ.get("UPDATE_GOLDEN"):
            path.write_text(text + "\n")
        self.assertEqual(text + "\n", path.read_text(), f"output differs from tests/{path.name}")

    # ---- phase 1: accounts only ----
    def test_phase1_twelve_seats_exact_output(self):
        fx = self.fixture()
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        self.assertEqual(data["phase"], 1)
        # einh's wording: providers only, no counts and no account names.
        self.assertEqual(data["intro"], ["Found on this machine: Claude, Codex, Kimi, Grok, Agy, Muse, OMP.", f"Glitch folder detected: {fx.glitch}."])
        self.golden(GOLDEN, data, fx)

    def test_phase1_asks_the_gate_providers_count_and_labels(self):
        fx = self.fixture()
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        self.assertEqual([p["id"] for p in data["prompts"]], ["accounts", "providers", "count", "labels"])
        gate = q_id(data, "multi")
        self.assertEqual((gate["question"], labels(gate), [o["preselected"] for o in gate["options"]]),
                         ("Are there any providers for which you have more than one account?", ["No", "Yes"], [True, False]))
        picks = [q for q in questions(data) if q["id"].startswith("providers")]
        self.assertEqual([q["question"] for q in picks], ["Which providers have more than one account? (1 of 2)", "Which providers have more than one account? (2 of 2)"])
        self.assertEqual([labels(q) for q in picks], [["Claude", "Codex", "Kimi", "Grok"], ["Agy", "Muse", "OMP"]])
        self.assertEqual([o["value"] for q in picks for o in q["options"]], PROVIDERS)
        self.assertTrue(all(q["multiSelect"] and q["when"] == {"question": "multi", "is": "Yes"} for q in picks))
        count = q_id(data, "count")
        self.assertEqual((count["question"], labels(count)), ("How many {provider} accounts?", ["2", "3", "4"]))
        self.assertEqual((count["for_each"], count["other"]), ({"questions": ["providers-1", "providers-2"]}, {"whole_number": [2, 16]}))
        names = q_id(data, "labels")
        self.assertEqual((names["question"], labels(names)), ("Labels for your {N} {provider} accounts?", ["Number them ({provider} 1, {provider} 2)", "Type my own labels"]))
        self.assertEqual(([o.get("value") for o in names["options"]], names["for_each_count"]), (["numbered", "typed"], {"question": "count"}))
        self.assertEqual(data["next"], {"argv": ["--phase", "2"], "per_answer": {"question": "labels", "argv": ["--accounts", "{cli}={labels}"]},
                                        "numbered": "{provider} 1,{provider} 2,...,{provider} {N}"})

    def test_phase1_never_proposes_a_label_or_names_an_account(self):
        # einh: "dont propose labels, BWAI and KK are me-only labels". Seat names chosen so no English word contains them.
        seats = ["claudeqzx", "claudewvk", "codexjrm", "agyplu", "agyxor"]
        fx = self.fixture(seats=seats, extra_installs=[("acctbzz", "claude")])
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        forbidden = [*seats, "qzx", "wvk", "jrm", "plu", "xor", "acctbzz", str(fx.home)]
        shown = [q["question"] for q in questions(data)] + [p["title"] for p in data["prompts"]]
        shown += [t for q in questions(data) for o in q["options"] for t in (o["label"], o["description"], str(o.get("value", "")))]
        for text in shown:
            for word in forbidden:
                self.assertNotIn(word.lower(), text.lower(), f"phase 1 shows {word!r}: {text!r}")
        self.assertNotIn("accounts", data["derived"], "phase 1 carries no account rows")
        self.assertIn(f"Glitch folder detected: {fx.glitch}.", data["intro"], "the Glitch intro line keeps its path")

    def test_phase1_one_provider_skips_the_provider_question(self):
        fx = self.fixture(seats=[], operator_clis=["claude"])
        data = self.output(fx)
        self.assertEqual([p["id"] for p in data["prompts"]], ["accounts", "count", "labels"])
        self.assertEqual(q_id(data, "count")["for_each"], {"items": [{"label": "Claude", "value": "claude"}]})
        self.assertEqual(data["intro"][:2], ["Found on this machine: Claude.", "Not found: Codex, Kimi, Grok, Agy, Muse, OMP."])

    def test_missing_providers_and_missing_glitch_are_said_plainly(self):
        fx = self.fixture(seats=["claudework", "claudehome"], operator_clis=["claude", "codex"])
        data = self.output(fx)
        self.assertEqual(data["intro"][0], "Found on this machine: Claude, Codex.")
        self.assertEqual(data["intro"][1], "Not found: Kimi, Grok, Agy, Muse, OMP.")
        self.assertRegex(data["intro"][2], r"^Glitch folder: not found in .+no-system-glitch.+Glitch.+the launch folder and its parents\.$")
        p2 = self.output(fx, "--phase", "2")
        self.assertNotIn("folder", [p["id"] for p in p2["prompts"]], "no Glitch: the folder question is not asked")
        self.assertEqual({a["home"] for a in p2["derived"]["accounts"]}, {str(fx.home / "claudehome"), str(fx.home / "you")}, "one account: the first seat in name order")

    def test_an_account_without_the_cli_is_unavailable_never_substituted(self):
        fx = self.fixture(no_cli=("agyfour",))
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        self.assertIn("Unavailable: agyfour (it has no agy it can run).", data["intro"])
        p2 = self.output(fx, "--glitch-root", str(fx.glitch), *EINH)
        self.assertNotIn("agyfour", [a["account"] for a in p2["derived"]["accounts"]])
        self.assertNotIn("agyfour", [c["account"] for c in p2["derived"]["candidates"]])

    def test_without_sudo_seat_accounts_are_not_guessed(self):
        fx = self.fixture(sudo=False)
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        self.assertTrue(any("sudo is not installed" in line for line in data["intro"]))
        p2 = self.output(fx, "--glitch-root", str(fx.glitch), "--phase", "2")
        self.assertTrue(all(c["operator"] for c in p2["derived"]["candidates"]))

    # ---- phase 2: the mapping ----
    def test_phase2_twelve_seats_map_by_label_exact_output(self):
        fx = self.fixture()
        data = self.output(fx, "--glitch-root", str(fx.glitch), *EINH)
        self.assertEqual(data["phase"], 2)
        self.golden(GOLDEN_P2, data, fx)
        got = {a["id"]: (a["account"], a["account_label"]) for a in data["derived"]["accounts"]}
        self.assertEqual(got, {
            "claude-work": ("claudework", "Work"), "claude-home": ("claudehome", "Home"), "codex-one": ("codexone", "One"),
            "codex-two": ("codextwo", "Two"), "kimi": ("kimione", "Kimi"), "grok": ("grokone", "Grok"),
            "agy-four": ("agyfour", "Four"), "agy-two": ("agytwo", "Two"), "agy-one": ("agyone", "One"), "agy-three": ("agythree", "Three"),
            "muse": ("museone", "Muse"), "omp": ("ompone", "OMP")})
        mapping = q_id(data, "mapping")
        self.assertEqual((mapping["question"], labels(mapping)), ("Use this mapping?", ["Use it (Recommended)", "Change some"]))
        rows = lines(data, "mapping")
        self.assertEqual(rows[0], f"Claude Work — claudework — {fx.home}/claudework/.local/bin/claude")
        self.assertIn(f"Not used for Claude: you (you) — {fx.home}/you/.local/bin/claude.", rows, "the operator is listed as not used")
        for a in data["derived"]["accounts"]:
            self.assertTrue(a["command"].startswith(f"{fx.home}/{a['account']}/"), "an agent never gets another account's CLI path")
            self.assertEqual(a["home"], str(fx.home / a["account"]))

    def test_one_user_one_install_is_one_confirm(self):
        fx = self.fixture(seats=[])
        first = self.output(fx, "--glitch-root", str(fx.glitch))
        data = self.output(fx, "--glitch-root", str(fx.glitch), "--phase", "2")
        self.golden(GOLDEN_SINGLE, {"phase1": first, "phase2": data}, fx)
        mapping = q_id(data, "mapping")
        self.assertEqual((mapping["question"], labels(mapping)), ("All agents run as you?", ["Yes (Recommended)", "Change some"]))
        self.assertEqual(lines(data, "mapping"), [], "the table is not shown when everything is the first install")
        self.assertEqual({a["id"]: a["account_label"] for a in data["derived"]["accounts"]},
                         {p: n for p, n in zip(PROVIDERS, ["Claude", "Codex", "Kimi", "Grok", "Agy", "Muse", "OMP"])})
        self.assertTrue(all(a["operator"] and a["account"] == "you" for a in data["derived"]["accounts"]))
        # The common case reaches the review after: accounts gate, this confirm, the permission gate and the folder.
        self.assertEqual([p["id"] for p in data["prompts"]], ["mapping", "permissions", "permission-modes-1", "permission-modes-2", "folder", "folder-agents", "omp", "review"])

    def test_two_installs_under_one_user_map_to_two_accounts(self):
        fx = self.fixture(seats=[], operator_clis=["claude"], extra_installs=[("acct2", "claude")])
        data = self.output(fx, "--accounts", "claude=Claude 1,Claude 2")
        self.golden(GOLDEN_TWO, data, fx)
        a = agents(data)
        self.assertEqual((a["claude-1"]["command"], a["claude-2"]["command"]), (f"{fx.home}/you/.local/bin/claude", f"{fx.home}/you/acct2/claude"))
        self.assertEqual(q_id(data, "mapping")["question"], "All agents run as you?")
        self.assertEqual(lines(data, "mapping"), [f"Claude 1 — you (you) — {fx.home}/you/.local/bin/claude", f"Claude 2 — you (you) — {fx.home}/you/acct2/claude"],
                         "a second install in use shows the table")
        # A label naming the install's folder takes it, whatever its place on PATH.
        named = agents(self.output(fx, "--accounts", "claude=acct2,Main"))
        self.assertEqual((named["claude-acct2"]["command"], named["claude-main"]["command"]), (f"{fx.home}/you/acct2/claude", f"{fx.home}/you/.local/bin/claude"))

    def test_an_account_with_no_install_left_gets_the_limitation_sentence(self):
        fx = self.fixture(seats=[], operator_clis=["claude", "agy"], extra_installs=[("acct2", "claude")])
        data = self.output(fx, "--accounts", "claude=Claude 1,Claude 2,Claude 3", "--accounts", "agy=KK,BWAI")
        self.golden(GOLDEN_SHORT, data, fx)
        self.assertIn(LIMIT, lines(data, "mapping"))
        self.assertIn("Agy BWAI: no second install or OS user found. Each Agy account needs its own install with its own login. Type its path, or skip it.", lines(data, "mapping"))
        self.assertEqual(lines(data, "mapping")[-1], AGY)
        q = q_id(data, "missing-claude-3")
        self.assertEqual((q["question"], labels(q), q["agent_id"]), ("Claude 3: type its path, or skip it?", ["Skip it (Recommended)", "Type its path"], "claude-3"))
        self.assertNotIn("claude-3", agents(data))
        self.assertEqual([m["id"] for m in data["derived"]["missing"]], ["claude-3", "agy-bwai"])
        # Two Agy installs under one OS user: the warning is said even when nothing is missing.
        fx2 = self.fixture(seats=[], operator_clis=["agy"], extra_installs=[("second", "agy")])
        self.assertIn(AGY, lines(self.output(fx2, "--accounts", "agy=A,B"), "mapping"))
        self.assertNotIn(AGY, lines(self.output(fx2, "--accounts", "agy=A,B", "--skip", "agy-b"), "mapping"))

    def test_other_os_accounts_are_listed_never_proposed(self):
        # "every OS user with the CLI" is a candidate; one not named for the provider is only proposed when chosen.
        fx = self.fixture(seats=[], operator_clis=["claude"], others=("partner",))
        data = self.output(fx, "--accounts", "claude=Mine,Theirs")
        self.assertEqual(agents(data)["claude-mine"]["account"], "you")
        self.assertNotIn("claude-theirs", agents(data))
        self.assertIn("Claude Theirs: no second install or OS user found. Each Claude account needs its own install with its own login. Type its path, or skip it.", lines(data, "mapping"))
        self.assertIn(f"Not used for Claude: partner — {fx.home}/partner/.local/bin/claude.", lines(data, "mapping"))
        chosen = self.output(fx, "--accounts", "claude=Mine,Theirs", "--map", "claude-theirs=partner#1")
        self.assertEqual((agents(chosen)["claude-theirs"]["account"], agents(chosen)["claude-theirs"]["operator"]), ("partner", False))
        self.assertEqual(q_id(chosen, "mapping")["question"], "Use this mapping?")

    def test_a_label_matching_another_accounts_folder_never_proposes_it(self):
        # Kimi review round 1, P1: pass 1 matched every candidate's folder, so a label could pick another person's login.
        fx = self.fixture(seats=[], operator_clis=[], others=("partner",))
        data = self.output(fx, "--accounts", "claude=Bin,Other")
        self.assertEqual(agents(data), {}, "another OS account is never proposed, even when a label names its folder")
        self.assertEqual([m["id"] for m in data["derived"]["missing"]], ["claude-bin", "claude-other"])
        chosen = agents(self.output(fx, "--accounts", "claude=Bin,Other", "--map", "claude-bin=partner#1"))
        self.assertEqual(chosen["claude-bin"]["account"], "partner", "it is used once chosen")

    def test_a_typed_folder_is_not_an_install(self):
        # Kimi review round 1, P2: `test -x` accepts a searchable folder for another account.
        fx = self.fixture()
        for path in (fx.home / "claudework/.local", fx.home / "you/.local"):
            why = self.refused(fx, *EINH, "--map", f"claude-work={path}")
            self.assertIn("cannot run", why, path)

    def test_the_last_map_for_an_agent_wins(self):
        # Kimi review round 1, P2: the rerun argv repeats earlier answers; stale overrides kept installs reserved.
        fx = self.fixture()
        same = agents(self.output(fx, *EINH, "--map", "claude-work=you#1", "--map", "claude-work=you#1"))
        self.assertEqual(same["claude-work"]["account"], "you")
        data = self.output(fx, *EINH, "--map", "claude-work=you#1", "--map", "claude-work=claudework#1")
        self.assertEqual(agents(data)["claude-work"]["account"], "claudework")
        used = {c["key"]: c["used_by"] for c in data["derived"]["candidates"] if c["provider"] == "Claude"}
        self.assertEqual(used["you#1"], "", "an earlier override reserves nothing")
        typed = self.output(fx, *EINH, "--map", f"claude-work={fx.home}/you/.local/bin/claude", "--map", "claude-work=claudework#1")
        self.assertEqual(agents(typed)["claude-work"]["command"], f"{fx.home}/claudework/.local/bin/claude", "a key after a typed path wins")

    def test_text_that_is_not_utf8_is_refused_never_printed(self):
        # Kimi review round 1, P2: a POSIX argv byte 0xFF passed --check-args and broke the JSON.
        done = subprocess.run([b"/bin/sh", bytes(SCRIPT), b"--check-args", b"omp", b"--ok", b"a\xffb"], capture_output=True, stdin=subprocess.DEVNULL)
        self.assertEqual((done.returncode, json.loads(done.stdout.decode("utf-8"))), (3, {"ok": False, "why": "Arguments must be valid UTF-8 text."}))
        for bad in (b"\xc0\xaf", b"\xed\xa0\x80", b"\xe2\x82"):
            done = subprocess.run([b"/bin/sh", bytes(SCRIPT), b"--check-args", b"omp", bad], capture_output=True, stdin=subprocess.DEVNULL)
            self.assertEqual(done.returncode, 3, bad)
        ok = subprocess.run([b"/bin/sh", bytes(SCRIPT), b"--check-args", b"omp", "--name=Ünï😀".encode()], capture_output=True, stdin=subprocess.DEVNULL)
        self.assertEqual(json.loads(ok.stdout.decode("utf-8"))["arguments"], ["--name=Ünï😀"])
        fx = self.fixture(seats=[], operator_clis=["claude"])
        done = fx.run("--accounts", "claude=Good,Bad\udcff")
        self.assertEqual((done.returncode, json.loads(done.stdout)["why"]), (3, "Every answer must be valid UTF-8 text."))
        # Kimi review round 2: every other text that reaches the JSON goes through one gate.
        done = fx.run("--phase", "2", "--map", "claude=/x\udcff", "--map", "claude=you#1")
        self.assertEqual((done.returncode, json.loads(done.stdout)["why"]), (3, "Every answer must be valid UTF-8 text."), "an overridden answer is still in rerun.argv")
        for phase in ((), ("--phase", "2")):
            done = fx.run(*phase, cwd="/tmp/a\udcffb")
            self.assertEqual((done.returncode, json.loads(done.stdout)["why"]), (3, "The launch folder must be valid UTF-8 text."), phase)
        bad_root = fx.base / "g\udcff"
        Fixture.make_glitch(bad_root)
        data = self.output(fx, "--glitch-root", str(bad_root))
        self.assertTrue(all("g\ufffd" not in line and "Glitch folder detected" not in line for line in data["intro"]), "a Glitch folder that is not UTF-8 is not offered")

    def test_a_seat_named_with_a_dash_maps_like_any_other(self):
        fx = self.fixture(seats=["claude-work", "claudehome"], operator_clis=[])
        a = agents(self.output(fx, "--accounts", "claude=Home,Work"))
        self.assertEqual((a["claude-work"]["account"], a["claude-home"]["account"]), ("claude-work", "claudehome"))

    def test_map_and_skip_overrides(self):
        fx = self.fixture()
        data = self.output(fx, "--glitch-root", str(fx.glitch), *EINH, "--map", "claude-work=you#1", "--skip", "agy-three", "--skip", "muse")
        a = agents(data)
        self.assertEqual((a["claude-work"]["account"], a["claude-work"]["command"]), ("you", f"{fx.home}/you/.local/bin/claude"))
        self.assertEqual(a["claude-home"]["account"], "claudehome")
        self.assertNotIn("agy-three", a)
        self.assertNotIn("muse", a)
        self.assertEqual(data["derived"]["rerun"]["argv"], ["--phase", "2", *EINH, "--map", "claude-work=you#1", "--skip", "agy-three", "--skip", "muse"])
        used = {c["key"]: c["used_by"] for c in data["derived"]["candidates"] if c["provider"] == "Claude"}
        self.assertEqual(used, {"claudework#1": "", "claudehome#1": "claude-home", "you#1": "claude-work"})
        # A typed path is checked as the account that will run it (the one whose home holds it, else the operator).
        typed = self.output(fx, *EINH, "--map", f"claude-work={fx.home}/claudework/.local/bin/claude")
        self.assertEqual(agents(typed)["claude-work"]["account"], "claudework")
        self.assertIn("cannot run", self.refused(fx, *EINH, "--map", "claude-work=/nowhere/claude"))

    def test_refused_answers_say_why(self):
        fx = self.fixture()
        self.assertEqual(self.refused(fx, "--accounts", "claude=Work,work"), 'Two Claude accounts have the label "work".')
        self.assertEqual(self.refused(fx, "--accounts", "claude=Work, ,Home"), "A Claude label is empty.")
        self.assertEqual(self.refused(fx, "--accounts", "claude=" + "x" * 33), 'The Claude label "' + "x" * 33 + '" is longer than 32 characters.')
        self.assertEqual(self.refused(fx, "--accounts", "claude=a\tb"), "A Claude label has a control character, such as a tab or a line break.")
        self.assertEqual(self.refused(fx, "--accounts", "claude=" + ",".join(map(str, range(17)))), "At most 16 Claude accounts.")
        self.assertEqual(self.refused(fx, "--accounts", "claude=A", "--accounts", "claude=B"), "Claude accounts were given twice.")
        self.assertEqual(self.refused(fx, "--accounts", "nope=A"), "SPAWN knows no CLI with that name.")
        self.assertEqual(self.refused(fx, "--skip", "claude-nobody"), 'No agent has the ID "claude-nobody".')
        self.assertEqual(self.refused(fx, *EINH, "--map", "claude-work=codexone#1"), '"codexone#1" is not a Claude install found on this machine.')
        self.assertEqual(self.refused(fx, *EINH, "--map", "claude-work=claudehome#1", "--map", "claude-home=claudehome#1"), "Two agents cannot use the same install: claudehome#1.")
        self.assertEqual(self.refused(fx, *EINH, "--map", "claude-work=claudehome#1", "--map", f"claude-home={fx.home}/claudehome/.local/bin/claude"), "Two agents cannot use the same install: claudehome#1.")
        loose = fx.home / "you/loose/claude"  # an install not on any PATH, typed for two agents
        loose.parent.mkdir()
        loose.write_text("#!/bin/sh\n")
        loose.chmod(0o755)
        self.assertEqual(self.refused(fx, *EINH, "--map", f"claude-work={loose}", "--map", f"claude-home={loose}"), "claude-work and claude-home would run the same install as the same account, so they would share one login.")
        self.assertEqual(agents(self.output(fx, *EINH, "--map", "claude-work=claudehome#1"))["claude-home"]["account"], "claudework", "an override wins; the rest adapt in candidate order")
        none = self.fixture(seats=[], operator_clis=["claude"])
        self.assertEqual(self.refused(none, "--accounts", "codex=A,B"), "No Codex was found on this machine, so it cannot have accounts.")
        # Labels keep their own characters; IDs are slugs, unique per provider.
        ok = self.output(none, "--accounts", "claude=Ünïcode Work!,Work")
        self.assertEqual({k: v["account_label"] for k, v in agents(ok).items()}, {"claude-n-code-work": "Ünïcode Work!"})
        self.assertEqual([(m["id"], m["account_label"]) for m in ok["derived"]["missing"]], [("claude-work", "Work")])

    def test_each_seat_resolves_as_its_own_account_through_sudo_login(self):
        fx = self.fixture()
        data = self.output(fx, "--glitch-root", str(fx.glitch), *EINH)
        log = (fx.base / "sudo.log").read_text().splitlines()
        calls = [decode_login(line) for line in log]
        self.assertNotIn(None, calls, "every seat call is the constant login wrapper with one encoded word")
        self.assertNotIn("-n true", log, "root is never probed: only the per-account route")
        walks = [(acct, text) for acct, text in calls if "'spawn-walk'" in text]
        self.assertEqual(sorted(acct for acct, _ in walks), sorted([*SEATS, "plainuser"]), "one PATH walk per OS login account, named for a provider or not")
        self.assertTrue(all(text.endswith("'spawn-walk' 'claude' 'codex' 'kimi' 'grok' 'agy' 'muse' 'omp'") for _, text in walks))
        for account in ("claudework", "grokone", "ompone"):
            provider = next(p for p in PROVIDERS if account.startswith(p))
            self.assertIn((account, f"exec '{fx.home}/{account}/.local/bin/{provider}' '--help'"), calls)
        self.assertEqual(agents(data)["omp"]["provider_family"], "anthropic", "an OMP seat's family is read from its own config")

    def test_permission_gate_then_per_agent_choices(self):
        fx = self.fixture(help_by={"claudehome": "usage: claude [--other]\n"})
        data = self.output(fx, "--glitch-root", str(fx.glitch), *EINH)
        gate = q_id(data, "perm-gate")
        self.assertEqual((gate["question"], labels(gate)), ("Do you want to set special permission modes to start some of these agents with?", ["No, all Default (Recommended)", "Yes"]))
        per = [q for q in questions(data) if q["id"].startswith("perm-") and q["id"] != "perm-gate"]
        self.assertEqual(len(per), 12)
        self.assertTrue(all(q["when"] == {"question": "perm-gate", "is": "Yes"} for q in per))
        self.assertEqual(labels(q_id(data, "perm-claude-work")), ["Default (no arguments)", "YOLO (--dangerously-skip-permissions)", "Custom (type the arguments)"])
        self.assertEqual(labels(q_id(data, "perm-claude-home")), ["Default (no arguments)", "Custom (type the arguments)"], "YOLO is dropped where --help lacks it")
        self.assertIn("YOLO is not offered for Claude Home: its --help does not show --dangerously-skip-permissions.", lines(data, "permission-modes-1"))
        yolo = {k: v[-1]["arguments"] for k, v in data["derived"]["permissions"].items() if len(v) == 2}
        self.assertEqual(yolo, {"claude-work": ["--dangerously-skip-permissions"], "codex-one": ["--dangerously-bypass-approvals-and-sandbox"], "codex-two": ["--dangerously-bypass-approvals-and-sandbox"],
                                "kimi": ["--auto"], "grok": ["--permission-mode", "bypassPermissions"], "agy-four": ["--dangerously-skip-permissions"],
                                "agy-two": ["--dangerously-skip-permissions"], "agy-one": ["--dangerously-skip-permissions"], "agy-three": ["--dangerously-skip-permissions"],
                                "muse": ["--yolo"], "omp": ["--approval-mode", "yolo"]})
        self.assertEqual(data["derived"]["permissions"]["claude-home"], [{"label": "Default (no arguments)", "arguments": []}])
        self.assertNotIn("Ask when needed", json.dumps(data), "Kimi's --yolo choice is gone: einh's three choices")

    def test_custom_arguments_are_checked_as_data(self):
        # --check-args is the first argument and needs no discovery: run the script directly.
        script = lambda *a: subprocess.run(["/bin/sh", str(SCRIPT), *a], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        done = script("--check-args", "omp", "--profile", "work", "--model=a/b:c@1")
        self.assertEqual((done.returncode, json.loads(done.stdout)), (0, {"ok": True, "arguments": ["--profile", "work", "--model=a/b:c@1"]}))
        for word, why in ((";", "a semicolon (;)"), ("$HOME", "a dollar sign ($)"), ("`x`", "a backtick (`)"), ("a'b", "a single quote (')"), ('a"b', 'a double quote (")'),
                          ("a\\b", "a backslash (\\)"), ("a|b", "a vertical bar (|)"), ("~/x", "a tilde (~)"), ("*", "an asterisk (*)"), ("(x)", "a parenthesis (()")):
            done = script("--check-args", "omp", "--ok", word)
            self.assertEqual((done.returncode, json.loads(done.stdout)), (3, {"ok": False, "why": f"Arguments cannot contain {why}."}), word)
        for words, why in ((["a\tb"], "Arguments cannot contain control characters, such as a tab or a line break."), ([""], "An argument is empty."),
                           (["=x"], "An argument cannot start with =."), ([], "Type at least one argument.")):
            done = script("--check-args", "omp", *words)
            self.assertEqual(json.loads(done.stdout)["why"], why)
        self.assertEqual(json.loads(script("--check-args", "nope", "a").stdout)["why"], "SPAWN knows no such CLI.")

    def test_folder_all_choose_none_and_glitch_choices(self):
        fx = self.fixture(seats=[], operator_clis=["claude", "codex"])
        data = self.output(fx, "--glitch-root", str(fx.glitch), "--phase", "2")
        folder = q_id(data, "folder")
        self.assertEqual((folder["question"], labels(folder)), (f"I detected Glitch at {fx.glitch}. Would you like to start all these agents within Glitch?", ["All (Recommended)", "Choose per agent", "None"]))
        pick = q_id(data, "folder-agents")
        self.assertEqual((labels(pick), [o["value"] for o in pick["options"]], pick["when"], pick["multiSelect"]),
                         (["Claude", "Codex"], ["claude", "codex"], {"question": "folder", "is": "Choose per agent"}, True))
        one = self.output(self.fixture(seats=[], operator_clis=["claude"]), "--glitch-root", str(fx.glitch), "--phase", "2")
        self.assertEqual(labels(q_id(one, "folder")), ["All (Recommended)", "None"], "one agent: no per-agent choice")
        self.assertNotIn("folder-agents", [p["id"] for p in one["prompts"]])
        # Two roots: which one first, then the same question; more than three: Other, and the rest named.
        roots = [fx.glitch]
        for n in range(3):
            extra = fx.base / f"glitch{n}"
            Fixture.make_glitch(extra)
            roots.append(extra)
        two = self.output(fx, "--glitch-root", str(roots[0]), "--glitch-root", str(roots[1]), "--phase", "2")
        which = q_id(two, "glitch-root")
        self.assertEqual((which["question"], labels(which), sum(o["preselected"] for o in which["options"])), ("Which Glitch folder?", [str(roots[0]), str(roots[1])], 0))
        self.assertEqual(q_id(two, "folder")["question"], "Would you like to start all these agents within Glitch?")
        four = self.output(fx, *[a for r in roots for a in ("--glitch-root", str(r))], "--phase", "2")
        self.assertEqual(len(q_id(four, "glitch-root")["options"]), 3)
        self.assertTrue(any(line.startswith("More Glitch folders found, not listed as choices") and str(roots[3]) in line for line in lines(four, "folder")))

    def test_omp_service_per_omp_agent(self):
        fx = self.fixture(seats=["ompone"], operator_clis=["omp"], omp_family="moonshot")
        data = self.output(fx, "--accounts", "omp=Seat,Mine")
        self.assertEqual({q["agent_id"]: labels(q) for q in by_id(data, "omp")["questions"]},
                         {"omp-seat": ["anthropic (from its config) (Recommended)", "openai", "google"], "omp-mine": ["moonshot (from its config) (Recommended)", "openai", "google"]})
        self.assertEqual(q_id(data, "omp-omp-seat")["question"], "Which service runs omp-seat's model?")
        self.assertEqual({a["id"]: a["provider_family"] for a in data["derived"]["accounts"]}, {"omp-seat": "anthropic", "omp-mine": "moonshot"})
        self.assertEqual(data["derived"]["omp_prompt"], "Follow the explicitly assigned task. Role text is guidance, not identity isolation.")

    def test_limits_and_absolutes_on_every_output(self):
        outputs = []
        fx = self.fixture()
        outputs += [self.output(fx, "--glitch-root", str(fx.glitch)), self.output(fx, "--glitch-root", str(fx.glitch), *EINH)]
        single = self.fixture(seats=[], extra_installs=[("acct2", "claude")])
        outputs += [self.output(single), self.output(single, "--accounts", "claude=A,B,C", "--accounts", "agy=A,B")]
        for data in outputs:
            text = json.dumps(data).lower()
            self.assertNotRegex(text, r"which model|startup prompt|token|password|credential|\.credentials|auth\.json")
            for q in questions(data):
                self.assertTrue(2 <= len(q["options"]) <= 4, q["id"])
                self.assertLessEqual(len(q["header"]), 12, q["header"])
                self.assertEqual(sum(o["preselected"] for o in q["options"]) <= 1 or q["multiSelect"], True, q["id"])
            for prompt in data["prompts"]:
                self.assertTrue(1 <= len(prompt["questions"]) <= 4, prompt["id"])
            ids = [q["id"] for q in questions(data)]
            self.assertEqual(len(ids), len(set(ids)), "question ids are unique")
            self.assertEqual(data["limits"], {"questions_per_prompt": 4, "options_per_question": 4, "header_characters": 12})
            if data["phase"] == 2:
                review = q_id(data, "review")
                self.assertEqual((review["question"], labels(review)), ("Save these {N} agents?", ["Save and set up (Recommended)", "Change something"]))

    def test_output_is_deterministic_and_leaves_nothing_behind(self):
        fx = self.fixture()
        for extra in ((), EINH):
            first = fx.run("--glitch-root", str(fx.glitch), *extra).stdout
            second = fx.run("--glitch-root", str(fx.glitch), *extra).stdout
            self.assertEqual(first, second)
        self.assertEqual([p for p in fx.base.iterdir() if p.name.startswith("spawn-questions.")], [])

    # ---- cross-family review round 1 (SKILLS-210), kept for the redesigned flow ----
    def test_a_path_is_never_put_inside_a_shell_string(self):
        # P1: the resolved CLI path crossed `sh -c` unquoted, so spaces broke and metacharacters ran as the seat.
        fx = self.fixture(name="a b;touch PWNED;'q$(touch PWNED2)")
        data = self.output(fx, "--glitch-root", str(fx.glitch), *EINH)
        self.assertEqual([p for p in fx.base.rglob("PWNED*")], [], "a metacharacter in a path executed")
        self.assertEqual(agents(data)["claude-work"]["command"], f"{fx.base}/home/claudework/.local/bin/claude")
        self.assertIn("YOLO (--dangerously-skip-permissions)", labels(q_id(data, "perm-claude-work")), "help still read for a path with spaces and quotes")

    def test_a_forged_row_in_an_input_is_only_data(self):
        # P2: paths went into an unescaped tab-separated file; a newline in --cwd forged a row.
        fx = self.fixture()
        evil = "x\nCAND\tclaude\tevil\tuser\t/evil/claude\t/evil\nGLITCH\t/evil\tq"
        data = self.output(fx, "--glitch-root", str(fx.glitch), "--phase", "2", cwd=evil)
        self.assertNotIn("evil", [c["account"] for c in data["derived"]["candidates"]])
        self.assertEqual(data["derived"]["launch_folder"], evil)
        self.assertEqual(data["derived"]["glitch_folders"], [str(fx.glitch)])
        tabbed = self.output(fx, "--glitch-root", str(fx.glitch), "--phase", "2", cwd="a\tb c%41")
        self.assertEqual(tabbed["derived"]["launch_folder"], "a\tb c%41", "tabs and percent signs survive intact")
        self.assertEqual(self.refused(fx, "--accounts", "claude=Work\nAG\tx,Home"), "A Claude label has a control character, such as a tab or a line break.")
        self.assertEqual(agents(self.output(fx, "--accounts", "claude=Work,Home%41"))["claude-home-41"]["account_label"], "Home%41")

    def test_a_hanging_command_is_bounded_without_gnu_timeout(self):
        # P2: no `timeout` on macOS, none on Windows, and GNU timeout had no kill fallback.
        fx = self.fixture(hang=("claudework", "you"))
        started = time.monotonic()
        done = fx.run("--glitch-root", str(fx.glitch), *EINH, "--map", "codex-one=you#1", timeout=90, seconds="1")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertLess(time.monotonic() - started, 60)
        data = json.loads(done.stdout)
        self.assertNotIn("YOLO (--dangerously-skip-permissions)", labels(q_id(data, "perm-claude-work")), "an install whose --help hangs supports nothing")
        self.assertNotIn("YOLO (--dangerously-bypass-approvals-and-sandbox)", labels(q_id(data, "perm-codex-one")))
        self.assertIn("YOLO (--dangerously-skip-permissions)", labels(q_id(data, "perm-claude-home")))
        self.assertEqual([p for p in fx.base.iterdir() if p.name.startswith("spawn-questions.")], [])

    def test_a_killed_call_leaves_no_child_behind(self):
        # P2: only the wrapper's pid was killed; its children, and a straggler of a wrapper that exited, survived.
        for groups in ("setsid", "perl"):  # the two ways a process group is made (macOS has perl, not setsid)
            with self.subTest(groups=groups):
                fx = self.fixture(fork=("claudework",), leak=("claudehome",), groups=groups)
                pids = []
                try:
                    done = fx.run("--glitch-root", str(fx.glitch), *EINH, timeout=90, seconds="1")
                    self.assertEqual((done.returncode, done.stderr), (0, ""), done.stderr)
                    pids = [int((fx.base / f"child-{who}.pid").read_text()) for who in ("claudework", "claudehome")]
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline and any(alive(p) for p in pids):
                        time.sleep(0.2)
                    self.assertEqual([p for p in pids if alive(p)], [], "a child of a bounded call outlived the script")
                finally:
                    for p in pids:
                        if alive(p):
                            os.kill(p, 9)

    def yolo_offered(self, help_text):
        fx = self.fixture(help_text=help_text)
        data = self.output(fx, "--glitch-root", str(fx.glitch), *EINH)
        return {q["agent_id"] for q in questions(data) if q["id"].startswith("perm-") and any(o.startswith("YOLO") for o in labels(q))}

    def test_a_flag_counts_only_as_its_own_token(self):
        # P2: `--yolo-extra` matched `--yolo` by substring.
        self.assertEqual(self.yolo_offered("usage: tool [--yolo-extra] [--auto-approve] [--dangerously-skip-permissions-now]\n"), set(), "no look-alike flag enables YOLO")

    def test_a_valued_flag_needs_its_value_in_its_own_help_entry(self):
        # P2: `--approval-mode MODE` enabled `--approval-mode yolo` without ever showing `yolo`.
        listed = "  --approval-mode=<value>   Override tools.approvalMode (always-ask|always-ask-cached|write|yolo)\n  --permission-mode <MODE>\n      Permission mode [possible values: default, acceptEdits, bypassPermissions, plan]\n"
        unlisted = "usage: tool [--approval-mode MODE] [--permission-mode MODE]\n  --other   mentions yolo and bypassPermissions elsewhere\n"
        wrong = "  --approval-mode=<value>   Override (always-ask|yolo-extra)\n  --permission-mode <MODE>\n      Permission mode [possible values: default, bypassPermissions-x]\n"
        for text, expected in ((listed, {"grok", "omp"}), (unlisted, set()), (wrong, set())):
            self.assertEqual(self.yolo_offered(text), expected, text)

    def test_a_sibling_entry_is_not_a_continuation_of_the_flag(self):
        # P2: any indented non-option line counted as a continuation, so a sibling `MODEL ... yolo` entry after
        # `--approval-mode MODE` enabled YOLO.
        self.assertEqual(self.yolo_offered("  --approval-mode MODE\n  MODEL   pick a model (always-ask|yolo)\n  --permission-mode MODE\n  MODEL   bypassPermissions\n"), set())
        # The same value on a continuation indented deeper than the flag still counts (the real grok layout).
        self.assertEqual(self.yolo_offered("  --approval-mode MODE\n      pick one of always-ask|yolo\n  --permission-mode <MODE>\n      [possible values: default, bypassPermissions]\n"), {"grok", "omp"})

    # ---- the Windows twin (no PowerShell on the build host: source checks; the runtime test runs on Windows) ----
    def test_windows_twin_carries_the_same_exact_wording(self):
        sh, ps1 = SCRIPT.read_text(), (PACKAGE / "structuredquestions.ps1").read_text()
        for exact in ["Found on this machine: ", "Not found: ", "Glitch folder detected: ", "Are there any providers for which you have more than one account?",
                      "Which providers have more than one account?", "How many {provider} accounts?", "Labels for your {N} {provider} accounts?",
                      "Number them ({provider} 1, {provider} 2)", "Type my own labels", "All agents run as ", "Change some",
                      "no ", "install or OS user found. Each ", " account needs its own install with its own login. Type its path, or skip it.",
                      "Agy keeps its login per OS user; a second install may share the first one", "Do you want to set special permission modes to start some of these agents with?",
                      "No, all Default (Recommended)", "Default (no arguments)", "Custom (type the arguments)", "which permission mode?", "YOLO is not offered for ",
                      "Would you like to start all these agents within Glitch?", "Choose per agent", "Which agents start in Glitch?", "Which Glitch folder?",
                      "Save these {N} agents?", "Save and set up (Recommended)", "Change something", "(from its config) (Recommended)",
                      "Follow the explicitly assigned task. Role text is guidance, not identity isolation.", "SPAWN knows no CLI with that name.",
                      "--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox", "--permission-mode bypassPermissions", "--approval-mode yolo",
                      "Arguments cannot contain ", "Not used for "]:
            self.assertIn(exact, sh, exact)
            self.assertIn(exact, ps1, exact)
        # Windows has no OS-user launch, so its every agent is the operator's: the several-accounts question is POSIX only.
        self.assertIn("Use this mapping?", sh)
        self.assertNotIn("Use this mapping?", ps1)

    def test_windows_twin_reads_the_omp_config_and_bounds_every_call(self):
        ps1 = (PACKAGE / "structuredquestions.ps1").read_text()
        self.assertIn("WaitForExit($timeoutMs)", ps1)
        self.assertIn("Stop-ProcessTree $id $since", ps1, "the whole tree is stopped, not only the launched process")
        self.assertNotIn("& $cmd.Source --help", ps1, "no unbounded help call")
        self.assertIn(".omp\\agent\\config.yml", ps1)
        self.assertIn("modelRoles:", ps1)
        self.assertIn("Get-OmpFamily", ps1)
        self.assertIn("Get-Command -All", ps1, "every install of a CLI on PATH is a candidate")

    def test_windows_launch_plan_and_flag_tokens_from_the_ps1_source(self):
        # The launch decision and the token boundary are literal patterns in the twin's source; they are read from it
        # and applied here, so the source itself is what is exercised.
        ps1 = (PACKAGE / "structuredquestions.ps1").read_text()

        def literal(name):
            m = re.search(r"\$script:" + name + r" = '((?:[^']|'')*)'", ps1)
            self.assertIsNotNone(m, name)
            return m.group(1).replace("''", "'")
        shim, direct, script, unsafe = (re.compile(literal(n)) for n in ("CmdShim", "DirectExe", "PsScript", "UnsafeForCmd"))
        for path in (r"C:\Users\you\AppData\Roaming\npm\claude.cmd", r"C:\Program Files (x86)\tools\codex.BAT"):
            self.assertTrue(shim.search(path) and not direct.search(path) and not unsafe.search(path), path)
        for path in (r"C:\tools\kimi.exe", r"C:\tools\grok.COM"):
            self.assertTrue(direct.search(path) and not shim.search(path), path)
        for path in (r"C:\x\a%PATH%.cmd", 'C:\\x\\a"b.cmd', "C:\\x\\a!b.bat", "C:\\x\\a\nb.cmd"):
            self.assertTrue(shim.search(path) and unsafe.search(path), "refused: " + path)
        self.assertTrue(script.search(r"C:\x\tool.ps1") and not shim.search(r"C:\x\tool.ps1") and not direct.search(r"C:\x\tool.ps1"))
        self.assertIn("'/d /c \"\"' + $Path + '\" --help\"'", ps1)
        self.assertIn("-NoLogo -NoProfile -File \"' + $Path + '\" --help'", ps1, "a .ps1 install runs the way SPAWN launches it")
        before, after = re.compile(literal("TokenBefore")), re.compile(literal("TokenAfter"))

        def token(text, tok):
            return re.search(before.pattern + re.escape(tok) + after.pattern, text) is not None
        self.assertTrue(token("  --yolo, -y   run", "--yolo") and token("[--approval-mode=<value>]", "--approval-mode"))
        self.assertFalse(token("--yolo-extra", "--yolo") or token("x--yolo", "--yolo") or token("--approval-mode-x", "--approval-mode"))
        self.assertTrue(token("(always-ask|yolo)", "yolo") and not token("(always-ask|yolo-extra)", "yolo"))

    @unittest.skipUnless(shutil.which("pwsh") or shutil.which("powershell"), "needs PowerShell (the build host has none; run on Windows)")
    def test_windows_runtime_hang_tree_kill_and_help_layouts(self):
        host = shutil.which("pwsh") or shutil.which("powershell")
        work = Path(self.tmp.name) / "win"
        work.mkdir()
        done = subprocess.run([host, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(HERE / "structuredquestions_windows.ps1"),
                               "-Dir", str(work), "-Script", str(PACKAGE / "structuredquestions.ps1")], capture_output=True, text=True, timeout=300)
        self.assertIn("VERDICT PASS", done.stdout, done.stdout + done.stderr)

    def test_skill_forwards_every_observed_glitch_candidate(self):
        skill = (PACKAGE / "skills/setup/SKILL.md").read_text()
        self.assertIn("every entry of its `candidates` in any state", skill)
        self.assertIn("--check-args", skill)
        self.assertIn("`when`", skill)
        self.assertIn("`for_each`", skill)
        self.assertIn("`{N}` in its question is that count", skill, "the review's {N} and its table are defined")
        self.assertLessEqual(len(json.dumps(skill)), 8957, "stays within 0.6.9's JSON-encoded size; the whole helper prompt is bounded at 32000 bytes")

    def test_script_is_read_only_and_forbids_model_questions(self):
        text = SCRIPT.read_text()
        commands = re.findall(r"(?m)(?:^|[;&|(]|\bthen|\bdo|\belse)\s*(mv|cp|chmod|chown|mkdir|install|apt|pip|curl|wget|tee|touch|ln)\s", re.sub(r"#.*", "", text))
        self.assertEqual(commands, [], "the script runs no command that changes the machine")
        self.assertNotIn("which model", text.lower())


if __name__ == "__main__":
    unittest.main()

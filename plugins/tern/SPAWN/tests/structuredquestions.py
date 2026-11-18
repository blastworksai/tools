#!/usr/bin/env python3
"""SKILLS-210: structuredquestions.sh prints the exact Guided-setup questions for a fixture host.

Hermetic: fake getent/id/sudo and fake provider CLIs on PATH, twelve neutral seat accounts plus the
operator "you". Nothing here touches a real account, provider or login."""

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
GOLDEN = Path(__file__).with_name("structuredquestions.golden.json")
PROVIDERS = ["claude", "codex", "kimi", "grok", "agy", "muse", "omp"]
SEATS = ["claudework", "claudehome", "codexone", "codextwo", "kimione", "grokone",
         "agyone", "agytwo", "agythree", "agyfour", "museone", "ompone"]
HELP_ALL = "usage: tool [--dangerously-skip-permissions] [--dangerously-bypass-approvals-and-sandbox] [--yolo] [--auto] [--permission-mode default|bypassPermissions] [--approval-mode always-ask|yolo]\n"


class Fixture:
    def __init__(self, base, seats=SEATS, operator_clis=PROVIDERS, help_text=HELP_ALL, glitch=True, sudo=True, no_cli=(), help_by=None, hang=(), omp_family="openai", fork=(), leak=(), groups="setsid"):
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
        for account in ["you", *seats]:
            (self.home / account / ".local/bin").mkdir(parents=True)
        for account in seats:
            provider = next(p for p in PROVIDERS if account.startswith(p))
            if account not in no_cli:
                self.cli(account, provider, (help_by or {}).get(account, help_text), hang=account in hang, mode=("fork" if account in fork else "leak" if account in leak else None), who=account)
        for provider in operator_clis:
            self.cli("you", provider, (help_by or {}).get("you", help_text), hang="you" in hang)
        omp = self.home / "ompone/.omp/agent"
        omp.mkdir(parents=True)
        (omp / "config.yml").write_text("modelRoles:\n  default: anthropic/claude-model\nsetupVersion: 3\n")
        mine = self.home / "you/.omp/agent"
        mine.mkdir(parents=True)
        (mine / "config.yml").write_text(f"modelRoles:\n  default: {omp_family}/some-model\n")
        passwd = "".join(f"{a}:x:{1100 + i}:{1100 + i}::{self.home / a}:/bin/bash\n" for i, a in enumerate(seats))
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
            (self.glitch / ".claude/scripts").mkdir(parents=True)
            (self.glitch / ".claude/scripts/workspaces.py").write_text("x")
            (self.glitch / ".claude/scripts/plan_check.py").write_text("x")
        (self.base / "nothing").mkdir()

    def script(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def cli(self, account, provider, help_text, hang=False, mode=None, who=""):
        path = self.home / account / ".local/bin" / provider
        body = "sleep 300\n" if hang else f"printf '%s' '{help_text}'\n"
        if mode == "fork":    # forks a child, then hangs: the child must not outlive the script
            body = f'sleep 301 &\necho $! > "$FIX/child-{who}.pid"\nsleep 300\n'
        elif mode == "leak":  # answers, exits at once and leaves a child behind
            body = f"sleep 302 &\necho $! > \"$FIX/child-{who}.pid\"\nprintf '%s' '{help_text}'\n"
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run(self, *extra, cwd=None, timeout=120, seconds="20"):
        env = {"SPAWN_QUESTIONS_TIMEOUT": seconds, "PATH": f"{self.bin}:{self.home / 'you/.local/bin'}:{self.sys}", "HOME": str(self.home / "you"),
               "FIX": str(self.base), "TMPDIR": str(self.base), "SPAWN_QUESTIONS_SYSTEM_GLITCH": str(self.base / "no-system-glitch")}
        args = ["/bin/sh", str(SCRIPT), "--cwd", str(cwd or self.base / "nothing"), *extra]
        done = subprocess.run(args, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)
        self.assert_clean = (done.returncode, done.stderr)
        return done


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


def labels(question):
    return [o["label"] for o in question["options"]]


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
        self.assertEqual((done.returncode, done.stderr), (0, ""), done.stderr)
        return json.loads(done.stdout)

    def test_twelve_seats_and_operator_exact_output(self):
        fx = self.fixture()
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        # Exact intro, in the approved order and wording.
        self.assertEqual(data["intro"], ["Found on this machine: Claude 2 · Codex 2 · Kimi 1 · Grok 1 · Agy 4 · Muse 1 · OMP 1.",
                                         f"Glitch folder detected: {fx.glitch}."])
        # Pinned whole-output comparison for the fixture (paths normalised).
        text = json.dumps(data, ensure_ascii=False, indent=1, sort_keys=False).replace(str(fx.base), "@FIX@")
        if os.environ.get("UPDATE_GOLDEN"):
            GOLDEN.write_text(text + "\n")
        self.assertEqual(text + "\n", GOLDEN.read_text(), "output differs from tests/structuredquestions.golden.json")

    def test_exact_titles_options_and_limits(self):
        fx = self.fixture()
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        accounts = [q for q in questions(data) if q["question"].endswith("which accounts should SPAWN run?") or "which accounts should SPAWN run? (" in q["question"]]
        self.assertEqual([q["question"] for q in accounts], [
            "Claude: which accounts should SPAWN run?", "Codex: which accounts should SPAWN run?",
            "Kimi: which accounts should SPAWN run?", "Grok: which accounts should SPAWN run?",
            "Agy: which accounts should SPAWN run? (1 of 2)", "Agy: which accounts should SPAWN run? (2 of 2)",
            "Muse: which accounts should SPAWN run?", "OMP: which accounts should SPAWN run?"])
        home = fx.base / "home"
        claude = accounts[0]
        self.assertEqual(labels(claude), [f"claudework — {home}/claudework/.local/bin/claude",
                                          f"claudehome — {home}/claudehome/.local/bin/claude",
                                          f"you (you) — {home}/you/.local/bin/claude"])
        self.assertEqual([o["preselected"] for o in claude["options"]], [True, True, False])
        self.assertTrue(all(q["multiSelect"] for q in accounts))
        # Agy: four seats + the operator = five options, split into two questions of at most four.
        self.assertEqual([len(q["options"]) for q in accounts[4:6]], [3, 2])
        self.assertEqual([q["header"] for q in accounts[4:6]], ["Agy 1/2", "Agy 2/2"])
        ids = by_id(data, "ids")["questions"][0]
        self.assertEqual((ids["question"], labels(ids)), ("Use these IDs and labels?", ["Use these (Recommended)", "Change some"]))
        folder = by_id(data, "folder")["questions"][0]
        self.assertEqual((folder["question"], labels(folder)), ("Which folder should every agent start in?", [f"Glitch folder: {fx.glitch} (Recommended)", "Each account's own home folder"]))
        permissions = {q["when"]["provider"]: labels(q) for q in questions(data) if q["question"].endswith("which permission mode?")}
        self.assertEqual(permissions, {
            "Claude": ["Normal (asks before actions)", "Skip permission prompts (--dangerously-skip-permissions)"],
            "Codex": ["Normal", "YOLO, no sandbox (--dangerously-bypass-approvals-and-sandbox)"],
            "Kimi": ["Normal", "Ask when needed (--yolo)", "Never ask (--auto)"],
            "Grok": ["Normal", "Bypass permissions (--permission-mode bypassPermissions)"],
            "Agy": ["Normal", "Skip permission prompts (--dangerously-skip-permissions)"],
            "Muse": ["Normal", "No approval prompts (--yolo)"],
            "OMP": ["Normal", "YOLO (--approval-mode yolo)"]})
        for q in questions(data):
            if q["question"].endswith("which permission mode?"):
                self.assertEqual([o["preselected"] for o in q["options"]][0], True, "Normal is preselected")
                self.assertEqual(sum(o["preselected"] for o in q["options"]), 1)
        omp = {q["when"]["account_id"]: labels(q) for q in by_id(data, "omp")["questions"]}
        self.assertEqual(omp, {"omp-one": ["anthropic (from its config) (Recommended)", "openai", "google"],
                               "omp-you": ["openai (from its config) (Recommended)", "google", "anthropic"]})
        review = by_id(data, "review")["questions"][0]
        self.assertEqual((review["question"], labels(review)), ("Save these {N} agents?", ["Save and set up (Recommended)", "Change something"]))
        self.assertEqual(data["derived"]["omp_prompt"], "Follow the explicitly assigned task. Role text is guidance, not identity isolation.")
        # No model question, and the limits of both tools hold on every prompt.
        for q in questions(data):
            self.assertNotRegex(q["question"].lower(), r"which model|startup prompt")
            self.assertGreaterEqual(len(q["options"]), 2)
            self.assertLessEqual(len(q["options"]), 4)
            self.assertLessEqual(len(q["header"]), 12, q["header"])
        for prompt in data["prompts"]:
            self.assertTrue(1 <= len(prompt["questions"]) <= 4, prompt["id"])
        self.assertEqual(data["limits"], {"questions_per_prompt": 4, "options_per_question": 4, "header_characters": 12})

    def test_ids_and_labels_derive_from_account_names(self):
        fx = self.fixture()
        accounts = {a["account"]: a for a in self.output(fx, "--glitch-root", str(fx.glitch))["derived"]["accounts"]}
        self.assertEqual((accounts["claudework"]["id"], accounts["claudework"]["account_label"]), ("claude-work", "WORK"))
        self.assertEqual((accounts["agythree"]["id"], accounts["agythree"]["account_label"]), ("agy-three", "THREE"))
        self.assertEqual(accounts["claudework"]["row"], "claudework → ID claude-work, label WORK")
        self.assertEqual(accounts["claudework"]["provider_family"], "anthropic")
        self.assertEqual(accounts["ompone"]["provider_family"], "anthropic")
        every = self.output(fx)["derived"]["accounts"]
        self.assertEqual(len([a for a in every if a["operator"]]), 7)
        self.assertEqual(len({a["id"] for a in every}), len(every), "IDs are unique")

    def test_each_seat_resolves_as_its_own_account_through_sudo_login(self):
        fx = self.fixture()
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        calls = [decode_login(line) for line in (fx.base / "sudo.log").read_text().splitlines()]
        self.assertNotIn(None, calls, "every seat call is the constant login wrapper with one encoded word")
        self.assertNotIn("-n true", (fx.base / "sudo.log").read_text().splitlines(), "root is never probed: only the per-account route")
        for account in ("claudework", "grokone", "ompone"):
            provider = next(p for p in PROVIDERS if account.startswith(p))
            self.assertIn((account, f"exec 'sh' '-c' 'command -v {provider}'"), calls)
            self.assertIn((account, f"exec 'test' '-x' '{fx.base}/home/{account}/.local/bin/{provider}'"), calls)
        for a in data["derived"]["accounts"]:
            if not a["operator"]:
                self.assertTrue(a["command"].startswith(f"{fx.base}/home/{a['account']}/"), "a seat never gets another account's CLI path")
        # The operator's own CLI is a separate row, found as the operator.
        operator = [a for a in data["derived"]["accounts"] if a["operator"] and a["provider"] == "Grok"][0]
        self.assertEqual(operator["command"], f"{fx.base}/home/you/.local/bin/grok")

    def test_an_account_without_the_cli_is_unavailable_never_substituted(self):
        fx = self.fixture(no_cli=("agyfour",))
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        self.assertNotIn("agyfour", [a["account"] for a in data["derived"]["accounts"]])
        self.assertIn("Unavailable: agyfour (it has no agy it can run).", data["intro"])

    def test_missing_providers_and_missing_glitch_are_said_plainly(self):
        fx = self.fixture(seats=["claudework", "claudehome"], operator_clis=["claude", "codex"])
        data = self.output(fx)
        self.assertEqual(data["intro"][0], "Found on this machine: Claude 2 · Codex you.")
        self.assertEqual(data["intro"][1], "Not found: Kimi, Grok, Agy, Muse, OMP.")
        self.assertRegex(data["intro"][2], r"^Glitch folder: not found in .+no-system-glitch.+Glitch.+the launch folder and its parents\.$")
        folder = by_id(data, "folder")["questions"][0]
        self.assertEqual(labels(folder)[0], "Each account's own home folder")
        self.assertEqual(len(labels(folder)), 2, "a question needs two options even without a Glitch folder")
        # A provider with a lone row still gets two options (the second skips it).
        codex = [q for q in questions(data) if q["question"].startswith("Codex: which accounts")][0]
        self.assertEqual(labels(codex)[1], "Skip Codex")

    def test_flags_the_installed_help_does_not_show_are_not_offered(self):
        fx = self.fixture(help_text="usage: tool [--yolo]\n")
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        permissions = {q["when"]["provider"]: labels(q) for q in questions(data) if q["question"].endswith("which permission mode?")}
        self.assertEqual(set(permissions), {"Kimi", "Muse"}, "a provider whose only flag is unconfirmed is not asked")
        self.assertEqual(permissions["Kimi"], ["Normal", "Ask when needed (--yolo)"])
        self.assertTrue(any(line.startswith("Permissions: Claude offers Normal only") for line in data["intro"]))

    def test_without_sudo_seat_accounts_are_not_guessed(self):
        fx = self.fixture(sudo=False)
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        self.assertTrue(all(a["operator"] for a in data["derived"]["accounts"]))
        self.assertTrue(any("sudo is not installed" in line for line in data["intro"]))

    def test_output_is_deterministic_and_leaves_nothing_behind(self):
        fx = self.fixture()
        first = fx.run("--glitch-root", str(fx.glitch)).stdout
        second = fx.run("--glitch-root", str(fx.glitch)).stdout
        self.assertEqual(first, second)
        self.assertEqual([p for p in fx.base.iterdir() if p.name.startswith("spawn-questions.")], [])

    def test_windows_twin_carries_the_same_exact_wording(self):
        sh, ps1 = SCRIPT.read_text(), (PACKAGE / "structuredquestions.ps1").read_text()
        for exact in ["which accounts should SPAWN run?", "Use these IDs and labels?", "Use these (Recommended)", "Change some",
                      "Which folder should every agent start in?", "Each account", "which permission mode?", "Save these {N} agents?",
                      "Save and set up (Recommended)", "Change something", "Normal (asks before actions)",
                      "Skip permission prompts (--dangerously-skip-permissions)", "YOLO, no sandbox (--dangerously-bypass-approvals-and-sandbox)",
                      "Ask when needed (--yolo)", "Never ask (--auto)", "Bypass permissions (--permission-mode bypassPermissions)",
                      "No approval prompts (--yolo)", "YOLO (--approval-mode yolo)", "(from its config) (Recommended)",
                      "Follow the explicitly assigned task. Role text is guidance, not identity isolation.",
                      "Found on this machine", "Not found: ", "Glitch folder detected: "]:
            self.assertIn(exact, sh)
            self.assertIn(exact, ps1)

    # ---- cross-family review round 1 (SKILLS-210) ----
    def test_a_path_is_never_put_inside_a_shell_string(self):
        # P1: the resolved CLI path crossed `sh -c` unquoted, so spaces broke and metacharacters ran as the seat.
        fx = self.fixture(name="a b;touch PWNED;'q$(touch PWNED2)")
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        self.assertEqual([p for p in fx.base.rglob("PWNED*")], [], "a metacharacter in a path executed")
        claude = [a for a in data["derived"]["accounts"] if a["account"] == "claudework"][0]
        self.assertEqual(claude["command"], f"{fx.base}/home/claudework/.local/bin/claude")
        self.assertIn("Claude 2", data["intro"][0])
        perm = [q for q in questions(data) if q["question"] == "Claude: which permission mode?"]
        self.assertEqual(len(perm), 1, "help still read for a path with spaces and quotes")

    def test_a_forged_row_in_an_input_is_only_data(self):
        # P2: paths went into an unescaped tab-separated file; a newline in --cwd forged an ACC row.
        fx = self.fixture()
        evil = "x\nACC\tclaude\tevil\tseat\t/evil/claude\t/evil\tanthropic\nGLITCH\t/evil\tq"
        data = self.output(fx, "--glitch-root", str(fx.glitch), cwd=evil)
        self.assertNotIn("evil", [a["account"] for a in data["derived"]["accounts"]])
        self.assertEqual(data["derived"]["launch_folder"], evil)
        self.assertEqual(data["derived"]["glitch_folders"], [str(fx.glitch)])
        tabbed = self.output(fx, "--glitch-root", str(fx.glitch), cwd="a\tb c%41")
        self.assertEqual(tabbed["derived"]["launch_folder"], "a\tb c%41", "tabs and percent signs survive intact")

    def test_a_hanging_command_is_bounded_without_gnu_timeout(self):
        # P2: no `timeout` on macOS, none on Windows, and GNU timeout had no kill fallback.
        fx = self.fixture(hang=("claudework", "you"))
        started = time.monotonic()
        done = fx.run("--glitch-root", str(fx.glitch), timeout=90, seconds="1")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertLess(time.monotonic() - started, 60)
        data = json.loads(done.stdout)
        claude = [q for q in questions(data) if q["question"] == "Claude: which permission mode?"][0]
        unsupported = claude["options"][1]["unsupported_by"]
        self.assertIn("claude-work", unsupported, "an account whose --help hangs supports nothing")
        self.assertIn("claude-you", unsupported)
        self.assertNotIn("claude-home", unsupported)
        self.assertEqual([p for p in fx.base.iterdir() if p.name.startswith("spawn-questions.")], [])

    def test_permission_flags_are_checked_per_account(self):
        # P2: the flag list came from the first account's --help only.
        fx = self.fixture(help_by={"claudehome": "usage: claude [--other]\n"})
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        claude = [q for q in questions(data) if q["question"] == "Claude: which permission mode?"][0]
        self.assertEqual(claude["options"][0].get("unsupported_by"), None)
        self.assertEqual(claude["options"][1]["unsupported_by"], ["claude-home"])
        self.assertEqual(data["derived"]["permissions"]["Claude"][1]["unsupported_by"], ["claude-home"])
        # Every account supports it everywhere else: no unsupported_by at all.
        codex = [q for q in questions(data) if q["question"] == "Codex: which permission mode?"][0]
        self.assertTrue(all("unsupported_by" not in o for o in codex["options"]))
        # No account supports the flag: the option is not offered and the intro says so.
        none = self.output(self.fixture(help_text="usage: tool\n"), "--glitch-root", "/nonexistent")
        self.assertEqual([q for q in questions(none) if q["question"].endswith("which permission mode?")], [])

    def test_four_glitch_roots_still_fit_four_options(self):
        # P2: 4 roots plus the home option made five options.
        fx = self.fixture()
        roots = [fx.glitch]
        for n in range(3):
            extra = fx.base / f"glitch{n}"
            (extra / ".claude/scripts").mkdir(parents=True)
            (extra / ".claude/scripts/workspaces.py").write_text("x")
            (extra / ".claude/scripts/plan_check.py").write_text("x")
            roots.append(extra)
        args = [a for r in roots for a in ("--glitch-root", str(r))]
        data = self.output(fx, *args)
        folder = by_id(data, "folder")["questions"][0]
        self.assertEqual(len(folder["options"]), 4)
        self.assertEqual(labels(folder)[-1], "Each account's own home folder")
        self.assertEqual(sum(o["preselected"] for o in folder["options"]), 0, "no single recommendation among several roots")
        self.assertTrue(any(line.startswith("More Glitch folders found, not listed as choices") and str(roots[3]) in line for line in data["intro"]))

    def test_an_operator_allowed_per_seat_but_not_root_resolves_every_seat(self):
        # P2: `sudo -n true` tested root, not the per-account route.
        fx = self.fixture()
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        self.assertEqual(len([a for a in data["derived"]["accounts"] if not a["operator"]]), 12)
        self.assertFalse(any(line.startswith("Unavailable:") for line in data["intro"]))
        self.assertNotIn("-n true", (fx.base / "sudo.log").read_text().splitlines())

    def test_an_omp_service_outside_the_three_is_offered_as_configured(self):
        fx = self.fixture(omp_family="moonshot")
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        omp = {q["when"]["account_id"]: labels(q) for q in by_id(data, "omp")["questions"]}
        self.assertEqual(omp["omp-you"], ["moonshot (from its config) (Recommended)", "openai", "google"])
        self.assertEqual([a["provider_family"] for a in data["derived"]["accounts"] if a["id"] == "omp-you"], ["moonshot"])

    def test_windows_twin_reads_the_omp_config_and_bounds_every_call(self):
        # No PowerShell on the build host: these are source checks of the Windows twin, not a run of it.
        ps1 = (PACKAGE / "structuredquestions.ps1").read_text()
        self.assertIn("WaitForExit($timeoutMs)", ps1)
        self.assertIn("Stop-ProcessTree $id $since", ps1, "the whole tree is stopped, not only the launched process")
        self.assertNotIn("& $cmd.Source --help", ps1, "no unbounded help call")
        self.assertIn(".omp\\agent\\config.yml", ps1)
        self.assertIn("modelRoles:", ps1)
        self.assertIn("Get-OmpFamily", ps1)
        self.assertIn("Select-Object -First 3", ps1)

    def test_skill_forwards_every_observed_glitch_candidate(self):
        skill = (PACKAGE / "skills/setup/SKILL.md").read_text()
        self.assertIn("every entry of its `candidates` in any state", skill)
        self.assertIn("`unsupported_by`", skill)
        self.assertLessEqual(len(json.dumps(skill)), 8957, "stays within main's JSON-encoded size")


    # ---- cross-family review round 2 (SKILLS-210) ----
    def test_a_killed_call_leaves_no_child_behind(self):
        # P2: only the wrapper's pid was killed; its children, and a straggler of a wrapper that exited, survived.
        for groups in ("setsid", "perl"):  # the two ways a process group is made (macOS has perl, not setsid)
            with self.subTest(groups=groups):
                fx = self.fixture(fork=("claudework",), leak=("claudehome",), groups=groups)
                pids = []
                try:
                    done = fx.run("--glitch-root", str(fx.glitch), timeout=90, seconds="1")
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

    def test_a_flag_counts_only_as_its_own_token(self):
        # P2: `--yolo-extra` matched `--yolo` by substring.
        fx = self.fixture(help_text="usage: tool [--yolo-extra] [--auto-approve] [--dangerously-skip-permissions-now]\n")
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        self.assertEqual([q for q in questions(data) if q["question"].endswith("which permission mode?")], [], "no look-alike flag enables an option")
        self.assertTrue(any(line.startswith("Permissions: Kimi offers Normal only") for line in data["intro"]))

    def test_a_valued_flag_needs_its_value_in_its_own_help_entry(self):
        # P2: `--approval-mode MODE` enabled `--approval-mode yolo` without ever showing `yolo`.
        listed = "  --approval-mode=<value>   Override tools.approvalMode (always-ask|always-ask-cached|write|yolo)\n  --permission-mode <MODE>\n      Permission mode [possible values: default, acceptEdits, bypassPermissions, plan]\n"
        unlisted = "usage: tool [--approval-mode MODE] [--permission-mode MODE]\n  --other   mentions yolo and bypassPermissions elsewhere\n"
        wrong = "  --approval-mode=<value>   Override (always-ask|yolo-extra)\n  --permission-mode <MODE>\n      Permission mode [possible values: default, bypassPermissions-x]\n"
        for text, expected in ((listed, True), (unlisted, False), (wrong, False)):
            fx = self.fixture(help_text=text)
            data = self.output(fx, "--glitch-root", str(fx.glitch))
            asked = {q["when"]["provider"] for q in questions(data) if q["question"].endswith("which permission mode?")}
            self.assertEqual({"Grok", "OMP"} <= asked, expected, text)
            self.assertEqual(bool({"Grok", "OMP"} & asked), expected, text)

    def test_a_sibling_entry_is_not_a_continuation_of_the_flag(self):
        # P2: any indented non-option line counted as a continuation, so a sibling `MODEL ... yolo` entry after
        # `--approval-mode MODE` enabled YOLO.
        sibling = "  --approval-mode MODE\n  MODEL   pick a model (always-ask|yolo)\n  --permission-mode MODE\n  MODEL   bypassPermissions\n"
        fx = self.fixture(help_text=sibling)
        data = self.output(fx, "--glitch-root", str(fx.glitch))
        asked = {q["when"]["provider"] for q in questions(data) if q["question"].endswith("which permission mode?")}
        self.assertFalse({"Grok", "OMP"} & asked, "a sibling entry at the same indent ended the flag's entry")
        # The same value on a continuation indented deeper than the flag still counts (the real grok layout).
        deeper = "  --approval-mode MODE\n      pick one of always-ask|yolo\n  --permission-mode <MODE>\n      [possible values: default, bypassPermissions]\n"
        fx = self.fixture(help_text=deeper)
        asked = {q["when"]["provider"] for q in questions(self.output(fx, "--glitch-root", str(fx.glitch))) if q["question"].endswith("which permission mode?")}
        self.assertTrue({"Grok", "OMP"} <= asked)

    def test_windows_launch_plan_and_flag_tokens_from_the_ps1_source(self):
        # No PowerShell on the build host. The launch decision and the token boundary are literal patterns in the
        # twin's source; they are read from it and applied here, so the source itself is what is exercised.
        ps1 = (PACKAGE / "structuredquestions.ps1").read_text()

        def literal(name):
            m = re.search(r"\$script:" + name + r" = '((?:[^']|'')*)'", ps1)
            self.assertIsNotNone(m, name)
            return m.group(1).replace("''", "'")
        shim, direct, unsafe = re.compile(literal("CmdShim")), re.compile(literal("DirectExe")), re.compile(literal("UnsafeForCmd"))
        for path in (r"C:\Users\you\AppData\Roaming\npm\claude.cmd", r"C:\Program Files (x86)\tools\codex.BAT"):
            self.assertTrue(shim.search(path) and not direct.search(path) and not unsafe.search(path), path)
        for path in (r"C:\tools\kimi.exe", r"C:\tools\grok.COM"):
            self.assertTrue(direct.search(path) and not shim.search(path), path)
        for path in (r"C:\x\a%PATH%.cmd", 'C:\\x\\a"b.cmd', "C:\\x\\a!b.bat", "C:\\x\\a\nb.cmd"):
            self.assertTrue(shim.search(path) and unsafe.search(path), "refused: " + path)
        self.assertFalse(shim.search(r"C:\x\tool.ps1") or direct.search(r"C:\x\tool.ps1"), "a script is not started directly")
        # The plan routes shims through cmd.exe /d /c, catches a launch failure per provider and keeps going.
        self.assertIn("'/d /c \"\"' + $Path + '\" --help\"'", ps1)
        self.assertRegex(ps1, r"try \{ \$help = Invoke-Bounded \$plan\.file \$plan\.arguments \} catch \{ \$unavailable \+= ")
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
        done = subprocess.run([host, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(Path(__file__).with_name("structuredquestions_windows.ps1")),
                               "-Dir", str(work), "-Script", str(PACKAGE / "structuredquestions.ps1")], capture_output=True, text=True, timeout=300)
        self.assertIn("VERDICT PASS", done.stdout, done.stdout + done.stderr)

    def test_script_is_read_only_and_forbids_model_questions(self):
        text = SCRIPT.read_text()
        self.assertEqual(re.findall(r"\b(rm|mv|cp|chmod|chown|mkdir|install|apt|pip|curl|wget)\b(?=\s)", re.sub(r"#.*", "", text)).count("curl"), 0)
        self.assertNotIn("which model", text.lower())


if __name__ == "__main__":
    unittest.main()

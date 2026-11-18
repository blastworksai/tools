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
import unittest

PACKAGE = Path(__file__).resolve().parents[1]
SCRIPT = PACKAGE / "structuredquestions.sh"
GOLDEN = Path(__file__).with_name("structuredquestions.golden.json")
PROVIDERS = ["claude", "codex", "kimi", "grok", "agy", "muse", "omp"]
SEATS = ["claudework", "claudehome", "codexone", "codextwo", "kimione", "grokone",
         "agyone", "agytwo", "agythree", "agyfour", "museone", "ompone"]
HELP_ALL = "usage: tool [--dangerously-skip-permissions] [--dangerously-bypass-approvals-and-sandbox] [--yolo] [--auto] [--permission-mode MODE] [--approval-mode MODE]\n"


class Fixture:
    def __init__(self, base, seats=SEATS, operator_clis=PROVIDERS, help_text=HELP_ALL, glitch=True, sudo=True, no_cli=()):
        self.base = Path(base)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        # A closed PATH: only these system tools, so a real provider CLI or sudo on the test machine never leaks in.
        self.sys = self.base / "sys"
        self.sys.mkdir()
        for tool in ("sh", "awk", "grep", "mktemp", "rm", "timeout", "cat", "env", "test", "true", "tail", "sed", "tr", "head"):
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
                self.cli(account, provider, help_text)
        for provider in operator_clis:
            self.cli("you", provider, help_text)
        omp = self.home / "ompone/.omp/agent"
        omp.mkdir(parents=True)
        (omp / "config.yml").write_text("modelRoles:\n  default: anthropic/claude-model\nsetupVersion: 3\n")
        mine = self.home / "you/.omp/agent"
        mine.mkdir(parents=True)
        (mine / "config.yml").write_text("modelRoles:\n  default: openai/gpt-model\n")
        passwd = "".join(f"{a}:x:{1100 + i}:{1100 + i}::{self.home / a}:/bin/bash\n" for i, a in enumerate(seats))
        passwd += f"you:x:1000:1000::{self.home / 'you'}:/bin/bash\n"
        passwd += "nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin\nclaudeservice:x:1200:1200::/nonexistent:/usr/sbin/nologin\n"
        passwd += "root:x:0:0::/root:/bin/bash\nplainuser:x:1300:1300::/home/plainuser:/bin/bash\n"
        (self.base / "passwd").write_text(passwd)
        self.script("getent", '[ "$1" = passwd ] && cat "$FIX/passwd"\n')
        self.script("id", 'echo you\n')
        if sudo:
            self.script("sudo", f'''echo "$*" >> "$FIX/sudo.log"
[ "$1" = -n ] || exit 1
shift
[ "$1" = true ] && exit 0
[ "$1" = -i ] && [ "$2" = -u ] || exit 1
account=$3; shift 3
[ "$1" = -- ] || exit 1
shift
[ -d "$FIX/home/$account" ] || exit 1
cd "$FIX/home/$account" || exit 1
exec env -i HOME="$FIX/home/$account" PATH="$FIX/home/$account/.local/bin:$FIX/sys" "$@"
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

    def cli(self, account, provider, help_text):
        path = self.home / account / ".local/bin" / provider
        path.write_text(f"#!/bin/sh\nprintf '%s' '{help_text}'\n")
        path.chmod(0o755)

    def run(self, *extra, cwd=None):
        env = {"PATH": f"{self.bin}:{self.home / 'you/.local/bin'}:{self.sys}", "HOME": str(self.home / "you"),
               "FIX": str(self.base), "TMPDIR": str(self.base), "SPAWN_QUESTIONS_SYSTEM_GLITCH": str(self.base / "no-system-glitch")}
        args = ["/bin/sh", str(SCRIPT), "--cwd", str(cwd or self.base / "nothing"), *extra]
        done = subprocess.run(args, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
        self.assert_clean = (done.returncode, done.stderr)
        return done


def questions(data):
    return [q for p in data["prompts"] for q in p["questions"]]


def by_id(data, prompt_id):
    return next(p for p in data["prompts"] if p["id"] == prompt_id)


def labels(question):
    return [o["label"] for o in question["options"]]


class StructuredQuestions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="spawn-sq-")
        self.addCleanup(self.tmp.cleanup)

    def fixture(self, **kwargs):
        base = Path(self.tmp.name) / f"fx{len(list(Path(self.tmp.name).iterdir()))}"
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
        calls = (fx.base / "sudo.log").read_text().splitlines()
        for account in ("claudework", "grokone", "ompone"):
            provider = next(p for p in PROVIDERS if account.startswith(p))
            self.assertIn(f"-n -i -u {account} -- sh -c command -v {provider}", calls)
            self.assertIn(f"-n -i -u {account} -- test -x {fx.base}/home/{account}/.local/bin/{provider}", calls)
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
        self.assertTrue(any("sudo -n is not available" in line for line in data["intro"]))

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

    def test_script_is_read_only_and_forbids_model_questions(self):
        text = SCRIPT.read_text()
        self.assertEqual(re.findall(r"\b(rm|mv|cp|chmod|chown|mkdir|install|apt|pip|curl|wget)\b(?=\s)", re.sub(r"#.*", "", text)).count("curl"), 0)
        self.assertNotIn("which model", text.lower())


if __name__ == "__main__":
    unittest.main()

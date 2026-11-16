#!/usr/bin/env python3
"""Real POSIX helper regressions. Run explicitly: python3 tests/mailbox_posix.py.

Uses temporary mailboxes only. Fault-injection executables pause/kill the actual
helper at durable boundaries; no production failpoint or service is installed.
Requires the helpers' existing jq/iconv/awk/base64/hash tools plus Python 3.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1]
WORKER = SOURCE / "mailbox_worker.sh"
TARGET = SOURCE / "mailbox_target.sh"
OWNER = "regression_owner_123456"
HARD_BYTES, HARD_FILES = 4194304, 1024
ORDINARY_BYTES, ORDINARY_FILES = 2097152, 896
SEVEN = ["report-files-v1", "native-ask-v1", "worker-poll-v1", "argv-v1", "coordinator-control-v1",
         "check-runner-v1", "release-manager-v1"]
CHECKS = ["report-files-v1", "check-runner-v1"]
RELEASE = ["report-files-v1", "release-manager-v1"]
START = ["report-files-v1", "coordinator-control-v1", "project-start-v1"]
MANIFEST_BYTES = 4096


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()


def git(cwd, *argv, env=None):
    return subprocess.run(["git", *argv], cwd=cwd, check=True, capture_output=True, env=env).stdout.decode().strip()


def make_repo(path):
    path.mkdir(parents=True)
    git(path, "init", "-q", "-b", "main")
    git(path, "config", "user.email", "test@example.invalid")
    git(path, "config", "user.name", "Test")
    (path / "tracked.txt").write_text("base\n")
    git(path, "add", "tracked.txt")
    git(path, "commit", "-q", "-m", "base")
    return git(path, "rev-parse", "HEAD")


def until(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("helper did not reach the requested boundary")
        time.sleep(0.01)


class Mailbox:
    def __init__(self, root, handle="box", enrolment_token="enrolment_aaaaaaaa", handover=None,
                 manifest=None, capabilities=None, binding=None, initialize=True):
        self.root, self.handle = root, handle
        self.box = root / handle
        self.operation = 0
        self.binding = dict(logical_session_id="session", worker_id="worker",
                            worker_generation=1, launch_request_id="launch",
                            work_id="work", enrolment_token=enrolment_token,
                            mailbox_handle=handle)
        if binding is not None:
            self.binding = {key: binding[key] for key in self.binding}
        provision = dict(version=1, handle=handle, binding_digest=digest(encode(self.binding)),
                         binding=self.binding)
        if capabilities is not None:
            provision["capabilities"] = capabilities
        if manifest is not None:
            provision["manifest_sha256"] = digest(manifest)
        if handover is not None:
            # A rollover successor: the issued ID and sha256(id:token), never the token.
            handover_id, token = handover
            provision["handover"] = dict(handover_id=handover_id,
                                         handover_sha256=digest(f"{handover_id}:{token}".encode()))
        # The target receives the manifest as a second Base64 line and writes it verbatim.
        extra = [manifest] if manifest is not None else []
        assert self.target("provision", "provision.json", encode(provision), extra=extra).stdout == b"provisioned\n"
        if initialize:
            self.worker("init", check=True)

    @property
    def journal_path(self):
        return self.box / "producer/journal.json"

    def journal(self):
        return json.loads(self.journal_path.read_bytes())

    def worker_argv(self, mode, message="", poll=1, seconds=2):
        return ["/bin/sh", str(WORKER), str(self.root), self.handle, OWNER,
                mode, message, str(poll), str(seconds)]

    def worker(self, mode, value=None, message="", env=None, check=False, cwd=None):
        data = value if isinstance(value, bytes) else (encode(value) if value is not None else b"")
        result = subprocess.run(self.worker_argv(mode, message), input=data,
                                capture_output=True, env=env, timeout=60, cwd=cwd)
        if check and result.returncode:
            raise AssertionError(result.stderr.decode())
        return result

    def retire_authorized(self, report_floor, reply_floor, chain, binding=None, owner=OWNER, withdrawn=None, env=None):
        argv = self.worker_argv("retire-authorized", poll=5, seconds=30)
        argv[4] = owner
        expected = self.binding if binding is None else binding
        encoded = base64.b64encode(encode(expected)).decode()
        extra = [] if withdrawn is None else [base64.b64encode(encode(withdrawn)).decode()]
        return subprocess.run(argv + [str(report_floor), str(reply_floor), chain, encoded] + extra,
                              capture_output=True, timeout=20, env=env)

    def target(self, mode, selected="-", data=b"", report_floor=0, reply_floor=0, extra=(), withdrawn=None, env=None):
        self.operation += 1
        argv = ["/bin/sh", str(TARGET), str(self.root), self.handle, mode, selected,
                "operation_" + str(self.operation), pwd.getpwuid(os.getuid()).pw_name,
                str(report_floor), str(reply_floor), str(WORKER)]
        if withdrawn is not None:
            argv.append(base64.b64encode(encode(withdrawn)).decode())
        stdin = base64.b64encode(data) + b"".join(b"\n" + base64.b64encode(part) for part in extra)
        result = subprocess.run(argv, input=stdin + (b"\n" if extra else b""), capture_output=True, timeout=20, env=env)
        if result.returncode:
            raise AssertionError(result.stderr.decode())
        return result

    def reply(self, seq, text="work", action=None, transform=None):
        binding = {key: value for key, value in self.binding.items()
                   if key not in ("mailbox_handle", "enrolment_token")}
        reply = dict(binding, version=1, message_id="message_" + str(seq), reply_seq=seq,
                     action_id=action or "action_" + str(seq), action_revision=1,
                     kind="assignment", payload=dict(assignment_ref="task", assignment_sha256="a" * 64,
                                                     instructions=text))
        if transform is not None:
            transform(reply)
        # Preserve noncanonical whitespace and the final newline through receipt,
        # host compaction, restart, and unclaimed re-delivery.
        raw = (json.dumps(reply, ensure_ascii=False, indent=1) + "\n\n").encode()
        self.install_reply(raw, seq, reply["message_id"])
        return raw

    def install_reply(self, raw, seq, message_id):
        """Publish supplied logical bytes unchanged, including invalid JSON."""
        count = (len(raw) + 2047) // 2048
        common = dict(transport="report-files-v1", version=1, mailbox_handle=self.handle,
                      direction="reply", slot=seq, message_id=message_id,
                      message_sha256=digest(raw), count=count)
        for index in range(1, count + 1):
            chunk = dict(common, type="chunk", index=index,
                         data_b64=base64.b64encode(raw[(index-1)*2048:index*2048]).decode())
            result = self.target("publish", f"replies/{seq}/chunk-{index}.json", encode(chunk))
            if result.stdout != b"published\n":
                raise AssertionError(result.stdout)
        manifest = dict(common, type="manifest", message_bytes=len(raw))
        result = self.target("publish", f"replies/{seq}/manifest.json", encode(manifest))
        if result.stdout != b"published\n":
            raise AssertionError(result.stdout)

    def acknowledge_pending(self, collect=True):
        journal = self.journal()
        chain = journal["receipt_chain"]
        binding = {key: value for key, value in self.binding.items()
                   if key not in ("mailbox_handle", "enrolment_token")}
        for pending in journal["pending"]:
            seq = pending["seq"]
            suffix = f'{seq}\n{pending["event_id"]}\n{pending["sha256"]}\n{seq}\n'.encode()
            chain = digest(bytes.fromhex(chain) + suffix)
            ack = dict(binding, version=1, event_id=pending["event_id"], seq=seq,
                       event_sha256=pending["sha256"], committed_revision=seq,
                       disposition="accepted", receipt_chain_sha256=chain)
            result = self.target("publish", f"acks/{seq}.json", encode(ack))
            if result.stdout != b"published\n":
                raise AssertionError(result.stdout)
        if collect:
            self.worker("receipts", check=True)
        return chain

    def usage(self):
        files = [path for path in self.box.rglob("*") if path.is_file()]
        return sum(path.stat().st_size for path in files), len(files)

    def fill_bytes(self, ceiling=ORDINARY_BYTES):
        size, _ = self.usage()
        padding = self.box / "consumer/padding"
        with padding.open("wb") as stream:
            stream.truncate(ceiling - size)
        return padding

    def recover_stopped_worker(self):
        # Only called after subprocess.wait/communicate proves THIS test process
        # exited. Production deliberately does not perform lock/PID stealing.
        work = self.box / "staging" / ("worker-" + OWNER)
        if work.exists():
            shutil.rmtree(work)
        for lock in (self.box / "producer/lock", self.box / "capacity.lock"):
            if lock.exists():
                lock.rmdir()


class PosixMailboxTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spawn-mailbox-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.mailbox = Mailbox(self.root)

    def test_inventory_observes_file_age_without_writing_or_following_links(self):
        box = self.mailbox.box
        paths = [path for path in box.rglob("*") if path.is_file()]
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in paths}
        old = box / "staging" / "old.json"
        old.write_text("{}")
        os.utime(old, (time.time() - 3600, time.time() - 3600))
        fresh = box / "staging" / "fresh.json"
        fresh.write_text("{}")
        result = json.loads(self.mailbox.target("inventory", "60000").stdout)
        self.assertEqual(result["open_files"], len(paths) + 2)
        self.assertEqual(result["stale_files"], 1)
        self.assertLessEqual(abs(result["observed_at_ms"] - time.time() * 1000), 2000)
        self.assertFalse((box / "capacity.lock").exists())
        for path, evidence in before.items():
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), evidence)
        (box / "staging" / "foreign").symlink_to(self.root, target_is_directory=True)
        self.assertEqual(self.mailbox.target("inventory", "60000").stdout, b"binding_mismatch\n")
        self.assertEqual(self.mailbox.target("inventory", "0").stdout, b"binding_mismatch\n")

    def assert_full(self, wire, resource):
        lines = wire.decode().splitlines()
        self.assertEqual(len(lines), 4)
        self.assertEqual(lines[0], "full")
        self.assertRegex(lines[1], r"^[A-Za-z0-9_-]{1,96}$")
        self.assertEqual(lines[1], resource)
        self.assertGreaterEqual(int(lines[2]), 0)
        self.assertGreater(int(lines[3]), 0)
        self.assertLessEqual(int(lines[2]), 9007199254740991)
        self.assertLessEqual(int(lines[3]), 9007199254740991)

    def test_coordinator_proposals_publish_and_reject(self):
        root = self.root / "coordinator space 雪"
        root.mkdir()
        mailbox = Mailbox(root, capabilities=SEVEN)
        identity = dict(owner_id="owner", owner_generation=1, activation_token="a" * 64,
                        proposal_id="proposal")
        work = dict(identity, kind="new_work", new_project_name="雪 project",
                    record_id="configured native", record_revision=0, prompt="Discuss 雪 work",
                    scope=dict(paths=["src/雪 file"], systems=["editor"]),
                    checks=[dict(check_id="review", argv=["check", "雪 argument"])])
        source = dict(identity, kind="add_source", orch_project_id="existing",
                      source=dict(kind="plan_file", path="/plans/雪 plan.md", revision="rev-1"))
        valid = [work, dict(work, repository_id="repo", target_ref="main",
                            target_revision="b" * 40, base_ref="base"),
                 dict(work, new_project_name="é" * 80, scope=dict(paths=[], systems=[]), checks=[]),
                 source,
                 dict(source, source=dict(kind="board", path="C:\\plans\\雪 board", revision="rev-2")),
                 dict(source, source=dict(kind="board", path="\\\\server\\share\\雪", revision="rev-3")),
                 dict(source, source=dict(kind="template", template_id="template", revision="rev-4",
                                          input="Describe the proposed work"))]
        # Both unions retain their exact old shapes.
        for kind in ("dispatch", "report", "review", "rollover", "landing"):
            old = dict(identity, kind=kind, work_id="old_work", project_id="old_project")
            if kind == "dispatch":
                old.update(record_id="record", record_revision=0, prompt="Old task")
            elif kind != "report":
                old["checkpoint_id"] = "checkpoint"
            valid.append(old)
        for payload in valid:
            with self.subTest(valid=payload):
                mailbox.worker("report", dict(kind="COORDINATOR_PROPOSAL", payload=payload), check=True)
                pending = mailbox.journal()["pending"][-1]
                raw = base64.b64decode(pending["bytes"])
                logical = json.loads(raw)
                self.assertEqual(logical["payload"], payload)
                self.assertEqual(logical["work_id"], mailbox.binding["work_id"])
                self.assertEqual(logical["kind"], "COORDINATOR_PROPOSAL")
                folder = mailbox.box / "reports" / str(pending["seq"])
                manifest = json.loads((folder / "manifest.json").read_bytes())
                chunks = b"".join(base64.b64decode(json.loads(
                    (folder / f"chunk-{index}.json").read_bytes())["data_b64"])
                    for index in range(1, manifest["count"] + 1))
                self.assertEqual(chunks, raw)
                self.assertEqual(manifest["message_sha256"], digest(raw))
                before = {path: path.read_bytes() for path in folder.iterdir()}
                mailbox.worker("replay", check=True)
                self.assertEqual({path: path.read_bytes() for path in folder.iterdir()}, before)
                mailbox.acknowledge_pending()
        invalid = []
        for original in (work, source):
            for key, value in (("work_id", "forged"), ("project_id", "forged"),
                               ("checkpoint_id", "forged"), ("argv", ["sh"]),
                               ("account_id", "account"), ("pane_id", "pane"),
                               ("execution_cwd", "/override"), ("executable", "sh")):
                invalid.append(dict(original, **{key: value}))
            both = dict(original, orch_project_id="existing", new_project_name="new")
            neither = {key: value for key, value in original.items()
                       if key not in ("orch_project_id", "new_project_name")}
            invalid.extend([both, neither, dict(original, owner_generation=0),
                            dict(original, activation_token="bad")])
        invalid.extend([
            dict(work, prompt=" \t\n"), dict(work, new_project_name="é" * 81),
            dict(work, checks=work["checks"] * 2),
            dict(work, checks=[dict(check_id=f"c{i}", argv=["check"]) for i in range(17)]),
            dict(work, checks=[dict(check_id="c", argv=[])]),
            dict(work, checks=[dict(check_id="c", argv=["x"] * 17)]),
            dict(work, checks=[dict(check_id="c", argv=["é" * 257])]),
            dict(work, checks=[dict(check_id="c", argv=["x"], command="override")]),
            dict(work, scope=dict(paths=["x"] * 65, systems=[])),
            dict(work, scope=dict(paths=[], systems=["x"] * 17)),
            dict(work, scope=dict(paths=["é" * 129], systems=[])),
            dict(work, scope=dict(paths=[], systems=["é" * 41])),
            dict(work, scope=dict(paths=["a\0b"], systems=[])),
            dict(work, scope=dict(paths=[], systems=[], cwd="/override")),
            dict(work, target_ref="main"), dict(work, target_revision="b" * 40),
            dict(work, target_ref="main", target_revision="b" * 40),
            dict(work, repository_id="repo", target_ref="main", target_revision="HEAD"),
            dict(source, source=dict(kind="plan_file", path="relative.md", revision="r")),
            dict(source, source=dict(kind="plan_file", path="/a\0b", revision="r")),
            dict(source, source=dict(kind="plan_file", path="/plan", revision=" \t")),
            dict(source, source=dict(kind="board", path="/board", revision="r", input="extra")),
            dict(source, source=dict(kind="template", template_id="t", revision="r", input=" ")),
            dict(source, source=dict(kind="template", template_id="t", revision="r\0", input="text")),
            dict(source, source=dict(kind="shell", path="/plan", revision="r")),
        ])
        before = mailbox.journal_path.read_bytes()
        published_before = {path: path.read_bytes() for path in (mailbox.box / "reports").rglob("*.json")}
        for payload in invalid:
            with self.subTest(invalid=payload):
                result = mailbox.worker("report", dict(kind="COORDINATOR_PROPOSAL", payload=payload))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"invalid_schema", result.stderr)
                self.assertEqual(mailbox.journal_path.read_bytes(), before)
        # The actual lexical gate must reject aliases before jq can erase them.
        duplicate = encode(dict(kind="COORDINATOR_PROPOSAL", payload=work))
        duplicate = duplicate.replace(b'"scope":', b'"\\u0073cope":{},"scope":')
        result = mailbox.worker("report", duplicate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"invalid_schema", result.stderr)
        self.assertEqual(mailbox.journal_path.read_bytes(), before)
        self.assertEqual({path: path.read_bytes() for path in (mailbox.box / "reports").rglob("*.json")},
                         published_before)


    def test_enrol_cancellation_delayed_paste_and_producer_races(self):
        accepted = dict(kind="ACCEPTED", payload=dict(assignment_sha256="a" * 64))
        for initialized in (False, True):
            with self.subTest(initialized=initialized):
                mailbox = Mailbox(self.root, f"cancel_{initialized}", enrolment_token=OWNER,
                                  initialize=initialized)
                chain = digest(f"report-files-v1\n{mailbox.handle}\n".encode())
                result = mailbox.retire_authorized(0, 0, chain)
                expected = b"producer_retired\n" if initialized else b"producer_absent\n"
                self.assertEqual((result.returncode, result.stdout), (0, expected))
                self.assertEqual(mailbox.target("retire").stdout, b"retired\n")
                self.assertFalse(mailbox.box.exists())
                # No terminal process is stopped: an old pasted token simply has no mailbox.
                for mode, value in (("init", None), ("report", accepted)):
                    self.assertNotEqual(mailbox.worker(mode, value).returncode, 0)
                    self.assertFalse(mailbox.box.exists())
        for after_cleanup in (False, True):
            mailbox = Mailbox(self.root, f"winner_{after_cleanup}", enrolment_token=OWNER)
            chain = mailbox.journal()["receipt_chain"]
            if after_cleanup:
                self.assertEqual(mailbox.retire_authorized(0, 0, chain).stdout, b"producer_retired\n")
                mailbox.worker("init", check=True)
                # Recreated empty journal alone prevents positive target retirement.
                self.assertEqual(mailbox.target("retire").stdout, b"incomplete\n")
                self.assertTrue(mailbox.journal_path.exists())
            mailbox.worker("report", accepted, check=True)
            before = mailbox.journal_path.read_bytes()
            reports = {p: p.read_bytes() for p in (mailbox.box / "reports").rglob("*.json")}
            result = mailbox.retire_authorized(0, 0, chain)
            self.assertEqual((result.returncode, result.stdout), (0, b"producer_unsettled\n"))
            self.assertEqual(mailbox.target("retire").stdout, b"incomplete\n")
            self.assertEqual(mailbox.journal_path.read_bytes(), before)
            self.assertEqual({p: p.read_bytes() for p in (mailbox.box / "reports").rglob("*.json")}, reports)
            self.assertTrue((mailbox.box / "provision.json").exists())
        # Even an absent producer can lose the gap before target retirement.
        mailbox = Mailbox(self.root, "absent_winner", enrolment_token=OWNER, initialize=False)
        chain = digest(f"report-files-v1\n{mailbox.handle}\n".encode())
        self.assertEqual(mailbox.retire_authorized(0, 0, chain).stdout, b"producer_absent\n")
        mailbox.worker("init", check=True)
        mailbox.worker("report", accepted, check=True)
        before = mailbox.journal_path.read_bytes()
        self.assertEqual(mailbox.target("retire").stdout, b"incomplete\n")
        self.assertEqual(mailbox.journal_path.read_bytes(), before)

    def test_absent_producer_requires_exact_empty_authorization(self):
        mailbox = Mailbox(self.root, "absent_guards", enrolment_token=OWNER, initialize=False)
        chain = digest(f"report-files-v1\n{mailbox.handle}\n".encode())
        for report, reply, proof in ((1, 0, chain), (0, 1, chain), (0, 0, "0" * 64)):
            result = mailbox.retire_authorized(report, reply, proof)
            self.assertEqual((result.returncode, result.stdout), (0, b"producer_unsettled\n"))
            self.assertFalse(mailbox.journal_path.exists())
        wrong = dict(mailbox.binding, worker_id="wrong")
        self.assertNotEqual(mailbox.retire_authorized(0, 0, chain, binding=wrong).returncode, 0)
        self.assertNotEqual(mailbox.retire_authorized(0, 0, chain, owner="different_owner_1234").returncode, 0)
        for lane in ("reports", "replies", "acks", "watermarks"):
            evidence = mailbox.box / lane / ".retained"
            evidence.write_bytes(b"retained evidence")
            result = mailbox.retire_authorized(0, 0, chain)
            self.assertEqual((result.returncode, result.stdout), (0, b"producer_unsettled\n"))
            self.assertEqual(evidence.read_bytes(), b"retained evidence")
            evidence.unlink()
        for lane in ("producer/lock", "capacity.lock"):
            lock = mailbox.box / lane
            lock.mkdir()
            result = mailbox.retire_authorized(0, 0, chain)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(lock.is_dir())
            lock.rmdir()
        self.assertEqual(mailbox.retire_authorized(0, 0, chain).stdout, b"producer_absent\n")

    def test_raw_nul_reply_rejected_without_consumption(self):
        mailbox = self.mailbox
        binding = {key: value for key, value in mailbox.binding.items()
                   if key not in ("mailbox_handle", "enrolment_token")}
        reply = dict(binding, version=1, message_id="nul_reply", reply_seq=1,
                     action_id="action", action_revision=1, kind="assignment",
                     payload=dict(assignment_ref="task", assignment_sha256="a" * 64,
                                  instructions="work"))
        mailbox.install_reply(encode(reply) + b"\0", 1, reply["message_id"])
        before = mailbox.journal_path.read_bytes()
        objects = {path: path.read_bytes() for path in (mailbox.box / "replies/1").iterdir()}
        result = mailbox.worker("consume")
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (1, b"", b"invalid_schema\n"))
        self.assertEqual(mailbox.journal_path.read_bytes(), before)
        self.assertEqual({path: path.read_bytes() for path in objects}, objects)
        self.assertEqual(list((mailbox.box / "reports").iterdir()), [])

    def test_shared_wire_corpus(self):
        corpus = json.loads((SOURCE.parents[2] / "shared/report-files-v1/corpus.json").read_bytes())
        exercised = set()
        ruling_cases = set()
        for case in corpus["cases"]:
            if "posix" not in case.get("helpers", []):
                continue
            with self.subTest(case=case["id"]):
                raw = base64.b64decode(case["bytes_b64"], validate=True)
                if case["op"] == "strict_decode":
                    valid_utf8 = subprocess.run(["iconv", "-f", "UTF-8", "-t", "UTF-8"],
                                                input=raw, capture_output=True, timeout=20)
                    parsed = subprocess.run(["awk", "-f", str(SOURCE / "mailbox_json.awk")],
                                            input=raw, capture_output=True, timeout=20,
                                            env=dict(os.environ, LC_ALL="C"))
                    accepted = b"\0" not in raw and len(raw) <= case.get("maximum", 65536) and valid_utf8.returncode == 0 and parsed.returncode == 0
                    self.assertEqual(accepted, case["expect"]["ok"])
                elif case.get("helper_report_input_b64") and case["expect"].get("code") != "unsupported_capability":
                    report_input = base64.b64decode(case["helper_report_input_b64"], validate=True)
                    strict = subprocess.run(["awk", "-f", str(SOURCE / "mailbox_json.awk")],
                                            input=report_input, capture_output=True, timeout=20,
                                            env=dict(os.environ, LC_ALL="C"))
                    schema = subprocess.run(["jq", "-e", "--arg", "schema", "report_input",
                                             "-f", str(SOURCE / "mailbox_reply.jq")],
                                            input=report_input, capture_output=True, timeout=20)
                    self.assertEqual(strict.returncode == 0 and schema.returncode == 0, case["expect"]["ok"])
                elif case["op"] == "decode_reply" or case.get("helper_frame") or case.get("helper_report_input_b64"):
                    binding = case.get("binding", corpus["binding"])
                    root = self.root / case["id"]
                    root.mkdir()
                    mailbox = Mailbox(root, binding["mailbox_handle"],
                                      binding=binding, capabilities=binding.get("capabilities"))
                    if case.get("helper_frame"):
                        framing = case["helper_frame"]
                        manifest = base64.b64decode(framing["manifest_b64"], validate=True)
                        slot = json.loads(manifest)["slot"]
                        for index, encoded in enumerate(framing["chunks_b64"], 1):
                            self.assertEqual(mailbox.target("publish", f"replies/{slot}/chunk-{index}.json",
                                                           base64.b64decode(encoded, validate=True)).stdout, b"published\n")
                        self.assertEqual(mailbox.target("publish", f"replies/{slot}/manifest.json", manifest).stdout, b"published\n")
                    elif case["op"] == "decode_reply":
                        envelope = json.loads(raw)
                        mailbox.install_reply(raw, envelope["reply_seq"], envelope["message_id"])
                    before = mailbox.journal_path.read_bytes()
                    if case.get("helper_report_input_b64"):
                        result = mailbox.worker("report", base64.b64decode(case["helper_report_input_b64"], validate=True))
                    else:
                        result = mailbox.worker("consume")
                    self.assertEqual(result.returncode == 0, case["expect"]["ok"], result.stderr)
                    if case["id"].startswith("c3-ruling-"):
                        ruling_cases.add(case["id"])
                        if case["expect"]["ok"]:
                            journal = mailbox.journal()
                            self.assertEqual(journal["consumed"][0]["execution"], "unclaimed")
                            self.assertEqual(base64.b64decode(journal["consumed"][0]["bytes"]), raw)
                            ack = json.loads(base64.b64decode(journal["pending"][0]["bytes"]))
                            self.assertEqual(ack["kind"], "reply_ack")
                            self.assertEqual(ack["payload"], dict(message_id=envelope["message_id"],
                                             reply_seq=envelope["reply_seq"], reply_sha256=digest(raw),
                                             status="recorded"))
                        else:
                            self.assertEqual(list((mailbox.box / "reports").iterdir()), [])
                    if case["expect"]["ok"]:
                        if case["op"] == "decode_reply":
                            self.assertEqual(result.stdout, raw)
                        elif case.get("helper_frame"):
                            self.assertEqual(digest(result.stdout), json.loads(manifest)["message_sha256"])
                        else:
                            published = json.loads(base64.b64decode(mailbox.journal()["pending"][0]["bytes"]))
                            self.assertEqual(published["payload"], json.loads(raw)["payload"])
                    else:
                        self.assertEqual(mailbox.journal_path.read_bytes(), before)
                        code = case["expect"]["code"]
                        allowed = case["expect"].get("helper_codes", {}).get(
                            "posix", corpus.get("diagnostics", {}).get(code, {}).get("posix", [code]))
                        self.assertIn(result.stderr.decode().strip().split(":")[0], allowed)
                else:
                    self.fail("Unsupported marked helper corpus operation: " + case["op"])
                exercised.add((case["op"], case["expect"]["ok"]))
        self.assertTrue({("strict_decode", False), ("strict_decode", True),
                         ("decode_reply", False), ("decode_reply", True),
                         ("decode_report", False), ("decode_report", True),
                         ("decode_object", False), ("decode_object", True)} <= exercised)
        self.assertEqual(ruling_cases, {case["id"] for case in corpus["cases"]
                                       if case["id"].startswith("c3-ruling-")})

    def stop_process(self, process, release):
        release.touch()
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=10)

    def shim(self, executable, body):
        directory = self.root / "bin"
        directory.mkdir(exist_ok=True)
        path = directory / executable
        actual = shutil.which(executable)
        self.assertIsNotNone(actual)
        path.write_text("#!/usr/bin/env python3\nimport os, pathlib, signal, subprocess, sys, time, json\n"
                        + "actual = " + repr(actual) + "\n" + body)
        path.chmod(0o755)
        return dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                    TEST_JOURNAL=str(self.mailbox.journal_path), TEST_ROOT=str(self.root))

    def test_target_scan_during_producer_cleanup(self):
        released = self.root / "capacity-released"
        producer_continue = self.root / "producer-continue"
        scanned = self.root / "scan-captured"
        scan_continue = self.root / "scan-continue"
        self.shim("rmdir", """
result = subprocess.run([actual] + sys.argv[1:])
if (result.returncode == 0 and os.environ.get("TEST_ROLE") == "producer"
        and sys.argv[1:] == [str(pathlib.Path(os.environ["TEST_ROOT"]) / "box/capacity.lock")]):
    root = pathlib.Path(os.environ["TEST_ROOT"])
    (root / "capacity-released").touch()
    while not (root / "producer-continue").exists():
        time.sleep(0.01)
sys.exit(result.returncode)
""")
        env = self.shim("find", """
result = subprocess.run([actual] + sys.argv[1:], capture_output=True)
if os.environ.get("TEST_ROLE") == "target":
    root = pathlib.Path(os.environ["TEST_ROOT"])
    (root / "scan-captured").touch()
    while not (root / "scan-continue").exists():
        time.sleep(0.01)
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
""")
        producer = subprocess.Popen(self.mailbox.worker_argv("receipts"),
                                    env=dict(env, TEST_ROLE="producer"),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.stop_process, producer, producer_continue)
        until(released.exists)
        argv = ["/bin/sh", str(TARGET), str(self.root), self.mailbox.handle,
                "read", "provision.json", "cleanup_race_read",
                pwd.getpwuid(os.getuid()).pw_name, "0", "0", str(WORKER)]
        target = subprocess.Popen(argv, env=dict(env, TEST_ROLE="target"),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.stop_process, target, scan_continue)
        until(scanned.exists)
        # Target owns shared admission and has enumerated the mailbox. Allow
        # the producer to exit before the target inspects those exact entries.
        producer_continue.touch()
        _, error = producer.communicate(timeout=10)
        self.assertEqual(producer.returncode, 0, error)
        scan_continue.touch()
        result, error = target.communicate(timeout=10)
        self.assertEqual(target.returncode, 0, error)
        expected = b"object\n" + base64.b64encode(
            (self.mailbox.box / "provision.json").read_bytes()) + b"\n"
        self.assertEqual(result, expected)

    def authorized_mailbox(self):
        return Mailbox(self.root, "authorized", enrolment_token=OWNER)

    def test_init_refuses_piped_input_and_accepts_empty_stdin(self):
        mailbox = Mailbox(self.root, "init_input")
        mailbox.journal_path.unlink()
        accepted = dict(kind="ACCEPTED", payload=dict(assignment_sha256="a" * 64))
        for value in (accepted, b"x"):
            with self.subTest(value=value):
                result = mailbox.worker("init", value)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"init takes no input; it only creates a new journal. "
                                 b"Publish reports with mode report (stdin = one report object).\n")
                self.assertFalse(mailbox.journal_path.exists())
                self.assertEqual(list((mailbox.box / "reports").iterdir()), [])
                self.assertFalse((mailbox.box / "producer/lock").exists())
        hint = b"journal initialized; next: publish ACCEPTED with mode report\n"
        result = mailbox.worker("init", check=True)
        self.assertEqual((result.stdout, result.stderr), (b"", hint))
        self.assertEqual(mailbox.journal()["next_seq"], 1)
        mailbox.journal_path.unlink()
        result = subprocess.run(mailbox.worker_argv("init"), stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=20)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", hint))
        mailbox.journal_path.unlink()
        # An empty pipe whose writer stays open must not hang the probe.
        process = subprocess.Popen(mailbox.worker_argv("init"), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.wait(timeout=10), 0)
            self.assertEqual(process.stderr.read(), hint)
        finally:
            if process.poll() is None:
                process.kill()
            process.stdin.close(); process.stdout.close(); process.stderr.close()
        self.assertTrue(mailbox.journal_path.exists())

    def test_authorized_retirement_strict_expected_binding_decode(self):
        mailbox = self.authorized_mailbox()
        before = mailbox.journal_path.read_bytes()
        chain = mailbox.journal()["receipt_chain"]
        raw = encode(mailbox.binding)
        malformed = [b"\xef\xbb\xbf" + raw, raw + b"\x00", raw + b"{}",
                     b'{"worker_id":"a","worker_id":"b"}', b"\xff", b" " * 2049]
        encoded = ["", "!", "A" * 2733]
        encoded += [base64.b64encode(value).decode() for value in malformed]
        for value in encoded:
            with self.subTest(value=value[:40]):
                argv = mailbox.worker_argv("retire-authorized", poll=5, seconds=30)
                result = subprocess.run(argv + ["0", "0", chain, value],
                                        capture_output=True, timeout=20)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(mailbox.journal_path.read_bytes(), before)
                self.assertFalse((mailbox.box / "producer/lock").exists())
                self.assertFalse((mailbox.box / "capacity.lock").exists())
        # Missing new authorization arguments cannot fall back to worker-local retirement.
        self.assertNotEqual(mailbox.worker("retire-authorized").returncode, 0)
        self.assertEqual(mailbox.journal_path.read_bytes(), before)
        result = mailbox.retire_authorized(0, 0, chain)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"producer_retired\n")
        self.assertFalse(mailbox.journal_path.exists())

    def test_worker_local_retirement_keeps_original_arguments_and_owner_contract(self):
        result = self.mailbox.worker("retire-local")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertFalse(self.mailbox.journal_path.exists())

    def assert_retirement_refused(self, mailbox, report_floor, reply_floor, chain, **kwargs):
        before = mailbox.journal_path.read_bytes()
        unknown = mailbox.box / "consumer/unknown"
        unknown.write_bytes(b"retain unknown bytes")
        result = mailbox.retire_authorized(report_floor, reply_floor, chain, **kwargs)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(mailbox.journal_path.read_bytes(), before)
        self.assertEqual(unknown.read_bytes(), b"retain unknown bytes")
        self.assertFalse((mailbox.box / "producer/lock").exists())
        self.assertFalse((mailbox.box / "capacity.lock").exists())
        self.assertFalse((mailbox.box / ("staging/worker-" + OWNER)).exists())

    def assert_retirement_unsettled(self, mailbox, report_floor, reply_floor, chain):
        # A journal that is not settled at the authorized floors is a definite pre-effect
        # refusal: exit 0 with exactly producer_unsettled, nothing removed, gates released.
        before = mailbox.journal_path.read_bytes()
        unknown = mailbox.box / "consumer/unknown"
        unknown.write_bytes(b"retain unknown bytes")
        result = mailbox.retire_authorized(report_floor, reply_floor, chain)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"producer_unsettled\n")
        self.assertEqual(mailbox.journal_path.read_bytes(), before)
        self.assertEqual(unknown.read_bytes(), b"retain unknown bytes")
        self.assertFalse((mailbox.box / "producer/lock").exists())
        self.assertFalse((mailbox.box / "capacity.lock").exists())
        self.assertFalse((mailbox.box / ("staging/worker-" + OWNER)).exists())

    def test_authorized_retirement_requires_exact_arguments_and_binding(self):
        mailbox = self.authorized_mailbox()
        chain = mailbox.journal()["receipt_chain"]
        for floor in ("", "-1", "1.0", "1e0", "01", "true", " 0", "0\n",
                      "9007199254740992", "999999999999999999999999"):
            for slot in ("report", "reply"):
                with self.subTest(floor=floor, slot=slot):
                    self.assert_retirement_refused(mailbox, floor if slot == "report" else 0,
                                                   floor if slot == "reply" else 0, chain)
        for report, reply in ((1, 0), (0, 1), (9007199254740991, 0)):
            self.assert_retirement_unsettled(mailbox, report, reply, chain)
        for wrong in ("", "a" * 63, "A" * 64, "g" * 64, chain + "\n"):
            self.assert_retirement_refused(mailbox, 0, 0, wrong)
        self.assert_retirement_unsettled(mailbox, 0, 0, "0" * 64)
        for field, value in (("worker_generation", 2), ("work_id", "other"),
                             ("enrolment_token", "other_token_123456")):
            self.assert_retirement_refused(mailbox, 0, 0, chain,
                                           binding=dict(mailbox.binding, **{field: value}))
        self.assert_retirement_refused(mailbox, 0, 0, chain, owner="other_owner_123456")
        # Old worker ownership alone cannot authorize host retirement.
        self.assert_retirement_refused(self.mailbox, 0, 0, self.mailbox.journal()["receipt_chain"])
        journal = mailbox.journal()
        journal["binding"]["work_id"] = "other"
        mailbox.journal_path.write_bytes(encode(journal))
        self.assert_retirement_refused(mailbox, 0, 0, chain)

    def test_authorized_retirement_preserves_pending_and_unresolved_execution(self):
        mailbox = self.authorized_mailbox()
        mailbox.worker("report", dict(kind="READY", payload=dict(state="idle")), check=True)
        self.assert_retirement_unsettled(mailbox, 0, 0, mailbox.journal()["receipt_chain"])
        mailbox.acknowledge_pending()
        mailbox.reply(1)
        mailbox.worker("consume", check=True)
        mailbox.acknowledge_pending()
        chain = mailbox.journal()["receipt_chain"]
        self.assert_retirement_unsettled(mailbox, 2, 1, chain)
        mailbox.worker("claim", message="message_1", check=True)
        self.assert_retirement_unsettled(mailbox, 2, 1, chain)
        retained = mailbox.journal()
        retained["consumed"][0]["execution"] = "uncertain"
        mailbox.journal_path.write_bytes(encode(retained))
        self.assert_retirement_unsettled(mailbox, 2, 1, chain)
        retained["consumed"][0]["execution"] = "resolved"
        retained["consumed"][0]["acknowledged"] = False
        mailbox.journal_path.write_bytes(encode(retained))
        self.assert_retirement_unsettled(mailbox, 2, 1, chain)
        retained["consumed"][0]["acknowledged"] = True
        mailbox.journal_path.write_bytes(encode(retained))
        result = mailbox.retire_authorized(2, 1, chain)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"producer_retired\n")
        self.assertFalse(mailbox.journal_path.exists())
        self.assertEqual((mailbox.box / "consumer/unknown").read_bytes(), b"retain unknown bytes")

    def test_authorized_retirement_exact_cursors_then_target_retirement_replay(self):
        mailbox = self.authorized_mailbox()
        mailbox.reply(1)
        mailbox.worker("consume", check=True)
        mailbox.worker("claim", message="message_1", check=True)
        mailbox.acknowledge_pending()
        mailbox.worker("resolve", message="message_1", check=True)
        settled = mailbox.journal()
        self.assertEqual(settled["consumed"], [])
        # Inconsistent cursors make the journal itself invalid: a non-zero refusal.
        for field, value in (("receipt_seq", 0), ("next_seq", 3)):
            with self.subTest(field=field):
                mailbox.journal_path.write_bytes(encode(dict(settled, **{field: value})))
                self.assert_retirement_refused(mailbox, 1, 1, settled["receipt_chain"])
        # A valid journal that differs from the authorized floors is a definite pre-effect refusal.
        for field, value in (("consumed_reply_floor", 0), ("reply_next", 3), ("receipt_chain", "0" * 64)):
            with self.subTest(field=field):
                mailbox.journal_path.write_bytes(encode(dict(settled, **{field: value})))
                self.assert_retirement_unsettled(mailbox, 1, 1, settled["receipt_chain"])
        mailbox.journal_path.write_bytes(encode(settled))
        # Unknown files are never swept by the private helper.
        (mailbox.box / "consumer/unknown").unlink()
        result = mailbox.retire_authorized(1, 1, settled["receipt_chain"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"producer_retired\n")
        self.assertFalse(mailbox.journal_path.exists())
        self.assertFalse((mailbox.box / "producer/lock").exists())
        self.assertFalse((mailbox.box / "capacity.lock").exists())
        self.assertEqual(list((mailbox.box / "staging").iterdir()), [])
        self.assertEqual(mailbox.target("retire", report_floor=1, reply_floor=1).stdout, b"retired\n")
        self.assertEqual(mailbox.target("reconcile_retire").stdout, b"retired\n")
        self.assertEqual(mailbox.target("read", "provision.json").stdout, b"missing\n")

    def test_authorized_retirement_keeps_existing_locks_and_containment(self):
        mailbox = self.authorized_mailbox()
        chain = mailbox.journal()["receipt_chain"]
        before = mailbox.journal_path.read_bytes()
        for relative in ("producer/lock", "capacity.lock"):
            lock = mailbox.box / relative
            lock.mkdir()
            result = mailbox.retire_authorized(0, 0, chain)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"producer_locked", result.stderr)
            self.assertTrue(lock.is_dir())
            self.assertEqual(mailbox.journal_path.read_bytes(), before)
            lock.rmdir()
        outside = self.root / "outside-authorized"
        outside.write_bytes(b"outside bytes")
        link = mailbox.box / "consumer/redirect"
        link.symlink_to(outside)
        self.assert_retirement_refused(mailbox, 0, 0, chain)
        self.assertTrue(link.is_symlink())
        self.assertEqual(outside.read_bytes(), b"outside bytes")

    def test_nested_scan_case_patterns_preserve_containment(self):
        # /bin/sh is Bash 3.2 on the supported macOS target. Both real helpers
        # must parse their nested $(pipeline | (case ...)) scans without an
        # unpaired case ')' terminating the command substitution prematurely.
        root = self.root / "mailbox root (literal)"
        root.mkdir()
        mailbox = Mailbox(root)
        before = mailbox.journal_path.read_bytes()
        outside = self.root / "outside"
        outside.write_bytes(b"unchanged outside mailbox")
        link = mailbox.box / "consumer/redirect"
        link.symlink_to(outside)
        try:
            self.assertEqual(mailbox.target("read", "provision.json").stdout, b"binding_mismatch\n")
            result = mailbox.worker("replay")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"binding_mismatch", result.stderr)
            self.assertEqual(mailbox.journal_path.read_bytes(), before)
            self.assertEqual(outside.read_bytes(), b"unchanged outside mailbox")
        finally:
            link.unlink()
        nested = mailbox.box / "consumer/nested"
        (nested / "too/deep").mkdir(parents=True)
        try:
            self.assertEqual(mailbox.target("read", "provision.json").stdout, b"binding_mismatch\n")
            result = mailbox.worker("replay")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"binding_mismatch", result.stderr)
            self.assertEqual(mailbox.journal_path.read_bytes(), before)
        finally:
            shutil.rmtree(nested)
        mailbox.worker("report", dict(kind="READY", payload=dict(state="idle")), check=True)
        self.assertTrue(mailbox.target("read", "reports/1/manifest.json").stdout.startswith(b"object\n"))

    def test_full_closed_report_validation_before_sequence_allocation(self):
        checkpoint = dict(checkpoint_id="checkpoint", task_ref="task", project_id="project",
                          worktree_ref="tree", artifact_revision="revision", completed=[],
                          remaining=[], holds=[], checks=[])
        accepted = dict(kind="ACCEPTED", payload=dict(assignment_sha256="a" * 64))
        proposal = dict(owner_id="owner", owner_generation=1, activation_token="a" * 64,
                        proposal_id="proposal", kind="review", work_id="work",
                        project_id="project", checkpoint_id="checkpoint")
        landing_request = dict(checkpoint_id="checkpoint", project_id="project", repo_ref="repo", target_ref="main",
                               target_revision="base", source_ref="work", source_revision="revision")
        landing = dict(landing_id="landing", grant_id="grant", project_id="project", repo_ref="repo", target_ref="main",
                       target_revision="base", source_revision="revision", evidence=[])
        def landing_result(**fields):
            return dict(kind="LANDING_RESULT", action_id="a", action_revision=1, payload=dict(landing, **fields))
        invalid = [
            b'{"kind":"READY","kind":"READY","payload":{"state":"idle"}}',
            b'{"kind":"READY","payload":{"state":"idle","summary":null}}',
            dict(kind="READY", payload={}),
            dict(kind="READY", payload=dict(state="idle", unknown=True)),
            dict(kind="READY", payload=dict(state="working")),
            dict(kind="READY", payload=dict(state="idle"), action_id="action", action_revision=1),
            dict(kind="REGISTER", payload=dict(capabilities=[])),
            dict(kind="REGISTER", payload=dict(capabilities=["argv-v1"])),
            dict(kind="REGISTER", payload=dict(capabilities=["report-files-v1", "report-files-v1"])),
            dict(kind="REGISTER", payload=dict(capabilities=["report-files-v1", "invented"])),
            dict(kind="ACCEPTED", payload={}),
            dict(kind="ACCEPTED", payload=dict(assignment_sha256="A" * 64)),
            dict(accepted, handover_id="handover"),
            dict(accepted, handover_id="handover", handover_token="short"),
            dict(accepted, action_id="action", action_revision=1),
            dict(kind="HEARTBEAT", payload=dict(state="unknown")),
            dict(kind="HEARTBEAT", payload=dict(state="working", request_id=None)),
            dict(kind="COORDINATOR_PROPOSAL", payload=dict(proposal, kind="shell")),
            dict(kind="COORDINATOR_PROPOSAL", payload=dict(proposal, command="merge")),
            dict(kind="COORDINATOR_PROPOSAL", payload=dict(proposal, activation_token="wrong")),
            dict(kind="COORDINATOR_PROPOSAL", payload=dict(proposal, kind="report")),
            dict(kind="COORDINATOR_PROPOSAL", payload=dict(proposal, kind="dispatch", record_id="native", record_revision=0, prompt="task")),
            dict(kind="WAITING", payload=dict(reason="wait"), action_id="action"),
            dict(kind="WAITING", payload=dict(reason="wait", request_id="bad\n")),
            dict(kind="BLOCKED", payload=dict(reason="blocked", evidence=[True])),
            dict(kind="ASK", payload=dict(question="?", options=[dict(id="a", label="A"), dict(id="a", label="B")])),
            dict(kind="ASK", payload=dict(question="?", options=[dict(id="a", label="A", extra=True)])),
            dict(kind="CHECKPOINT", payload=dict(checkpoint, plan_ref="plan")),
            dict(kind="CHECKPOINT", payload=dict(checkpoint, checks=[dict(check_id="c", artifact_revision="r", outcome="maybe", evidence_ref="e")])),
            dict(kind="REVIEW_READY", payload=dict(checkpoint_id="c", artifact_revision="r"), handover_id="h", handover_token="x" * 16),
            dict(kind="REVIEW_RESULT", payload=dict(artifact_revision="r", outcome="approved", evidence=[])),
            dict(kind="DONE", payload=dict(checkpoint_id="c", artifact_revision="r", summary="é" * 16385)),
            dict(kind="ROLLOVER_REQUEST", payload=dict(checkpoint_id="c", reason="")),
            dict(kind="LANDING_RESULT", action_id="a", action_revision=1,
                 payload=dict(project_id="p", target_ref="t", source_revision="s", outcome="landed", evidence=[], result_revision="r")),
            landing_result(outcome="landed"),
            landing_result(outcome="landed", result_revision="head", reason="extra"),
            landing_result(outcome="rejected"),
            landing_result(outcome="rejected", reason="conflict", result_revision="head"),
            landing_result(outcome="stale_target"),
            landing_result(outcome="stale_target", observed_target_revision="base"),
            landing_result(outcome="uncertain"),
            landing_result(outcome="failed", reason="legacy"),
            landing_result(outcome="landed", result_revision="head", command="git merge"),
            dict(landing_result(outcome="landed", result_revision="head"), action_id=None),
            {key: value for key, value in landing_result(outcome="landed", result_revision="head").items() if key not in ("action_id", "action_revision")},
            dict(kind="LANDING_REQUEST", payload=landing_request, action_id="a", action_revision=1),
            dict(kind="LANDING_REQUEST", payload={key: value for key, value in landing_request.items() if key != "source_ref"}),
            dict(kind="LANDING_REQUEST", payload=dict(landing_request, project_id="bad id")),
            dict(kind="LANDING_REQUEST", payload=dict(landing_request, target_revision="")),
            dict(kind="reply_ack", action_id="a", action_revision=1,
                 payload=dict(message_id="m", reply_seq=1, reply_sha256="a" * 64, status="executed")),
            dict(kind="READY", payload=dict(state="idle"), seq=123),
            dict(kind="WAITING", payload=dict(reason="wait", context_used_pct=10)),
            *[dict(kind=kind, payload=dict(state=state, context_used_pct=bad))
              for kind, state in (("READY", "idle"), ("HEARTBEAT", "working"))
              for bad in (-1, 101, 42.5, "42", True)],
        ]
        original = self.mailbox.journal_path.read_bytes()
        for value in invalid:
            with self.subTest(value=value):
                result = self.mailbox.worker("report", value)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.mailbox.journal_path.read_bytes(), original)
                self.assertEqual(list((self.mailbox.box / "reports").iterdir()), [])
        valid = [
            dict(kind="REGISTER", payload=dict(capabilities=["report-files-v1", "worker-poll-v1", "argv-v1"])),
            dict(kind="READY", payload=dict(state="idle", summary="ready")), accepted,
            dict(kind="HEARTBEAT", payload=dict(state="working", request_id="request")),
            dict(kind="WAITING", action_id="a", action_revision=1, payload=dict(reason="wait", request_id="request")),
            dict(kind="BLOCKED", payload=dict(reason="blocked", evidence=[])),
            dict(kind="ASK", payload=dict(question="?", options=[dict(id="a", label="A")])),
            dict(kind="CHECKPOINT", payload=dict(checkpoint, request_id="request")),
            dict(kind="COORDINATOR_PROPOSAL", payload=proposal),
            dict(kind="COORDINATOR_PROPOSAL", payload={key: value for key, value in dict(proposal, kind="report").items() if key != "checkpoint_id"}),
            dict(kind="COORDINATOR_PROPOSAL", payload={key: value for key, value in dict(proposal, kind="dispatch", record_id="configured native", record_revision=0, prompt="Explicit task").items() if key != "checkpoint_id"}),
            dict(kind="REVIEW_READY", payload=dict(checkpoint_id="c", artifact_revision="r")),
            dict(kind="REVIEW_RESULT", action_id="a", action_revision=1,
                 payload=dict(review_id="r", round=1, artifact_revision="r", outcome="approved", findings=[])),
            dict(kind="DONE", payload=dict(checkpoint_id="c", artifact_revision="r", summary="done")),
            dict(kind="ROLLOVER_REQUEST", payload=dict(checkpoint_id="c", reason="next")),
            dict(kind="LANDING_REQUEST", payload=landing_request),
            dict(kind="LANDING_REQUEST", payload=dict(landing_request, summary="ready to land")),
            landing_result(outcome="landed", result_revision="head", pr_ref="pr", summary="merged"),
            landing_result(outcome="rejected", reason="conflict"),
            landing_result(outcome="stale_target", observed_target_revision="moved"),
            landing_result(outcome="stale_target", observed_target_revision="moved", reason="target advanced"),
            landing_result(outcome="uncertain", reason="push timed out"),
            dict(kind="reply_ack", action_id="a", action_revision=1,
                 payload=dict(message_id="m", reply_seq=1, reply_sha256="a" * 64, status="recorded")),
            *[dict(kind=kind, payload=dict(state=state, context_used_pct=pct))
              for kind, state in (("READY", "idle"), ("HEARTBEAT", "working"))
              for pct in (0, 100)],
        ]
        for index, value in enumerate(valid):
            with self.subTest(valid=value):
                mailbox = Mailbox(self.root, "valid_" + str(index))
                mailbox.worker("report", value, check=True)
                report = json.loads(base64.b64decode(mailbox.journal()["pending"][0]["bytes"]))
                self.assertEqual(report["payload"], value["payload"])
                self.assertEqual(mailbox.journal()["next_seq"], 2)

    def test_handover_pair_verified_before_sequence_allocation(self):
        # A coordinator successor typed the last token digit wrong. The producer
        # refuses it by field before allocating a sequence, without echoing either value.
        issued = "29f79cde" * 7 + "b5851668"
        mistyped = "29f79cde" * 7 + "b585166a"
        accepted = dict(kind="ACCEPTED", payload=dict(assignment_sha256="a" * 64))
        mailbox = Mailbox(self.root, "successor", handover=("handover-540", issued))
        original = mailbox.journal_path.read_bytes()
        refusals = [
            (dict(accepted, handover_id="handover-540", handover_token=mistyped), b"binding_mismatch: handover_token differs"),
            (dict(accepted, handover_id="handover-541", handover_token=issued), b"binding_mismatch: handover_id differs"),
            (accepted, b"binding_mismatch: handover_id and handover_token are required"),
        ]
        for value, message in refusals:
            with self.subTest(value=value):
                result = mailbox.worker("report", value)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(result.stderr.startswith(message), result.stderr)
                self.assertNotIn(issued.encode(), result.stderr)
                self.assertNotIn(mistyped.encode(), result.stderr)
                self.assertEqual(mailbox.journal_path.read_bytes(), original)
                self.assertEqual(list((mailbox.box / "reports").iterdir()), [])
        exact = dict(accepted, handover_id="handover-540", handover_token=issued)
        mailbox.worker("report", exact, check=True)
        report = json.loads(base64.b64decode(mailbox.journal()["pending"][0]["bytes"]))
        self.assertEqual((report["seq"], report["handover_id"], report["handover_token"]), (1, "handover-540", issued))
        self.assertTrue((mailbox.box / "reports/1/manifest.json").is_file())
        # An ordinary generation was issued no pair, so a supplied one is refused too.
        result = self.mailbox.worker("report", exact)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr.startswith(b"binding_mismatch: handover_id was not issued"), result.stderr)

    def test_malformed_provisioned_handover_only_affects_acceptance(self):
        # Parity with the PowerShell helper: only ACCEPTED reads the provisioned handover, so a
        # malformed one leaves authorized retirement and other reports unchanged.
        def malformed(mailbox):
            provision = json.loads((mailbox.box / "provision.json").read_bytes())
            provision["handover"] = dict(handover_id="bad id", handover_sha256="x")
            (mailbox.box / "provision.json").write_bytes(encode(provision))
        retiring = self.authorized_mailbox()
        malformed(retiring)
        result = retiring.retire_authorized(0, 0, retiring.journal()["receipt_chain"])
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"producer_retired\n", b""))
        reporting = Mailbox(self.root, "malformed_handover")
        malformed(reporting)
        original = reporting.journal_path.read_bytes()
        result = reporting.worker("report", dict(kind="ACCEPTED", payload=dict(assignment_sha256="a" * 64)))
        self.assertEqual((result.returncode, result.stderr), (1, b"binding_mismatch\n"))
        self.assertEqual(reporting.journal_path.read_bytes(), original)
        self.assertEqual(list((reporting.box / "reports").iterdir()), [])
        reporting.worker("report", dict(kind="READY", payload=dict(state="idle")), check=True)

    def test_coordinator_release_entrypoint_schema_and_replay(self):
        payload = dict(owner_id="owner", owner_generation=1, activation_token="a" * 64, quiescent=True)
        release = dict(kind="COORDINATOR_RELEASE", action_id="grant", action_revision=1, payload=payload)
        # Provision has no capability metadata. Negotiation belongs to the
        # configured launch/intake authority, not this transport schema helper.
        capabilities = ["report-files-v1", "native-ask-v1", "worker-poll-v1", "argv-v1", "coordinator-control-v1"]
        registered = Mailbox(self.root, "registered_control")
        registered.worker("report", dict(kind="REGISTER", payload=dict(capabilities=capabilities)), check=True)
        registered.worker("report", dict(kind="READY", payload=dict(state="idle")), check=True)
        invalid = []
        for field in release:
            invalid.append({key: value for key, value in release.items() if key != field})
        for field in payload:
            invalid.append(dict(release, payload={key: value for key, value in payload.items() if key != field}))
        for field, value in [("owner_id", "bad\n"), ("owner_generation", 0), ("owner_generation", True),
                             ("owner_generation", 1.5), ("owner_generation", 9007199254740992),
                             ("activation_token", "A" * 64), ("activation_token", "a" * 63),
                             ("quiescent", False), ("quiescent", 1), ("quiescent", "true"), ("extra", True)]:
            invalid.append(dict(release, payload=dict(payload, **{field: value})))
        invalid += [dict(release, action_revision=True), dict(release, action_revision=0),
                    dict(release, extra=True), dict(release, handover_id="h", handover_token="x" * 16)]
        before = self.mailbox.journal_path.read_bytes()
        for value in invalid:
            with self.subTest(value=value):
                self.assertNotEqual(self.mailbox.worker("report", value).returncode, 0)
                self.assertEqual(self.mailbox.journal_path.read_bytes(), before)
        self.mailbox.worker("report", release, check=True)
        pending = self.mailbox.journal()["pending"][0]
        raw = base64.b64decode(pending["bytes"])
        self.assertEqual(json.loads(raw)["payload"], payload)
        self.assertEqual(json.loads(raw)["action_id"], "grant")
        self.assertEqual(json.loads(raw)["action_revision"], 1)
        self.assertEqual(digest(raw), pending["sha256"])
        manifest = (self.mailbox.box / "reports/1/manifest.json").read_bytes()
        self.mailbox.worker("replay", check=True)
        self.assertEqual((self.mailbox.box / "reports/1/manifest.json").read_bytes(), manifest)
        self.assertEqual(base64.b64decode(self.mailbox.journal()["pending"][0]["bytes"]), raw)

    def project_start_payload(self):
        return dict(owner_id="owner", owner_generation=1, activation_token="a" * 64,
                    orch_project_id="project", project_revision=1, decision_context="b" * 64)

    def withdrawn_fixture(self, handle, count=2):
        mailbox = Mailbox(self.root, handle, enrolment_token=OWNER, capabilities=START)
        # Keep a real settled transport prefix so failed target preflight must
        # preserve more than the unread START slots.
        mailbox.reply(1)
        mailbox.worker("consume", check=True)
        mailbox.worker("claim", message="message_1", check=True)
        mailbox.acknowledge_pending()
        mailbox.worker("resolve", message="message_1", check=True)
        records = []
        for seq in range(2, 2 + count):
            raw = mailbox.reply(seq, transform=lambda reply: reply.update(
                kind="project_start", payload=self.project_start_payload()))
            records.append(dict(reply_seq=seq, message_id=f"message_{seq}", message_sha256=digest(raw)))
        return mailbox, records, mailbox.journal()["receipt_chain"]

    def snapshot_mailbox(self, mailbox):
        return {str(path.relative_to(mailbox.box)): path.read_bytes()
                for path in mailbox.box.rglob("*") if path.is_file()}

    def test_withdrawn_starts_physical_tail_retirement(self):
        for count in (1, 2, 8):
            with self.subTest(count=count):
                mailbox, records, chain = self.withdrawn_fixture(f"withdraw_positive_{count}", count)
                physical = self.snapshot_mailbox(mailbox)
                self.assertEqual(mailbox.target("reconcile_retire", report_floor=1, reply_floor=1,
                                                withdrawn=records).stdout, b"incomplete\n")
                self.assertEqual(self.snapshot_mailbox(mailbox), physical)
                for mode in ("compact", "reconcile_compact"):
                    self.assertEqual(mailbox.target(mode, report_floor=1, reply_floor=1,
                                                    withdrawn=records).stdout, b"binding_mismatch\n")
                    self.assertEqual(self.snapshot_mailbox(mailbox), physical)
                before = mailbox.journal()
                self.assertEqual((before["receipt_seq"], before["consumed_reply_floor"],
                                  before["reply_next"]), (1, 1, 2))
                # Ordinary compaction remains limited to the genuine consumed floor.
                self.assertEqual(mailbox.target("compact", report_floor=1, reply_floor=1).stdout,
                                 b"compacted\n")
                self.assertTrue((mailbox.box / "replies/2/manifest.json").exists())
                result = mailbox.retire_authorized(1, 1, chain, withdrawn=records)
                self.assertEqual((result.returncode, result.stdout), (0, b"producer_retired\n"), result.stderr)
                self.assertFalse(mailbox.journal_path.exists())
                self.assertEqual(mailbox.target("retire", report_floor=1, reply_floor=1,
                                                withdrawn=records).stdout, b"retired\n")
                self.assertFalse(mailbox.box.exists())
                self.assertEqual(mailbox.target("reconcile_retire", report_floor=1, reply_floor=1,
                                                withdrawn=records).stdout, b"retired\n")

    def test_withdrawn_starts_reject_before_any_destruction(self):
        cases = ("empty", "reversed", "duplicate", "extra_key", "wrong_hash", "wrong_id", "missing_record",
                 "missing_chunk", "extra_chunk", "hidden", "missing_manifest", "changed_chunk", "duplicate_json",
                 "foreign_binding", "wrong_kind", "bad_payload", "missing_control", "missing_start",
                 "unknown_slot", "foreign_manifest", "pending", "unresolved", "wrong_floor", "wrong_chain")
        for stage in ("worker", "target"):
            for index, case in enumerate(cases):
                if stage == "target" and case in ("pending", "unresolved", "wrong_floor", "wrong_chain"):
                    continue
                with self.subTest(stage=stage, case=case):
                    mailbox, records, chain = self.withdrawn_fixture(f"withdraw_{stage}_{index}")
                    if stage == "target":
                        result = mailbox.retire_authorized(1, 1, chain, withdrawn=records)
                        self.assertEqual(result.stdout, b"producer_retired\n", result.stderr)
                    slot = mailbox.box / "replies/2"
                    if case == "empty": records = []
                    elif case == "reversed": records.reverse()
                    elif case == "duplicate": records[1] = records[0].copy()
                    elif case == "extra_key": records[0]["unknown"] = True
                    elif case == "wrong_hash": records[0]["message_sha256"] = "0" * 64
                    elif case == "wrong_id": records[0]["message_id"] = "different"
                    elif case == "missing_record": records.pop()
                    elif case == "missing_chunk": (slot / "chunk-1.json").unlink()
                    elif case == "extra_chunk": (slot / "chunk-32.json").write_bytes(b"{}")
                    elif case == "hidden": (slot / ".unknown").write_bytes(b"retain")
                    elif case == "missing_manifest": (slot / "manifest.json").unlink()
                    elif case == "changed_chunk":
                        part = slot / "chunk-1.json"
                        value = json.loads(part.read_bytes()); value["data_b64"] = "eA=="
                        part.write_bytes(encode(value))
                    elif case == "duplicate_json":
                        part = slot / "manifest.json"
                        part.write_bytes(part.read_bytes().replace(b'{', b'{"version":1,', 1))
                    elif case in ("foreign_binding", "wrong_kind", "bad_payload"):
                        def mutate(reply):
                            reply.update(kind="project_start", payload=self.project_start_payload())
                            if case == "foreign_binding": reply["worker_id"] = "foreign"
                            elif case == "wrong_kind": reply.update(kind="assignment", payload=dict(
                                assignment_ref="task", assignment_sha256="a" * 64, instructions="not START"))
                            else: reply["payload"]["unknown"] = True
                        for part in slot.iterdir(): part.unlink()
                        raw = mailbox.reply(2, transform=mutate)
                        records[0]["message_sha256"] = digest(raw)
                    elif case in ("missing_control", "missing_start"):
                        part = mailbox.box / "provision.json"; provision = json.loads(part.read_bytes())
                        provision["capabilities"].remove("coordinator-control-v1" if case == "missing_control" else "project-start-v1")
                        part.write_bytes(encode(provision))
                    elif case == "unknown_slot": (mailbox.box / "replies/4").mkdir()
                    elif case == "foreign_manifest":
                        part = slot / "manifest.json"; value = json.loads(part.read_bytes())
                        value["mailbox_handle"] = "foreign"; part.write_bytes(encode(value))
                    elif case == "pending": mailbox.worker("report", dict(kind="REGISTER", payload=dict(capabilities=START)), check=True)
                    elif case == "unresolved": mailbox.worker("consume", check=True)
                    before = self.snapshot_mailbox(mailbox)
                    if stage == "worker":
                        result = mailbox.retire_authorized(1, 0 if case == "wrong_floor" else 1,
                            "0" * 64 if case == "wrong_chain" else chain, withdrawn=records)
                        if case in ("pending", "unresolved", "wrong_chain"):
                            self.assertEqual((result.returncode, result.stdout), (0, b"producer_unsettled\n"), result.stderr)
                        else:
                            self.assertNotEqual(result.returncode, 0, result.stdout)
                    else:
                        self.assertNotEqual(mailbox.target("retire", report_floor=1, reply_floor=1,
                                                          withdrawn=records).stdout, b"retired\n")
                    self.assertEqual(self.snapshot_mailbox(mailbox), before)

    def test_withdrawn_namespace_preflight_preserves_settled_prefix(self):
        locations = ("consumer/unknown", "producer/unknown", "staging/.held", "unknown",
                     "reports/1/.unknown", "acks/.unknown", "watermarks/.unknown", "reports/2/manifest.json",
                     "acks/2.json", "replies/.unknown/manifest.json")
        for stage in ("worker", "target"):
            for index, location in enumerate(locations):
                with self.subTest(stage=stage, location=location):
                    mailbox, records, chain = self.withdrawn_fixture(f"withdraw_namespace_{stage}_{index}")
                    if stage == "target":
                        self.assertEqual(mailbox.retire_authorized(1, 1, chain, withdrawn=records).stdout,
                                         b"producer_retired\n")
                    path = mailbox.box / location
                    path.parent.mkdir(exist_ok=True)
                    path.write_bytes(b"retain")
                    before = self.snapshot_mailbox(mailbox)
                    if stage == "worker":
                        result = mailbox.retire_authorized(1, 1, chain, withdrawn=records)
                        if location in ("consumer/unknown", "producer/unknown", "staging/.held",
                                        "reports/2/manifest.json", "acks/2.json"):
                            self.assertEqual((result.returncode, result.stdout), (0, b"producer_unsettled\n"), result.stderr)
                        else:
                            self.assertNotEqual(result.returncode, 0, result.stdout)
                    else:
                        self.assertNotEqual(mailbox.target("retire", report_floor=1, reply_floor=1,
                                                          withdrawn=records).stdout, b"retired\n")
                    self.assertEqual(self.snapshot_mailbox(mailbox), before)

    def test_withdrawn_starts_ingests_only_real_final_ack(self):
        for case in ("accepted", "missing", "event", "hash", "chain", "floor"):
            with self.subTest(case=case):
                mailbox, records, _ = self.withdrawn_fixture(f"withdraw_final_ack_{case}")
                mailbox.worker("report", dict(kind="READY", payload=dict(state="idle")), check=True)
                chain = mailbox.acknowledge_pending(collect=False)
                ack_path = mailbox.box / "acks/2.json"
                if case == "missing":
                    ack_path.unlink()
                elif case in ("event", "hash", "chain"):
                    ack = json.loads(ack_path.read_bytes())
                    field = {"event": "event_id", "hash": "event_sha256", "chain": "receipt_chain_sha256"}[case]
                    ack[field] = "wrong_event" if case == "event" else "0" * 64
                    ack_path.write_bytes(encode(ack))
                before = self.snapshot_mailbox(mailbox)
                self.assertEqual(mailbox.journal()["receipt_seq"], 1)
                self.assertEqual(len(mailbox.journal()["pending"]), 1)
                result = mailbox.retire_authorized(1 if case == "floor" else 2, 1, chain, withdrawn=records)
                if case == "accepted":
                    self.assertEqual((result.returncode, result.stdout), (0, b"producer_retired\n"), result.stderr)
                    self.assertFalse(mailbox.journal_path.exists())
                    self.assertTrue((mailbox.box / "watermarks/2.json").exists())
                    self.assertEqual(mailbox.target("retire", report_floor=2, reply_floor=1,
                                                   withdrawn=records).stdout, b"retired\n")
                    self.assertFalse(mailbox.box.exists())
                else:
                    if case in ("missing", "floor"):
                        self.assertEqual((result.returncode, result.stdout), (0, b"producer_unsettled\n"), result.stderr)
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(self.snapshot_mailbox(mailbox), before)

    def test_withdrawn_invalid_preflight_never_ingests_existing_ack(self):
        for case in ("proof", "tail", "namespace", "link"):
            with self.subTest(case=case):
                mailbox, records, _ = self.withdrawn_fixture(f"withdraw_ack_preflight_{case}")
                mailbox.worker("report", dict(kind="READY", payload=dict(state="idle")), check=True)
                chain = mailbox.acknowledge_pending(collect=False)
                if case == "proof":
                    records[0]["message_sha256"] = "0" * 64
                elif case == "tail":
                    (mailbox.box / "replies/4").mkdir()
                elif case == "namespace":
                    (mailbox.box / "staging/held").write_bytes(b"retain")
                else:
                    (mailbox.box / "staging/link").symlink_to(mailbox.box / "acks/2.json")
                before = self.snapshot_mailbox(mailbox)
                result = mailbox.retire_authorized(2, 1, chain, withdrawn=records)
                if case == "namespace":
                    self.assertEqual((result.returncode, result.stdout), (0, b"producer_unsettled\n"), result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.snapshot_mailbox(mailbox), before)

    def test_project_start_receipt_claim_report_replay_and_resolution(self):
        mailbox = Mailbox(self.root, "project_start", capabilities=START)
        mailbox.worker("report", dict(kind="REGISTER", payload=dict(capabilities=SEVEN + ["project-start-v1"])),
                       check=True)
        mailbox.acknowledge_pending()
        payload = self.project_start_payload()
        raw = mailbox.reply(1, transform=lambda reply: reply.update(kind="project_start", payload=payload))
        self.assertEqual(mailbox.worker("consume", check=True).stdout, raw)
        fact = mailbox.journal()["consumed"][0]
        self.assertEqual((fact["execution"], fact["sha256"]), ("unclaimed", digest(raw)))
        ack = json.loads(base64.b64decode(mailbox.journal()["pending"][0]["bytes"]))
        self.assertEqual((ack["action_id"], ack["action_revision"]), ("action_1", 1))
        self.assertEqual(ack["payload"]["reply_sha256"], digest(raw))
        mailbox.acknowledge_pending()
        self.assertEqual(mailbox.target("compact", report_floor=2, reply_floor=1).stdout, b"compacted\n")
        self.assertEqual(mailbox.worker("wait", check=True).stdout, raw)
        self.assertEqual(mailbox.journal()["next_seq"], 3)
        mailbox.worker("claim", message="message_1", check=True)
        self.assertNotEqual(mailbox.worker("claim", message="message_1").returncode, 0)
        self.assertEqual(mailbox.worker("consume", check=True).stdout, b"")
        claim = dict(kind="PROJECT_START_CLAIM", action_id="action_1", action_revision=1, payload=payload)
        mailbox.worker("report", claim, check=True)
        pending = mailbox.journal()["pending"][0]
        logical = base64.b64decode(pending["bytes"])
        published = json.loads(logical)
        self.assertEqual({key: published[key] for key in claim}, claim)
        self.assertEqual(pending["sha256"], digest(logical))
        manifest = (mailbox.box / "reports/3/manifest.json").read_bytes()
        mailbox.worker("replay", check=True)
        self.assertEqual((mailbox.box / "reports/3/manifest.json").read_bytes(), manifest)
        self.assertEqual(base64.b64decode(mailbox.journal()["pending"][0]["bytes"]), logical)
        mailbox.acknowledge_pending()
        mailbox.worker("resolve", message="message_1", check=True)
        self.assertEqual(mailbox.journal()["consumed"], [])

    def test_project_start_closed_payload_and_action_correlation(self):
        payload = self.project_start_payload()
        mutations = [{key: value for key, value in payload.items() if key != missing} for missing in payload]
        for field, value in [("owner_id", "bad id"), ("owner_generation", 0), ("owner_generation", True),
                             ("activation_token", "A" * 64), ("orch_project_id", ""),
                             ("project_revision", 0), ("project_revision", -1), ("project_revision", True),
                             ("project_revision", 1.5), ("project_revision", "1"),
                             ("project_revision", 9007199254740992), ("decision_context", "b" * 63),
                             ("decision_context", "B" * 64), ("instructions", "execute arbitrary work"),
                             ("extra", True)]:
            mutations.append(dict(payload, **{field: value}))
        for index, invalid in enumerate(mutations):
            with self.subTest(index=index):
                mailbox = Mailbox(self.root, f"start_invalid_{index}", capabilities=START)
                mailbox.reply(1, transform=lambda reply: reply.update(kind="project_start", payload=invalid))
                before = mailbox.journal_path.read_bytes()
                self.assertEqual(mailbox.worker("consume").stderr, b"invalid_schema\n")
                self.assertEqual(mailbox.journal_path.read_bytes(), before)
                report = dict(kind="PROJECT_START_CLAIM", action_id="action", action_revision=1, payload=invalid)
                self.assertEqual(mailbox.worker("report", report).stderr, b"invalid_schema\n")
                self.assertEqual(mailbox.journal_path.read_bytes(), before)
                self.assertEqual(list((mailbox.box / "reports").iterdir()), [])
        mailbox = Mailbox(self.root, "start_correlation", capabilities=START)
        valid = dict(kind="PROJECT_START_CLAIM", action_id="action", action_revision=1, payload=payload)
        invalid = [{key: value for key, value in valid.items() if key != missing}
                   for missing in ("action_id", "action_revision")]
        invalid += [dict(kind="PROJECT_START_CLAIM", payload=payload)]
        invalid += [dict(valid, action_id="bad id"), dict(valid, action_revision=0),
                    dict(valid, action_revision=True), dict(valid, action_revision=1.5),
                    dict(valid, handover_id="h", handover_token="x" * 16), dict(valid, extra=True)]
        before = mailbox.journal_path.read_bytes()
        for report in invalid:
            with self.subTest(report=report):
                self.assertEqual(mailbox.worker("report", report).stderr, b"invalid_schema\n")
                self.assertEqual(mailbox.journal_path.read_bytes(), before)

    def test_project_start_requires_both_capabilities_on_fresh_retained_and_report_replay(self):
        payload = self.project_start_payload()
        for index, capabilities in enumerate((None, ["report-files-v1"],
                                               ["report-files-v1", "coordinator-control-v1"],
                                               ["report-files-v1", "project-start-v1"])):
            for retained in (False, True):
                with self.subTest(capabilities=capabilities, retained=retained):
                    mailbox = Mailbox(self.root, f"start_caps_{index}_{int(retained)}", capabilities=START)
                    raw = mailbox.reply(1, transform=lambda reply: reply.update(kind="project_start", payload=payload))
                    if retained:
                        self.assertEqual(mailbox.worker("consume", check=True).stdout, raw)
                    # Simulate a descriptor losing one permission across restart.
                    provision_path = mailbox.box / "provision.json"
                    provision = json.loads(provision_path.read_bytes())
                    if capabilities is None:
                        provision.pop("capabilities")
                    else:
                        provision["capabilities"] = capabilities
                    provision_path.write_bytes(encode(provision))
                    before = mailbox.journal_path.read_bytes()
                    for mode in ("consume", "wait"):
                        result = mailbox.worker(mode)
                        self.assertEqual((result.returncode, result.stdout, result.stderr),
                                         (1, b"", b"unsupported_capability\n"))
                        self.assertEqual(mailbox.journal_path.read_bytes(), before)
                    report = dict(kind="PROJECT_START_CLAIM", action_id="action", action_revision=1, payload=payload)
                    self.assertEqual(mailbox.worker("report", report).stderr, b"unsupported_capability\n")
                    self.assertEqual(mailbox.journal_path.read_bytes(), before)
            mailbox = Mailbox(self.root, f"start_report_replay_{index}", capabilities=START)
            mailbox.worker("report", report, check=True)
            provision_path = mailbox.box / "provision.json"
            provision = json.loads(provision_path.read_bytes())
            provision["capabilities"] = capabilities or []
            provision_path.write_bytes(encode(provision))
            before = mailbox.journal_path.read_bytes()
            objects = {path: path.read_bytes() for path in (mailbox.box / "reports/1").iterdir()}
            self.assertEqual(mailbox.worker("replay").stderr, b"unsupported_capability\n")
            self.assertEqual(mailbox.journal_path.read_bytes(), before)
            self.assertEqual({path: path.read_bytes() for path in objects}, objects)

    def test_project_start_darwin_base64_and_shasum_paths(self):
        # Exercise the shipped fallback paths even on a Linux regression host.
        # macOS /bin/sh, awk and iconv still run natively when this suite runs there.
        mailbox = Mailbox(self.root, "start_darwin", capabilities=START)
        payload = self.project_start_payload()
        raw = mailbox.reply(1, transform=lambda reply: reply.update(kind="project_start", payload=payload))
        env = self.shim("base64", """args = sys.argv[1:]
if '-d' in args:
    sys.exit(1)
if '-D' in args and sys.platform != 'darwin':
    args[args.index('-D')] = '-d'
sys.exit(subprocess.run([actual] + args).returncode)
""")
        farm = self.root / "darwin-tools"
        farm.mkdir()
        for directory in env["PATH"].split(os.pathsep):
            if not os.path.isdir(directory):
                continue
            for entry in os.listdir(directory):
                source, link = os.path.join(directory, entry), farm / entry
                if entry != "sha256sum" and not os.path.lexists(link) and os.path.isfile(source) and os.access(source, os.X_OK):
                    link.symlink_to(source)
        self.assertIsNotNone(shutil.which("shasum", path=str(farm)))
        env["PATH"] = str(farm)
        retiring, withdrawn, chain = self.withdrawn_fixture("withdraw_darwin")
        # The exact same shipped seam must use BSD base64 -D and shasum.
        result = retiring.retire_authorized(1, 1, chain, withdrawn=withdrawn, env=env)
        self.assertEqual((result.returncode, result.stdout), (0, b"producer_retired\n"), result.stderr)
        part = retiring.box / "replies/2/chunk-1.json"
        original = part.read_bytes()
        part.write_bytes(b"{}")
        before = self.snapshot_mailbox(retiring)
        self.assertNotEqual(retiring.target("retire", report_floor=1, reply_floor=1,
                                           withdrawn=withdrawn, env=env).stdout, b"retired\n")
        self.assertEqual(self.snapshot_mailbox(retiring), before)
        part.write_bytes(original)
        self.assertEqual(retiring.target("retire", report_floor=1, reply_floor=1,
                                        withdrawn=withdrawn, env=env).stdout, b"retired\n")
        self.assertEqual(mailbox.worker("consume", env=env, check=True).stdout, raw)
        self.assertEqual(mailbox.worker("consume", env=env, check=True).stdout, raw)
        mailbox.worker("claim", message="message_1", env=env, check=True)
        mailbox.worker("report", dict(kind="PROJECT_START_CLAIM", action_id="action_1",
                                     action_revision=1, payload=payload), env=env, check=True)
        mailbox.worker("replay", env=env, check=True)
        published = json.loads(base64.b64decode(mailbox.journal()["pending"][-1]["bytes"]))
        self.assertEqual(published["payload"], payload)

    def test_coordinator_grant_entrypoints_closed_schema_and_exact_bytes(self):
        for kind, field, limit in [("coordinator_activation", "instructions", 32768),
                                   ("coordinator_retirement", "reason", 1024)]:
            payload = dict(owner_id="owner", owner_generation=1, activation_token="a" * 64,
                           **{field: "é" * (limit // 2)})
            def grant(reply):
                reply.update(kind=kind, payload=payload.copy())
            mailbox = Mailbox(self.root, kind)
            raw = mailbox.reply(1, transform=grant)
            for mode in ("consume", "wait"):
                self.assertEqual(mailbox.worker(mode, check=True).stdout, raw)
            retained = mailbox.journal()["consumed"][0]
            self.assertEqual(base64.b64decode(retained["bytes"]), raw)
            self.assertEqual(retained["sha256"], digest(raw))
            ack = json.loads(base64.b64decode(mailbox.journal()["pending"][0]["bytes"]))
            self.assertEqual(ack["payload"]["reply_sha256"], digest(raw))
            mutations = [("payload", key, None) for key in payload]
            mutations += [("payload", "extra", True), ("payload", "owner_id", "bad\n"),
                          ("payload", "owner_generation", 0), ("payload", "owner_generation", True),
                          ("payload", "owner_generation", 1.5), ("payload", "activation_token", "A" * 64),
                          ("payload", "activation_token", "a" * 63), ("payload", field, ""),
                          ("payload", field, "é" * (limit // 2) + "x"),
                          ("envelope", "extra", True), ("envelope", "action_id", None),
                          ("envelope", "action_revision", None), ("envelope", "action_revision", True),
                          ("envelope", "action_revision", 0)]
            for index, (location, key, value) in enumerate(mutations):
                with self.subTest(kind=kind, location=location, key=key, value=value):
                    rejected = Mailbox(self.root, kind + "_" + str(index))
                    def invalid(reply):
                        grant(reply)
                        target = reply["payload"] if location == "payload" else reply
                        if value is None:
                            del target[key]
                        else:
                            target[key] = value
                    rejected.reply(1, transform=invalid)
                    before = rejected.journal_path.read_bytes()
                    self.assertNotEqual(rejected.worker("consume").returncode, 0)
                    self.assertEqual(rejected.journal_path.read_bytes(), before)

    def test_record_ruling_durable_receipt_is_not_document_completion(self):
        document = self.root / "owner's existing plan.md"
        original = b"Plan\r\nProgress without final newline"
        document.write_bytes(original)
        payload = dict(path=str(document), marker="orchplus-ruling:authority:gate",
                       entry="> Owner: approve &lt;literal&gt; &#96;work&#96;\n> Context: café",
                       expected_document_sha256=digest(original),
                       expected_non_rulings_sha256=digest(original))
        def ruling(reply):
            reply.update(kind="record_ruling", gate_id="gate", gate_revision=1, payload=payload.copy())

        # Neither a legacy descriptor nor an unrelated permission can grant writing.
        for suffix, capabilities in (("legacy", None), ("release", RELEASE)):
            mailbox = Mailbox(self.root, "ruling_" + suffix, capabilities=capabilities)
            mailbox.reply(1, transform=ruling)
            before = mailbox.journal_path.read_bytes()
            descriptor = (mailbox.box / "provision.json").read_bytes()
            result = mailbox.worker("consume")
            self.assertEqual((result.returncode, result.stdout, result.stderr),
                             (1, b"", b"unsupported_capability\n"))
            self.assertEqual(mailbox.journal_path.read_bytes(), before)
            self.assertEqual((mailbox.box / "provision.json").read_bytes(), descriptor)
            self.assertEqual(list((mailbox.box / "reports").iterdir()), [])

        mailbox = Mailbox(self.root, "ruling_control",
                          capabilities=["report-files-v1", "coordinator-control-v1"])
        raw = mailbox.reply(1, transform=ruling)
        self.assertEqual(mailbox.worker("consume", check=True).stdout, raw)
        self.assertEqual(document.read_bytes(), original)
        fact = mailbox.journal()["consumed"][0]
        self.assertEqual((fact["execution"], fact["ack_seq"]), ("unclaimed", 1))
        ack = json.loads(base64.b64decode(mailbox.journal()["pending"][0]["bytes"]))
        self.assertEqual(ack["payload"]["status"], "recorded")
        self.assertEqual(ack["payload"]["reply_sha256"], digest(raw))
        mailbox.acknowledge_pending()
        self.assertEqual(mailbox.target("compact", report_floor=1, reply_floor=1).stdout, b"compacted\n")
        self.assertEqual(mailbox.worker("wait", check=True).stdout, raw)
        self.assertEqual(mailbox.journal()["next_seq"], 2)
        self.assertEqual(mailbox.journal()["consumed"][0]["execution"], "unclaimed")
        mailbox.worker("claim", message="message_1", check=True)
        self.assertNotEqual(mailbox.worker("claim", message="message_1").returncode, 0)
        self.assertEqual(mailbox.worker("consume", check=True).stdout, b"")
        # Only the existing writer could perform the effect after claim. The helper
        # neither appends nor mistakes transport acknowledgement for that effect.
        self.assertEqual(document.read_bytes(), original)
        mailbox.worker("resolve", message="message_1", check=True)
        self.assertEqual(mailbox.journal()["consumed"], [])
        self.assertEqual(document.read_bytes(), original)

    def test_record_ruling_literal_and_utf8_bounds(self):
        corpus = json.loads((SOURCE.parents[2] / "shared/report-files-v1/corpus.json").read_bytes())
        valid = json.loads(base64.b64decode(next(case["bytes_b64"] for case in corpus["cases"]
                                               if case["id"] == "c3-ruling-valid")))
        mutations = [
            ("payload", "entry", "> "),  # An empty quoted line is literal content.
            ("payload", "entry", "> " + "é" * 4095),
            ("payload", "path", r"\\server\share\existing.md"),
            ("payload", "entry", "> " + "é" * 4095 + "x"),
            ("payload", "entry", "> text\n"),
            ("payload", "entry", "> text\r\n> text"),
            ("payload", "entry", "> text\x00"),
            ("payload", "entry", "> `command`"),
            ("payload", "entry", "> nested > quote"),
            ("payload", "path", "/existing\x00.md"),
            ("payload", "marker", "orchplus-ruling:" + "a" * 237 + ":gate"),
            ("payload", "marker", "orchplus-ruling:authority:gate\n"),
            ("envelope", "gate_revision", True),
            ("envelope", "gate_revision", 0),
            ("envelope", "gate_id", "Gate"),
        ]
        for index, (location, field, value) in enumerate(mutations):
            with self.subTest(location=location, field=field, value=value[:80] if isinstance(value, str) else value):
                mailbox = Mailbox(self.root, f"ruling_literal_{index}",
                                  capabilities=["report-files-v1", "coordinator-control-v1"])
                reply = json.loads(json.dumps(valid))
                (reply["payload"] if location == "payload" else reply)[field] = value
                raw = encode(reply)
                mailbox.install_reply(raw, 1, reply["message_id"])
                before = mailbox.journal_path.read_bytes()
                result = mailbox.worker("consume")
                if index < 3:
                    self.assertEqual((result.returncode, result.stdout), (0, raw), result.stderr)
                else:
                    self.assertEqual((result.returncode, result.stdout), (1, b""))
                    self.assertEqual(mailbox.journal_path.read_bytes(), before)
                    self.assertEqual(list((mailbox.box / "reports").iterdir()), [])

    def test_landing_grant_entrypoint_closed_schema_and_exact_bytes(self):
        payload = dict(landing_id="landing", grant_id="grant", project_id="project", checkpoint_id="checkpoint",
                       repo_ref="repo", target_ref="main", target_revision="base", source_ref="work", source_revision="revision",
                       builder_work_id="builder", review_id="review", reviewer_family="openai",
                       proof=dict(mode="cross_family_review", artifact_revision="revision", review_id="review", check_refs=[]))
        def grant(reply):
            reply.update(kind="landing_grant", payload=payload.copy())
        mailbox = Mailbox(self.root, "landing_grant", capabilities=RELEASE)
        raw = mailbox.reply(1, transform=grant)
        self.assertEqual(mailbox.worker("consume", check=True).stdout, raw)
        ack = json.loads(base64.b64decode(mailbox.journal()["pending"][0]["bytes"]))
        self.assertEqual(ack["payload"]["reply_sha256"], digest(raw))
        mutations = [(key, None) for key in payload]
        mutations += [("extra", True), ("landing_id", "bad id"), ("grant_id", ""), ("repo_ref", ""),
                      ("target_revision", "é" * 513), ("source_ref", 1)]
        for index, (key, value) in enumerate(mutations):
            with self.subTest(key=key, value=value):
                rejected = Mailbox(self.root, "landing_grant_" + str(index), capabilities=RELEASE)
                def invalid(reply):
                    grant(reply)
                    if value is None:
                        del reply["payload"][key]
                    else:
                        reply["payload"][key] = value
                rejected.reply(1, transform=invalid)
                before = rejected.journal_path.read_bytes()
                self.assertNotEqual(rejected.worker("consume").returncode, 0)
                self.assertEqual(rejected.journal_path.read_bytes(), before)

    def test_landing_refresh_entrypoint_closed_schema_and_exact_bytes(self):
        payload = dict(landing_id="landing", project_id="project", repo_ref="repo", target_ref="main",
                       expected_revision="base", current_revision="moved", reason="Target moved; refresh against current_revision.")
        def refresh(reply):
            reply.update(kind="landing_refresh", payload=payload.copy())
        mailbox = Mailbox(self.root, "landing_refresh")
        raw = mailbox.reply(1, transform=refresh)
        self.assertEqual(mailbox.worker("consume", check=True).stdout, raw)
        ack = json.loads(base64.b64decode(mailbox.journal()["pending"][0]["bytes"]))
        self.assertEqual(ack["payload"]["reply_sha256"], digest(raw))
        mutations = [(key, None) for key in payload]
        mutations += [("extra", True), ("landing_id", "bad id"), ("project_id", ""), ("repo_ref", ""),
                      ("current_revision", "é" * 513), ("reason", 1)]
        for index, (key, value) in enumerate(mutations):
            with self.subTest(key=key, value=value):
                rejected = Mailbox(self.root, "landing_refresh_" + str(index))
                def invalid(reply):
                    refresh(reply)
                    if value is None:
                        del reply["payload"][key]
                    else:
                        reply["payload"][key] = value
                rejected.reply(1, transform=invalid)
                before = rejected.journal_path.read_bytes()
                self.assertNotEqual(rejected.worker("consume").returncode, 0)
                self.assertEqual(rejected.journal_path.read_bytes(), before)

    def assert_reply_kind(self, kind, payload, mutations, capabilities=None, optional=()):
        def build(reply):
            reply.update(kind=kind, payload=json.loads(json.dumps(payload)))
        mailbox = Mailbox(self.root, kind, capabilities=capabilities)
        raw = mailbox.reply(1, transform=build)
        self.assertEqual(mailbox.worker("consume", check=True).stdout, raw)
        removals = [(key, None) for key in payload if key not in optional]
        for index, (key, value) in enumerate(removals + mutations):
            with self.subTest(kind=kind, key=key, value=value):
                rejected = Mailbox(self.root, f"{kind}_{index}", capabilities=capabilities)
                def invalid(reply):
                    build(reply)
                    if value is None:
                        del reply["payload"][key]
                    else:
                        reply["payload"][key] = value
                rejected.reply(1, transform=invalid)
                before = rejected.journal_path.read_bytes()
                self.assertNotEqual(rejected.worker("consume").returncode, 0)
                self.assertEqual(rejected.journal_path.read_bytes(), before)

    def assert_reply_needs_release_manager(self, kind, payload):
        # Without release-manager-v1 the grant is refused before any receipt.
        for suffix, capabilities in (("none", None), ("checks", CHECKS)):
            with self.subTest(kind=kind, capabilities=capabilities):
                mailbox = Mailbox(self.root, f"{kind}_{suffix}", capabilities=capabilities)
                mailbox.reply(1, transform=lambda reply: reply.update(kind=kind, payload=dict(payload)))
                before = mailbox.journal_path.read_bytes()
                self.assertNotEqual(mailbox.worker("consume").returncode, 0)
                self.assertEqual(mailbox.journal_path.read_bytes(), before)

    def test_new_reply_kinds_closed_schema_and_capability(self):
        self.assert_reply_kind("review_request", dict(
            review_id="review", round=1, question_id="implements_task_v1", builder_work_id="builder", task_ref="task",
            plan_ref="plan", plan_revision="3", source_ref="work", artifact_revision="revision",
            scope_paths=["a.luau"], findings_prev=[]), [("extra", True), ("question_id", "score_v1")],
            optional=("plan_ref", "plan_revision"))
        self.assert_reply_kind("rework", dict(
            review_id="review", round=2, artifact_revision="revision", failed_checks=[dict(check_id="c1", exit_code=1)],
            findings=[dict(finding_id="f1", path="a.luau", line=3, summary="Missing bound.")]),
            [("extra", True), ("failed_checks", [dict(check_id="c1")])], optional=("review_id",))
        deploy = dict(deploy_id="deploy", attempt_id="attempt", landing_id="landing", revision="revision", target_ref="production")
        self.assert_reply_kind("deploy_grant", deploy, [("extra", True), ("deploy_id", "bad id"), ("revision", "")],
                               capabilities=RELEASE)
        self.assert_reply_needs_release_manager("deploy_grant", deploy)
        self.assert_reply_kind("label_request", dict(work_ref="work", classes=["feature", "fix"], text="Classify."),
                               [("extra", True), ("classes", "feature")])
        self.assert_reply_needs_release_manager("landing_grant", dict(
            landing_id="landing", grant_id="grant", project_id="project", checkpoint_id="checkpoint",
            repo_ref="repo", target_ref="main", target_revision="base", source_ref="work", source_revision="revision",
            builder_work_id="builder", review_id="review", reviewer_family="openai",
            proof=dict(mode="helper_checks", artifact_revision="revision", review_id="review", check_refs=["c1"])))

    def test_new_report_kinds_and_capability_bound(self):
        valid = [
            dict(kind="LABEL", action_id="label", action_revision=1, payload={"work_ref": "work", "class": "feature", "reason": "new mode"}),
            dict(kind="REVIEW_RESULT", action_id="review", action_revision=1, payload=dict(
                review_id="review", round=1, artifact_revision="revision", outcome="changes_required",
                findings=[dict(finding_id="f1", path="a.luau", line=3, summary="Missing bound.")], summary="One")),
            dict(kind="DONE", payload=dict(checkpoint_id="cp", artifact_revision="revision", summary="done", output_ref="out/a.md")),
            dict(kind="REGISTER", payload=dict(capabilities=SEVEN)),
        ]
        deploy = dict(kind="DEPLOY_RESULT", action_id="deploy", action_revision=1, payload=dict(
            deploy_id="deploy", attempt_id="attempt", landing_id="landing", outcome="deployed", revision="revision", evidence=[]))
        for index, (capabilities, value) in enumerate([(None, value) for value in valid] + [(RELEASE, deploy)]):
            with self.subTest(kind=value["kind"]):
                mailbox = Mailbox(self.root, "new_valid_" + str(index), capabilities=capabilities)
                mailbox.worker("report", value, check=True)
                report = json.loads(base64.b64decode(mailbox.journal()["pending"][0]["bytes"]))
                self.assertEqual(report["payload"], value["payload"])
        invalid = [
            (None, dict(kind="REGISTER", payload=dict(capabilities=SEVEN + ["invented-v1"]))),
            (None, dict(kind="REGISTER", payload=dict(capabilities=SEVEN + ["argv-v1"]))),
            (None, dict(kind="REVIEW_RESULT", action_id="review", action_revision=1, payload=dict(
                artifact_revision="revision", outcome="approved", evidence=[]))),
            (None, dict(kind="DONE", payload=dict(checkpoint_id="cp", artifact_revision="revision", summary="done", output_ref="o" * 257))),
            (None, dict(kind="LABEL", action_id="label", action_revision=1, payload={"work_ref": "work", "class": "feature", "extra": 1})),
            (None, dict(kind="LABEL", payload={"work_ref": "work", "class": "feature"})),
            (None, deploy), (CHECKS, deploy),
        ]
        for index, (capabilities, value) in enumerate(invalid):
            with self.subTest(index=index):
                mailbox = Mailbox(self.root, "new_invalid_" + str(index), capabilities=capabilities)
                before = mailbox.journal_path.read_bytes()
                self.assertNotEqual(mailbox.worker("report", value).returncode, 0)
                self.assertEqual(mailbox.journal_path.read_bytes(), before)

    def test_report_mode_refuses_helper_only_kinds(self):
        mailbox = Mailbox(self.root, "helper_only", manifest=canonical(dict(checks=[], base_ref="", files=[], scope=dict(paths=[], systems=[]))),
                          capabilities=CHECKS)
        for value in (dict(kind="CHECK_RESULT", payload=dict(check_id="c", argv_sha256="a" * 64, exit_code=0,
                                                             output_sha256="a" * 64, head="a" * 40, ran_at_ms=1)),
                      dict(kind="CHECKOUT", payload=dict(worktree_path="/w", common_dir="/w/.git", branch="main", head="a" * 40,
                                                         changed_files=[], changed_overflow=False, changed_total=0, dirty=False))):
            with self.subTest(kind=value["kind"]):
                before = mailbox.journal_path.read_bytes()
                result = mailbox.worker("report", value)
                self.assertEqual((result.returncode, result.stderr), (1, b"helper_only_kind\n"))
                self.assertEqual(mailbox.journal_path.read_bytes(), before)
                self.assertEqual(list((mailbox.box / "reports").iterdir()), [])


    def test_crash_after_receipt_commit_before_ack_publication_and_stdout(self):
        raw = self.mailbox.reply(1)
        env = self.shim("mv", """result = subprocess.run([actual] + sys.argv[1:]).returncode
if result == 0 and sys.argv[-1] == os.environ['TEST_JOURNAL']:
    journal = json.loads(pathlib.Path(os.environ['TEST_JOURNAL']).read_bytes())
    if journal['consumed'] and journal['consumed'][0]['ack_seq'] > 0:
        os.kill(os.getppid(), signal.SIGKILL)
sys.exit(result)
""")
        result = self.mailbox.worker("consume", env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(self.mailbox.journal()["reply_next"], 2)
        self.mailbox.recover_stopped_worker()
        self.assertEqual(self.mailbox.worker("consume", check=True).stdout, raw)
        self.assertEqual(self.mailbox.journal()["next_seq"], 2)
        self.assertEqual(self.mailbox.worker("consume", check=True).stdout, raw)
        self.assertEqual(self.mailbox.journal()["next_seq"], 2)

    def test_crash_after_ack_publication_before_stdout_and_host_compaction(self):
        raw = self.mailbox.reply(1)
        env = self.shim("rmdir", """result = subprocess.run([actual] + sys.argv[1:]).returncode
if result == 0 and sys.argv[-1].endswith('/capacity.lock'):
    journal = json.loads(pathlib.Path(os.environ['TEST_JOURNAL']).read_bytes())
    if journal['consumed'] and journal['consumed'][0]['ack_seq'] > 0:
        os.kill(os.getppid(), signal.SIGKILL)
sys.exit(result)
""")
        result = self.mailbox.worker("consume", env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.mailbox.recover_stopped_worker()
        self.mailbox.acknowledge_pending()
        self.assertEqual(self.mailbox.journal()["consumed_reply_floor"], 1)
        result = self.mailbox.target("compact", report_floor=1, reply_floor=1)
        self.assertEqual(result.stdout, b"compacted\n")
        self.assertEqual(self.mailbox.worker("consume", check=True).stdout, raw)
        self.mailbox.worker("claim", message="message_1", check=True)
        self.assertEqual(self.mailbox.worker("consume", check=True).stdout, b"")
        self.assertNotEqual(self.mailbox.worker("claim", message="message_1").returncode, 0)
        journal = self.mailbox.journal()
        journal["consumed"][0]["execution"] = "uncertain"
        self.mailbox.journal_path.write_bytes(encode(journal))
        self.assertEqual(self.mailbox.worker("consume", check=True).stdout, b"")
        self.assertNotEqual(self.mailbox.worker("claim", message="message_1").returncode, 0)
        self.assertNotEqual(self.mailbox.worker("retire-local").returncode, 0)

    def test_acknowledged_retained_execution_bound_remains_visible(self):
        for seq in range(1, 9):
            raw = self.mailbox.reply(seq)
            self.assertEqual(self.mailbox.worker("consume", check=True).stdout, raw)
            self.mailbox.worker("claim", message="message_" + str(seq), check=True)
        self.mailbox.acknowledge_pending()
        self.assertEqual(len(self.mailbox.journal()["consumed"]), 8)
        raw = self.mailbox.reply(9)
        result = self.mailbox.worker("consume")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"full", result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(self.mailbox.journal()["reply_next"], 9)
        self.mailbox.worker("resolve", message="message_1", check=True)
        self.assertEqual(self.mailbox.worker("consume", check=True).stdout, raw)

    def test_ordinary_byte_pressure_preserves_ack_watermark_and_journal_replacement(self):
        self.mailbox.worker("report", dict(kind="READY", payload=dict(state="idle")), check=True)
        self.mailbox.fill_bytes()
        original = self.mailbox.journal_path.read_bytes()
        result = self.mailbox.worker("report", dict(kind="READY", payload=dict(state="idle")))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"full", result.stderr)
        self.assertEqual(self.mailbox.journal_path.read_bytes(), original)
        self.assert_full(self.mailbox.target("publish", "replies/1/chunk-1.json", b"x").stdout, "mailbox_bytes")
        self.mailbox.acknowledge_pending()
        self.assertEqual(self.mailbox.journal()["receipt_seq"], 1)
        self.assertTrue((self.mailbox.box / "watermarks/1.json").is_file())
        self.assertEqual(self.mailbox.target("compact", report_floor=1).stdout, b"compacted\n")
        size, files = self.mailbox.usage()
        self.assertLessEqual(size, HARD_BYTES)
        self.assertLessEqual(files, HARD_FILES)

    def test_fresh_consumption_uses_drain_capacity_at_ordinary_byte_ceiling(self):
        raw = self.mailbox.reply(1)
        self.mailbox.fill_bytes()
        self.assertEqual(self.mailbox.worker("consume", check=True).stdout, raw)
        self.assertEqual(self.mailbox.journal()["consumed"][0]["ack_seq"], 1)
        self.mailbox.acknowledge_pending()
        self.assertEqual(self.mailbox.journal()["consumed_reply_floor"], 1)
        self.mailbox.worker("claim", message="message_1", check=True)
        self.mailbox.worker("resolve", message="message_1", check=True)
        self.assertEqual(self.mailbox.journal()["consumed"], [])
        self.assertLessEqual(self.mailbox.usage()[0], HARD_BYTES)

    def test_no_receipt_cursor_commit_without_ack_slot_admission(self):
        for seq in range(1, 9):
            value = dict(kind="reply_ack", action_id="a", action_revision=1,
                         payload=dict(message_id="m_" + str(seq), reply_seq=seq,
                                      reply_sha256="a" * 64, status="recorded"))
            self.mailbox.worker("report", value, check=True)
        self.mailbox.reply(1)
        original = self.mailbox.journal_path.read_bytes()
        result = self.mailbox.worker("consume")
        self.assertNotEqual(result.returncode, 0)
        self.assert_full(result.stderr, "pending_reports")
        self.assertEqual(self.mailbox.journal_path.read_bytes(), original)
        self.assertEqual(self.mailbox.journal()["reply_next"], 1)

    def test_file_pressure_preserves_reply_ack_and_exact_journal_save(self):
        raw = self.mailbox.reply(1)
        self.assertEqual(self.mailbox.worker("consume", check=True).stdout, raw)
        # Restore the durable receipt-before-ACK state to test the reserved path
        # at a full ordinary file quota, without allocating a second reply.
        journal = self.mailbox.journal()
        journal["consumed"][0]["ack_seq"] = 0
        journal["next_seq"] = 1
        journal["pending"] = []
        self.mailbox.journal_path.write_bytes(encode(journal))
        shutil.rmtree(self.mailbox.box / "reports/1")
        _, files = self.mailbox.usage()
        for index in range(ORDINARY_FILES - files):
            (self.mailbox.box / "consumer" / ("pad_" + str(index))).touch()
        self.assert_full(self.mailbox.target("publish", "replies/2/chunk-1.json", b"x").stdout, "mailbox_files")
        self.assertEqual(self.mailbox.worker("consume", check=True).stdout, raw)
        self.assertEqual(self.mailbox.journal()["consumed"][0]["ack_seq"], 1)
        self.assertLessEqual(self.mailbox.usage()[1], HARD_FILES)

    def test_target_and_worker_share_admission_through_commit(self):
        marker, release = self.root / "at_link", self.root / "release_link"
        env = self.shim("ln", """root = pathlib.Path(os.environ['TEST_ROOT'])
(root / 'at_link').touch()
while not (root / 'release_link').exists():
    time.sleep(0.01)
sys.exit(subprocess.run([actual] + sys.argv[1:]).returncode)
""")
        process = subprocess.Popen(self.mailbox.worker_argv("report"), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.addCleanup(self.stop_process, process, release)
        process.stdin.write(encode(dict(kind="READY", payload=dict(state="idle"))))
        process.stdin.close()
        process.stdin = None
        until(marker.exists)
        self.assertTrue((self.mailbox.box / "capacity.lock").is_dir())
        self.assertEqual(self.mailbox.target("publish", "replies/1/chunk-1.json", b"x" * 3000).stdout, b"admission_full\ncapacity_admission\n1\n1\n")
        release.touch()
        stdout, stderr = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(stdout, b"")
        self.assertFalse((self.mailbox.box / "capacity.lock").exists())
        self.assertLessEqual(self.mailbox.usage()[0], ORDINARY_BYTES)

    def test_wait_releases_shared_gate_before_sleep_and_never_steals_gate(self):
        marker, release = self.root / "sleeping", self.root / "wake"
        env = self.shim("sleep", """root = pathlib.Path(os.environ['TEST_ROOT'])
(root / 'sleeping').touch()
while not (root / 'wake').exists():
    time.sleep(0.01)
sys.exit(subprocess.run([actual] + sys.argv[1:]).returncode)
""")
        process = subprocess.Popen(self.mailbox.worker_argv("wait", seconds=30),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.addCleanup(self.stop_process, process, release)
        until(marker.exists)
        self.assertTrue((self.mailbox.box / "producer/lock").is_dir())
        self.assertFalse((self.mailbox.box / "capacity.lock").exists())
        raw = self.mailbox.reply(1)
        release.touch()
        stdout, stderr = process.communicate(timeout=20)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(stdout, raw)
        gate = self.mailbox.box / "capacity.lock"
        gate.mkdir()
        os.utime(gate, (1, 1))
        result = self.mailbox.worker("receipts")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"producer_locked", result.stderr)
        self.assertEqual(self.mailbox.target("publish", "acks/1.json", b"{}").stdout, b"admission_full\ncapacity_admission\n1\n1\n")
        self.assertTrue(gate.is_dir())
        gate.rmdir()

    def paused_wait(self):
        # `wait` paused in its first poll sleep, holding only its producer lock.
        # Fractional gate-wait sleeps pass straight through and are recorded.
        env = self.shim("sleep", """root = pathlib.Path(os.environ['TEST_ROOT'])
if sys.argv[1:] == ['0.1']:
    (root / 'gate_wait').touch()
else:
    (root / 'sleeping').touch()
    while not (root / 'wake').exists():
        time.sleep(0.01)
sys.exit(subprocess.run([actual] + sys.argv[1:]).returncode)
""")
        process = subprocess.Popen(self.mailbox.worker_argv("wait", seconds=30), env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        self.addCleanup(self.stop_process, process, self.root / "wake")
        until((self.root / "sleeping").exists)
        self.assertTrue((self.mailbox.box / "producer/lock").is_dir())
        self.assertFalse((self.mailbox.box / "capacity.lock").exists())
        return process

    def assert_producer_released(self):
        for leftover in ("producer/lock", "staging/worker-" + OWNER):
            self.assertFalse((self.mailbox.box / leftover).exists(), leftover + " leaked")

    def test_wait_poll_waits_out_busy_gate_then_releases_producer_lock(self):
        # Final-smoke leak: a later poll met the target's short-lived gate, failed
        # producer_locked, and exit cleanup could not re-take the gate to remove
        # its lock, so every later call was refused producer_locked.
        process = self.paused_wait()
        raw = self.mailbox.reply(1)
        gate = self.mailbox.box / "capacity.lock"
        gate.mkdir()
        (self.root / "wake").touch()
        until(lambda: process.poll() is not None or (self.root / "gate_wait").exists())
        self.assertTrue(gate.is_dir())
        gate.rmdir()
        stdout, stderr = process.communicate(timeout=30)
        self.assert_producer_released()
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(stdout, raw)
        self.assertFalse(gate.exists())
        self.assertEqual(self.mailbox.worker("receipts").returncode, 0)

    def test_interrupted_wait_waits_out_busy_gate_then_releases_producer_lock(self):
        process = self.paused_wait()
        gate = self.mailbox.box / "capacity.lock"
        gate.mkdir()
        os.killpg(process.pid, signal.SIGTERM)
        until(lambda: process.poll() is not None or (self.root / "gate_wait").exists())
        # Cleanup waits for the other holder; it never takes or removes that gate.
        self.assertTrue(gate.is_dir())
        gate.rmdir()
        _, stderr = process.communicate(timeout=30)
        self.assertNotEqual(process.returncode, 0)
        self.assert_producer_released()
        self.assertFalse(gate.exists())
        result = self.mailbox.worker("receipts")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_interrupted_wait_releases_own_lock_but_never_takes_held_gate(self):
        process = self.paused_wait()
        gate = self.mailbox.box / "capacity.lock"
        gate.mkdir()
        os.utime(gate, (1, 1))
        started = time.monotonic()
        os.killpg(process.pid, signal.SIGTERM)
        _, stderr = process.communicate(timeout=60)
        elapsed = time.monotonic() - started
        self.assertNotEqual(process.returncode, 0)
        # Release of its own lock does not depend on the gate; the gate is untouched.
        self.assert_producer_released()
        self.assertTrue(gate.is_dir())
        self.assertEqual(gate.stat().st_mtime, 1)
        # It first waited out the gate (which is normally short-lived).
        self.assertGreaterEqual(elapsed, 5)
        result = self.mailbox.worker("receipts")
        self.assertIn(b"producer_locked", result.stderr)
        self.assert_producer_released()
        # Explicit recovery of the abandoned gate alone makes the mailbox usable.
        gate.rmdir()
        result = self.mailbox.worker("receipts")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_read_and_compaction_remain_available_above_byte_ceiling(self):
        self.mailbox.worker("report", dict(kind="READY", payload=dict(state="idle")), check=True)
        self.mailbox.fill_bytes(HARD_BYTES + 1)
        self.assertTrue(self.mailbox.target("read", "reports/1/manifest.json").stdout.startswith(b"object\n"))
        self.assertEqual(self.mailbox.target("compact", report_floor=1).stdout, b"compacted\n")


class PosixHelperModeTests(unittest.TestCase):
    """run-checks and checkout on disposable git repositories (Contracts C/F/G)."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spawn-helper-modes-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.base = make_repo(self.repo)
        self.count = 0

    def manifest(self, checks=()):
        return canonical(dict(checks=list(checks), base_ref=self.base, files=[], scope=dict(paths=[], systems=[])))

    def mailbox(self, manifest=None, capabilities=CHECKS):
        self.count += 1
        return Mailbox(self.root, "helper_" + str(self.count), manifest=manifest, capabilities=capabilities)

    def published(self, mailbox):
        pending = mailbox.journal()["pending"]
        self.assertEqual(len(pending), 1)
        self.assertTrue((mailbox.box / "reports/1/manifest.json").is_file())
        return json.loads(base64.b64decode(pending[0]["bytes"]))

    def refused(self, mailbox, mode, code, message="", cwd=None, env=None):
        before = mailbox.journal_path.read_bytes()
        result = mailbox.worker(mode, message=message, cwd=cwd or self.repo, env=env)
        self.assertEqual((result.returncode, result.stderr, result.stdout), (1, code.encode() + b"\n", b""))
        self.assertEqual(mailbox.journal_path.read_bytes(), before)
        self.assertEqual(list((mailbox.box / "reports").iterdir()), [])

    def checkout(self, cwd=None):
        mailbox = self.mailbox(self.manifest())
        result = mailbox.worker("checkout", cwd=cwd or self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = self.published(mailbox)
        self.assertEqual(report["kind"], "CHECKOUT")
        return report["payload"]

    def test_run_checks_pass_and_fail_are_both_reported(self):
        checks = [dict(check_id="t1-c1", argv=["true"]), dict(check_id="t1-c2", argv=["false"]),
                  dict(check_id="t1-c3", argv=["printf", "%s", "a b;$(x)"])]
        manifest = self.manifest(checks)
        head = git(self.repo, "rev-parse", "HEAD")
        for check, exit_code, output in ((checks[0], 0, b""), (checks[1], 1, b""), (checks[2], 0, b"a b;$(x)")):
            with self.subTest(check=check["check_id"]):
                mailbox = self.mailbox(manifest)
                before = int(time.time() * 1000)
                result = mailbox.worker("run-checks", message=check["check_id"], cwd=self.repo)
                self.assertEqual((result.returncode, result.stdout), (0, b""), result.stderr)
                report = self.published(mailbox)
                self.assertEqual(report["kind"], "CHECK_RESULT")
                payload = report["payload"]
                self.assertEqual(sorted(payload), ["argv_sha256", "check_id", "exit_code", "head", "output_sha256", "ran_at_ms"])
                self.assertEqual((payload["check_id"], payload["exit_code"], payload["head"]), (check["check_id"], exit_code, head))
                self.assertEqual(payload["argv_sha256"], digest(encode(check["argv"])))
                # Output is hashed, never published; argv metacharacters reach printf unexpanded.
                self.assertEqual(payload["output_sha256"], digest(output))
                self.assertNotIn(b"a b;", base64.b64decode(mailbox.journal()["pending"][0]["bytes"]))
                self.assertGreaterEqual(payload["ran_at_ms"], before - 1000)

    def test_run_checks_output_hash_is_capped_at_64_kib(self):
        big = self.root / "big.bin"
        big.write_bytes(b"x" * 70000)
        mailbox = self.mailbox(self.manifest([dict(check_id="cat", argv=["cat", str(big)])]))
        mailbox.worker("run-checks", message="cat", cwd=self.repo, check=True)
        payload = self.published(mailbox)["payload"]
        self.assertEqual((payload["exit_code"], payload["output_sha256"]), (0, digest(b"x" * 65536)))

    def test_run_checks_and_checkout_refusals(self):
        manifest = self.manifest([dict(check_id="t1-c1", argv=["true"])])
        self.refused(self.mailbox(manifest), "run-checks", "check_undeclared", message="t1-c9")
        for mode, message in (("run-checks", "t1-c1"), ("checkout", "")):
            with self.subTest(mode=mode):
                # Capability is checked first, before any manifest fact.
                self.refused(self.mailbox(manifest, capabilities=["report-files-v1"]), mode, "unsupported_capability", message=message)
                self.refused(self.mailbox(None, capabilities=None), mode, "unsupported_capability", message=message)
                self.refused(self.mailbox(None), mode, "manifest_missing", message=message)
                missing = self.mailbox(manifest)
                (missing.box / "manifest.json").unlink()
                self.refused(missing, mode, "manifest_mismatch", message=message)
                tampered = self.mailbox(manifest)
                # A worker editing argv after provisioning cannot run it.
                (tampered.box / "manifest.json").write_bytes(manifest.replace(b'"true"', b'"echo"'))
                self.refused(tampered, mode, "manifest_mismatch", message=message)

    def test_provision_writes_manifest_verbatim(self):
        manifest = self.manifest([dict(check_id="t1-c1", argv=["true"])])
        mailbox = self.mailbox(manifest)
        self.assertEqual((mailbox.box / "manifest.json").read_bytes(), manifest)
        self.assertEqual(json.loads((mailbox.box / "provision.json").read_bytes())["manifest_sha256"], digest(manifest))
        self.assertFalse((self.mailbox(None).box / "manifest.json").exists())

    def test_checkout_clean_repository(self):
        payload = self.checkout()
        self.assertEqual(payload["worktree_path"], os.path.realpath(self.repo))
        self.assertEqual(payload["common_dir"], os.path.realpath(self.repo / ".git"))
        self.assertEqual((payload["branch"], payload["head"], payload["base"]), ("main", self.base, self.base))
        self.assertEqual((payload["changed_files"], payload["changed_overflow"], payload["changed_total"], payload["dirty"]),
                         ([], False, 0, False))

    def test_checkout_dirty_repository_unions_committed_staged_unstaged(self):
        (self.repo / "committed.txt").write_text("c\n")
        git(self.repo, "add", "committed.txt")
        git(self.repo, "commit", "-q", "-m", "work")
        (self.repo / "tracked.txt").write_text("changed\n")
        (self.repo / "staged.txt").write_text("s\n")
        git(self.repo, "add", "staged.txt")
        payload = self.checkout()
        self.assertEqual((payload["head"], payload["base"]), (git(self.repo, "rev-parse", "HEAD"), self.base))
        self.assertEqual(payload["changed_files"], ["committed.txt", "staged.txt", "tracked.txt"])
        self.assertEqual((payload["changed_overflow"], payload["changed_total"], payload["dirty"]), (False, 3, True))

    def test_checkout_untracked_only(self):
        (self.repo / "sub").mkdir()
        (self.repo / "sub/new.txt").write_text("n\n")
        payload = self.checkout()
        self.assertEqual(payload["changed_files"], ["sub/new.txt"])
        self.assertEqual((payload["changed_total"], payload["dirty"]), (1, True))

    def test_checkout_linked_worktree_reports_own_top_level_and_shared_common_dir(self):
        linked = self.root / "linked"
        git(self.repo, "worktree", "add", "-q", "-b", "side", str(linked))
        (linked / "nested").mkdir()
        payload = self.checkout(cwd=linked / "nested")
        self.assertEqual(payload["worktree_path"], os.path.realpath(linked))
        self.assertEqual(payload["common_dir"], os.path.realpath(self.repo / ".git"))
        self.assertEqual(payload["branch"], "side")

    def test_checkout_overflow_beyond_512_paths(self):
        names = [f"many/f{index:04d}.txt" for index in range(600)]
        (self.repo / "many").mkdir()
        for name in names:
            (self.repo / name).write_text("x")
        payload = self.checkout()
        self.assertEqual((payload["changed_overflow"], payload["changed_total"]), (True, 600))
        self.assertEqual(payload["changed_files"], sorted(names)[:512])

    def test_checkout_without_base_ref_pins_launch_base(self):
        for label, base_ref in (("empty", ""), ("absent", None)):
            with self.subTest(base_ref=label):
                fields = dict(checks=[], files=[], scope=dict(paths=[], systems=[]))
                if base_ref is not None:
                    fields["base_ref"] = base_ref
                mailbox = self.mailbox(canonical(fields))
                launch = git(self.repo, "rev-parse", "HEAD")
                mailbox.worker("checkout", cwd=self.repo, check=True)
                first = self.published(mailbox)["payload"]
                pin = mailbox.box / "checkout-base"
                self.assertEqual(pin.read_bytes(), launch.encode() + b"\n")
                self.assertEqual((first["base"], first["changed_files"]), (launch, []))
                self.assertEqual([p.name for p in mailbox.box.iterdir() if p.name.startswith("checkout-base")], ["checkout-base"])
                (self.repo / ("outside-" + label + ".txt")).write_text("x\n")
                git(self.repo, "add", ".")
                git(self.repo, "commit", "-q", "-m", "out of scope")
                mailbox.worker("checkout", cwd=self.repo, check=True)
                second = json.loads(base64.b64decode(mailbox.journal()["pending"][-1]["bytes"]))["payload"]
                self.assertEqual(pin.read_bytes(), launch.encode() + b"\n")
                self.assertEqual((second["base"], second["changed_files"]), (launch, ["outside-" + label + ".txt"]))

    def test_checkout_rejects_tampered_launch_base(self):
        manifest = canonical(dict(checks=[], base_ref="", files=[], scope=dict(paths=[], systems=[])))
        for label, plant in (("garbage", lambda p: p.write_text("--output=x\n")),
                             ("symlink", lambda p: p.symlink_to(self.root / "elsewhere"))):
            with self.subTest(pin=label):
                mailbox = self.mailbox(manifest)
                plant(mailbox.box / "checkout-base")
                self.refused(mailbox, "checkout", "storage_error")

    def test_git_unavailable_is_a_definite_refusal(self):
        # A PATH holding every executable the helpers might use except git.
        farm = self.root / "nogit"
        farm.mkdir()
        for directory in os.environ["PATH"].split(os.pathsep):
            if not os.path.isdir(directory):
                continue
            for entry in os.listdir(directory):
                source, link = os.path.join(directory, entry), farm / entry
                if entry != "git" and not os.path.lexists(link) and os.path.isfile(source) and os.access(source, os.X_OK):
                    link.symlink_to(source)
        env = dict(os.environ, PATH=str(farm))
        manifest = self.manifest([dict(check_id="t1-c1", argv=["true"])])
        self.refused(self.mailbox(manifest), "run-checks", "git_unavailable", message="t1-c1", env=env)
        self.refused(self.mailbox(manifest), "checkout", "git_unavailable", env=env)


    def test_manifest_bound_is_4096_bytes(self):
        manifest = self.manifest([dict(check_id="t1-c1", argv=["true"])])
        oversized = self.mailbox(manifest)
        (oversized.box / "manifest.json").write_bytes(manifest + b" " * (MANIFEST_BYTES + 1 - len(manifest)))
        self.refused(oversized, "run-checks", "manifest_mismatch", message="t1-c1")
        padded = manifest[:-1] + b" " * (MANIFEST_BYTES - len(manifest)) + b"}"
        self.assertEqual(len(padded), MANIFEST_BYTES)
        self.mailbox(padded).worker("run-checks", message="t1-c1", cwd=self.repo, check=True)
        with self.assertRaises(AssertionError):
            self.mailbox(padded + b" ")

if __name__ == "__main__":
    unittest.main()

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


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def until(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("helper did not reach the requested boundary")
        time.sleep(0.01)


class Mailbox:
    def __init__(self, root, handle="box", enrolment_token="enrolment_aaaaaaaa", handover=None):
        self.root, self.handle = root, handle
        self.box = root / handle
        self.operation = 0
        self.binding = dict(logical_session_id="session", worker_id="worker",
                            worker_generation=1, launch_request_id="launch",
                            work_id="work", enrolment_token=enrolment_token,
                            mailbox_handle=handle)
        provision = dict(version=1, handle=handle, binding_digest=digest(encode(self.binding)),
                         binding=self.binding)
        if handover is not None:
            # A rollover successor: the issued ID and sha256(id:token), never the token.
            handover_id, token = handover
            provision["handover"] = dict(handover_id=handover_id,
                                         handover_sha256=digest(f"{handover_id}:{token}".encode()))
        assert self.target("provision", "provision.json", encode(provision)).stdout == b"provisioned\n"
        self.worker("init", check=True)

    @property
    def journal_path(self):
        return self.box / "producer/journal.json"

    def journal(self):
        return json.loads(self.journal_path.read_bytes())

    def worker_argv(self, mode, message="", poll=1, seconds=2):
        return ["/bin/sh", str(WORKER), str(self.root), self.handle, OWNER,
                mode, message, str(poll), str(seconds)]

    def worker(self, mode, value=None, message="", env=None, check=False):
        data = value if isinstance(value, bytes) else (encode(value) if value is not None else b"")
        result = subprocess.run(self.worker_argv(mode, message), input=data,
                                capture_output=True, env=env, timeout=20)
        if check and result.returncode:
            raise AssertionError(result.stderr.decode())
        return result

    def retire_authorized(self, report_floor, reply_floor, chain, binding=None, owner=OWNER):
        argv = self.worker_argv("retire-authorized", poll=5, seconds=30)
        argv[4] = owner
        expected = self.binding if binding is None else binding
        encoded = base64.b64encode(encode(expected)).decode()
        return subprocess.run(argv + [str(report_floor), str(reply_floor), chain, encoded],
                              capture_output=True, timeout=20)

    def target(self, mode, selected="-", data=b"", report_floor=0, reply_floor=0):
        self.operation += 1
        argv = ["/bin/sh", str(TARGET), str(self.root), self.handle, mode, selected,
                "operation_" + str(self.operation), pwd.getpwuid(os.getuid()).pw_name,
                str(report_floor), str(reply_floor), str(WORKER)]
        result = subprocess.run(argv, input=base64.b64encode(data), capture_output=True, timeout=20)
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
        count = (len(raw) + 2047) // 2048
        common = dict(transport="report-files-v1", version=1, mailbox_handle=self.handle,
                      direction="reply", slot=seq, message_id=reply["message_id"],
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
        return raw

    def acknowledge_pending(self):
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
        self.worker("receipts", check=True)

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
                 payload=dict(artifact_revision="r", outcome="approved", evidence=[])),
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

    def test_landing_grant_entrypoint_closed_schema_and_exact_bytes(self):
        payload = dict(landing_id="landing", grant_id="grant", project_id="project", checkpoint_id="checkpoint",
                       repo_ref="repo", target_ref="main", target_revision="base", source_ref="work", source_revision="revision")
        def grant(reply):
            reply.update(kind="landing_grant", payload=payload.copy())
        mailbox = Mailbox(self.root, "landing_grant")
        raw = mailbox.reply(1, transform=grant)
        self.assertEqual(mailbox.worker("consume", check=True).stdout, raw)
        ack = json.loads(base64.b64decode(mailbox.journal()["pending"][0]["bytes"]))
        self.assertEqual(ack["payload"]["reply_sha256"], digest(raw))
        mutations = [(key, None) for key in payload]
        mutations += [("extra", True), ("landing_id", "bad id"), ("grant_id", ""), ("repo_ref", ""),
                      ("target_revision", "é" * 513), ("source_ref", 1)]
        for index, (key, value) in enumerate(mutations):
            with self.subTest(key=key, value=value):
                rejected = Mailbox(self.root, "landing_grant_" + str(index))
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

    def test_read_and_compaction_remain_available_above_byte_ceiling(self):
        self.mailbox.worker("report", dict(kind="READY", payload=dict(state="idle")), check=True)
        self.mailbox.fill_bytes(HARD_BYTES + 1)
        self.assertTrue(self.mailbox.target("read", "reports/1/manifest.json").stdout.startswith(b"object\n"))
        self.assertEqual(self.mailbox.target("compact", report_floor=1).stdout, b"compacted\n")


if __name__ == "__main__":
    unittest.main()

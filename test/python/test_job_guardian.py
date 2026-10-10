"""Hermetic Linux tests for successor job guardian.

Exercises the adapter around Albedo's copied process cleanup primitives. No home,
network, project checkout, or provider credential is touched.
"""
from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

TOOLS = Path(__file__).parents[2] / "priv" / "python" / "successor_tools"
GUARDIAN = TOOLS / "guardian.py"
sys.path.insert(0, str(TOOLS))
import proc  # noqa: E402
import guardian  # noqa: E402


def wait_until(predicate, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError("condition did not become true")


class Running:
    def __init__(self, root: Path, argv: list[str], seconds=30.0, status=None,
                 env=None, lifetime_closed=False):
        self.root = root
        self.status = status or root / "status.json"
        self.lock_path = root / "jobs.lock"
        active_dir = root / "active-jobs"
        active_dir.mkdir(exist_ok=True)
        self.active_record = active_dir / f"{self.status.name}.active"
        self.active_record.write_text("active\n")
        lease = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(lease, fcntl.LOCK_SH)
        lifetime_r, self.lifetime_w = os.pipe()
        if lifetime_closed:
            os.close(self.lifetime_w)
            self.lifetime_w = -1
        self.process = subprocess.Popen(
            [sys.executable, "-I", "-u", str(GUARDIAN), "--lifetime-fd", str(lifetime_r),
             "--lease-fd", str(lease), "--status", str(self.status),
             "--active-record", str(self.active_record), "--deadline", str(time.monotonic() + seconds), "--", *argv],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            close_fds=True, pass_fds=(lifetime_r, lease), start_new_session=True,
            env=env,
        )
        os.close(lifetime_r)
        os.close(lease)  # never LOCK_UN the shared open file description

    def record(self):
        def read():
            try:
                return json.loads(self.status.read_text())
            except (OSError, json.JSONDecodeError):
                return None
        return wait_until(read)

    def terminal(self, timeout=8.0):
        self.process.wait(timeout=timeout)
        value = json.loads(self.status.read_text())
        self.close_writer()
        if value.get("state") == "terminated" and value.get("termination", {}).get("gone") is True:
            assert not self.active_record.exists(), "terminal checked-gone must clear active record"
        self.output = b"" if self.process.stdout is None else self.process.stdout.read()
        if self.process.stdout is not None:
            self.process.stdout.close()
        return value

    def close_writer(self, marker=b""):
        if self.lifetime_w >= 0:
            if marker:
                os.write(self.lifetime_w, marker)
            os.close(self.lifetime_w)
            self.lifetime_w = -1

    def cleanup(self):
        self.close_writer(b"S")
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait()
        if self.process.stdout is not None:
            self.process.stdout.close()


class GuardianTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.running = []

    def tearDown(self):
        for item in self.running:
            item.cleanup()
        self.temp.cleanup()

    def launch(self, code, seconds=30.0, status=None):
        item = Running(self.root, [sys.executable, "-c", code], seconds, status)
        self.running.append(item)
        return item

    def test_natural_exit_cleans_forked_child_before_terminal(self):
        pidfile = self.root / "child.pid"
        item = self.launch(
            "import os,time; p=os.fork(); "
            f"open({str(pidfile)!r},'w').write(str(p)); "
            "(time.sleep(30) if p==0 else None)")
        initial = item.record()
        result = item.terminal()
        child = int(wait_until(lambda: pidfile.read_text() if pidfile.exists() else None))
        self.assertEqual(initial["state"], "running")
        self.assertEqual(result["state"], "terminated")
        self.assertTrue(result["termination"]["gone"])
        self.assertFalse(proc.current(proc.Group(result["pid"], result["leader"])))
        self.assertNotEqual(child, result["pid"])

    def test_deadline_is_independent_and_kills_group(self):
        item = self.launch("import time; time.sleep(30)", seconds=0.15)
        item.record()
        result = item.terminal()
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["reason"], "deadline")
        self.assertTrue(result["termination"]["gone"])

    def test_cancel_marker_cleans_and_only_then_publishes_terminal(self):
        item = self.launch("import os,time; os.fork(); time.sleep(30)")
        running = item.record()
        item.close_writer(b"S")
        result = item.terminal()
        self.assertEqual(result["reason"], "cancelled")
        self.assertTrue(result["termination"]["gone"])
        self.assertFalse(proc.current(proc.Group(running["pid"], running["leader"])))

    def test_sigkill_lifetime_owner_causes_eof_cleanup(self):
        item = self.launch("import os,time; os.fork(); time.sleep(30)")
        running = item.record()
        owner = os.fork()
        if owner == 0:
            try:
                time.sleep(30)
            finally:
                os._exit(0)
        # Transfer the sole write end to the fake kernel owner: after fork both
        # have it, so closing here makes SIGKILL of owner produce EOF.
        item.close_writer()
        os.kill(owner, signal.SIGKILL)
        os.waitpid(owner, 0)
        result = item.terminal()
        self.assertEqual(result["reason"], "owner_lost")
        self.assertTrue(result["termination"]["gone"])
        self.assertFalse(proc.current(proc.Group(running["pid"], running["leader"])))

    def test_target_descendant_does_not_retain_lifetime_or_lease(self):
        item = self.launch("import os,time; os.fork(); time.sleep(30)")
        item.record()
        item.close_writer()
        result = item.terminal(timeout=5)
        self.assertEqual(result["reason"], "owner_lost")
        probe = os.open(item.lock_path, os.O_RDWR)
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(probe)

    def test_shared_lease_is_held_while_target_live(self):
        item = self.launch("import time; time.sleep(30)")
        item.record()
        self.assertTrue(item.active_record.exists())
        probe = os.open(item.lock_path, os.O_RDWR)
        try:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(probe)
        item.close_writer(b"S")
        item.terminal()
        probe = os.open(item.lock_path, os.O_RDWR)
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(probe)

    def test_preclosed_lifetime_and_elapsed_deadline_never_pass_gate(self):
        for index, options in enumerate(({"lifetime_closed": True}, {"seconds": -1.0})):
            effect = self.root / f"pre-gate-effect-{index}"
            item = Running(
                self.root, [sys.executable, "-c", f"open({str(effect)!r},'w').write('bad')"],
                status=self.root / f"pre-gate-{index}.json", **options)
            self.running.append(item)
            item.process.wait(timeout=5)
            item.close_writer()
            self.assertEqual(item.process.returncode, 126)
            record = json.loads(item.status.read_text())
            self.assertEqual(record["state"], "terminated")
            self.assertTrue(record["termination"]["gone"])
            self.assertIsInstance(record["leader"], str)
            self.assertFalse(effect.exists())

    def test_immediate_cancel_always_gets_checked_terminal_status(self):
        for index in range(8):
            item = Running(
                self.root, [sys.executable, "-c", "import time; time.sleep(30)"],
                status=self.root / f"immediate-{index}.json")
            self.running.append(item)
            item.close_writer(b"S")
            result = item.terminal()
            self.assertEqual(result["state"], "terminated")
            self.assertEqual(result["reason"], "cancelled")
            self.assertTrue(result["termination"]["gone"])
            self.assertIsInstance(result["leader"], str)

    def test_isolated_helpers_ignore_python_environment(self):
        hostile = self.root / "hostile"
        hostile.mkdir()
        (hostile / "proc.py").write_text("raise RuntimeError('PYTHONPATH controlled helper')\n")
        env = dict(os.environ, PYTHONPATH=str(hostile), PYTHONHOME=str(self.root / "missing-home"))
        item = Running(self.root, ["/usr/bin/env"], env=env)
        self.running.append(item)
        item.record()
        result = item.terminal()
        self.assertEqual(result["returncode"], 0)
        self.assertIn(f"PYTHONPATH={hostile}".encode(), item.output)
        self.assertIn(f"PYTHONHOME={self.root / 'missing-home'}".encode(), item.output)

    def test_uncertain_retention_ignores_status_exception_and_returns_fresh_proof(self):
        first = proc.Termination(123, ("SIGKILL",), False)
        final = proc.Termination(123, (), True)
        with mock.patch.object(guardian, "write_status", side_effect=ValueError("large")), \
             mock.patch.object(guardian, "cleanup", side_effect=[RuntimeError("probe"), final]), \
             mock.patch.object(guardian.time, "sleep"):
            result = guardian.retain_until_gone(
                proc.Group(123, "token"), self.root / "status", 123, "token",
                None, False, "test", first)
        self.assertIs(result, final)

    def test_active_record_requires_fresh_gone_proof(self):
        active = self.root / "manual.active"
        active.write_text("active\n")
        uncertain = proc.Termination(123, ("SIGKILL",), False)
        self.assertFalse(guardian.clear_active_record(active, uncertain))
        self.assertTrue(active.exists())
        gone = proc.Termination(123, (), True)
        self.assertTrue(guardian.clear_active_record(active, gone))
        self.assertFalse(active.exists())

    def test_active_record_delete_failure_strands_fence(self):
        active = self.root / "stranded.active"
        active.write_text("active\n")
        gone = proc.Termination(123, (), True)
        with mock.patch.object(Path, "unlink", side_effect=PermissionError("refused")):
            self.assertFalse(guardian.clear_active_record(active, gone))
        self.assertTrue(active.exists())

    def test_status_write_failure_refuses_gated_source(self):
        effect = self.root / "must-not-exist"
        bad_status = self.root / "missing" / "status.json"
        item = self.launch(f"open({str(effect)!r},'w').write('bad')", status=bad_status)
        item.process.wait(timeout=5)
        item.close_writer()
        self.assertEqual(item.process.returncode, 126)
        self.assertFalse(effect.exists())
        self.assertFalse(bad_status.exists())
        self.assertFalse(item.active_record.exists())


if __name__ == "__main__":
    unittest.main()

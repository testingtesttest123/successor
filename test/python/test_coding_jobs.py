"""Hermetic real-process tests for successor_tools.jobs."""
from __future__ import annotations
import asyncio
import math
import os
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve()
PYTHON_ROOT = HERE.parents[2] / "priv" / "python"
sys.path.insert(0, str(PYTHON_ROOT))
from successor_tools.jobs import JobPolicy, JobRuntime
from successor_tools.output import OutputRegistry


class JobsTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.runtime = JobRuntime(self.root, OutputRegistry(self.root / "output"))

    async def asyncTearDown(self):
        await self.runtime.shutdown()
        self.temp.cleanup()

    async def test_launch_output_nonzero_and_minimal_environment(self):
        job = self.runtime.run(sys.executable, "-c", "import os,sys; print(os.getenv('SUCCESSOR_TEST_SECRET')); sys.exit(7)")
        self.assertIs(self.runtime.jobs[job.id], job)
        await job
        self.assertEqual(job.exit_code, 7)
        self.assertEqual(str(job.read()).strip(), "None")
        self.assertTrue(job.termination.gone)
        self.assertIsInstance(job.duration, float)
        self.assertIn(sys.executable, job.argv)

    async def test_full_large_stdin_and_pipeline_backpressure(self):
        payload = b"x" * (2 * 1024 * 1024 + 123)
        direct = self.runtime.run(sys.executable, "-c", "import sys; d=sys.stdin.buffer.read(); print(len(d))", stdin=payload)
        await direct
        self.assertEqual(str(direct.read()).strip(), str(len(payload)))

        producer = self.runtime.run(sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'z'*(2*1024*1024+9))")
        consumer = producer.pipe(sys.executable, "-c", "import sys; d=sys.stdin.buffer.read(); print(len(d), d[:1].decode(), d[-1:].decode())")
        self.assertIn(" | ", consumer.pipeline)
        await consumer
        await producer
        self.assertEqual(consumer.exit_code, 0)
        self.assertEqual(str(consumer.read()).strip(), "2097161 z z")

    async def test_timeout_and_cancel_are_guardian_checked(self):
        timed = self.runtime.run(sys.executable, "-c", "import time; time.sleep(30)", timeout=0.15)
        await timed
        self.assertTrue(timed.timed_out)
        self.assertTrue(timed.termination.gone)
        self.assertIsNotNone(timed.exit_code)

        cancelled = self.runtime.run(sys.executable, "-c", "import time; time.sleep(30)")
        termination = await cancelled.stop()
        self.assertIsNotNone(termination)
        self.assertTrue(termination.gone)
        self.assertFalse(cancelled.timed_out)
        self.assertIsNotNone(cancelled.exit_code)

    async def test_admission_validation_precedes_dispatch(self):
        marker = self.root / "marker"
        bad = (0, -1, math.inf, math.nan, 86401, True, "1")
        for timeout in bad:
            with self.assertRaises((TypeError, ValueError)):
                self.runtime.run(sys.executable, "-c", f"open({str(marker)!r},'w').write('bad')", timeout=timeout)
        with self.assertRaises(TypeError):
            self.runtime.run(sys.executable, stdin=object())
        with self.assertRaises(FileNotFoundError):
            self.runtime.run("definitely-no-such-successor-program")
        with self.assertRaises(ValueError):
            self.runtime.run("bad\x00program")
        with self.assertRaisesRegex(ValueError, "argv exceeds"):
            self.runtime.run(sys.executable, "x" * (1024 * 1024))
        with self.assertRaisesRegex(ValueError, "environment exceeds"):
            self.runtime.run(sys.executable, env={"BIG": "x" * (1024 * 1024)})
        import successor_tools.jobs as jobs_module
        stdin_limit = jobs_module.STDIN_LIMIT
        jobs_module.STDIN_LIMIT = 3
        try:
            with self.assertRaisesRegex(ValueError, "stdin exceeds"):
                self.runtime.run(sys.executable, stdin=b"four")
        finally:
            jobs_module.STDIN_LIMIT = stdin_limit
        self.assertFalse(marker.exists())
        self.assertFalse(self.runtime.jobs)

    async def test_capacity_retention_forget_and_eviction(self):
        await self.runtime.shutdown()
        self.runtime = JobRuntime(self.root / "limited", OutputRegistry(self.root / "limited-output"), JobPolicy(1, 1))
        first = self.runtime.run(sys.executable, "-c", "import time; time.sleep(.2)")
        with self.assertRaises(RuntimeError):
            self.runtime.run(sys.executable, "-c", "pass")
        await first
        second = self.runtime.run(sys.executable, "-c", "print('second')")
        await second
        self.assertNotIn(first.id, self.runtime.jobs)
        self.assertNotIn(first.id, self.runtime.output_registry.list())
        self.assertIn(second.id, self.runtime.jobs)
        self.runtime.forget(second)
        self.assertNotIn(second.id, self.runtime.jobs)

    async def test_late_pipe_refuses_incomplete_history(self):
        producer = self.runtime.run(sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'x'*(2*1024*1024))")
        await producer
        self.assertGreater(producer.capture.seen, len(producer.capture.data))
        with self.assertRaises(ValueError):
            producer.pipe(sys.executable, "-c", "pass")

    async def test_path_stdin_and_explicit_env_snapshot(self):
        source = self.root / "in"
        source.write_bytes(b"hello path")
        overrides = {"ONLY_EXPLICIT": "before"}
        job = self.runtime.run(sys.executable, "-c", "import os,sys; print(os.getenv('ONLY_EXPLICIT')); print(sys.stdin.read())", stdin=source, env=overrides, cwd=self.root)
        overrides["ONLY_EXPLICIT"] = "after"
        source.write_bytes(b"hello path")
        await job
        self.assertEqual(str(job.read()).splitlines(), ["before", "hello path"])

    async def test_broken_reader_unblocks_large_producer_and_stop_owns_pipeline(self):
        producer = self.runtime.run(sys.executable, "-c", "import sys;\nwhile True: sys.stdout.buffer.write(b'x'*65536); sys.stdout.buffer.flush()", timeout=5)
        reader = producer.pipe(sys.executable, "-c", "pass", timeout=5)
        await asyncio.wait_for(reader._wait(), 3)
        self.assertIsNotNone(producer.duration)
        self.assertTrue(producer.termination.gone)

        source = self.runtime.run(sys.executable, "-c", "import time; time.sleep(30)")
        sink = source.pipe(sys.executable, "-c", "import sys; sys.stdin.buffer.read()")
        await sink.stop()
        self.assertTrue(source.termination.gone)
        self.assertTrue(sink.termination.gone)

    async def test_lifetime_fd_closed_once_even_when_reused(self):
        first = self.runtime.run(sys.executable, "-c", "import time; time.sleep(30)")
        await first._request_stop()
        self.assertIsNone(first._command.lifetime)
        second = self.runtime.run(sys.executable, "-c", "import time; time.sleep(.15); print('alive')")
        await first
        await second
        self.assertEqual(second.exit_code, 0)
        self.assertEqual(str(second.read()).strip(), "alive")

    async def test_cancelled_task_adopts_spawn_and_cleans(self):
        job = self.runtime.run(sys.executable, "-c", "import time; time.sleep(30)")
        job.task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await job.task
        while job._recovery is None:
            await asyncio.sleep(0)
        await asyncio.wait_for(job._recovery, 5)
        self.assertTrue(job.termination.gone)
        self.assertNotIn(job.id, self.runtime._active)

    async def test_input_delivery_failure_is_not_success(self):
        source = self.root / "vanishes"
        source.write_text("data")
        job = self.runtime.run(sys.executable, "-c", "import sys; print(len(sys.stdin.read()))", stdin=source)
        source.unlink()
        with self.assertRaisesRegex(RuntimeError, "stdin delivery failed"):
            await job
        self.assertIsNone(job.exit_code)
        self.assertTrue(job.termination.gone)
        early = self.runtime.run(sys.executable, "-c", "pass", stdin=b"x" * (4 * 1024 * 1024))
        with self.assertRaisesRegex(RuntimeError, "stdin delivery failed"):
            await early
        self.assertIsNone(early.exit_code)

    async def test_unknown_status_is_not_complete_or_released(self):
        original = type(self.runtime.run)._read_status if False else None
        from successor_tools.jobs import Job
        reader = Job._read_status
        Job._read_status = lambda self, path: (_ for _ in ()).throw(RuntimeError("forced corrupt status"))
        try:
            job = self.runtime.run(sys.executable, "-c", "print('effect')")
            with self.assertRaisesRegex(RuntimeError, "outcome unknown"):
                await job
            self.assertIsNone(job.duration)
            self.assertIsNone(job.exit_code)
            self.assertIn(job.id, self.runtime._active)
            with self.assertRaises(RuntimeError): job.read()
        finally:
            Job._read_status = reader
            await self.runtime.shutdown()
            # The guardian proved cleanup; restore it for teardown without lying in production.
            self.runtime._active.clear()

    async def test_status_read_is_bounded_and_nested_types_strict(self):
        from successor_tools.jobs import Job
        fake = object.__new__(Job)
        status = self.root / "status"
        status.write_bytes(b"x" * 9000)
        with self.assertRaisesRegex(RuntimeError, "status size"):
            fake._read_status(status)
        status.write_text('{"v":1,"state":"terminated","pid":1,"leader":"x","returncode":0,"timed_out":false,"reason":"x","termination":{"pgid":1,"signals":[1],"gone":true,"failures":[],"note":""}}')
        with self.assertRaisesRegex(RuntimeError, "signals"):
            fake._read_status(status)

    async def test_default_home_is_workspace_and_helper_ignores_python_overrides(self):
        job = self.runtime.run("/usr/bin/env", env={"PYTHONHOME": "/definitely/bad", "PYTHONPATH": "/definitely/bad"})
        await job
        environment = str(job.read())
        self.assertIn(f"HOME={self.root}", environment)
        self.assertIn("PYTHONHOME=/definitely/bad", environment)
        explicit = self.runtime.run("/usr/bin/env", env={"HOME": str(self.root / "chosen")})
        await explicit
        self.assertIn(f"HOME={self.root / 'chosen'}", str(explicit.read()))

    async def test_nonblocking_lease_refusal_is_definitive(self):
        import fcntl
        fd = os.open(self.runtime.lock_path, os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            job = self.runtime.run(sys.executable, "-c", "raise SystemExit('must not run')")
            await job
            self.assertTrue(job.termination.gone)
            self.assertNotIn(job.id, self.runtime._active)
            self.assertIn("before dispatch", str(job.read()))
            self.assertEqual(list(self.runtime.active_dir.iterdir()), [])
        finally:
            os.close(fd)

    async def test_execute_waits_only_on_unfinished_tasks(self):
        import successor_tools.jobs as jobs_module
        original_read = jobs_module.Job._read_output
        original_wait = jobs_module.asyncio.wait
        calls = 0
        async def output_finishes_first(self, stream):
            return None
        async def counted_wait(awaitables, **kwargs):
            nonlocal calls
            calls += 1
            return await original_wait(awaitables, **kwargs)
        jobs_module.Job._read_output = output_finishes_first
        jobs_module.asyncio.wait = counted_wait
        try:
            job = self.runtime.run(sys.executable, "-c", "import time; time.sleep(.2)")
            await job
            self.assertLess(calls, 10, "done task caused FIRST_COMPLETED busy spin")
        finally:
            jobs_module.Job._read_output = original_read
            jobs_module.asyncio.wait = original_wait

    async def test_stop_reports_uncertain_when_upstream_status_unknown(self):
        source = self.runtime.run(sys.executable, "-c", "import time; time.sleep(30)")
        sink = source.pipe(sys.executable, "-c", "import sys; sys.stdin.buffer.read()")
        def corrupt(path):
            raise RuntimeError("forced upstream status corruption")
        source._read_status = corrupt
        termination = await sink.stop()
        self.assertIsNone(termination)
        self.assertIsNone(source.termination)
        self.assertIsNone(source.duration)
        self.assertIn(source.id, self.runtime._active)
        self.assertTrue(sink.termination.gone)
        # Test teardown cannot reconcile an intentionally forged status failure.
        self.runtime._active.pop(source.id)

    async def test_active_record_precedes_spawn_and_checked_cleanup_removes(self):
        import json
        import successor_tools.jobs as jobs_module
        original = jobs_module.asyncio.create_subprocess_exec
        witnessed = []
        async def checked_spawn(*argv, **kwargs):
            marker = Path(argv[argv.index("--active-record") + 1])
            value = json.loads(marker.read_text())
            self.assertEqual(value, {"v": 1, "id": marker.name})
            witnessed.append(marker)
            return await original(*argv, **kwargs)
        jobs_module.asyncio.create_subprocess_exec = checked_spawn
        try:
            job = self.runtime.run(sys.executable, "-c", "print('marked')")
            await job
        finally:
            jobs_module.asyncio.create_subprocess_exec = original
        self.assertEqual(len(witnessed), 1)
        self.assertFalse(witnessed[0].exists())

    async def test_ambiguous_spawn_retains_marker_and_bounds_admission(self):
        import successor_tools.jobs as jobs_module
        await self.runtime.shutdown()
        self.runtime = JobRuntime(self.root / "latched", OutputRegistry(self.root / "latched-output"), JobPolicy(1, 1))
        original = jobs_module.asyncio.create_subprocess_exec
        async def ambiguous(*argv, **kwargs):
            raise OSError("forced ambiguous spawn")
        jobs_module.asyncio.create_subprocess_exec = ambiguous
        try:
            job = self.runtime.run(sys.executable, "-c", "raise SystemExit('must not run')")
            with self.assertRaisesRegex(RuntimeError, "outcome unknown"):
                await job
        finally:
            jobs_module.asyncio.create_subprocess_exec = original
        markers = list(self.runtime.active_dir.iterdir())
        self.assertEqual([marker.name for marker in markers], [job.id])
        self.assertEqual(markers[0].read_text(), '{"id":"' + job.id + '","v":1}\n')
        with self.assertRaisesRegex(RuntimeError, "active or latched"):
            self.runtime.run(sys.executable, "-c", "pass")
        self.runtime._active.pop(job.id)
        markers[0].unlink()

    async def test_capacity_counts_pending_handles_plus_stranded_markers(self):
        await self.runtime.shutdown()
        self.runtime = JobRuntime(self.root / "union", OutputRegistry(self.root / "union-output"), JobPolicy(4, 4))
        stranded = [self.runtime.active_dir / f"stranded-{n}" for n in range(2)]
        for marker in stranded:
            marker.write_text('{"v":1,"id":"stranded"}\n')
        first = self.runtime.run(sys.executable, "-c", "import time; time.sleep(30)")
        second = self.runtime.run(sys.executable, "-c", "import time; time.sleep(30)")
        # No await/yield occurred: both handles are pending and have no marker yet.
        self.assertEqual(len(self.runtime._active), 2)
        with self.assertRaisesRegex(RuntimeError, "active or latched"):
            self.runtime.run(sys.executable, "-c", "pass")
        self.assertLessEqual(len(self.runtime._active) + len(stranded), 4)
        for marker in stranded:
            marker.unlink()
        await asyncio.gather(first.stop(), second.stop())


if __name__ == "__main__":
    unittest.main()

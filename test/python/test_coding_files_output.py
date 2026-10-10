"""Hermetic stdlib tests for successor files and bounded output helpers."""
from __future__ import annotations
import asyncio, json, os, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "priv" / "python"))
from successor_tools.api import OUTPUT_PREVIEW, RETAIN, Text
from successor_tools.capture import Capture, SPILL_LIMIT
from successor_tools.output import JobOutput, OutputRegistry
from successor_tools import files

class FakeOutput(JobOutput):
    def __init__(self, capture, done=True):
        self.capture = capture; self.duration = 0.1 if done else None
        self.exit_code = 0 if done else None; self._read = False

class FilesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()

    def test_utf8_numbering_crlf_chunk_boundary_and_huge_line(self):
        target = self.root / "unicode.txt"
        target.write_bytes(("é\n" + "a" * 65532 + "\r\n雪\n").encode())
        shown = files.read(str(target), start_line=1, end_line=3, max_chars=70000)
        self.assertIn("     1 | é", shown); self.assertIn("     3 | 雪", shown)
        huge = files.read(str(target), start_line=2, end_line=2, max_chars=100)
        self.assertIn("line 2 is", huge); self.assertIn("read it alone", huge)
        boundary = self.root / "boundary.txt"
        boundary.write_bytes(b"x" * 65535 + b"\r\nlast")
        result = files.read(str(boundary), start_line=2, end_line=2)
        self.assertEqual(result, "     2 | last")

    def test_unique_ambiguous_hint_and_failed_edits_preserve_bytes(self):
        target = self.root / "edit.txt"; target.write_text("one\nsame\nmid\nsame\n", encoding="utf-8")
        before = target.read_bytes()
        with self.assertRaisesRegex(ValueError, "found 2 occurrences") as error:
            files.edit(str(target), "same", "changed")
        self.assertIn("lines 2, 4", str(error.exception)); self.assertEqual(target.read_bytes(), before)
        files.edit(str(target), "same", "changed", line_hint=4)
        self.assertEqual(target.read_text(), "one\nsame\nmid\nchanged\n")
        before = target.read_bytes()
        with self.assertRaisesRegex(ValueError, "string not found"):
            files.edit(str(target), "missing", "x")
        self.assertEqual(target.read_bytes(), before)
        same_line = self.root / "same-line.txt"; same_line.write_text("same same\n")
        with self.assertRaisesRegex(ValueError, "inside multiple occurrences"):
            files.edit(str(same_line), "same", "x", line_hint=1)
        self.assertEqual(same_line.read_text(), "same same\n")

    def test_write_and_edit_encoding_or_size_failure_do_not_mutate(self):
        target = self.root / "safe.txt"; target.write_bytes(b"original")
        with self.assertRaises(UnicodeEncodeError): files.write(str(target), "bad\ud800")
        self.assertEqual(target.read_bytes(), b"original")
        with mock.patch.object(files, "WRITE_LIMIT", 4):
            with self.assertRaisesRegex(ValueError, "maximum"): files.write(str(target), "12345")
            self.assertEqual(target.read_bytes(), b"original")
            small = self.root / "small.txt"; small.write_text("a")
            with self.assertRaisesRegex(ValueError, "new_str has"): files.edit(str(small), "a", "12345")
            with self.assertRaisesRegex(ValueError, "new_str exceeds"): files.edit(str(small), "a", "雪雪")
            self.assertEqual(small.read_bytes(), b"a")
            with self.assertRaisesRegex(ValueError, "edit maximum"): files.edit(str(target), "original", "x")
            self.assertEqual(target.read_bytes(), b"original")

    def test_write_preserves_symlink_and_replaces_referent(self):
        referent = self.root / "referent.txt"; referent.write_text("old")
        link = self.root / "link.txt"; link.symlink_to(referent)
        files.write(str(link), "new")
        self.assertTrue(link.is_symlink()); self.assertEqual(referent.read_text(), "new")

    def test_bounded_occurrence_diagnostics_and_large_fuzzy_omission(self):
        target = self.root / "many.txt"; target.write_text(("x " * 1000) + "\n")
        found = files._occurrences(target.read_text(), "x", None)
        self.assertEqual(found.total, 1000); self.assertEqual(len(found.shown), files.LISTED)
        dense = self.root / "dense.txt"; dense.write_text("x\n" + "\n" * 500_000 + "x\n")
        with self.assertRaisesRegex(ValueError, "found 2 occurrences") as error:
            files.edit(str(dense), "x", "y")
        self.assertIn("500002", str(error.exception)); self.assertEqual(dense.read_text()[-2:], "x\n")
        large = self.root / "large.txt"; large.write_text("z" * (1024 * 1024 + 1))
        with self.assertRaisesRegex(ValueError, "diagnostics omitted"):
            files.edit(str(large), "absent", "new")

    def test_atomic_write_failure_keeps_destination(self):
        target = self.root / "atomic.txt"; target.write_bytes(b"old")
        with mock.patch.object(files.os, "replace", side_effect=OSError("injected")):
            with self.assertRaisesRegex(OSError, "injected"): files.write(str(target), "new")
        self.assertEqual(target.read_bytes(), b"old")
        self.assertEqual(list(self.root.glob(".atomic.txt.*.tmp")), [])

class CaptureOutputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()

    def test_first_tail_spill_pages_and_exact_atomic_save(self):
        capture = Capture("odd/id", spill_dir=self.root / "spill")
        expected = b"A" * RETAIN + "雪".encode() + b"B" * 70000
        for at in range(0, len(expected), 33333): capture.write_bytes(expected[at:at+33333])
        capture.end_spill()
        self.assertEqual(capture.seen, len(expected)); self.assertEqual(capture.retained, len(expected))
        self.assertEqual(capture.data, expected[:RETAIN]); self.assertEqual(capture.tail(10), expected[-10:])
        self.assertEqual(capture.read_bytes(RETAIN-2, 10), expected[RETAIN-2:RETAIN+8])
        registry = OutputRegistry(self.root / "registry")
        registered = registry.capture("page"); registered.write_bytes(expected); registered.end_spill()
        self.assertIs(registry.capture("page"), registered)
        self.assertEqual(registry.read("page", RETAIN+3, 13).encode(), expected[RETAIN+3:RETAIN+16])
        self.assertEqual(registry.list(), ["page"])
        job = FakeOutput(capture); target = self.root / "saved.bin"; target.write_bytes(b"old")
        self.assertEqual(Path(job.save(target)), target.absolute()); self.assertEqual(target.read_bytes(), expected)
        target.write_bytes(b"keep")
        with mock.patch("successor_tools.output.os.replace", side_effect=OSError("injected save")):
            with self.assertRaisesRegex(OSError, "injected save"): job.save(target)
        self.assertEqual(target.read_bytes(), b"keep")
        self.assertEqual(list(self.root.glob(".saved.bin.*.tmp")), [])
        registry.forget("page"); self.assertEqual(registry.list(), [])
        self.assertTrue(registered.spill and Path(registered.spill).exists())

    def test_large_unicode_write_encodes_in_bounded_chunks(self):
        class ObservedCapture(Capture):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs); self.largest = 0
            def write_bytes(self, data):
                self.largest = max(self.largest, len(data)); super().write_bytes(data)
        capture = ObservedCapture("unicode", spill_dir=self.root / "spill")
        text = "雪" * 300_000
        capture.write(text); capture.end_spill()
        self.assertLessEqual(capture.largest, 64 * 1024 * 3)
        self.assertEqual(capture.seen, len(text.encode()))
        self.assertEqual(capture.read_bytes(0, 12), text.encode()[:12])

    def test_spill_failure_and_over_limit_refuse_incomplete_and_preserve_save_target(self):
        not_directory = self.root / "not-directory"; not_directory.write_text("x")
        failed = Capture("failure", spill_dir=not_directory)
        failed.write_bytes(b"x" * (RETAIN + 1))
        self.assertGreater(failed.seen, failed.retained); self.assertIsNone(failed.spill)
        target = self.root / "keep.bin"; target.write_bytes(b"keep")
        with self.assertRaisesRegex(ValueError, "refusing incomplete output"):
            FakeOutput(failed).save(target)
        self.assertEqual(target.read_bytes(), b"keep")

        capped = Capture("capped", spill_dir=self.root / "spill")
        chunk = b"z" * (1024 * 1024)
        for _ in range(17): capped.write_bytes(chunk)
        capped.end_spill()
        self.assertEqual(capped.spilled, SPILL_LIMIT); self.assertGreater(capped.seen, capped.retained)
        with self.assertRaisesRegex(ValueError, "refusing incomplete output"): FakeOutput(capped).read()
        self.assertEqual(capped.read_bytes(SPILL_LIMIT-8, 8), b"z" * 8)
        with self.assertRaisesRegex(ValueError, "not retained"): capped.read_bytes(SPILL_LIMIT, 1)

    def test_preview_line_boundaries_and_running_guard(self):
        capture = Capture("preview")
        capture.write_bytes(b"partial" + b"\nline\n" + b"x" * (RETAIN + 1))
        output = FakeOutput(capture)
        self.assertTrue(output.head(lines=1).startswith("partial"))
        self.assertTrue(output.tail(12).endswith("x" * 12))
        running = FakeOutput(Capture("running"), done=False)
        with self.assertRaisesRegex(RuntimeError, "still running"): running.read()

class FakeJob(JobOutput):
    def __init__(self, payload: bytes, status: int):
        self.capture = Capture("search"); self.capture.write_bytes(payload)
        self.duration = None; self.exit_code = None; self.timed_out = False
        self.termination = None; self._read = False; self.status = status
    def __await__(self):
        async def wait(): self.exit_code = self.status; self.duration = .01; return self
        return wait().__await__()
    async def stop(self): self.termination = "stopped"

class FakeRuntime:
    def __init__(self, payload: bytes, status=0): self.payload=payload; self.status=status; self.calls=[]; self.forgot=[]
    def run(self, program, *args, **kwargs):
        self.calls.append((program,args,kwargs)); return FakeJob(self.payload,self.status)
    def forget(self, job): self.forgot.append(job)

class SequenceRuntime(FakeRuntime):
    def __init__(self, replies): self.replies=list(replies); self.calls=[]; self.forgot=[]
    def run(self, program, *args, **kwargs):
        self.calls.append((program,args,kwargs)); payload,status=self.replies.pop(0); return FakeJob(payload,status)

class SearchTests(unittest.IsolatedAsyncioTestCase):
    async def test_search_uses_explicit_supervised_argv(self):
        event = {"type":"match","data":{"path":{"text":"a b.txt"},"line_number":2,"lines":{"text":"hit\n"}}}
        summary = {"type":"summary","data":{"stats":{"searches":1}}}
        runtime = FakeRuntime((json.dumps(event)+"\n"+json.dumps(summary)+"\n").encode()); files.initialize(runtime)
        rows = await files.find("h.*", ".", max_results=2)
        self.assertEqual(rows[0].path, "a b.txt"); self.assertFalse(rows.truncated)
        self.assertEqual(runtime.calls[0][0], "rg"); self.assertNotIn("/bin/sh", runtime.calls[0])
        args = runtime.calls[0][1]; self.assertIn("--", args); self.assertLess(args.index("--"), len(args)-1)
        self.assertEqual(len(runtime.forgot),1)

    async def test_dash_prefixed_roots_are_after_option_terminator(self):
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as temporary:
            os.chdir(temporary)
            try:
                Path("-root").mkdir()
                summary = {"type":"summary","data":{"stats":{"searches":0}}}
                runtime = FakeRuntime((json.dumps(summary)+"\n").encode(), 1); files.initialize(runtime)
                await files.find("x", "-root")
                args = runtime.calls[0][1]
                self.assertEqual(args[args.index("--") + 1], "-root")
                runtime = FakeRuntime(b"", 0); files.initialize(runtime)
                await files.paths(path="-root")
                args = runtime.calls[0][1]
                self.assertEqual(args[args.index("--") + 1], "-root")
            finally:
                os.chdir(previous)

    async def test_rg_absence_is_explicit(self):
        class MissingRuntime(FakeRuntime):
            def run(self, *args, **kwargs): raise FileNotFoundError("rg")
        files.initialize(MissingRuntime(b""))
        with self.assertRaisesRegex(RuntimeError, "ripgrep .* required"):
            await files.paths(path=".")
        runtime = FakeRuntime(b"", 127); files.initialize(runtime)
        with self.assertRaisesRegex(RuntimeError, "ripgrep .* required"):
            await files.paths(path=".")

    async def test_withheld_diagnostic_failure_is_not_treated_as_filenames(self):
        summary = {"type":"summary","data":{"stats":{"searches":1}}}
        runtime = SequenceRuntime([
            ((json.dumps(summary)+"\n").encode(), 1),
            (b"rg: permission denied\n", 2),
        ])
        files.initialize(runtime)
        with self.assertRaisesRegex(RuntimeError, "diagnostic search failed"):
            await files.find("missing", ".")

    async def test_unknown_and_incomplete_search_are_not_reported_as_no_matches(self):
        runtime = FakeRuntime(b"", None); files.initialize(runtime)
        with self.assertRaisesRegex(RuntimeError, "without a known exit status"):
            await files.find("x", ".")
        runtime = FakeRuntime(b'{not-json\n', 1); files.initialize(runtime)
        rows = await files.find("x", ".")
        self.assertTrue(rows.truncated); self.assertIn("incomplete", rows.note)

if __name__ == "__main__": unittest.main()

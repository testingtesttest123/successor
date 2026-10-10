"""Joined acceptance through the actual isolated framed Python kernel."""
from __future__ import annotations
import fcntl
import json
import os
import shutil
from pathlib import Path
import sys
import tempfile
import time
import unittest

from test_kernel import Kernel, frame


def until(check, seconds=6):
    deadline = time.monotonic() + seconds
    while True:
        value = check()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise AssertionError("condition did not become true before deadline")
        time.sleep(.01)


def lease_free(root):
    path = Path(root) / ".successor-runtime" / "jobs.lock"
    if not path.exists():
        return True
    with path.open("rb") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            active = Path(root) / '.successor-runtime' / 'active-jobs'
            return not active.exists() or not any(active.iterdir())
        except BlockingIOError:
            return False


class CodingKernelTests(unittest.TestCase):
    def setUp(self):
        self.directories = []
        self.kernels = []

    def tearDown(self):
        for kernel, root in self.kernels:
            kernel.close()
            until(lambda: lease_free(root))
        for directory in self.directories:
            directory.cleanup()

    def kernel(self, inherited=None):
        directory = tempfile.TemporaryDirectory()
        self.directories.append(directory)
        root = Path(directory.name)
        kernel = Kernel(str(root), inherited=inherited)
        self.kernels.append((kernel, root))
        return kernel, root

    def execute(self, kernel, source):
        result = kernel.execute("joined", source)
        self.assertEqual(result["status"], "succeeded", result)
        return result["output"]

    def test_top_level_await_and_ready_helper_results(self):
        kernel, root = self.kernel()
        text = self.execute(kernel, "await asyncio.sleep(.01)\nawait files.write('hello.txt', 'héllo\\nworld')\nawait files.read('hello.txt', limit=1)")
        self.assertIn("1 | héllo", text)
        self.assertIn("limit=1", text)
        self.assertEqual((root / "hello.txt").read_text(), "héllo\nworld")
        self.assertEqual(self.execute(kernel, "answer=41\nawait asyncio.sleep(.01)\nanswer+1"), "42\n")

    def test_bare_job_handle_is_not_implicitly_awaited(self):
        kernel, _ = self.kernel()
        started = time.monotonic()
        text = self.execute(kernel, f"job=run({sys.executable!r}, '-c', 'import time; time.sleep(30)', timeout=30)\njob")
        self.assertLess(time.monotonic()-started, 2)
        self.assertIn("Job(", text)
        self.assertIn("True", self.execute(kernel, "ending=await job.stop()\nending.gone"))

    def test_background_progress_between_cells_and_job_output_registry(self):
        kernel, root = self.kernel()
        program = "from pathlib import Path; print('background output', flush=True); Path('ran-idle').write_text('done')"
        self.execute(kernel, f"job=run({sys.executable!r}, '-c', {program!r})")
        until(lambda: (root / "ran-idle").exists())  # no second cell to unstick its loop
        text = self.execute(kernel, "await job\nprint(job.exit_code)\noutput.read(job.id)")
        self.assertEqual(text, "0\nbackground output\n")

    def test_late_task_stdout_not_attributed_to_next_cell_or_raw_protocol(self):
        kernel, _ = self.kernel()
        self.execute(kernel, "async def later():\n    await asyncio.sleep(.02)\n    print('late-native')\ntask=asyncio.create_task(later())")
        text = self.execute(kernel, "await task\nprint('this-cell')")
        self.assertEqual(text, "this-cell\n")
        self.assertEqual(self.execute(kernel, "output.read('native')"), "late-native\n")

    def test_helpers_are_private_and_shadowed_binding_can_be_deleted(self):
        left, left_root = self.kernel()
        right, _ = self.kernel()
        self.execute(left, "files.write('private.txt','left')\nstate='left'")
        self.assertIn("False", self.execute(right, "(Path('private.txt').exists(), 'state' in globals())"))
        self.assertEqual((left_root / "private.txt").read_text(), "left")
        self.execute(left, "files='shadow'\ndel files")
        self.assertIn("left", self.execute(left, "files.read('private.txt')"))

    @unittest.skipUnless(shutil.which('rg'), 'ripgrep required for real search acceptance')
    def test_real_supervised_rg_find_paths_and_literal_optionlike_root(self):
        # Explicit tool PATH, not host credentials/environment inheritance.
        path = str(Path(shutil.which('rg')).parent) + os.pathsep + '/usr/bin:/bin'
        kernel, _ = self.kernel(inherited={'PATH': path})
        self.execute(kernel, "files.write('src/example.py', 'first\\nNeedle\\nlast\\n')\nfiles.write('-odd.txt', 'Needle')")
        text = self.execute(kernel, "await files.find('needle', 'src', case_sensitive=False, context=1)")
        self.assertIn("example.py:2: Needle", text)
        self.assertIn("example.py-1- first", text)
        self.assertIn("example.py", self.execute(kernel, "await files.paths('*.py', 'src')"))
        self.assertIn("Needle", self.execute(kernel, "await files.find('Needle', '-odd.txt', literal=True)"))
        absent = kernel.execute("absent", "await files.find('x', 'does-not-exist')")
        self.assertEqual(absent["status"], "failed")
        self.assertIn("FileNotFoundError", absent["error"])

    def test_guardian_deadline_works_while_live_kernel_event_loop_is_cpu_bound(self):
        kernel, root = self.kernel()
        program = "import os,time; from pathlib import Path; Path('deadline-pid').write_text(str(os.getpid())); time.sleep(30)"
        self.execute(kernel, f"job=run({sys.executable!r},'-c',{program!r},timeout=.3)\nwhile not Path('deadline-pid').exists(): await asyncio.sleep(.005)")
        pid = int((root / 'deadline-pid').read_text())
        kernel.input.write(frame({'v':1,'type':'execute','id':'blocked',
                                  'source':'while True: pass','max_output_bytes':1024}))
        kernel.input.flush()
        def target_gone():
            try:
                state = Path(f'/proc/{pid}/stat').read_bytes().rsplit(b')',1)[1].split()[0]
                return state == b'Z'
            except FileNotFoundError:
                return True
        until(target_gone, seconds=4)
        self.assertIsNone(kernel.process.poll(), 'guardian deadline must not depend on kernel exit')
        # No completed-cell receipt is inferred for the deliberately blocked cell.

    def test_spilled_binary_pages_and_exact_atomic_artifact(self):
        kernel, root = self.kernel()
        size = 1048576 + 123
        program = f"import sys; sys.stdout.buffer.write(b'a'*{size}+b'\\x00\\xffEND')"
        text = self.execute(kernel, f"job=run({sys.executable!r},'-c',{program!r})\nawait job\njob.save('saved.bin')\nprint(job.capture.seen, job.capture.retained)\njob.read(offset={size+2},limit=3)")
        self.assertIn(f"{size+5} {size+5}", text)
        self.assertTrue(text.endswith("END\n"))
        self.assertEqual((root / "saved.bin").read_bytes(), b'a'*size+b'\x00\xffEND')
        self.assertIn("END", self.execute(kernel, "job.tail(3)"))

    def test_over_disk_prefix_refuses_complete_read_and_preserves_save_target(self):
        kernel, root = self.kernel()
        program = "import sys; sys.stdout.buffer.write(b'x'*(17*1024*1024))"
        self.execute(kernel, f"job=run({sys.executable!r}, '-c', {program!r})\nawait job\nPath('keep').write_text('ORIGINAL')")
        result = kernel.execute("refuse", "job.save('keep')")
        self.assertEqual(result["status"], "failed")
        self.assertIn("refusing incomplete output", result["error"])
        self.assertEqual((root / "keep").read_text(), "ORIGINAL")
        result = kernel.execute("refuse-page", "job.read(offset=16*1024*1024,limit=1)")
        self.assertEqual(result["status"], "failed")
        self.assertIn("refusing incomplete output", result["error"])
        self.assertEqual(self.execute(kernel, "job.read(offset=0,limit=4)"), "xxxx\n")


if __name__ == '__main__':
    unittest.main()

from __future__ import annotations

import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).parents[2] / "priv" / "python" / "kernel.py"


def frame(value: object) -> bytes:
    data = json.dumps(value, separators=(",", ":")).encode()
    return struct.pack(">I", len(data)) + data


def exact(stream, size: int) -> bytes:
    result = bytearray()
    while len(result) < size:
        chunk = stream.read(size - len(result))
        if not chunk:
            raise EOFError
        result.extend(chunk)
    return bytes(result)


class Kernel:
    def __init__(self, workspace: str, inherited: dict[str, str] | None = None):
        environment = {
            "HOME": workspace,
            "TMPDIR": workspace,
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C.UTF-8",
        }
        if inherited:
            environment.update(inherited)
        self.process = subprocess.Popen(
            [sys.executable, "-I", "-u", str(SCRIPT)],
            cwd=workspace,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.input = self.process.stdin
        self.output = self.process.stdout
        ready = self.read()
        assert ready["v"] == 1 and ready["type"] == "ready"
        assert ready["pid"] == ready["pgid"] == self.process.pid

    def read(self) -> dict[str, object]:
        size = struct.unpack(">I", exact(self.output, 4))[0]
        return json.loads(exact(self.output, size))

    def execute(self, cell_id: str, source: str, maximum: int = 262144):
        self.input.write(frame({
            "v": 1,
            "type": "execute",
            "id": cell_id,
            "source": source,
            "max_output_bytes": maximum,
        }))
        self.input.flush()
        return self.read()

    def close(self):
        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, 15)
                self.process.wait(timeout=1)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.process.pid, 9)
                except ProcessLookupError:
                    pass
                self.process.wait(timeout=1)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


class KernelTests(unittest.TestCase):
    def setUp(self):
        self.directories: list[tempfile.TemporaryDirectory[str]] = []
        self.kernels: list[Kernel] = []

    def tearDown(self):
        for kernel in self.kernels:
            kernel.close()
        for directory in self.directories:
            directory.cleanup()

    def kernel(self, **kwargs) -> Kernel:
        directory = tempfile.TemporaryDirectory()
        self.directories.append(directory)
        kernel = Kernel(directory.name, **kwargs)
        self.kernels.append(kernel)
        return kernel

    def test_namespace_persists_and_last_expression_displays(self):
        kernel = self.kernel()
        self.assertEqual(kernel.execute("one", "answer = 40\nanswer + 2")["output"], "42\n")
        self.assertEqual(kernel.execute("two", "answer += 1\nanswer")["output"], "41\n")

    def test_exception_retains_prior_state(self):
        kernel = self.kernel()
        failed = kernel.execute("bad", "kept = 'yes'\nraise ValueError('broken')")
        self.assertEqual(failed["status"], "failed")
        self.assertIn("ValueError: broken", failed["output"])
        self.assertEqual(failed["error"], "ValueError: broken")
        self.assertEqual(kernel.execute("after", "kept")["output"], "'yes'\n")

    def test_output_is_bounded_while_written(self):
        kernel = self.kernel()
        result = kernel.execute("overflow", "print('x' * 1000000)", 127)
        self.assertEqual(result["status"], "succeeded")
        self.assertTrue(result["truncated"])
        self.assertEqual(len(result["output"].encode()), 127)

    def test_workspaces_have_independent_namespace_and_cwd(self):
        left, right = self.kernel(), self.kernel()
        left.execute("set", "shared = 1\nopen('left.txt', 'w').write('left')")
        self.assertEqual(right.execute("cwd", "import os; (os.getcwd(), 'shared' in globals())")["output"],
                         f"('{self.directories[1].name}', False)\n")
        self.assertFalse((Path(self.directories[1].name) / "left.txt").exists())

    def test_minimal_environment_does_not_inherit_synthetic_secret(self):
        # The production launcher uses env -i. Model that exact allowlist here;
        # a secret in this test runner is deliberately not copied.
        os.environ["SUCCESSOR_SYNTHETIC_SECRET"] = "must-not-cross"
        self.addCleanup(os.environ.pop, "SUCCESSOR_SYNTHETIC_SECRET", None)
        kernel = self.kernel()
        result = kernel.execute("env", "import os; os.environ.get('SUCCESSOR_SYNTHETIC_SECRET')")
        self.assertEqual(result["output"], "")

    def test_malformed_and_truncated_frames_end_transport(self):
        for payload in (b"not json", b'{"v":1'):
            kernel = self.kernel()
            kernel.input.write(struct.pack(">I", len(payload)) + payload)
            kernel.input.flush()
            self.assertEqual(kernel.process.wait(timeout=2), 2)

    def test_native_stdout_cannot_manufacture_success(self):
        kernel = self.kernel()
        kernel.input.write(frame({"v": 1, "type": "execute", "id": "raw",
                                  "source": "import os; os.write(1, b'junk')",
                                  "max_output_bytes": 100}))
        kernel.input.flush()
        # Raw fd 1 bytes corrupt the packet stream. A host must classify this as
        # unknown and close it; it is not silently accepted as a cell result.
        self.assertEqual(exact(kernel.output, 4), b"junk")

    def test_raw_request_bounds_reject_before_source_evaluation(self):
        maximum = (64 * 1024 * 1024 - 65536) // 6
        cases = [
            ("x" * 4097, maximum, "bad-id"),
            ("valid", maximum + 1, "bad-output-limit"),
        ]
        for cell_id, output_limit, effect in cases:
            kernel = self.kernel()
            source = f"open({effect!r}, 'w').write('must not run')"
            kernel.input.write(frame({"v": 1, "type": "execute", "id": cell_id,
                                      "source": source, "max_output_bytes": output_limit}))
            kernel.input.flush()
            self.assertEqual(kernel.process.wait(timeout=2), 2)
            self.assertFalse((Path(self.directories[-1].name) / effect).exists())

    def test_write_frame_enforces_hard_response_limit(self):
        import importlib.util
        import io
        spec = importlib.util.spec_from_file_location("tested_successor_kernel", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        module.MAX_FRAME_BYTES = 100
        with self.assertRaisesRegex(ValueError, "response frame exceeds"):
            module.write_frame(io.BytesIO(), {"output": chr(0) * 20})

    def test_termination_reaps_nonadversarial_child_group(self):
        kernel = self.kernel()
        result = kernel.execute("child", "import subprocess; child = subprocess.Popen(['sleep', '30']); child.pid")
        child_pid = int(result["output"].strip())
        kernel.close()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            # A killed child can briefly remain a zombie until init adopts it.
            stat = Path(f"/proc/{child_pid}/stat")
            if stat.exists() and stat.read_text().split()[2] == "Z":
                break
            time.sleep(0.01)
        else:
            self.fail("owned child process survived kernel group termination")


if __name__ == "__main__":
    unittest.main()

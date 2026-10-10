"""Protocol plumbing tests, not substitutes for Home's shared scenario corpus."""
import hashlib
import json
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PREFIX = "@@SUCCESSOR@@"


def run_bridge(requests):
    result = subprocess.run(
        ["gleam", "run", "-m", "conformance_host"],
        cwd=ROOT,
        input="".join(json.dumps(request) + "\n" for request in requests),
        text=True,
        capture_output=True,
        timeout=30,
    )
    replies = [json.loads(line[len(PREFIX):]) for line in result.stdout.splitlines()
               if line.startswith(PREFIX)]
    return result, replies


class BridgeProtocolTests(unittest.TestCase):
    def test_unknown_operation_cannot_succeed(self):
        result, replies = run_bridge([{"op": "tool"}])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(replies, [])

    def test_inspect_cannot_create_missing_database(self):
        with tempfile.TemporaryDirectory() as folder:
            result, replies = run_bridge([
                {"op": "inspect", "dataDir": folder, "sessionId": "missing"},
            ])
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(replies, [])
            self.assertEqual(list(pathlib.Path(folder).iterdir()), [])

    def test_inspect_is_read_only_and_exits_without_starting_host(self):
        # '?' and '#' must remain path bytes, never SQLite URI options.
        with tempfile.TemporaryDirectory(prefix="bridge?#") as folder:
            result, replies = run_bridge([
                {"op": "start", "dataDir": folder,
                 "recipe": json.dumps({"agent": {"name": "test", "provider": "mock"}})},
                {"op": "text", "content": "bridge plumbing"},
                {"op": "stop"},
            ])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([reply["op"] for reply in replies], ["start", "text", "stop"])
            before_snapshot = replies[1]["snapshot"]
            for record in before_snapshot["records"]:
                self.assertIn("createdAtMs", record)
                self.assertIsInstance(record["createdAtMs"], int)
            self.assertIn("createdAtMs", before_snapshot["catalog"][0])
            receipt = before_snapshot["receipts"][0]
            self.assertIn("startedAtMs", receipt)
            self.assertIn("finishedAtMs", receipt)
            self.assertGreaterEqual(receipt["finishedAtMs"], receipt["startedAtMs"])
            database = pathlib.Path(folder) / "successor.db"
            before = hashlib.sha256(database.read_bytes()).hexdigest()
            result, inspected = run_bridge([
                {"op": "inspect", "dataDir": folder,
                 "sessionId": before_snapshot["sessionId"]},
            ])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(inspected), 1)
            self.assertEqual(inspected[0]["op"], "inspect")
            self.assertNotIn("event=host.started", result.stderr)
            self.assertEqual(hashlib.sha256(database.read_bytes()).hexdigest(), before)
            after_snapshot = inspected[0]["snapshot"]
            self.assertNotEqual(after_snapshot.pop("processId"), before_snapshot.pop("processId"))
            self.assertEqual(after_snapshot, before_snapshot)

    def test_second_start_cannot_replace_running_host(self):
        with tempfile.TemporaryDirectory() as folder:
            request = {"op": "start", "dataDir": folder,
                       "recipe": json.dumps({"agent": {"name": "test", "provider": "mock"}})}
            result, replies = run_bridge([request, request])
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual([reply["op"] for reply in replies], ["start"])


if __name__ == "__main__":
    unittest.main()

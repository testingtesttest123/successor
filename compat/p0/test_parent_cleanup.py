"""A failed fixture boot must kill and reap the real caller-owned parent.

The daemon cannot exercise its caller's failed-start cleanup, so inject that
failure while retaining a real subprocess and the production fixture method.
"""

import os
import signal
import subprocess
import unittest
from unittest import mock

import test_composition


class ParentCleanup(unittest.TestCase):
    def test_failed_boot_reaps_the_caller_owned_parent(self):
        spawned = []
        real_popen = subprocess.Popen

        def start_parent(*args, **kwargs):
            parent = real_popen(*args, **kwargs)
            spawned.append(parent)
            return parent

        case = test_composition.Composition(
            "test_parent_death_stops_the_actual_fixture_entrypoint"
        )
        try:
            with mock.patch.object(test_composition.subprocess, "Popen", start_parent):
                with mock.patch.object(
                    case, "app", side_effect=RuntimeError("fixture boot failed")
                ):
                    with self.assertRaisesRegex(RuntimeError, "fixture boot failed"):
                        case.test_parent_death_stops_the_actual_fixture_entrypoint()
            self.assertTrue(case.doCleanups())
            self.assertEqual(len(spawned), 1)
            self.assertEqual(spawned[0].returncode, -signal.SIGKILL)
            with self.assertRaises(ChildProcessError):
                os.waitpid(spawned[0].pid, os.WNOHANG)
        finally:
            case.doCleanups()
            for parent in spawned:
                if parent.poll() is None:
                    parent.kill()
                parent.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()

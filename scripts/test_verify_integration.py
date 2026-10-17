"""Exercise source drift and dependency refusals without changing real checkouts."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import verify_integration as verifier


class IntegrationVerificationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        parent = Path(self.temporary.name)
        self.root = parent / "successor"
        self.host = parent / "albedo"
        self.root.mkdir()
        self.host.mkdir()
        self.run_git("init", "-q")
        (self.host / "gleam.toml").write_text('name = "albedo"\n')
        (self.host / "src").mkdir()
        (self.host / "src/albedo.gleam").write_text("pub fn main() { Nil }\n")
        self.run_git("add", ".")
        self.run_git(
            "-c",
            "user.name=Verifier",
            "-c",
            "user.email=verifier@example.invalid",
            "commit",
            "-qm",
            "base",
        )
        self.commit = self.run_git("rev-parse", "HEAD").strip()
        self.base_tree = self.run_git("rev-parse", "HEAD^{tree}").strip()
        (self.host / "src/albedo.gleam").write_text(
            "pub fn main() { Nil } // patched\n"
        )
        (self.root / "gleam.toml").write_text('name = "successor"\n')
        (self.root / "manifest.toml").write_text("packages = []\n")
        self.package = self.root / "packages/successor_extension"
        self.package.mkdir(parents=True)
        (self.package / "gleam.toml").write_text(
            'name = "successor_extension"\n[dependencies]\nalbedo = { path = "../../../albedo" }\n'
        )
        (self.package / "manifest.toml").write_text(
            'packages = [{name="albedo", source="local", path="../../../albedo"}]\n[requirements]\nalbedo = {path="../../../albedo"}\n'
        )
        self.pin = self.root / "pin.json"
        self.refresh_pin()
        self.addCleanup(patch.stopall)
        patch.object(verifier, "ROOT", self.root).start()
        patch.object(verifier, "PIN", self.pin).start()

    def run_git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.host), *args], text=True)

    def refresh_pin(self):
        self.run_git("add", ".")
        source = self.run_git("diff", "--cached", "--binary", "--full-index", "HEAD")
        (self.root / "host.patch").write_text(source)
        self.pin.write_text(
            json.dumps(
                {
                    "commit": self.commit,
                    "base_tree": self.base_tree,
                    "patched_tree": self.run_git("write-tree").strip(),
                    "patches": [
                        {
                            "path": "host.patch",
                            "sha256": hashlib.sha256(source.encode()).hexdigest(),
                        }
                    ],
                }
            )
        )

    def test_matching_worktree_passes_without_changing_index(self):
        before = self.run_git("write-tree")
        self.assertEqual(verifier.verify(self.host)["host_entries"], 2)
        self.assertEqual(before, self.run_git("write-tree"))

    def test_unstaged_source_drift_refuses(self):
        (self.host / "src/albedo.gleam").write_text("changed")
        with self.assertRaisesRegex(ValueError, "host source differs"):
            verifier.verify(self.host)

    def test_executable_mode_drift_refuses(self):
        (self.host / "src/albedo.gleam").chmod(0o755)
        with self.assertRaisesRegex(ValueError, "host mode differs"):
            verifier.verify(self.host)

    def test_extra_source_refuses(self):
        (self.host / "src/extra.gleam").write_text("// extra")
        with self.assertRaisesRegex(ValueError, "extra host source"):
            verifier.verify(self.host)

    def test_staged_extra_root_source_refuses(self):
        folder = self.host / "cli"
        folder.mkdir()
        (folder / "unpinned.go").write_text("package cli\n")
        self.run_git("add", "cli/unpinned.go")
        with self.assertRaisesRegex(ValueError, "extra host source"):
            verifier.verify(self.host)

    def test_extra_cli_test_source_refuses(self):
        folder = self.host / "cli/test/e2e"
        folder.mkdir(parents=True)
        (folder / "unpinned.go").write_text("package e2e\n")
        with self.assertRaisesRegex(ValueError, "extra host source"):
            verifier.verify(self.host)

    def test_extra_host_script_refuses(self):
        folder = self.host / "scripts"
        folder.mkdir()
        (folder / "unpinned.py").write_text("print(1)\n")
        with self.assertRaisesRegex(ValueError, "extra host source"):
            verifier.verify(self.host)

    def test_extra_broken_symlink_refuses(self):
        (self.host / "src/extra.gleam").symlink_to("missing")
        with self.assertRaisesRegex(ValueError, "extra host source"):
            verifier.verify(self.host)

    def test_patch_digest_drift_refuses(self):
        (self.root / "host.patch").write_text("changed")
        with self.assertRaisesRegex(ValueError, "patch digest differs"):
            verifier.verify(self.host)

    def test_wrong_head_refuses(self):
        pin = json.loads(self.pin.read_text())
        pin["commit"] = "0" * 40
        self.pin.write_text(json.dumps(pin))
        with self.assertRaisesRegex(ValueError, "host HEAD differs"):
            verifier.verify(self.host)

    def test_wrong_dependency_target_refuses(self):
        config = self.package / "gleam.toml"
        config.write_text(
            config.read_text().replace("../../../albedo", "../../../archive")
        )
        with self.assertRaisesRegex(ValueError, "actual sibling host"):
            verifier.verify(self.host)

    def test_wrong_manifest_path_refuses(self):
        config = self.package / "manifest.toml"
        config.write_text(
            config.read_text().replace("../../../albedo", "../../../archive")
        )
        with self.assertRaisesRegex(ValueError, "stale local"):
            verifier.verify(self.host)

    def test_reverse_import_refuses_even_if_patch_matches(self):
        (self.host / "src/albedo.gleam").write_text(
            "import successor/personality/ledger\n"
        )
        self.refresh_pin()
        with self.assertRaisesRegex(ValueError, "host imports Successor"):
            verifier.verify(self.host)

    def test_extension_import_of_standalone_refuses(self):
        source = self.package / "src/successor/personality"
        source.mkdir(parents=True)
        (source / "example.gleam").write_text("import successor/runtime\n")
        with self.assertRaisesRegex(ValueError, "extension imports standalone"):
            verifier.verify(self.host)


if __name__ == "__main__":
    unittest.main()

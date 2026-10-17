"""Run product scenarios through the existing host E2E runner and local fakes.

Requires an already frozen/built product snapshot and stock test CLI. This
wrapper neither compiles nor contacts a provider. The host owns daemon/kernel
test processes through its unchanged runner and process_owner helper.
"""

import json
import os
import runpy
import shutil
import sqlite3
import subprocess
import sys
import threading
from contextlib import closing
from pathlib import Path

here = Path(__file__).resolve().parent
root = here.parents[1]
sys.dont_write_bytecode = True
host = Path(os.environ.get("SUCCESSOR_TEST_HOST", root.parent / "albedo")).resolve()
assert os.environ.get("ALBEDO_TEST_DAEMON"), "supply the product snapshot launcher"
assert os.environ.get("ALBEDO_TEST_CLI"), "supply the built stock CLI"
owned = len(sys.argv) > 1 and sys.argv[1] == "--owned"
arguments = sys.argv[2:] if owned else sys.argv[1:]
suite = (
    Path(arguments[0]).resolve() if arguments else here / "e2e/live_identity_test.py"
)
env = dict(os.environ)
env["PYTHONPATH"] = str(suite.parent) + os.pathsep + env.get("PYTHONPATH", "")
env["ALBEDO_NO_BROWSER"] = "1"
env["PYTHONDONTWRITEBYTECODE"] = "1"
if not owned:
    command = [
        sys.executable,
        str(here / "process_owner.py"),
        sys.executable,
        str(Path(__file__).resolve()),
        "--owned",
        str(suite),
    ]
    print("Running", command, flush=True)
    raise SystemExit(subprocess.call(command, cwd=host, env=env))

sys.path.insert(0, str(host / "test/e2e"))
sys.path.insert(0, str(suite.parent))
import harness  # noqa: E402 -- standalone fixture import path is installed above

# Keep complete daemon diagnostics before the unchanged harness removes each
# disposable home. This observes cleanup; it does not change process lifetimes,
# assertion deadlines, provider replies or test isolation.
evidence = Path(os.environ["SUCCESSOR_TEST_EVIDENCE"])
evidence.mkdir(parents=True, exist_ok=False)
lock = threading.Lock()
homes = {}
original_init = harness.Daemon.__init__
original_rmtree = shutil.rmtree


def observed_init(self, *args, **kwargs):
    original_init(self, *args, **kwargs)
    with lock:
        destination = evidence / f"daemon-{len(homes):03d}"
        destination.mkdir()
        homes[str(self.root)] = destination
        (destination / "launch.json").write_text(
            json.dumps(
                {
                    "root": str(self.root),
                    "home": str(self.home),
                    "product_launcher": os.environ["ALBEDO_TEST_DAEMON"],
                    "test_cli": os.environ["ALBEDO_TEST_CLI"],
                    "parent_pid": os.getpid(),
                    "vm_flags": self.env["ERL_FLAGS"],
                },
                indent=2,
            )
            + "\n"
        )


def observed_rmtree(path, *args, **kwargs):
    with lock:
        destination = homes.get(str(path))
    if destination:
        home = Path(path) / "home"
        if (home / "daemon.log").exists():
            shutil.copy2(home / "daemon.log", destination / "daemon.log")
        if (home / "albedo.sqlite").exists():
            # Include committed WAL contents in a consistent read-only snapshot.
            # Copying only the main file loses rows when shutdown leaves a WAL.
            original = (home / "albedo.sqlite").as_uri() + "?mode=ro"
            with (
                closing(sqlite3.connect(original, uri=True)) as source_db,
                closing(sqlite3.connect(destination / "albedo.sqlite")) as saved_db,
            ):
                source_db.backup(saved_db)
    return original_rmtree(path, *args, **kwargs)


harness.Daemon.__init__ = observed_init


class ObservedRemoval:
    avoids_symlink_attacks = original_rmtree.avoids_symlink_attacks

    def __call__(self, path, *args, **kwargs):
        return observed_rmtree(path, *args, **kwargs)


shutil.rmtree = ObservedRemoval()
sys.argv = [str(host / "test/e2e/run.py"), str(suite), "-j", "2", "-x", "2"]
runpy.run_path(str(host / "test/e2e/run.py"), run_name="__main__")

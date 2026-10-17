#!/usr/bin/env python3
"""Prepare missing pinned host and glinter checkouts; never reset existing work."""

import json
import hashlib
from pathlib import Path
import subprocess

from verify_integration import HOST, PIN, ROOT, git, require, verify


def run(cwd: Path, *args: str) -> None:
    subprocess.run(args, cwd=cwd, check=True)


def main() -> None:
    pin = json.loads(PIN.read_text())
    if not HOST.exists():
        run(ROOT.parent, "git", "clone", "--no-checkout", pin["repo"], str(HOST))
        run(HOST, "git", "checkout", "--detach", pin["commit"])
        for patch in pin["patches"]:
            require(
                hashlib.sha256((ROOT / patch["path"]).read_bytes()).hexdigest()
                == patch["sha256"],
                "patch digest differs",
            )
            run(HOST, "git", "apply", "--index", str(ROOT / patch["path"]))
    verify()
    lock = json.loads((HOST / "flake.lock").read_text())["nodes"]["glinter"]["locked"]
    require(lock["type"] == "github", "unsupported glinter lock source")
    location = ROOT / ".cache/static/glinter"
    if not location.exists():
        location.parent.mkdir(parents=True, exist_ok=True)
        run(
            ROOT,
            "git",
            "clone",
            "--no-checkout",
            f"https://github.com/{lock['owner']}/{lock['repo']}.git",
            str(location),
        )
        run(location, "git", "checkout", "--detach", lock["rev"])
    require(
        git(location, "rev-parse", "HEAD").decode().strip() == lock["rev"],
        "glinter pin differs",
    )
    require(
        not git(location, "status", "--porcelain", "--untracked-files=no"),
        "glinter has local source changes",
    )
    run(location, "gleam", "export", "erlang-shipment")


if __name__ == "__main__":
    main()

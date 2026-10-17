#!/usr/bin/env python3
"""Fast current-source static gate; no daemons, browsers or provider requests."""

from __future__ import annotations

import os
import json
from pathlib import Path
import subprocess
import sys

from verify_integration import HOST, ROOT, git, projects, require, verify


def run(cwd: Path, *command: str) -> None:
    print(f"[{cwd.name}] {' '.join(command)}", flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def main() -> None:
    print(verify(), flush=True)
    # Keep analyzer outputs outside the source roots whose exact contents we verify.
    os.environ["RUFF_CACHE_DIR"] = str(ROOT / ".cache/static/ruff")
    # Versions are deliberately shared with the CI job and current host tooling.
    for command, expected in [
        (("gleam", "--version"), "gleam 1.19.0"),
        (("ruff", "--version"), "ruff 0.16.10"),
        (("ty", "--version"), "ty 0.0.85"),
        (("go", "version"), "go version go1.26.8"),
    ]:
        version = subprocess.check_output(command, text=True).strip()
        if version != expected and not version.startswith(expected + " "):
            raise SystemExit(f"expected {expected}, got {version}")
    if sys.version_info[:2] != (3, 11):
        raise SystemExit("static gate requires Python 3.11")
    otp = subprocess.check_output(
        [
            "erl",
            "-noshell",
            "-eval",
            'io:format("~s", [erlang:system_info(otp_release)]), halt().',
        ],
        text=True,
    )
    if otp != "29":
        raise SystemExit(f"expected OTP 29, got {otp}")
    run(
        ROOT,
        sys.executable,
        "-m",
        "unittest",
        "discover",
        "-s",
        "scripts",
        "-p",
        "test_*.py",
    )
    for project in [*projects(), HOST]:
        roots = [name for name in ("src", "test") if (project / name).is_dir()]
        run(project, "gleam", "format", "--check", *roots)
        run(project, "gleam", "check")
    run(ROOT, "ruff", "check")
    run(ROOT, "ruff", "format", "--check")
    run(ROOT, "ty", "check", "--error-on-warning")
    python_scope = (
        'include = ["priv/python/**/*.py", "test/**/*.py", "scripts/**/*.py"]'
    )
    run(HOST, "ruff", "check", "--config", python_scope)
    run(
        HOST,
        "ruff",
        "format",
        "--check",
        "--config",
        python_scope,
        "priv/python",
        "test",
        "scripts",
    )
    run(
        HOST,
        "ty",
        "check",
        "--error-on-warning",
        "--config",
        'src.include = ["priv/python", "test", "scripts"]',
    )
    # Use the host's own maintained strict lint policy, with its exact locked tool.
    glinter = ROOT / ".cache/static/glinter"
    lock = json.loads((HOST / "flake.lock").read_text())["nodes"]["glinter"]["locked"]
    require(
        git(glinter, "rev-parse", "HEAD").decode().strip() == lock["rev"],
        "glinter revision differs",
    )
    require(
        not git(glinter, "status", "--porcelain", "--untracked-files=no"),
        "glinter source changed",
    )
    run(
        HOST,
        str(glinter / "build/erlang-shipment/entrypoint.sh"),
        "run",
        "--project",
        str(HOST),
    )
    run(HOST / "cli/tools/apigen", "go", "run", ".", "-check")
    run(HOST / "cli/tools/apigen", "go", "vet", "./...")
    run(HOST / "cli", "go", "vet", "./...")
    # Verify checks neither changed source nor hid a mismatched generated artifact.
    print(verify(), flush=True)
    print("Static checks passed; runtime/browser/Nix/Rust gates are separate.")


if __name__ == "__main__":
    os.environ.setdefault("ERL_FLAGS", "+S 4:4")
    main()

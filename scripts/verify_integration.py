#!/usr/bin/env python3
"""Verify the current sibling host, cumulative patch and dependency boundaries."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT.parent / "albedo"
PIN = ROOT / "upstream/albedo-current.pin.json"


def git(root: Path, *args: str, env=None) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args], env=env)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def projects() -> list[Path]:
    return [ROOT] + sorted(
        path.parent
        for folder in ("packages", "apps", "compat")
        for path in (ROOT / folder).rglob("gleam.toml")
        if "build" not in path.relative_to(ROOT).parts
    )


def verify(host: Path = HOST) -> dict:
    pin = json.loads(PIN.read_text())
    require(
        git(host, "rev-parse", "HEAD").decode().strip() == pin["commit"],
        "host HEAD differs from current pin",
    )
    require(
        git(host, "rev-parse", "HEAD^{tree}").decode().strip() == pin["base_tree"],
        "host base tree differs",
    )
    # A temporary index reconstructs expectations without trusting or changing
    # the host index/worktree. Git objects written here are local only.
    with tempfile.TemporaryDirectory(prefix="successor-host-index-") as temporary:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(temporary) / "index"))
        git(host, "read-tree", pin["commit"], env=env)
        for patch in pin["patches"]:
            path = ROOT / patch["path"]
            require(path.resolve().is_relative_to(ROOT), "patch outside repository")
            require(
                hashlib.sha256(path.read_bytes()).hexdigest() == patch["sha256"],
                f"patch digest differs: {path}",
            )
            git(host, "apply", "--cached", "--whitespace=error", str(path), env=env)
        tree = git(host, "write-tree", env=env).decode().strip()
    require(tree == pin["patched_tree"], "reconstructed patch tree differs")
    expected = set()
    for entry in filter(None, git(host, "ls-tree", "-r", "-z", tree).split(b"\0")):
        metadata, raw_path = entry.split(b"\t", 1)
        mode, kind, blob = metadata.decode().split()
        relative = os.fsdecode(raw_path)
        expected.add(relative)
        path = host / relative
        require(
            kind == "blob" and mode in {"100644", "100755", "120000"},
            f"unsupported host entry: {relative}",
        )
        if mode == "120000":
            require(path.is_symlink(), f"missing host symlink: {relative}")
            payload = os.fsencode(os.readlink(path))
        else:
            require(
                path.is_file() and not path.is_symlink(),
                f"missing host source: {relative}",
            )
            payload = path.read_bytes()
            require(
                bool(path.stat().st_mode & 0o111) == (mode == "100755"),
                f"host mode differs: {relative}",
            )
        actual = hashlib.sha1(f"blob {len(payload)}\0".encode() + payload).hexdigest()
        require(actual == blob, f"host source differs: {relative}")
        if path.suffix == ".gleam":
            require(
                not re.search(rb"(?m)^\s*import\s+successor(?:[/_\s]|$)", payload),
                f"host imports Successor: {relative}",
            )
    for raw in filter(
        None,
        git(host, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(
            b"\0"
        ),
    ):
        require(os.fsdecode(raw) in expected, f"extra host source: {os.fsdecode(raw)}")
    # Generated binaries/caches may exist, but never extra source modules.
    for folder in (
        "src",
        "test",
        "priv/python",
        "cli/internal",
        "cli/cmd",
        "cli/tools",
        "cli/test",
        "scripts",
        "native/render/src",
    ):
        for path in (host / folder).rglob("*"):
            if (
                path.is_file() or path.is_symlink()
            ) and "__pycache__" not in path.parts:
                require(
                    path.relative_to(host).as_posix() in expected,
                    f"extra host source: {path}",
                )
    host_config = tomllib.loads((host / "gleam.toml").read_text())
    require(
        not any(
            name.startswith("successor")
            for section in ("dependencies", "dev_dependencies")
            for name in host_config.get(section, {})
        ),
        "host depends on Successor",
    )
    for project in projects():
        config = tomllib.loads((project / "gleam.toml").read_text())
        dependencies = config.get("dependencies", {}) | config.get(
            "dev_dependencies", {}
        )
        if project == ROOT:
            require(
                not any(
                    name in dependencies
                    for name in ("albedo", "successor_extension", "successor_daemon")
                ),
                "standalone root depends on integration",
            )
        if project != ROOT:
            require(
                dependencies.get("albedo") == {"path": os.path.relpath(host, project)},
                f"project must depend on actual sibling host: {project}",
            )
        for name, spec in dependencies.items():
            if isinstance(spec, dict) and "path" in spec:
                target = (project / spec["path"]).resolve()
                require(
                    target
                    in {
                        host.resolve(),
                        (ROOT / "packages/successor_extension").resolve(),
                    },
                    f"unexpected local dependency: {project}:{name}",
                )
        if project == ROOT / "packages/successor_extension":
            require(
                not any(
                    name in dependencies for name in ("successor", "successor_daemon")
                ),
                "extension depends on standalone root or daemon",
            )
        if project == ROOT / "apps/successor_daemon":
            require(
                dependencies.get("successor_extension")
                == {"path": "../../packages/successor_extension"},
                "daemon must compose current extension",
            )
        manifest_path = project / "manifest.toml"
        require(manifest_path.is_file(), f"missing lockfile: {project}")
        manifest = tomllib.loads(manifest_path.read_text())
        locked = {package["name"] for package in manifest["packages"]}
        for name, spec in dependencies.items():
            if isinstance(spec, dict) and "path" in spec:
                require(
                    name in locked
                    and manifest.get("requirements", {}).get(name) == spec,
                    f"missing or stale local requirement: {project}:{name}",
                )
        for package in manifest["packages"]:
            if package["name"] in {"albedo", "successor_extension"}:
                target = (
                    host
                    if package["name"] == "albedo"
                    else ROOT / "packages/successor_extension"
                )
                require(
                    package["source"] == "local"
                    and (project / package["path"]).resolve() == target.resolve(),
                    f"stale local manifest dependency: {project}",
                )
    extension = ROOT / "packages/successor_extension/src"
    own_modules = {
        p.relative_to(extension).with_suffix("").as_posix()
        for p in extension.rglob("*.gleam")
    }
    for path in extension.rglob("*.gleam"):
        for imported in re.findall(
            r"(?m)^\s*import\s+(successor[/_][\w/]+)", path.read_text()
        ):
            require(
                imported in own_modules,
                f"extension imports standalone or daemon module: {path}:{imported}",
            )
    return {
        "host_commit": pin["commit"],
        "patched_tree": tree,
        "host_entries": len(expected),
        "projects": [str(p.relative_to(ROOT)) for p in projects()],
    }


if __name__ == "__main__":
    print(json.dumps(verify(), indent=2))

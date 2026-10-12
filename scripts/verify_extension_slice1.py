#!/usr/bin/env python3
"""Read-only source/pin/dependency-boundary checks for the released slice."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "packages/successor_extension"
HOST = PACKAGE / "build/packages/albedo"
BASE = "fb1f4dc4099d915ee926139fc49a5c55bb63eac4"
COMMIT = "e9df547f67f6819ebcd217649be326e53111027c"
TREE = "542057beeeb5eb67edbc3dca260060c12c493679"
REPO = "https://tangled.org/okami.mom/albedo"
REFERENCE = "albedo-personality/src/albedo/harness/extensions/personality/"


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args])


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def reference(path: str) -> str:
    return git(ROOT, "show", f"{BASE}:{REFERENCE}{path}").decode()


def main() -> None:
    pin = json.loads((ROOT / "upstream/albedo.pin.json").read_text())
    require((pin["repo"], pin["commit"], pin["tree"]) == (REPO, COMMIT, TREE),
            "unexpected upstream pin")
    require(pin["compatibility_patches"] == [], "host patches are forbidden")
    config = tomllib.loads((PACKAGE / "gleam.toml").read_text())
    require(config["dependencies"]["albedo"] == {"git": REPO, "ref": COMMIT},
            "package does not use the exact Git dependency")
    require(set(config["dependencies"]) ==
            {"albedo", "gleam_stdlib", "gleam_crypto", "sqlight"},
            "unexpected production dependency")
    manifest = tomllib.loads((PACKAGE / "manifest.toml").read_text())
    host_lock = next(p for p in manifest["packages"] if p["name"] == "albedo")
    require((host_lock["source"], host_lock["repo"], host_lock["commit"]) ==
            ("git", REPO, COMMIT), "manifest host pin differs")
    require(git(HOST, "rev-parse", "HEAD").decode().strip() == COMMIT,
            "downloaded host commit differs")
    require(git(HOST, "rev-parse", "HEAD^{tree}").decode().strip() == TREE,
            "downloaded host tree differs")

    # Hash every tracked entry against the pinned Git objects, including modes.
    host_entries = git(HOST, "ls-tree", "-r", "-z", COMMIT).split(b"\0")
    count = 0
    tracked_host_paths = set()
    for entry in filter(None, host_entries):
        metadata, raw_path = entry.split(b"\t", 1)
        tracked_host_paths.add(raw_path.decode())
        mode, kind, expected_blob = metadata.decode().split()
        path = HOST / raw_path.decode()
        require(kind == "blob" and mode in {"100644", "100755", "120000"},
                f"unsupported pinned source entry: {path}")
        if mode == "120000":
            require(path.is_symlink(), f"missing pinned symlink: {path}")
            payload = os.fsencode(os.readlink(path))
        else:
            require(path.is_file() and not path.is_symlink(), f"missing source: {path}")
            payload = path.read_bytes()
        actual_blob = hashlib.sha1(
            f"blob {len(payload)}\0".encode() + payload
        ).hexdigest()
        require(actual_blob == expected_blob, f"host source differs: {path}")
        if mode != "120000":
            require(bool(path.stat().st_mode & 0o111) == (mode == "100755"),
                    f"host source mode differs: {path}")
        if path.suffix == ".gleam":
            require(not re.search(rb"(?m)^import successor(?:/|\s)", payload),
                    f"host depends on extension: {path}")
        count += 1
    require(count == pin["source_entries"] == 1013, "host entry count differs")
    for folder in ("src", "test", "priv"):
        for path in (HOST / folder).rglob("*"):
            if path.is_file() or path.is_symlink():
                require(str(path.relative_to(HOST)) in tracked_host_paths,
                        f"extra host source entry: {path}")

    production = PACKAGE / "src/successor/personality"
    expected_types = reference("types.gleam")
    expected_domain = reference("domain.gleam").replace(
        "albedo/harness/extensions/personality/types",
        "successor/personality/types",
    )
    # Gleam format sorts the renamed import after the gleam/* imports.
    renamed_import = "import successor/personality/types as p\n"
    expected_domain = expected_domain.replace(renamed_import, "").replace(
        "import gleam/string\n", "import gleam/string\n" + renamed_import,
    )
    schema = reference("migrations/schema.gleam")
    constants = schema[schema.index("const tables ="):schema.index("pub fn apply(")]
    validation = schema[schema.index("pub fn validate("):]
    expected_schema = (
        "import albedo/daemon/store\nimport gleam/dynamic/decode\n"
        "import gleam/list\nimport gleam/result\nimport sqlight\n\n"
        + constants + validation
    ).rstrip() + "\n"
    expected = {"types.gleam": expected_types, "domain.gleam": expected_domain,
                "schema_validation.gleam": expected_schema}
    require({path for path in PACKAGE.joinpath("src").rglob("*")
             if path.is_file() or path.is_symlink()} ==
            {production / name for name in expected}, "production scope expanded")
    for name, content in expected.items():
        require((production / name).read_text() == content,
                f"extraction differs from released reference: {name}")
    for path in list(PACKAGE.joinpath("src").rglob("*.gleam")) + list(
            PACKAGE.joinpath("test").rglob("*.gleam")):
        require(not re.search(r"\bfn\s+apply\s*\(", path.read_text()),
                f"initializer copied into slice: {path}")

    # Existing reference files must remain untouched; only new slice paths vary.
    changed = set(git(ROOT, "diff", "--name-only", BASE).decode().splitlines())
    changed.update(git(ROOT, "ls-files", "--others", "--exclude-standard")
                   .decode().splitlines())
    for path in changed:
        require(path.startswith("packages/successor_extension/") or path in {
            "upstream/albedo.pin.json", "scripts/verify_extension_slice1.py"
        }, f"change outside slice: {path}")
        require(not git(ROOT, "ls-tree", BASE, "--", path),
                f"existing reference path modified: {path}")
    print(json.dumps({"base": BASE, "host_commit": COMMIT, "host_tree": TREE,
                      "host_entries_checked": count, "host_patches": 0,
                      "production_modules": sorted(expected),
                      "extraction": "exact apart from domain import namespace/order and schema subset",
                      "dependency_direction": "extension -> unpatched host",
                      "initializer": "absent", "changed_paths": sorted(changed),
                      "historical_qualification": "FAILED/OPEN"}, indent=2))


if __name__ == "__main__":
    main()

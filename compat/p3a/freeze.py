"""Freeze complete task inputs before compilation; never edit an existing output."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tomllib

parser = argparse.ArgumentParser()
parser.add_argument("worktree", type=Path)
parser.add_argument("authorized_host", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
assert not args.output.exists(), "freeze output must be new"
tree = args.output / "source"
tree.mkdir(parents=True)
def git(root, *argv):
    return subprocess.check_output(["git", "-C", str(root), *argv])
assert git(args.authorized_host, "rev-parse", "HEAD").decode().strip() == "e9df547f67f6819ebcd217649be326e53111027c"
assert git(args.authorized_host, "rev-parse", "HEAD^{tree}").decode().strip() == "542057beeeb5eb67edbc3dca260060c12c493679"
paths = set(git(args.worktree, "ls-files", "-z").split(b"\0"))
paths.update(git(args.worktree, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0"))
assert not any(raw.startswith(b"compat/p3a/fixture_app/build/") for raw in paths), "fixture build cache must be ignored"
for raw in sorted(filter(None, paths)):
    source = args.worktree / os.fsdecode(raw)
    target = tree / os.fsdecode(raw)
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        target.symlink_to(os.readlink(source))
    else:
        shutil.copy2(source, target)
host = tree / "build/upstream/albedo-p0"
host.mkdir(parents=True)
count = 0
for entry in git(args.authorized_host, "ls-tree", "-r", "-z", "HEAD").split(b"\0"):
    if not entry:
        continue
    metadata, raw_path = entry.split(b"\t", 1)
    mode, kind, blob = metadata.decode().split()
    source = args.authorized_host / os.fsdecode(raw_path)
    payload = os.fsencode(os.readlink(source)) if mode == "120000" else source.read_bytes()
    assert kind == "blob" and hashlib.sha1(f"blob {len(payload)}\0".encode() + payload).hexdigest() == blob
    target = host / os.fsdecode(raw_path)
    target.parent.mkdir(parents=True, exist_ok=True)
    if mode == "120000":
        target.symlink_to(os.fsdecode(payload))
    else:
        shutil.copy2(source, target)
        assert bool(target.stat().st_mode & 0o111) == (mode == "100755")
    count += 1
assert count == 1013
series = json.loads((args.worktree / "patches/albedo/series.json").read_text())
for row in series["patches"]:
    patch = args.worktree / "patches/albedo" / row["path"]
    assert hashlib.sha256(patch.read_bytes()).hexdigest() == row["sha256"]
    subprocess.run(["git", "apply", "--check", str(patch)], cwd=host, check=True)
    subprocess.run(["git", "apply", str(patch)], cwd=host, check=True)
fixture = tree / "compat/p3a/fixture_app"
lock = tomllib.loads((fixture / "manifest.toml").read_text())
local = [row for row in lock["packages"] if row["name"] == "albedo"]
assert len(local) == 1 and local[0]["source"] == "local"
assert local[0]["path"] == "../../../build/upstream/albedo-p0", "official lock must resolve inside the frozen export"
assert lock["requirements"]["albedo"]["path"] == local[0]["path"]
manifest = []
for path in sorted(tree.rglob("*")):
    if path.is_symlink():
        payload = os.fsencode(os.readlink(path)); kind = "symlink"
    elif path.is_file():
        payload = path.read_bytes(); kind = "file"
    else:
        continue
    manifest.append({"path": str(path.relative_to(tree)), "kind": kind,
                     "mode": oct(path.lstat().st_mode & 0o777),
                     "sha256": hashlib.sha256(payload).hexdigest()})
(args.output / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
with tarfile.open(args.output / "source.tar", "w") as archive:
    for row in manifest:
        archive.add(tree / row["path"], arcname=row["path"], recursive=False)
print(json.dumps({"host_entries": count, "total_source_entries": len(manifest),
                  "patches_applied": len(series["patches"]), "source": str(tree),
                  "source_tar_sha256": hashlib.sha256((args.output / "source.tar").read_bytes()).hexdigest()}))

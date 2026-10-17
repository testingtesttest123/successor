"""Copy built product code and all host assets into a standalone test snapshot."""

import hashlib
import json
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

source, output = (Path(argument).resolve() for argument in sys.argv[1:3])
assert not output.exists(), "snapshot output must be new"
output.mkdir(parents=True)
if len(sys.argv) > 3:
    shutil.copy2(Path(sys.argv[3]).resolve(), output / "test-cli")
for ebin in sorted((source / "apps/successor_daemon/build/dev/erlang").glob("*/ebin")):
    package = ebin.parent
    target = output / package.name
    shutil.copytree(ebin, target / "ebin")
    if (package / "priv").exists():
        shutil.copytree((package / "priv").resolve(), target / "priv")
assert (output / "successor_daemon/ebin/successor_daemon.app").is_file()
assert (
    output / "successor_extension/ebin/successor@personality@extension.beam"
).is_file()
argv = [str(output / "albedo/priv/bin/albedo-daemon"), "erl", "-pa"]
argv.extend(str(path) for path in sorted(output.glob("*/ebin")))
argv += ["-eval", "successor_daemon@@main:run(successor_daemon)", "-noshell", "-extra"]
launcher = output / "successor-daemon"
launcher.write_text("#!/bin/sh\nexec " + shlex.join(argv) + ' "$@"\n')
launcher.chmod(0o755)
stock_argv = [
    "albedo:main()" if item == "successor_daemon@@main:run(successor_daemon)" else item
    for item in argv
]
stock_launcher = output / "stock-daemon"
stock_launcher.write_text("#!/bin/sh\nexec " + shlex.join(stock_argv) + ' "$@"\n')
stock_launcher.chmod(0o755)
# Preserve the exact source bytes alongside immutable compiled assets. These
# inventories identify local edits as well as the upstream commit.
source_roots = {
    "host": source.parent / "albedo",
    "extension": source / "packages/successor_extension",
    "app": source / "apps/successor_daemon",
    "acceptance": source / "compat/live_identity",
}
source_inventory = {}
for label, tree in source_roots.items():
    source_inventory[label] = {}
    for path in sorted(tree.rglob("*")):
        relative = path.relative_to(tree)
        if any(
            part in {"build", ".git", "__pycache__", "target"}
            for part in relative.parts
        ) or relative.parts[:2] == ("cli", "bin"):
            continue
        if not path.is_file() or path.is_symlink():
            continue
        target = output / "source" / label / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        source_inventory[label][str(relative)] = hashlib.sha256(
            target.read_bytes()
        ).hexdigest()
(output / "source-inventory.json").write_text(
    json.dumps(source_inventory, indent=2) + "\n"
)
git_dir = source_roots["host"] / ".git"
if git_dir.is_file():
    git_dir = (
        source_roots["host"] / git_dir.read_text().strip().removeprefix("gitdir: ")
    ).resolve()
(output / "host-base.txt").write_text(
    subprocess.check_output(
        ["git", "--git-dir", str(git_dir), "rev-parse", "HEAD"],
        text=True,
    )
)
(output / "launch.json").write_text(json.dumps(argv, indent=2) + "\n")

assets = {
    str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted(output.rglob("*"))
    if path.is_file()
}
(output / "assets.json").write_text(json.dumps(assets, indent=2) + "\n")
print(
    json.dumps(
        {
            "entrypoint": "successor_daemon@@main:run(successor_daemon)",
            "packages": len(list(output.glob("*/ebin"))),
            "assets": len(assets),
            "launcher": str(launcher),
        }
    )
)

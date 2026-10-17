"""Copy all compiled dependency code/assets; launch the real consumer entrypoint."""

import hashlib
import json
from pathlib import Path
import shutil
import sys

source, output = map(Path, sys.argv[1:])
assert not output.exists(), "snapshot output must be new"
output.mkdir(parents=True)
for ebin in sorted((source / "compat/p0/fixture_app/build/dev/erlang").glob("*/ebin")):
    package = ebin.parent
    target = output / package.name
    shutil.copytree(ebin, target / "ebin")
    if (package / "priv").exists():
        shutil.copytree((package / "priv").resolve(), target / "priv")
assert (output / "boundary_fixture/ebin/boundary_fixture.app").is_file()
assert (output / "albedo/priv/bin/albedo-daemon").is_file()
argv = [str(output / "albedo/priv/bin/albedo-daemon"), "erl", "-pa"]
argv.extend(str(path) for path in sorted(output.glob("*/ebin")))
argv += ["-eval", "boundary_fixture@@main:run(boundary_fixture)", "-noshell", "-extra"]
assets = {
    str(path.relative_to(output / "albedo/priv")): hashlib.sha256(
        path.read_bytes()
    ).hexdigest()
    for path in sorted((output / "albedo/priv").rglob("*"))
    if path.is_file()
}
(output / "launch.json").write_text(json.dumps(argv, indent=2) + "\n")
(output / "host-assets.json").write_text(json.dumps(assets, indent=2) + "\n")
print(
    json.dumps(
        {
            "entrypoint": "boundary_fixture@@main:run(boundary_fixture)",
            "packages": len(list(output.glob("*/ebin"))),
            "host_assets": len(assets),
            "launcher": argv[0],
        }
    )
)

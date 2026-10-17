"""Run the local main-identity fixture without inheriting provider credentials."""

import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    package = ROOT / "packages" / "successor_extension"
    with tempfile.TemporaryDirectory(prefix="successor-main-identity-") as temporary:
        home = Path(temporary)
        env = {
            name: os.environ[name]
            for name in ("PATH", "SSL_CERT_FILE", "SSL_CERT_DIR")
            if name in os.environ
        }
        env.update(
            HOME=str(home),
            ALBEDO_HOME=str(home / "albedo"),
            ALBEDO_NO_BROWSER="1",
            ERL_FLAGS="+S 4:4",
        )
        for arguments in (
            ["gleam", "check"],
            ["gleam", "test"],
            ["gleam", "format", "--check", "src", "test"],
        ):
            subprocess.run(arguments, cwd=package, env=env, check=True)


if __name__ == "__main__":
    main()

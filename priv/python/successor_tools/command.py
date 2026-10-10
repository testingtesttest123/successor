#!/usr/bin/env python3
"""Exec a command only after its supervising guardian authorizes it.

Successor adapter written for the guardian ABI. The gate-before-exec pattern is
adapted from Albedo process supervision at commit
8920b8a8f4b295be0fde3d20aedf2a3cf5bcd450 (WTFPL v2); no Albedo source copied.
"""
from __future__ import annotations

import argparse
import os
import sys


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--gate-fd", required=True, type=int)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("missing command after --")
    try:
        go = os.read(args.gate_fd, 1)
    except OSError:
        return 125
    finally:
        try:
            os.close(args.gate_fd)
        except OSError:
            pass
    if go != b"G":
        return 125
    try:
        os.execvp(command[0], command)
    except OSError as error:
        print(f"command exec failed: {error}", file=sys.stderr, flush=True)
        return 127


if __name__ == "__main__":
    raise SystemExit(main())

"""Hold one stable workspace runtime lock until the owning Erlang port closes."""
from __future__ import annotations

import fcntl
import json
import os
import struct
import sys
import time


def send(kind: str) -> None:
    payload = json.dumps({"v": 1, "type": kind}, separators=(",", ":")).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(payload)) + payload)
    sys.stdout.buffer.flush()


def markers_clear(directory: str) -> bool:
    """Constant-space fail-closed probe, not a historical status-file scan."""
    try:
        with os.scandir(directory) as entries:
            return next(entries, None) is None
    except OSError:
        return False


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
    os.set_inheritable(fd, False)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            send("lock_busy")
            return 3
        # Job guardians inherit a shared lease before their kernel can die.
        # A replacement must not race still-running commands from the old heap.
        jobs = os.open(os.path.join(os.path.dirname(sys.argv[1]), "jobs.lock"),
                       os.O_RDWR | os.O_CREAT, 0o600)
        os.set_inheritable(jobs, False)
        try:
            try:
                fcntl.flock(jobs, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                send("lock_busy")
                return 3
            active = os.path.join(os.path.dirname(sys.argv[1]), "active-jobs")
            try:
                os.mkdir(active, 0o700)
            except FileExistsError:
                pass
            if not markers_clear(active):
                send("lock_busy")
                return 3
            fcntl.flock(jobs, fcntl.LOCK_UN)
            send("lock_ready")
            # os.read, not BufferedReader.read(n): one-byte release must wake now.
            while True:
                data = os.read(0, 65536)
                if not data or b"Q" in data:
                    break
            deadline = time.monotonic() + 4.5
            while True:
                try:
                    fcntl.flock(jobs, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    clear = markers_clear(active)
                except BlockingIOError:
                    clear = False
                if clear:
                    send("lock_released")
                    return 0
                if time.monotonic() >= deadline:
                    # Leases OR persisted cleanup latches block replacement even
                    # when this bounded wait ends. Never unlink stable locks.
                    send("cleanup_pending")
                    return 4
                time.sleep(0.02)
        finally:
            os.close(jobs)
    finally:
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())

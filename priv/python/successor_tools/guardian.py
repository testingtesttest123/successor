#!/usr/bin/env python3
"""Out-of-process guardian for one successor coding job.

The checked group ownership/termination primitives are copied in ``proc.py``
from Albedo ``priv/python/albedo_proc.py`` at commit
8920b8a8f4b295be0fde3d20aedf2a3cf5bcd450 (WTFPL v2). This adapter is new:
it adds the successor lifetime pipe, shared lease, gate-before-exec protocol,
independent deadline, and atomic bounded status record.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

# ``-I`` intentionally omits the script directory. Trust exactly the directory
# containing this installed helper, not PYTHONPATH or the target's cwd.
_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))
import proc

MAX_STATUS = 8192
POLL_SECONDS = 0.02
TOKEN_WAIT_SECONDS = 0.25


class GateRefused(RuntimeError):
    def __init__(self, reason: str, timed_out: bool = False):
        super().__init__(reason)
        self.reason = reason
        self.timed_out = timed_out


def refuse_if_lifetime_or_deadline(args: argparse.Namespace) -> None:
    if time.monotonic() >= args.deadline:
        raise GateRefused("deadline", timed_out=True)
    readable, _, _ = select.select([args.lifetime_fd], [], [], 0)
    if readable:
        marker = os.read(args.lifetime_fd, 1)
        raise GateRefused("cancelled" if marker == b"S" else "owner_lost")


def status_record(*, state: str, pid: int, leader: str | None,
                  returncode: int | None, timed_out: bool, reason: str,
                  termination: proc.Termination | None) -> dict[str, object]:
    return {"v": 1, "state": state, "pid": pid, "leader": leader,
            "returncode": returncode, "timed_out": timed_out, "reason": reason,
            "termination": None if termination is None else termination.as_json()}


def write_status(path: Path, value: dict[str, object]) -> None:
    payload = (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode()
    if len(payload) > MAX_STATUS:
        raise ValueError("status exceeds 8192 bytes")
    directory = path.parent
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=directory)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(payload)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def cleanup(group: proc.Group) -> proc.Termination:
    return asyncio.run(proc.end(group))


def cleanup_despite_errors(group: proc.Group) -> proc.Termination:
    """Never release the lease merely because a cleanup attempt raised."""
    while True:
        try:
            return cleanup(group)
        except Exception:
            time.sleep(0.25)


def retain_until_gone(group: proc.Group, status: Path, pid: int, leader: str | None,
                      returncode: int | None, timed_out: bool, reason: str,
                      first: proc.Termination) -> proc.Termination:
    """Fail closed: keep the guardian and lease while absence is unproved."""
    ending = first
    while not ending.gone:
        try:
            write_status(status, status_record(
                state="cleanup_uncertain", pid=pid, leader=leader,
                returncode=returncode, timed_out=timed_out, reason=reason,
                termination=ending))
        except Exception:
            # Status is observational; inability to update it cannot release
            # ownership while cleanup is uncertain.
            pass
        time.sleep(0.25)
        ending = cleanup_despite_errors(group)
    return ending



def clear_active_record(path: Path | None, ending: proc.Termination) -> bool:
    """Remove the persistent fence only with fresh checked-gone proof.

    False leaves (or restores) the marker so replacement remains refused. The
    caller still owns the shared lease throughout this removal/fsync attempt.
    """
    if path is None:
        return True  # compatibility for direct low-level fixtures only
    if not ending.gone:
        return False
    directory = path.parent
    try:
        path.unlink()
    except FileNotFoundError:
        return True
    except OSError:
        return False
    try:
        directory_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        return True
    except OSError:
        # The unlink is not durably established. Restore a visible fence before
        # allowing the guardian lease to close. If restoration itself cannot be
        # established, remain alive with the lease rather than create a gap.
        while True:
            try:
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                return False
            except OSError:
                time.sleep(0.25)
                continue
            try:
                os.write(fd, b"cleanup fence retained after fsync failure\n")
                os.fsync(fd)
            except OSError:
                pass
            finally:
                os.close(fd)
            return False

def run(args: argparse.Namespace) -> int:
    # Merely retaining this inherited descriptor retains the caller's shared OFD
    # lock. Never unlock it: close/exit is the only release.
    os.fstat(args.lease_fd)
    if args.active_record is not None:
        os.stat(args.active_record)  # JobRuntime must create the fence first.
    gate_read, gate_write = os.pipe()
    target: subprocess.Popen[bytes] | None = None
    group: proc.Group | None = None
    leader: str | None = None
    try:
        command_path = Path(__file__).with_name("command.py")
        target = subprocess.Popen(
            [sys.executable, "-I", "-u", str(command_path), "--gate-fd", str(gate_read), "--", *args.command],
            stdin=sys.stdin.buffer, stdout=sys.stdout.buffer, stderr=sys.stderr.buffer,
            close_fds=True, pass_fds=(gate_read,), start_new_session=True,
        )
        os.close(gate_read)
        gate_read = -1
        token_deadline = min(args.deadline, time.monotonic() + TOKEN_WAIT_SECONDS)
        while leader is None:
            if target.poll() is not None:
                raise RuntimeError("gated target exited before identity capture")
            leader = proc.leader_token(target.pid)
            if leader is None:
                refuse_if_lifetime_or_deadline(args)
                if time.monotonic() >= token_deadline:
                    raise RuntimeError("cannot establish target start token")
                time.sleep(0.001)
        group = proc.Group(target.pid, leader)
        # Check owner/deadline both before and after the low-level gate status
        # write. A close already observable before G must have zero user effect.
        refuse_if_lifetime_or_deadline(args)
        # This is only the process gate status, not the canonical SQL receipt.
        # If its atomic write fails, closing the gate refuses user argv.
        write_status(args.status, status_record(
            state="running", pid=target.pid, leader=leader, returncode=None,
            timed_out=False, reason="running", termination=None))
        refuse_if_lifetime_or_deadline(args)
        os.write(gate_write, b"G")
        os.close(gate_write)
        gate_write = -1

        reason = "exited"
        timed_out = False
        while True:
            returncode = target.poll()
            if returncode is not None:
                reason = "exited"
                break
            remaining = args.deadline - time.monotonic()
            if remaining <= 0:
                reason, timed_out = "deadline", True
                returncode = None
                break
            readable, _, _ = select.select([args.lifetime_fd], [], [], min(POLL_SECONDS, remaining))
            if readable:
                marker = os.read(args.lifetime_fd, 1)
                reason = "cancelled" if marker == b"S" else "owner_lost"
                returncode = target.poll()
                break

        ending = cleanup_despite_errors(group)
        target.poll()
        final_code = target.returncode if target.returncode is not None else returncode
        if not ending.gone:
            ending = retain_until_gone(group, args.status, target.pid, leader,
                                       final_code, timed_out, reason, ending)
        target.poll()
        final_code = target.returncode if target.returncode is not None else final_code
        write_status(args.status, status_record(
            state="terminated", pid=target.pid, leader=leader,
            returncode=final_code, timed_out=timed_out, reason=reason,
            termination=ending))
        clear_active_record(args.active_record, ending)
        return 0
    except BaseException as error:
        if target is None:
            # No target could have escaped; a synthetic gone proof permits the
            # precreated marker to be removed before the lease is released.
            clear_active_record(
                args.active_record,
                proc.Termination(None, (), True, (), "target was not created"),
            )
            raise
        try:
            os.close(gate_write)
        except OSError:
            pass
        # Authorized or not, prove the newly-created group gone before releasing
        # the lease. Before G this also proves zero user-program effect.
        # Once captured, never replace the start token: a later lookup could
        # identify a reused PID rather than the group we created.
        if group is None:
            group = proc.Group(target.pid, None)
        ending = cleanup_despite_errors(group)
        target.poll()
        error_reason = (
            error.reason if isinstance(error, GateRefused)
            else f"guardian_error:{type(error).__name__}"
        )
        error_timed_out = isinstance(error, GateRefused) and error.timed_out
        if not ending.gone:
            ending = retain_until_gone(
                group, args.status, target.pid, leader, target.returncode,
                error_timed_out, error_reason, ending)
        target.poll()
        # A checked pre-G refusal is a real terminal process fact too. Publishing
        # it lets immediate cancellation remain known; status-write failures may
        # still leave no record and are therefore unknown to the caller.
        try:
            write_status(args.status, status_record(
                state="terminated", pid=target.pid, leader=leader,
                returncode=target.returncode, timed_out=error_timed_out,
                reason=error_reason, termination=ending))
        except Exception:
            pass
        clear_active_record(args.active_record, ending)
        return 126
    finally:
        for fd in (gate_read, gate_write, args.lifetime_fd, args.lease_fd):
            try:
                os.close(fd)
            except OSError:
                pass


def parse(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--lifetime-fd", required=True, type=int)
    parser.add_argument("--lease-fd", required=True, type=int)
    parser.add_argument("--status", required=True, type=Path)
    parser.add_argument("--active-record", type=Path)
    parser.add_argument("--deadline", required=True, type=float)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("missing command after --")
    if not math.isfinite(args.deadline):
        parser.error("deadline must be finite")
    return args


def main(argv: list[str] | None = None) -> int:
    return run(parse(argv))


if __name__ == "__main__":
    raise SystemExit(main())
